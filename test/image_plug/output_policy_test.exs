defmodule ImagePlug.OutputPolicyTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePlug.OutputPlan
  alias ImagePlug.OutputPolicy

  describe "from_output_plan/3" do
    test "represents explicit output independently of Accept" do
      conn =
        :get
        |> conn("/_/f:webp/plain/images/cat.jpg")
        |> put_req_header("accept", "image/jpeg")

      assert OutputPolicy.from_output_plan(conn, %OutputPlan{mode: {:explicit, :webp}}, []) ==
               %OutputPolicy{
                 mode: {:explicit, :webp},
                 modern_candidates: [],
                 headers: [],
                 quality: :default
               }
    end

    test "represents automatic output as source mode plus modern candidates" do
      conn =
        :get
        |> conn("/_/plain/images/cat.jpg")
        |> put_req_header("accept", "image/webp;q=1,image/avif;q=0.1")

      assert OutputPolicy.from_output_plan(conn, %OutputPlan{mode: :automatic}, []) ==
               %OutputPolicy{
                 mode: :source,
                 modern_candidates: [:avif, :webp],
                 headers: [{"vary", "Accept"}],
                 quality: :default
               }
    end
  end

  describe "resolve_before_origin/1" do
    test "selects explicit and modern automatic formats before origin" do
      assert OutputPolicy.resolve_before_origin(%OutputPolicy{
               mode: {:explicit, :png},
               modern_candidates: [],
               headers: [],
               quality: :default
             }) == {:selected, :png, :explicit}

      assert OutputPolicy.resolve_before_origin(%OutputPolicy{
               mode: :source,
               modern_candidates: [:avif, :webp],
               headers: [{"vary", "Accept"}],
               quality: :default
             }) == {:selected, :avif, :auto}
    end

    test "requires source format when automatic output has no modern candidate" do
      assert OutputPolicy.resolve_before_origin(%OutputPolicy{
               mode: :source,
               modern_candidates: [],
               headers: [{"vary", "Accept"}],
               quality: :default
             }) == :needs_source_format
    end
  end

  describe "resolve_source_format/2" do
    test "uses source format without strict Accept rejection" do
      policy = %OutputPolicy{
        mode: :source,
        modern_candidates: [],
        headers: [{"vary", "Accept"}],
        quality: :default
      }

      assert OutputPolicy.resolve_source_format(policy, :png) == {:selected, :png, :source}
      assert OutputPolicy.resolve_source_format(policy, :jpeg) == {:selected, :jpeg, :source}
    end

    test "requires known source format" do
      policy = %OutputPolicy{
        mode: :source,
        modern_candidates: [],
        headers: [{"vary", "Accept"}],
        quality: :default
      }

      assert OutputPolicy.resolve_source_format(policy, nil) == {:error, :source_format_required}
    end
  end
end
