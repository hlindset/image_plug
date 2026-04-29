defmodule ImagePlug.Cache.EntryTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Cache.Entry

  test "builds an entry and normalizes allowlisted response headers" do
    created_at = ~U[2026-04-29 10:15:00Z]

    entry =
      Entry.new!(
        body: "encoded image",
        content_type: "image/webp",
        headers: [
          {"Vary", "Accept"},
          {"cache-control", "public, max-age=60"},
          {"connection", "close"},
          {"x-request-id", "abc123"}
        ],
        created_at: created_at
      )

    assert entry.body == "encoded image"
    assert entry.content_type == "image/webp"
    assert entry.headers == [{"vary", "Accept"}, {"cache-control", "public, max-age=60"}]
    assert entry.created_at == created_at
  end

  test "preserves duplicate allowed headers in input order" do
    entry =
      Entry.new!(
        body: <<1, 2, 3>>,
        content_type: "image/png",
        headers: [
          {"Vary", "Accept"},
          {"vary", "Origin"},
          {"Cache-Control", "public"},
          {"cache-control", "max-age=60"}
        ],
        created_at: ~U[2026-04-29 10:15:00Z]
      )

    assert entry.headers == [
             {"vary", "Accept"},
             {"vary", "Origin"},
             {"cache-control", "public"},
             {"cache-control", "max-age=60"}
           ]
  end

  test "drops response headers outside the cache allowlist case-insensitively" do
    entry =
      Entry.new!(
        body: <<1, 2, 3>>,
        content_type: "image/png",
        headers: [{"Set-Cookie", "secret"}, {"VARY", "Accept"}],
        created_at: ~U[2026-04-29 10:15:00Z]
      )

    assert entry.headers == [{"vary", "Accept"}]
  end

  test "normalizes content type before storing" do
    entry =
      Entry.new!(
        body: <<1, 2, 3>>,
        content_type: " Image/WEBP ",
        headers: [],
        created_at: ~U[2026-04-29 10:15:00Z]
      )

    assert entry.content_type == "image/webp"
  end

  test "rejects invalid entry fields" do
    valid_attrs = [
      body: <<1, 2, 3>>,
      content_type: "image/png",
      headers: [],
      created_at: DateTime.utc_now()
    ]

    assert {:error, {:invalid_attrs, :not_attrs}} = Entry.new(:not_attrs)

    assert {:error, {:invalid_body, :not_binary}} =
             Entry.new(
               body: :not_binary,
               content_type: "image/webp",
               headers: [],
               created_at: DateTime.utc_now()
             )

    assert {:error, {:invalid_content_type, ""}} =
             valid_attrs
             |> Keyword.put(:content_type, "")
             |> Entry.new()

    assert {:error, {:invalid_content_type, "   "}} =
             valid_attrs
             |> Keyword.put(:content_type, "   ")
             |> Entry.new()

    assert {:error, {:invalid_content_type, :png}} =
             valid_attrs
             |> Keyword.put(:content_type, :png)
             |> Entry.new()

    assert {:error, {:invalid_headers, :not_headers}} =
             valid_attrs
             |> Keyword.put(:headers, :not_headers)
             |> Entry.new()

    assert {:error, {:invalid_headers, [{"vary", :not_binary}]}} =
             valid_attrs
             |> Keyword.put(:headers, [{"vary", :not_binary}])
             |> Entry.new()

    for invalid_header_value <- ["Accept\r\nSet-Cookie: session=1", "public\nmax-age=60", <<0>>] do
      headers = [{"Vary", invalid_header_value}]

      assert {:error, {:invalid_headers, ^headers}} =
               valid_attrs
               |> Keyword.put(:headers, headers)
               |> Entry.new()
    end

    for invalid_header_name <- ["", "bad header", "vary:"] do
      headers = [{invalid_header_name, "value"}]

      assert {:error, {:invalid_headers, ^headers}} =
               valid_attrs
               |> Keyword.put(:headers, headers)
               |> Entry.new()
    end

    assert {:error, {:invalid_created_at, ~N[2026-04-29 10:15:00]}} =
             valid_attrs
             |> Keyword.put(:created_at, ~N[2026-04-29 10:15:00])
             |> Entry.new()

    for required_field <- [:body, :content_type, :headers, :created_at] do
      assert {:error, {:missing_required_field, ^required_field}} =
               valid_attrs
               |> Keyword.delete(required_field)
               |> Entry.new()
    end

    assert_raise ArgumentError, fn ->
      Entry.new!(
        body: :not_binary,
        content_type: "image/webp",
        headers: [],
        created_at: DateTime.utc_now()
      )
    end
  end
end
