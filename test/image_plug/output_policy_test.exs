defmodule ImagePlug.Output.PolicyTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePlug.Output.Policy
  alias ImagePlug.Output.Resolved
  alias ImagePlug.Plan.Output

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

  describe "resolve_before_source_fetch/1" do
    test "selects explicit and modern automatic formats before source fetch" do
      assert Policy.resolve_before_source_fetch(%Policy{
               mode: {:explicit, :png},
               modern_candidates: [],
               headers: [],
               quality: :default,
               format_qualities: %{}
             }) == {:selected, :png, :explicit}

      assert Policy.resolve_before_source_fetch(%Policy{
               mode: :source,
               modern_candidates: [:avif, :webp],
               headers: [{"vary", "Accept"}],
               quality: :default,
               format_qualities: %{}
             }) == {:selected, :avif, :auto}
    end

    test "requires source format when automatic output has no modern candidate" do
      assert Policy.resolve_before_source_fetch(%Policy{
               mode: :source,
               modern_candidates: [],
               headers: [{"vary", "Accept"}],
               quality: :default,
               format_qualities: %{}
             }) == :needs_source_format
    end
  end

  describe "resolve_source_format/2" do
    test "uses source format without strict Accept rejection" do
      policy = %Policy{
        mode: :source,
        modern_candidates: [],
        headers: [{"vary", "Accept"}],
        quality: :default,
        format_qualities: %{}
      }

      assert Policy.resolve_source_format(policy, :png) == {:selected, :png, :source}
      assert Policy.resolve_source_format(policy, :jpeg) == {:selected, :jpeg, :source}
    end

    test "requires known source format" do
      policy = %Policy{
        mode: :source,
        modern_candidates: [],
        headers: [{"vary", "Accept"}],
        quality: :default,
        format_qualities: %{}
      }

      assert Policy.resolve_source_format(policy, nil) == {:error, :source_format_required}
    end
  end

  describe "resolve/2" do
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
                  representation_headers: []
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
                  representation_headers: []
                }}
    end
  end
end
