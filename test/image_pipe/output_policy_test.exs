defmodule ImagePipe.Output.PolicyTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Output.Policy
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Plan.Output

  describe "from_output_plan/3" do
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

    test "keeps source format fallback for output-capable source families" do
      policy = %Policy{
        mode: :source,
        modern_candidates: [],
        headers: [{"vary", "Accept"}],
        quality: :default,
        format_qualities: %{}
      }

      assert Policy.resolve(policy, :webp) ==
               {:ok,
                %Resolved{
                  format: :webp,
                  quality: :default,
                  response_headers: [{"vary", "Accept"}]
                }}

      assert Policy.resolve(policy, :avif) ==
               {:ok,
                %Resolved{
                  format: :avif,
                  quality: :default,
                  response_headers: [{"vary", "Accept"}]
                }}
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
end
