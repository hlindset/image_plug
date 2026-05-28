defmodule ImagePipe.Cache.FileSystem.Admission do
  @moduledoc false

  use GenServer

  alias ImagePipe.Cache.FileSystem.Policy
  alias ImagePipe.Cache.FileSystem.Sketch

  defmodule State do
    @moduledoc false
    defstruct [
      :registry,
      :root,
      :node_id,
      :state_dir,
      :max_size_bytes,
      :window_budget,
      :sketch_depth,
      :sketch_width,
      :aging_sample_size,
      :doorkeeper_cardinality,
      :doorkeeper_fpr,
      :eviction_victim_limit,
      :local_cms,
      :boot_cms,
      # %Talan.BloomFilter{}
      :doorkeeper,
      :flush_interval_ms,
      :cleanup_interval_ms,
      :reconcile_interval_ms,
      :state_ttl_ms,
      path_prefix: "",
      window: nil,
      probationary: nil,
      protected: nil,
      window_bytes: 0,
      probationary_bytes: 0,
      protected_bytes: 0,
      next_position: 1,
      state_dirty: false,
      # populated by warm-start (Task 19), consumed by directory scan (Task 21):
      persisted_protected_hashes: [],
      # set by handle_continue (Task 20). `scan_task_ref` is the monitor
      # ref so an abnormal scan crash is observed and waiters are released
      # instead of blocking forever. `scan_complete?` flips when the scan
      # task reports done; `scan_waiters` holds `GenServer.call` `from`
      # tags queued by `await_scan/2` before completion.
      scan_task: nil,
      scan_task_ref: nil,
      scan_complete?: false,
      scan_waiters: []
    ]
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via_tuple(opts))
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :root), Keyword.fetch!(opts, :node_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  defp via_tuple(opts) do
    registry = Keyword.fetch!(opts, :registry)
    root = Keyword.fetch!(opts, :root)
    node_id = Keyword.fetch!(opts, :node_id)
    {:via, Registry, {registry, {root, node_id}}}
  end

  @impl true
  def init(opts) do
    max_size = Keyword.fetch!(opts, :max_size_bytes)
    window_ratio = Keyword.fetch!(opts, :window_ratio)
    sketch_depth = Keyword.fetch!(opts, :sketch_depth)
    sketch_width = Keyword.fetch!(opts, :sketch_width)
    # Aging cadence is decoupled from width (Sketch.new/1 docs). Fall back to
    # width * 10 only for direct-start unit tests that don't pass it.
    aging_sample_size = Keyword.get(opts, :aging_sample_size, sketch_width * 10)
    doorkeeper_cardinality = Keyword.fetch!(opts, :doorkeeper_cardinality)
    doorkeeper_fpr = Keyword.fetch!(opts, :doorkeeper_fpr)

    state = %State{
      registry: Keyword.fetch!(opts, :registry),
      root: Keyword.fetch!(opts, :root),
      node_id: Keyword.fetch!(opts, :node_id),
      state_dir: Keyword.fetch!(opts, :state_dir),
      # path_prefix mirrors the adapter option so the directory scan (Task 20)
      # walks the same partition root the adapter writes to. Defaults to "".
      path_prefix: Keyword.get(opts, :path_prefix, ""),
      max_size_bytes: max_size,
      window_budget: trunc(max_size * window_ratio),
      sketch_depth: sketch_depth,
      sketch_width: sketch_width,
      aging_sample_size: aging_sample_size,
      doorkeeper_cardinality: doorkeeper_cardinality,
      doorkeeper_fpr: doorkeeper_fpr,
      # Bounded eviction fan-out per admission (Task 25 config; default 64).
      # Defaulted here so direct-start unit tests need not pass it.
      eviction_victim_limit: Keyword.get(opts, :eviction_victim_limit, 64),
      local_cms:
        Sketch.new(depth: sketch_depth, width: sketch_width, sample_size: aging_sample_size),
      boot_cms:
        Sketch.new(depth: sketch_depth, width: sketch_width, sample_size: aging_sample_size),
      doorkeeper:
        Talan.BloomFilter.new(doorkeeper_cardinality, false_positive_probability: doorkeeper_fpr),
      flush_interval_ms: Keyword.get(opts, :flush_interval_ms, 30_000),
      cleanup_interval_ms: Keyword.get(opts, :cleanup_interval_ms, 3_600_000),
      reconcile_interval_ms: Keyword.get(opts, :reconcile_interval_ms, 60_000),
      state_ttl_ms: Keyword.get(opts, :state_ttl_ms, 604_800_000),
      # Tables are :protected: the GenServer is the sole writer, while test
      # and introspection readers (via :sys.get_state + :ets) can read them
      # cross-process. A :private table would raise on any non-owner read.
      window: :ets.new(:window, [:ordered_set, :protected]),
      probationary: :ets.new(:probationary, [:ordered_set, :protected]),
      protected: :ets.new(:protected, [:ordered_set, :protected])
    }

    {:ok, state}
  end

  @doc """
  Notify Admission of a cache hit. `descriptor` carries the same shape
  as an admit-time descriptor (key_hash, size_bytes, body_sha256,
  cost_us) so Admission can synthesize a probationary entry for hits
  that arrive before the boot scan reaches the corresponding key.
  """
  @spec hit(pid() | GenServer.name(), map()) :: :ok
  def hit(server, descriptor) when is_map(descriptor) do
    GenServer.cast(server, {:hit, descriptor})
  end

  @impl true
  def handle_cast({:hit, descriptor}, state) do
    state = sighting(state, descriptor.key_hash)
    state = on_hit_promote_or_synthesize(state, descriptor)
    {:noreply, %{state | state_dirty: true}}
  end

  defp on_hit_promote_or_synthesize(state, descriptor) do
    case locate(state, descriptor.key_hash) do
      nil ->
        # Cold-boot hit synthesis: scan hasn't reached this entry yet,
        # but the adapter has just read its meta and passed a full
        # descriptor. Insert at probationary MRU.
        {pos, state} = next_position(state)
        :ets.insert(state.probationary, {{pos, descriptor.key_hash}, descriptor})
        Map.update!(state, :probationary_bytes, &(&1 + descriptor.size_bytes))

      _located ->
        promote_on_hit(state, descriptor.key_hash)
    end
  end

  @spec admit(pid() | GenServer.name(), map()) ::
          {:admit, [map()]}
          | {:reject,
             :over_cap | :score_too_low | :no_evictable_victims | :victim_limit_exceeded}
  def admit(server, descriptor) do
    GenServer.call(server, {:admit, descriptor})
  end

  @impl true
  def handle_call({:admit, descriptor}, _from, state) do
    # Increment sighting first (commit is itself a sighting of the key)
    state = sighting(state, descriptor.key_hash)

    if descriptor.size_bytes > state.max_size_bytes do
      {:reply, {:reject, :over_cap}, state}
    else
      {result, state} = do_admit(state, descriptor)
      {:reply, result, %{state | state_dirty: true}}
    end
  end

  defp do_admit(state, descriptor) do
    cond do
      descriptor.size_bytes > state.window_budget ->
        run_main_gate(state, descriptor)

      already_tracked?(state, descriptor.key_hash) ->
        same_key_replace(state, descriptor)

      true ->
        insert_into_window(state, descriptor)
    end
  end

  defp insert_into_window(state, descriptor) do
    {position, state} = next_position(state)
    :ets.insert(state.window, {{position, descriptor.key_hash}, descriptor})
    state = %{state | window_bytes: state.window_bytes + descriptor.size_bytes}
    drain_window_overflow(state, [])
  end

  defp drain_window_overflow(state, victims) do
    cond do
      state.window_bytes <= state.window_budget ->
        {{:admit, victims}, state}

      # Defensive: byte counter says we are over budget but the table is
      # empty. This should not happen if accounting is consistent, but a
      # blind `:ets.first/1` + `:ets.lookup/2` on an empty table would
      # match `[]` against `[{...}]` and crash the GenServer. Stop draining.
      :ets.first(state.window) == :"$end_of_table" ->
        {{:admit, victims}, state}

      true ->
        # Pop window LRU
        first_key = :ets.first(state.window)
        [{{pos, hash}, descriptor}] = :ets.lookup(state.window, first_key)
        :ets.delete(state.window, {pos, hash})
        state = %{state | window_bytes: state.window_bytes - descriptor.size_bytes}

        {gate_result, state} = run_main_gate(state, descriptor)

        drain_after_gate(state, descriptor, gate_result, victims)
    end
  end

  defp drain_after_gate(state, descriptor, gate_result, victims) do
    case gate_result do
      {:admit, more_victims} ->
        drain_window_overflow(state, victims ++ more_victims)

      {:reject, _} ->
        # Window evictee lost main gate; its files must be deleted
        # (body and meta).
        evictee_victim = full_eviction_victim(descriptor)
        drain_window_overflow(state, victims ++ [evictee_victim])
    end
  end

  defp full_eviction_victim(descriptor) do
    %{
      key_hash: descriptor.key_hash,
      body_sha256: descriptor.body_sha256,
      size_bytes: descriptor.size_bytes,
      delete_body?: true,
      delete_meta?: true
    }
  end

  defp already_tracked?(state, key_hash) do
    # Search across all queues. Inefficient but correct; optimized later.
    in_queue?(state.window, key_hash) or in_queue?(state.probationary, key_hash) or
      in_queue?(state.protected, key_hash)
  end

  defp in_queue?(table, key_hash) do
    :ets.match_object(table, {{:_, key_hash}, :_}) != []
  end

  defp run_main_gate(state, descriptor) do
    # Clamp to 0: in-flight commit overshoot or restart reconciliation can
    # transiently push (probationary + protected) above the main budget, in
    # which case the raw subtraction goes negative. A negative `available`
    # must not be treated as "room" by the `>=` comparison below, and it must
    # not let a zero-byte descriptor slip through the free-space branch and
    # skip scoring.
    available =
      max(
        0,
        state.max_size_bytes - state.window_budget - state.probationary_bytes -
          state.protected_bytes
      )

    if available >= descriptor.size_bytes do
      insert_into_probationary(state, descriptor)
    else
      identify_and_score(state, descriptor)
    end
  end

  defp insert_into_probationary(state, descriptor) do
    {position, state} = next_position(state)
    :ets.insert(state.probationary, {{position, descriptor.key_hash}, descriptor})
    state = %{state | probationary_bytes: state.probationary_bytes + descriptor.size_bytes}
    {{:admit, []}, state}
  end

  defp identify_and_score(state, descriptor) do
    probationary_list = ordered_set_to_list(state.probationary)
    protected_list = ordered_set_to_list(state.protected)
    limit = state.eviction_victim_limit

    case Policy.victim_walk(
           probationary_list,
           protected_list,
           descriptor.size_bytes,
           limit
         ) do
      {:error, :no_evictable_victims} ->
        {{:reject, :no_evictable_victims}, state}

      {:error, :victim_limit_exceeded} ->
        {{:reject, :victim_limit_exceeded}, state}

      {:ok, victim_descriptors} ->
        freq_fn = fn key_hash ->
          Sketch.estimate(state.local_cms, key_hash) + Sketch.estimate(state.boot_cms, key_hash)
        end

        if Policy.admit?(descriptor, victim_descriptors, freq_fn) do
          state = remove_victims(state, victim_descriptors)
          {_result, state} = insert_into_probationary(state, descriptor)
          # Tag victims with full-eviction flags for the adapter.
          tagged = Enum.map(victim_descriptors, &full_eviction_victim/1)
          {{:admit, tagged}, state}
        else
          {{:reject, :score_too_low}, state}
        end
    end
  end

  defp ordered_set_to_list(table) do
    :ets.foldr(fn {_pos_and_hash, descriptor}, acc -> [descriptor | acc] end, [], table)
    |> Enum.reverse()
  end

  defp remove_victims(state, victims) do
    Enum.reduce(victims, state, fn descriptor, acc ->
      remove_descriptor(acc, descriptor)
    end)
  end

  defp remove_descriptor(state, descriptor) do
    # Search all queues for the descriptor and remove it. Update byte counters.
    Enum.reduce_while([:window, :probationary, :protected], state, fn queue, acc ->
      table = Map.fetch!(acc, queue)

      case :ets.match_object(table, {{:_, descriptor.key_hash}, :_}) do
        [] ->
          {:cont, acc}

        [{key, _value}] ->
          :ets.delete(table, key)
          bytes_field = :"#{queue}_bytes"
          acc = Map.update!(acc, bytes_field, &(&1 - descriptor.size_bytes))
          {:halt, acc}
      end
    end)
  end

  # stub for next task
  defp same_key_replace(state, _descriptor), do: {{:admit, []}, state}

  defp sighting(state, key_hash) do
    if Talan.BloomFilter.member?(state.doorkeeper, key_hash) do
      %{state | local_cms: Sketch.increment(state.local_cms, key_hash)}
    else
      # talan's put/2 mutates the underlying :atomics ref in place and
      # returns :ok.
      :ok = Talan.BloomFilter.put(state.doorkeeper, key_hash)
      state
    end
  end

  # Scan the three queues for a key_hash and return the located ETS object
  # `{{position, key_hash}, descriptor}`, or nil when the key is untracked.
  defp locate(state, key_hash) do
    find_in_queue(state.window, key_hash) ||
      find_in_queue(state.probationary, key_hash) ||
      find_in_queue(state.protected, key_hash)
  end

  defp find_in_queue(table, key_hash) do
    case :ets.match_object(table, {{:_, key_hash}, :_}) do
      [object | _] -> object
      [] -> nil
    end
  end

  defp next_position(state),
    do: {state.next_position, %{state | next_position: state.next_position + 1}}

  # TODO(Task 17): real promotion. For now a hit on an already-tracked key
  # leaves the queues unchanged; the sighting/2 CMS increment still applies.
  defp promote_on_hit(state, _key_hash), do: state
end
