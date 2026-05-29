defmodule ImagePipe.Output.PolicyTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Output.Policy
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Plan.Output

  describe "from_output_plan/3" do
    test "automatic output policy exposes Vary Accept and selected candidates from Accept" do
      conn =
        :get
        |> conn("/image")
        |> put_req_header("accept", "image/webp,image/avif;q=0.1")

      policy = Policy.from_output_plan(conn, %Output{mode: :automatic}, [])

      assert policy.headers == [{"vary", "Accept"}]
      assert policy.modern_candidates == [:avif, :webp]
    end

    test "represents explicit output independently of Accept" do
      conn =
        :get
        |> conn("/_/f:webp/plain/images/cat.jpg")
        |> put_req_header("accept", "image/jpeg")

      assert Policy.from_output_plan(conn, %Output{mode: {:explicit, :webp}}, []) ==
               %Policy{
                 mode: {:explicit, :webp},
                 modern_candidates: [],
                 headers: [],
                 quality: :default,
                 format_qualities: %{}
               }
    end

    test "represents automatic output as source mode plus modern candidates" do
      conn =
        :get
        |> conn("/_/plain/images/cat.jpg")
        |> put_req_header("accept", "image/webp;q=1,image/avif;q=0.1")

      assert Policy.from_output_plan(conn, %Output{mode: :automatic}, []) ==
               %Policy{
                 mode: :source,
                 modern_candidates: [:avif, :webp],
                 headers: [{"vary", "Accept"}],
                 quality: :default,
                 format_qualities: %{}
               }
    end

    test "keeps automatic Vary when Accept has no modern format signal" do
      cases = [
        conn(:get, "/_/plain/images/cat.jpg"),
        conn(:get, "/_/plain/images/cat.jpg") |> put_req_header("accept", ""),
        conn(:get, "/_/plain/images/cat.jpg") |> put_req_header("accept", "*/*"),
        conn(:get, "/_/plain/images/cat.jpg") |> put_req_header("accept", "*/*;q=1"),
        conn(:get, "/_/plain/images/cat.jpg")
        |> put_req_header("accept", "application/json,*/*;q=1")
      ]

      for conn <- cases do
        assert %Policy{
                 mode: :source,
                 modern_candidates: [],
                 headers: [{"vary", "Accept"}],
                 quality: :default,
                 format_qualities: %{}
               } = Policy.from_output_plan(conn, %Output{mode: :automatic}, [])
      end
    end
  end

  describe "resolve/2" do
    test "selects explicit format before source fetch" do
      policy = %Policy{
        mode: {:explicit, :png},
        modern_candidates: [],
        headers: [],
        quality: :default,
        format_qualities: %{}
      }

      assert Policy.resolve(policy, nil) ==
               {:ok,
                %Resolved{
                  format: :png,
                  quality: :default,
                  response_headers: []
                }}
    end

    test "selects modern automatic format before source fetch" do
      policy = %Policy{
        mode: :source,
        modern_candidates: [:avif, :webp],
        headers: [{"vary", "Accept"}],
        quality: :default,
        format_qualities: %{}
      }

      assert Policy.resolve(policy, nil) ==
               {:ok,
                %Resolved{
                  format: :avif,
                  quality: :default,
                  response_headers: [{"vary", "Accept"}]
                }}
    end

    test "requires source format when automatic output has no modern candidate" do
      policy = %Policy{
        mode: :source,
        modern_candidates: [],
        headers: [{"vary", "Accept"}],
        quality: :default,
        format_qualities: %{}
      }

      assert Policy.resolve(policy, nil) == {:error, :source_format_required}
    end

    test "uses source format without strict Accept rejection" do
      policy = %Policy{
        mode: :source,
        modern_candidates: [],
        headers: [{"vary", "Accept"}],
        quality: :default,
        format_qualities: %{}
      }

      assert Policy.resolve(policy, :png) ==
               {:ok,
                %Resolved{
                  format: :png,
                  quality: :default,
                  response_headers: [{"vary", "Accept"}]
                }}

      assert Policy.resolve(policy, :jpeg) ==
               {:ok,
                %Resolved{
                  format: :jpeg,
                  quality: :default,
                  response_headers: [{"vary", "Accept"}]
                }}
    end

    test "transcodes modern source formats to raster when no modern format is accepted" do
      policy = %Policy{
        mode: :source,
        modern_candidates: [],
        headers: [{"vary", "Accept"}],
        quality: :default,
        format_qualities: %{}
      }

      assert Policy.resolve(policy, :webp) == {:needs_final_image_alpha, :source}
      assert Policy.resolve(policy, :avif) == {:needs_final_image_alpha, :source}
    end

    test "defers source-only fallback until final image alpha is known" do
      policy = %Policy{
        mode: :source,
        modern_candidates: [],
        headers: [{"vary", "Accept"}],
        quality: :default,
        format_qualities: %{}
      }

      assert Policy.resolve(policy, :heif) == {:needs_final_image_alpha, :source}
      assert Policy.resolve(policy, :tiff) == {:needs_final_image_alpha, :source}

      assert Policy.resolve(policy, :jpeg2000) ==
               {:needs_final_image_alpha, :source}

      assert Policy.resolve(policy, :jpeg_xl) == {:needs_final_image_alpha, :source}
    end
  end

  describe "resolve_final_image_alpha/2" do
    test "selects png when final image has alpha" do
      policy = %Policy{
        mode: :source,
        modern_candidates: [],
        headers: [{"vary", "Accept"}],
        quality: :default,
        format_qualities: %{}
      }

      assert Policy.resolve_final_image_alpha(policy, true) ==
               %Resolved{
                 format: :png,
                 quality: :default,
                 response_headers: [{"vary", "Accept"}]
               }
    end

    test "selects jpeg when final image has no alpha" do
      policy = %Policy{
        mode: :source,
        modern_candidates: [],
        headers: [{"vary", "Accept"}],
        quality: :default,
        format_qualities: %{}
      }

      assert Policy.resolve_final_image_alpha(policy, false) ==
               %Resolved{
                 format: :jpeg,
                 quality: :default,
                 response_headers: [{"vary", "Accept"}]
               }
    end

    test "applies quality for selected alpha fallback format" do
      policy = %Policy{
        mode: :source,
        modern_candidates: [],
        headers: [{"vary", "Accept"}],
        quality: :default,
        format_qualities: %{jpeg: {:quality, 82}, png: {:quality, 70}}
      }

      assert Policy.resolve_final_image_alpha(policy, false) ==
               %Resolved{
                 format: :jpeg,
                 quality: {:quality, 82},
                 response_headers: [{"vary", "Accept"}]
               }

      assert Policy.resolve_final_image_alpha(policy, true) ==
               %Resolved{
                 format: :png,
                 quality: {:quality, 70},
                 response_headers: [{"vary", "Accept"}]
               }
    end
  end

  describe "quality resolution" do
    test "explicit global quality wins over matching format quality regardless of URL order" do
      plan = %Output{
        mode: {:explicit, :webp},
        quality: {:quality, 80},
        format_qualities: %{webp: {:quality, 70}}
      }

      policy = Policy.from_output_plan(conn(:get, "/image"), plan, [])

      assert Policy.resolve(policy, :jpeg) ==
               {:ok,
                %Resolved{
                  format: :webp,
                  quality: {:quality, 80},
                  response_headers: []
                }}
    end

    test "format quality supplies default only when global quality is default" do
      plan = %Output{
        mode: {:explicit, :webp},
        quality: :default,
        format_qualities: %{webp: {:quality, 70}}
      }

      policy = Policy.from_output_plan(conn(:get, "/image"), plan, [])

      assert Policy.resolve(policy, :jpeg) ==
               {:ok,
                %Resolved{
                  format: :webp,
                  quality: {:quality, 70},
                  response_headers: []
                }}
    end
  end

  describe "ensure_capable/2" do
    test "rejects an explicit format the build cannot write" do
      policy = %Policy{
        mode: {:explicit, :avif},
        modern_candidates: [],
        headers: [],
        quality: :default,
        format_qualities: %{}
      }

      assert Policy.ensure_capable(policy, output_capabilities: %{avif: false}) ==
               {:error, {:unsupported_output_format, :avif}}
    end

    test "allows a supported explicit format" do
      policy = %Policy{
        mode: {:explicit, :avif},
        modern_candidates: [],
        headers: [],
        quality: :default,
        format_qualities: %{}
      }

      assert Policy.ensure_capable(policy, output_capabilities: %{avif: true}) == :ok
    end

    test "automatic mode is always capable (resolution handles fallback)" do
      policy = %Policy{
        mode: :source,
        modern_candidates: [],
        headers: [{"vary", "Accept"}],
        quality: :default,
        format_qualities: %{}
      }

      assert Policy.ensure_capable(policy, output_capabilities: %{avif: false}) == :ok
    end
  end
end
