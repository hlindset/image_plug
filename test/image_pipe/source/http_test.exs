defmodule ImagePipe.Source.HTTPTest do
  use ExUnit.Case, async: false

  alias ImagePipe.Plan.Source.URL
  alias ImagePipe.Source
  alias ImagePipe.Source.HTTP
  alias ImagePipe.Source.Resolved
  alias ImagePipe.Source.Response

  test "http source defaults to not stable and disables internal cache in auto mode" do
    assert {:ok, opts} = HTTP.validate_options(allowed_hosts: ["example.com"])
    source = %URL{scheme: :https, host: "example.com", path: ["cat.jpg"]}

    assert {:ok, resolved} = HTTP.resolve(source, opts, [])

    assert resolved.internal_cache == :disabled
    assert resolved.cache_semantics.byte_identity == :none
  end

  test "http trusted byte identity doesn't expose raw query" do
    assert {:ok, opts} = HTTP.validate_options(allowed_hosts: ["example.com"], stable: :trusted)

    source = %URL{
      scheme: :https,
      host: "example.com",
      path: ["cat.jpg"],
      query: "X-Amz-Signature=secret"
    }

    assert {:ok, resolved} = HTTP.resolve(source, opts, [])
    assert {:strong, seed} = resolved.cache_semantics.byte_identity
    refute inspect(seed) =~ "X-Amz-Signature=secret"
    assert is_binary(seed[:query_sha256])
  end

  test "resolve normalizes URL identity and enforces allowed hosts" do
    assert {:ok, opts} = HTTP.validate_options(allowed_hosts: ["assets.example.com"])

    source = %URL{
      scheme: :https,
      host: "assets.example.com",
      port: nil,
      path: ["images", "cat.jpg"],
      query: "v=1"
    }

    assert {:ok, %Resolved{} = resolved} = HTTP.resolve(source, opts, [])
    assert resolved.adapter == :https
    assert resolved.source_kind == :url

    assert resolved.identity == [
             kind: :url,
             adapter: :https,
             scheme: :https,
             host: "assets.example.com",
             port: 443,
             path: ["images", "cat.jpg"],
             query: "v=1"
           ]

    denied = %URL{source | host: "evil.example"}
    assert HTTP.resolve(denied, opts, []) == {:error, {:source, :denied_host}}
  end

  test "resolve lowercases URL hosts before allowed-host checks and cache identity" do
    assert {:ok, opts} = HTTP.validate_options(allowed_hosts: ["assets.example.com"])

    source = %URL{
      scheme: :https,
      host: "Assets.Example.Com",
      port: nil,
      path: ["cat.jpg"],
      query: nil
    }

    assert {:ok, %Resolved{} = resolved} = HTTP.resolve(source, opts, [])
    assert resolved.identity[:host] == "assets.example.com"
  end

  test "resolve honors HTTP internal cache disabled option" do
    assert {:ok, opts} =
             HTTP.validate_options(
               allowed_hosts: ["assets.example.com"],
               internal_cache: :disabled
             )

    source = %URL{
      scheme: :https,
      host: "assets.example.com",
      port: nil,
      path: ["cat.jpg"],
      query: nil
    }

    assert {:ok, %Resolved{} = resolved} = HTTP.resolve(source, opts, [])
    assert resolved.internal_cache == :disabled
  end

  test "fetch creates a Req-backed lazy stream and preserves safe request options" do
    plug = fn conn -> Plug.Conn.send_resp(conn, 200, "image bytes") end

    source = %URL{
      scheme: :https,
      host: "assets.example.com",
      port: nil,
      path: ["cat.jpg"],
      query: nil
    }

    assert {:ok, opts} =
             HTTP.validate_options(
               allowed_hosts: ["assets.example.com"],
               req_options: [plug: plug]
             )

    assert {:ok, resolved} = HTTP.resolve(source, opts, [])

    assert {:ok, %Response{} = response} =
             Source.fetch(resolved, [sources: %{https: {HTTP, opts}}], max_body_bytes: 20)

    assert Enum.join(response.stream) == "image bytes"
  end

  test "req options cannot override adapter request controls" do
    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        self(),
        {:http_request, conn.method, conn.req_headers, conn.request_path, conn.query_string, body}
      )

      Plug.Conn.send_resp(conn, 200, "image bytes")
    end

    source = %URL{
      scheme: :https,
      host: "assets.example.com",
      port: nil,
      path: ["cat.jpg"],
      query: nil
    }

    assert {:ok, opts} =
             HTTP.validate_options(
               allowed_hosts: ["assets.example.com"],
               internal_cache: :enabled,
               req_options: [
                 plug: plug,
                 url: "https://evil.example/other.jpg",
                 base_url: "https://evil.example",
                 method: :post,
                 body: "not image",
                 params: [v: "evil"],
                 headers: [
                   {"Host", "evil.example"},
                   {"Range", "bytes=0-1"},
                   {"Accept", "application/json"},
                   {"x-extra", "kept"}
                 ],
                 into: :self,
                 retry: true,
                 max_redirects: 10
               ]
             )

    assert {:ok, resolved} = HTTP.resolve(source, opts, [])

    assert {:ok, %Response{} = response} =
             Source.fetch(resolved, [sources: %{https: {HTTP, opts}}], max_body_bytes: 20)

    assert Enum.join(response.stream) == "image bytes"
    assert_receive {:http_request, "GET", headers, "/cat.jpg", "", ""}

    assert {_name, "kept"} =
             Enum.find(headers, fn {name, _value} -> String.downcase(name) == "x-extra" end)

    refute Enum.any?(headers, fn {name, value} ->
             String.downcase(name) in ["host", "range", "accept", "accept-encoding"] and
               value in ["evil.example", "bytes=0-1", "application/json"]
           end)
  end

  test "trusted byte identity strips byte-changing headers even when internal cache is disabled" do
    plug = fn conn ->
      send(self(), {:http_request, conn.req_headers})
      Plug.Conn.send_resp(conn, 200, "image bytes")
    end

    source = %URL{
      scheme: :https,
      host: "assets.example.com",
      port: nil,
      path: ["cat.jpg"],
      query: nil
    }

    assert {:ok, opts} =
             HTTP.validate_options(
               allowed_hosts: ["assets.example.com"],
               stable: :trusted,
               internal_cache: :disabled,
               req_options: [
                 plug: plug,
                 headers: [
                   {"Range", "bytes=0-1"},
                   {"Accept", "application/json"},
                   {"Accept-Encoding", "gzip"},
                   {"x-extra", "kept"}
                 ]
               ]
             )

    assert {:ok, resolved} = HTTP.resolve(source, opts, [])

    assert {:ok, %Response{} = response} =
             Source.fetch(resolved, [sources: %{https: {HTTP, opts}}], max_body_bytes: 20)

    assert Enum.join(response.stream) == "image bytes"
    assert_receive {:http_request, headers}

    assert {_name, "kept"} =
             Enum.find(headers, fn {name, _value} -> String.downcase(name) == "x-extra" end)

    refute Enum.any?(headers, fn {name, _value} ->
             String.downcase(name) in ["range", "accept", "accept-encoding"]
           end)
  end

  test "configured max redirects allows bounded redirects" do
    plug = fn
      %{request_path: "/redirect.jpg"} = conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "/other.jpg")
        |> Plug.Conn.send_resp(302, "")

      conn ->
        send(self(), {:http_request, conn.request_path})
        Plug.Conn.send_resp(conn, 200, "image bytes")
    end

    source = %URL{
      scheme: :https,
      host: "assets.example.com",
      port: nil,
      path: ["redirect.jpg"],
      query: nil
    }

    assert {:ok, opts} =
             HTTP.validate_options(
               allowed_hosts: ["assets.example.com"],
               max_redirects: 1,
               req_options: [plug: plug]
             )

    assert {:ok, resolved} = HTTP.resolve(source, opts, [])

    assert {:ok, %Response{} = response} =
             Source.fetch(resolved, [sources: %{https: {HTTP, opts}}], max_body_bytes: 20)

    assert Enum.join(response.stream) == "image bytes"
    assert_receive {:http_request, "/other.jpg"}
  end

  test "req options cannot override redirect policy" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://assets.example.com/other.jpg")
      |> Plug.Conn.send_resp(302, "")
    end

    source = %URL{
      scheme: :https,
      host: "assets.example.com",
      port: nil,
      path: ["redirect.jpg"],
      query: nil
    }

    assert {:ok, opts} =
             HTTP.validate_options(
               allowed_hosts: ["assets.example.com"],
               req_options: [plug: plug, max_redirects: 10]
             )

    assert {:ok, resolved} = HTTP.resolve(source, opts, [])

    assert {:ok, %Response{} = response} =
             Source.fetch(resolved, [sources: %{https: {HTTP, opts}}], max_body_bytes: 20)

    error = assert_raise Source.StreamError, fn -> Enum.to_list(response.stream) end
    assert error.reason == :bad_status
  end

  test "fetch percent-encodes decoded path segments when building the request URL" do
    plug = fn conn ->
      send(self(), {:http_request, conn.request_path, conn.query_string})
      Plug.Conn.send_resp(conn, 200, "image bytes")
    end

    source = %URL{
      scheme: :https,
      host: "assets.example.com",
      port: nil,
      path: ["images", "cat#one%two space?.jpg"],
      query: "v=a%26b%3Dc"
    }

    assert {:ok, opts} =
             HTTP.validate_options(
               allowed_hosts: ["assets.example.com"],
               req_options: [plug: plug]
             )

    assert {:ok, resolved} = HTTP.resolve(source, opts, [])

    assert {:ok, %Response{} = response} =
             Source.fetch(resolved, [sources: %{https: {HTTP, opts}}], max_body_bytes: 20)

    assert Enum.join(response.stream) == "image bytes"
    assert_receive {:http_request, "/images/cat%23one%25two%20space%3F.jpg", "v=a%26b%3Dc"}
  end

  test "fetch brackets IPv6 literals when building the request URL" do
    plug = fn conn ->
      send(self(), {:http_request, conn.host, conn.request_path, conn.query_string})
      Plug.Conn.send_resp(conn, 200, "image bytes")
    end

    source = %URL{
      scheme: :http,
      host: "::1",
      port: 8080,
      path: ["cat.jpg"],
      query: "v=1"
    }

    assert {:ok, opts} =
             HTTP.validate_options(
               allowed_hosts: ["::1"],
               req_options: [plug: plug]
             )

    assert {:ok, resolved} = HTTP.resolve(source, opts, [])

    assert resolved.fetch[:url] == "http://[::1]:8080/cat.jpg?v=1"

    assert {:ok, %Response{} = response} =
             Source.fetch(resolved, [sources: %{http: {HTTP, opts}}], max_body_bytes: 20)

    assert Enum.join(response.stream) == "image bytes"
    assert_receive {:http_request, "::1", "/cat.jpg", "v=1"}
  end

  test "non-success statuses and transport failures are deferred safe stream errors" do
    plug = fn conn -> Plug.Conn.send_resp(conn, 404, "not found") end

    source = %URL{
      scheme: :https,
      host: "assets.example.com",
      port: nil,
      path: ["missing.jpg"],
      query: nil
    }

    assert {:ok, opts} =
             HTTP.validate_options(
               allowed_hosts: ["assets.example.com"],
               req_options: [plug: plug]
             )

    assert {:ok, resolved} = HTTP.resolve(source, opts, [])

    assert {:ok, %Response{} = response} =
             Source.fetch(resolved, [sources: %{https: {HTTP, opts}}], max_body_bytes: 20)

    error = assert_raise Source.StreamError, fn -> Enum.to_list(response.stream) end
    assert error.reason == :bad_status
  end

  test "redirects cannot bypass allowed host policy" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://evil.example/cat.jpg")
      |> Plug.Conn.send_resp(302, "")
    end

    source = %URL{
      scheme: :https,
      host: "assets.example.com",
      port: nil,
      path: ["redirect.jpg"],
      query: nil
    }

    assert {:ok, opts} =
             HTTP.validate_options(
               allowed_hosts: ["assets.example.com"],
               req_options: [plug: plug]
             )

    assert {:ok, resolved} = HTTP.resolve(source, opts, [])

    assert {:ok, %Response{} = response} =
             Source.fetch(resolved, [sources: %{https: {HTTP, opts}}], max_body_bytes: 20)

    error = assert_raise Source.StreamError, fn -> Enum.to_list(response.stream) end
    assert error.reason == :bad_status
  end
end
