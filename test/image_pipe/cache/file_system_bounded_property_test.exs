defmodule ImagePipe.Cache.FileSystem.BoundedPropertyTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias ImagePipe.Cache.FileSystem.Admission

  @cap 100_000

  property "Admission-tracked bytes stay within the cap after any admission sequence" do
    check all descriptors <- list_of(descriptor_generator(), min_length: 0, max_length: 50),
              max_runs: 50 do
      tmp = create_tmp_dir()
      registry = :"#{__MODULE__}.#{System.unique_integer([:positive])}.Registry"
      start_supervised!({Registry, keys: :unique, name: registry})

      opts = [
        registry: registry,
        root: tmp,
        node_id: "prop-node",
        state_dir: Path.join(tmp, ".cache_state"),
        max_size_bytes: @cap,
        window_ratio: 0.01,
        sketch_depth: 4,
        sketch_width: 64,
        doorkeeper_cardinality: 1024,
        doorkeeper_fpr: 0.01,
        # Don't tick during the test — admits are synchronous, so the tracked
        # invariant must hold without relying on background reconcile/flush.
        flush_interval_ms: 60_000,
        cleanup_interval_ms: 60_000
      ]

      pid = start_supervised!({Admission, opts})

      Enum.each(descriptors, fn descriptor ->
        # Synchronous admit means no in-flight bytes; tracked stays <= cap.
        Admission.admit(pid, descriptor)
      end)

      state = :sys.get_state(pid)
      tracked = state.window_bytes + state.probationary_bytes + state.protected_bytes
      assert tracked <= @cap, "Tracked bytes #{tracked} exceeded cap #{@cap}"
    end
  end

  defp descriptor_generator do
    gen all key <- string(:alphanumeric, min_length: 4, max_length: 16),
            size <- integer(100..50_000),
            cost <- integer(0..100_000) do
      %{
        key_hash: key,
        size_bytes: size,
        body_sha256: "sha-#{key}",
        cost_us: cost
      }
    end
  end

  defp create_tmp_dir do
    tmp = Path.join(System.tmp_dir!(), "bounded_prop_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    tmp
  end
end
