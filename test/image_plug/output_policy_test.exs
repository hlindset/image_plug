defmodule ImagePlug.Output.PolicyTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePlug.Output.Policy
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
                 quality: :default
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
                 quality: :default
               }
    end
  end

  describe "resolve_before_origin/1" do
    test "selects explicit and modern automatic formats before origin" do
      assert Policy.resolve_before_origin(%Policy{
               mode: {:explicit, :png},
               modern_candidates: [],
               headers: [],
               quality: :default
             }) == {:selected, :png, :explicit}

      assert Policy.resolve_before_origin(%Policy{
               mode: :source,
               modern_candidates: [:avif, :webp],
               headers: [{"vary", "Accept"}],
               quality: :default
             }) == {:selected, :avif, :auto}
    end

    test "requires source format when automatic output has no modern candidate" do
      assert Policy.resolve_before_origin(%Policy{
               mode: :source,
               modern_candidates: [],
               headers: [{"vary", "Accept"}],
               quality: :default
             }) == :needs_source_format
    end
  end

  describe "resolve_source_format/2" do
    test "uses source format without strict Accept rejection" do
      policy = %Policy{
        mode: :source,
        modern_candidates: [],
        headers: [{"vary", "Accept"}],
        quality: :default
      }

      assert Policy.resolve_source_format(policy, :png) == {:selected, :png, :source}
      assert Policy.resolve_source_format(policy, :jpeg) == {:selected, :jpeg, :source}
    end

    test "requires known source format" do
      policy = %Policy{
        mode: :source,
        modern_candidates: [],
        headers: [{"vary", "Accept"}],
        quality: :default
      }

      assert Policy.resolve_source_format(policy, nil) == {:error, :source_format_required}
    end
  end
end
