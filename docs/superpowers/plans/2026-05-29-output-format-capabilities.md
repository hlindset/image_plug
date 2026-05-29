# Output Format Capabilities & Capability-Aware Resolution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Probe libvips AVIF/WebP write support at boot, reject explicit unsupported-format requests before source fetch, and make automatic format negotiation capability-aware (filter candidates; transcode unaccepted modern source formats to raster).

**Architecture:** A new `ImagePipe.Output.Capabilities` module probes `:avif`/`:webp` write support once and caches it in `:persistent_term`. The single negotiation chokepoint `Negotiation.modern_candidates/2` gains a capability filter, so the filtered candidate list flows identically to resolution, the cache key, and conditional-GET. `Policy.resolve_source_format/2` changes source-passthrough so only baseline JPEG/PNG pass through (modern/source-only sources route to the existing raster-by-alpha path). Explicit unsupported formats are rejected pre-fetch in `Runner` with a distinct error mapped to 501.

**Tech Stack:** Elixir, Plug, `image`/`vix` (libvips), `:persistent_term`, `:telemetry`, Boundary, ExUnit.

**Spec:** `docs/superpowers/specs/2026-05-29-output-format-capabilities-and-fallback-design.md`

---

## File Structure

**Create:**
- `lib/image_pipe/output/capabilities.ex` — boot probe + `supports?/1,2` over `:persistent_term`.
- `test/image_pipe/output_capabilities_test.exs` — unit tests for the probe/readable API.

**Modify:**
- `lib/image_pipe/output.ex` — add `Capabilities` to boundary `exports`.
- `lib/application.ex` — add `ImagePipe.Output` boundary dep; call `Capabilities.probe/0` at supervisor start.
- `lib/image_pipe/output/negotiation.ex` — capability filter inside `modern_candidates/2`.
- `lib/image_pipe/output/policy.ex` — `resolve_source_format/2` passthrough rule; add `ensure_capable/2`.
- `lib/image_pipe/request/runner.ex` — pre-fetch `ensure_capable/2` gate in `process_prepared_stream/6`.
- `lib/image_pipe/response/sender.ex` — `{:unsupported_output_format, _}` → 501 clause.
- `test/image_pipe/output_negotiation_test.exs` — capability-filter unit cases.
- `test/image_pipe/output_policy_test.exs` — passthrough-rule + `ensure_capable/2` unit cases.
- `test/image_pipe/imgproxy_wire_conformance_test.exs` — wire-level capability tests + an AVIF origin source helper.

**Note on the `output_capabilities` opts key:** `Request.Options.validate!/1` validates only known keys and merges them back, so unknown keys pass through untouched (`lib/image_pipe/request/options.ex:105-115`). Tests inject `output_capabilities: %{avif: false}` through `opts` to simulate an incapable build on a capable test machine. Production callers omit it.

---

## Task 1: `ImagePipe.Output.Capabilities` probe module (#97)

**Files:**
- Create: `lib/image_pipe/output/capabilities.ex`
- Modify: `lib/image_pipe/output.ex`
- Test: `test/image_pipe/output_capabilities_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/image_pipe/output_capabilities_test.exs`:

```elixir
defmodule ImagePipe.Output.CapabilitiesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ImagePipe.Output.Capabilities

  describe "supports?/1" do
    test "baseline jpeg and png are always supported without probing" do
      assert Capabilities.supports?(:jpeg)
      assert Capabilities.supports?(:png)
    end

    test "returns a boolean for avif and webp" do
      assert is_boolean(Capabilities.supports?(:avif))
      assert is_boolean(Capabilities.supports?(:webp))
    end

    test "unknown formats are unsupported" do
      refute Capabilities.supports?(:gif)
    end
  end

  describe "supports?/2 with an injected capability map" do
    test "the override decides avif/webp" do
      opts = [output_capabilities: %{avif: false, webp: true}]
      refute Capabilities.supports?(:avif, opts)
      assert Capabilities.supports?(:webp, opts)
    end

    test "falls back to the probe when the format is absent from the map" do
      opts = [output_capabilities: %{webp: false}]
      assert is_boolean(Capabilities.supports?(:avif, opts))
    end

    test "without the key, behaves like supports?/1" do
      assert Capabilities.supports?(:jpeg, [])
    end
  end

  describe "probe/0" do
    test "returns :ok and is idempotent" do
      assert Capabilities.probe() == :ok
      assert Capabilities.probe() == :ok
    end
  end

  describe "warning" do
    test "warns when a format is unsupported and stays silent when supported" do
      assert capture_log(fn -> Capabilities.maybe_warn(:avif, false) end) =~ "avif"
      assert capture_log(fn -> Capabilities.maybe_warn(:avif, true) end) == ""
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/output_capabilities_test.exs`
Expected: FAIL — `ImagePipe.Output.Capabilities` is undefined.

- [ ] **Step 3: Write the module**

Create `lib/image_pipe/output/capabilities.ex`:

```elixir
defmodule ImagePipe.Output.Capabilities do
  @moduledoc false

  # libvips output-format write capability, probed once and cached in
  # :persistent_term. Capabilities cannot change without a process restart, so a
  # process-lifetime cache is correct here.

  require Logger

  @probed_formats [:avif, :webp]
  @baseline_formats [:jpeg, :png]

  @spec probe() :: :ok
  def probe do
    Enum.each(@probed_formats, fn format ->
      supported? = probe_once(format)
      maybe_warn(format, supported?)
    end)

    :ok
  end

  @spec supports?(atom()) :: boolean()
  def supports?(format) when format in @baseline_formats, do: true
  def supports?(format) when format in @probed_formats, do: probe_once(format)
  def supports?(_format), do: false

  @spec supports?(atom(), keyword()) :: boolean()
  def supports?(format, opts) do
    case opts |> Keyword.get(:output_capabilities, %{}) |> Map.fetch(format) do
      {:ok, supported?} -> supported?
      :error -> supports?(format)
    end
  end

  @doc false
  @spec maybe_warn(atom(), boolean()) :: :ok
  def maybe_warn(_format, true), do: :ok

  def maybe_warn(format, false) do
    Logger.warning(
      "ImagePipe: libvips build cannot write #{format}; requests resolving to " <>
        "#{format} will fall back (automatic) or be rejected (explicit)."
    )

    :ok
  end

  # Reads the cached result; probes once on first miss and caches it. The probe
  # is a 1x1 in-memory encode, so first-call cost is negligible.
  defp probe_once(format) do
    case :persistent_term.get({__MODULE__, format}, :unknown) do
      :unknown ->
        result = probe_format(format)
        :persistent_term.put({__MODULE__, format}, result)
        result

      result ->
        result
    end
  end

  defp probe_format(format) do
    with {:ok, image} <- Image.new(1, 1),
         {:ok, _binary} <- Image.write(image, :memory, suffix: suffix(format)) do
      true
    else
      _error -> false
    end
  rescue
    # External libvips boundary: any failure means the encoder is unavailable.
    _exception -> false
  end

  defp suffix(:avif), do: ".avif"
  defp suffix(:webp), do: ".webp"
end
```

- [ ] **Step 4: Export from the Output boundary**

In `lib/image_pipe/output.ex`, add `Capabilities` to `exports`:

```elixir
    exports: [
      Capabilities,
      Policy,
      Encoder,
      Negotiation,
      Resolved
    ]
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/output_capabilities_test.exs`
Expected: PASS (all cases).

- [ ] **Step 6: Verify no warnings-as-errors regressions**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: compiles clean.

- [ ] **Step 7: Commit**

```bash
git add lib/image_pipe/output/capabilities.ex lib/image_pipe/output.ex test/image_pipe/output_capabilities_test.exs
git commit -m "Add Output.Capabilities libvips write-support probe (#97)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Probe at application boot (#97 wiring)

**Files:**
- Modify: `lib/application.ex`

- [ ] **Step 1: Add the Output dep and probe call**

In `lib/application.ex`, add `ImagePipe.Output` to the boundary `deps` and call the probe at start:

```elixir
defmodule ImagePipe.Application do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Output,
      ImagePipe.Request
    ]

  use Application

  require Logger

  def start(_type, _args) do
    ImagePipe.Output.Capabilities.probe()

    children = [
      ImagePipe.Request.SourceSessionSupervisor
    ]

    opts = [strategy: :one_for_one, name: ImagePipe.Supervisor]

    Logger.info("Starting application...")
    Supervisor.start_link(children, opts)
  end
end
```

- [ ] **Step 2: Verify the app boots and boundaries hold**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: compiles clean, no `Boundary` violations.

Run: `mise exec -- mix test test/image_pipe/output_capabilities_test.exs`
Expected: PASS (probe still idempotent; boot path now also calls it).

- [ ] **Step 3: Commit**

```bash
git add lib/application.ex
git commit -m "Probe libvips output capabilities at boot (#97)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Capability filter in `Negotiation.modern_candidates/2` (#98 Change 1)

**Files:**
- Modify: `lib/image_pipe/output/negotiation.ex`
- Test: `test/image_pipe/output_negotiation_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `test/image_pipe/output_negotiation_test.exs` (inside the test module):

```elixir
  describe "modern_candidates/2 capability filtering" do
    test "drops avif when the build cannot write it" do
      opts = [output_capabilities: %{avif: false}]

      assert Negotiation.modern_candidates("image/avif,image/webp", opts) == [:webp]
    end

    test "an avif-only Accept on an avif-less build yields no modern candidates" do
      opts = [output_capabilities: %{avif: false}]

      assert Negotiation.modern_candidates("image/avif", opts) == []
    end

    test "keeps both when the build supports both" do
      opts = [output_capabilities: %{avif: true, webp: true}]

      assert Negotiation.modern_candidates("image/avif,image/webp", opts) == [:avif, :webp]
    end
  end
```

(If `Negotiation` is not already aliased in that test file, add `alias ImagePipe.Output.Negotiation` near the top.)

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/output_negotiation_test.exs`
Expected: FAIL — the avif-less cases still include `:avif`.

- [ ] **Step 3: Add the capability filter**

In `lib/image_pipe/output/negotiation.ex`, add the alias and replace `enabled_modern_formats/1` + `enabled?` logic:

Add near the existing alias:

```elixir
  alias ImagePipe.Output.Capabilities
```

Replace:

```elixir
  defp enabled_modern_formats(opts) do
    enabled? = %{
      avif: Keyword.get(opts, :auto_avif, true),
      webp: Keyword.get(opts, :auto_webp, true)
    }

    Enum.reject(@modern_formats, fn {format, _mime_type} ->
      not Map.fetch!(enabled?, format)
    end)
  end
```

with:

```elixir
  defp enabled_modern_formats(opts) do
    Enum.reject(@modern_formats, fn {format, _mime_type} ->
      not available?(format, opts)
    end)
  end

  # A modern format is a candidate only when it is config-enabled AND the libvips
  # build can actually write it. Capability filtering here flows identically to
  # resolution, the cache key, and conditional-GET, since all three call this fn.
  defp available?(format, opts) do
    config_enabled?(format, opts) and Capabilities.supports?(format, opts)
  end

  defp config_enabled?(:avif, opts), do: Keyword.get(opts, :auto_avif, true)
  defp config_enabled?(:webp, opts), do: Keyword.get(opts, :auto_webp, true)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mise exec -- mix test test/image_pipe/output_negotiation_test.exs test/image_pipe/output_negotiation_property_test.exs`
Expected: PASS (new cases pass; existing cases unaffected — the default build supports both formats, so the filter is a no-op without an override).

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/output/negotiation.ex test/image_pipe/output_negotiation_test.exs
git commit -m "Filter modern output candidates by libvips capability (#98)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Source-passthrough negotiation rule in `Policy.resolve_source_format/2` (#98 Change 2)

**Files:**
- Modify: `lib/image_pipe/output/policy.ex`
- Test: `test/image_pipe/output_policy_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `test/image_pipe/output_policy_test.exs` (inside the test module). This builds an automatic-mode policy with **no** `Accept` (so `modern_candidates` is empty) and drives `resolve/2`:

```elixir
  describe "resolve/2 source-passthrough rule" do
    setup do
      output = %ImagePipe.Plan.Output{
        mode: :automatic,
        quality: :default,
        format_qualities: %{}
      }

      conn = Plug.Test.conn(:get, "/")
      policy = ImagePipe.Output.Policy.from_output_plan(conn, output, [])
      %{policy: policy}
    end

    test "jpeg source passes through", %{policy: policy} do
      assert {:ok, %ImagePipe.Output.Resolved{format: :jpeg}} =
               ImagePipe.Output.Policy.resolve(policy, :jpeg)
    end

    test "png source passes through", %{policy: policy} do
      assert {:ok, %ImagePipe.Output.Resolved{format: :png}} =
               ImagePipe.Output.Policy.resolve(policy, :png)
    end

    test "avif source routes to the alpha path (transcode to raster)", %{policy: policy} do
      assert {:needs_final_image_alpha, :source} =
               ImagePipe.Output.Policy.resolve(policy, :avif)
    end

    test "webp source routes to the alpha path", %{policy: policy} do
      assert {:needs_final_image_alpha, :source} =
               ImagePipe.Output.Policy.resolve(policy, :webp)
    end

    test "source-only formats still route to the alpha path", %{policy: policy} do
      assert {:needs_final_image_alpha, :source} =
               ImagePipe.Output.Policy.resolve(policy, :tiff)
    end

    test "unknown formats error", %{policy: policy} do
      assert {:error, :source_format_required} =
               ImagePipe.Output.Policy.resolve(policy, :gif)
    end
  end
```

(If the test file lacks `import Plug.Test` or relevant aliases, fully-qualified names above avoid needing them; add `import Plug.Test` only if you prefer `conn(:get, "/")` unqualified.)

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/output_policy_test.exs`
Expected: FAIL — `:avif`/`:webp` currently resolve to `{:ok, %Resolved{format: :avif|:webp}}`, not the alpha path.

- [ ] **Step 3: Change the passthrough rule**

In `lib/image_pipe/output/policy.ex`, add a module attribute near the top (after `defstruct`):

```elixir
  @passthrough_source_formats [:jpeg, :png]
```

Replace:

```elixir
  defp resolve_source_format(%__MODULE__{mode: :source}, source_format) do
    cond do
      Format.output_format?(source_format) -> {:selected, source_format, :source}
      Format.source_only_format?(source_format) -> {:needs_final_image_alpha, :source}
      true -> {:error, :source_format_required}
    end
  end
```

with:

```elixir
  # Only baseline formats pass through as-is. Modern source formats (avif/webp)
  # are reached here only when the client accepted no modern format, so passing
  # them through would serve an unaccepted (possibly undecodable) format; route
  # them and source-only formats to the raster-by-alpha path instead.
  defp resolve_source_format(%__MODULE__{mode: :source}, source_format) do
    cond do
      source_format in @passthrough_source_formats -> {:selected, source_format, :source}
      Format.source_format?(source_format) -> {:needs_final_image_alpha, :source}
      true -> {:error, :source_format_required}
    end
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mise exec -- mix test test/image_pipe/output_policy_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/output/policy.ex test/image_pipe/output_policy_test.exs
git commit -m "Transcode unaccepted modern source formats to raster (#98)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Explicit-mode pre-fetch rejection (#98 explicit)

**Files:**
- Modify: `lib/image_pipe/output/policy.ex`
- Modify: `lib/image_pipe/request/runner.ex`
- Modify: `lib/image_pipe/response/sender.ex`
- Test: `test/image_pipe/output_policy_test.exs`

- [ ] **Step 1: Write the failing unit test for `ensure_capable/2`**

Append to `test/image_pipe/output_policy_test.exs`:

```elixir
  describe "ensure_capable/2" do
    test "rejects an explicit format the build cannot write" do
      output = %ImagePipe.Plan.Output{
        mode: {:explicit, :avif},
        quality: :default,
        format_qualities: %{}
      }

      policy = ImagePipe.Output.Policy.from_output_plan(Plug.Test.conn(:get, "/"), output, [])

      assert ImagePipe.Output.Policy.ensure_capable(policy, output_capabilities: %{avif: false}) ==
               {:error, {:unsupported_output_format, :avif}}
    end

    test "allows a supported explicit format" do
      output = %ImagePipe.Plan.Output{
        mode: {:explicit, :avif},
        quality: :default,
        format_qualities: %{}
      }

      policy = ImagePipe.Output.Policy.from_output_plan(Plug.Test.conn(:get, "/"), output, [])

      assert ImagePipe.Output.Policy.ensure_capable(policy, output_capabilities: %{avif: true}) ==
               :ok
    end

    test "automatic mode is always capable (resolution handles fallback)" do
      output = %ImagePipe.Plan.Output{
        mode: :automatic,
        quality: :default,
        format_qualities: %{}
      }

      policy = ImagePipe.Output.Policy.from_output_plan(Plug.Test.conn(:get, "/"), output, [])

      assert ImagePipe.Output.Policy.ensure_capable(policy, output_capabilities: %{avif: false}) ==
               :ok
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/output_policy_test.exs`
Expected: FAIL — `ensure_capable/2` is undefined.

- [ ] **Step 3: Add `ensure_capable/2` to `Policy`**

In `lib/image_pipe/output/policy.ex`, add the alias (near the other aliases):

```elixir
  alias ImagePipe.Output.Capabilities
```

Add the public function (place it next to `resolve/2`):

```elixir
  @spec ensure_capable(t(), keyword()) :: :ok | {:error, {:unsupported_output_format, format()}}
  def ensure_capable(%__MODULE__{mode: {:explicit, format}}, opts) do
    if Capabilities.supports?(format, opts) do
      :ok
    else
      {:error, {:unsupported_output_format, format}}
    end
  end

  def ensure_capable(%__MODULE__{mode: :source}, _opts), do: :ok
```

- [ ] **Step 4: Run the unit test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/output_policy_test.exs`
Expected: PASS.

- [ ] **Step 5: Add the sender 501 clause**

In `lib/image_pipe/response/sender.ex`, add a `handle_processing_error/3` clause (next to the other clauses, before the `@plan_validation_error_tags` catch-clause) and its sender helper:

```elixir
  defp handle_processing_error(conn, {:unsupported_output_format, _format} = reason, response_headers) do
    Logger.info("unsupported_output_format: #{inspect(reason)}")
    send_unsupported_output_format_error(conn, response_headers)
  end
```

Add the helper near `send_decode_error/3`:

```elixir
  defp send_unsupported_output_format_error(%Plug.Conn{} = conn, response_headers) do
    conn
    |> put_resp_headers(response_headers)
    |> put_resp_content_type("text/plain")
    |> send_resp(501, "requested output format is not supported by this server")
  end
```

- [ ] **Step 6: Wire the pre-fetch gate into the runner**

In `lib/image_pipe/request/runner.ex`, change `process_prepared_stream/6` to gate on `ensure_capable/2` before starting the session:

```elixir
  defp process_prepared_stream(conn, plan, resolved_source, cache_key, prepared_http_cache, opts) do
    policy = Policy.from_output_plan(conn, plan.output, opts)

    case Policy.ensure_capable(policy, opts) do
      :ok ->
        request = %SessionRequest{
          plan: plan,
          resolved_source: resolved_source,
          output_policy: policy,
          opts: opts,
          cache_key: cache_key
        }

        supervisor = Keyword.get(opts, :source_session_supervisor, SourceSessionSupervisor)

        case SourceSessionSupervisor.start_session(supervisor, request) do
          {:ok, session} ->
            prepare_supervised_session(
              session,
              supervisor,
              plan.response,
              policy,
              prepared_http_cache
            )

          {:error, reason} ->
            {:error, {:processing, normalize_session_prepare_error(reason), policy.headers}}
        end

      {:error, reason} ->
        {:error, {:processing, reason, policy.headers}}
    end
  end
```

- [ ] **Step 7: Verify compile + focused tests**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean.

Run: `mise exec -- mix test test/image_pipe/output_policy_test.exs test/image_pipe/request`
Expected: PASS (no existing request test exercises an unsupported explicit format on a capable build, so behavior is unchanged there).

- [ ] **Step 8: Commit**

```bash
git add lib/image_pipe/output/policy.ex lib/image_pipe/request/runner.ex lib/image_pipe/response/sender.ex test/image_pipe/output_policy_test.exs
git commit -m "Reject explicit unsupported output formats before fetch (#98)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Wire-level capability tests (#98 end-to-end)

**Files:**
- Modify: `test/image_pipe/imgproxy_wire_conformance_test.exs`

These exercise real `ImagePipe.Plug.call/2` requests with an injected `output_capabilities` profile, plus a new AVIF origin source. They mirror the existing wire-test helpers (`call_imgproxy/3`, `content_type/1`, `dimensions/1`, `@default_opts`, `OriginShouldNotFetch`).

- [ ] **Step 1: Add an AVIF origin source helper**

Near the other `defmodule …OriginImage` helpers at the top of the test module (e.g. after `EffectOriginImage`), add:

```elixir
  defmodule AvifOriginImage do
    @moduledoc false

    def call(conn, _opts) do
      body =
        64
        |> Image.new!(64, color: :red)
        |> Image.write!(:memory, suffix: ".avif")

      conn
      |> Plug.Conn.put_resp_content_type("image/avif")
      |> Plug.Conn.send_resp(200, body)
    end
  end
```

- [ ] **Step 2: Write the failing wire tests**

Add a `describe` block among the other tests:

```elixir
  describe "output capability handling" do
    test "automatic negotiation drops avif when the build cannot write it" do
      opts = Keyword.put(@default_opts, :output_capabilities, %{avif: false})

      conn = call_imgproxy("/_/plain/images/beach.jpg", opts, "image/avif,image/webp")

      assert conn.status == 200
      assert content_type(conn) == ["image/webp"]
      assert get_resp_header(conn, "vary") == ["Accept"]
    end

    test "automatic negotiation keeps avif when the build supports it" do
      opts = Keyword.put(@default_opts, :output_capabilities, %{avif: true})

      conn = call_imgproxy("/_/plain/images/beach.jpg", opts, "image/avif,image/webp")

      assert conn.status == 200
      assert content_type(conn) == ["image/avif"]
    end

    test "an avif source with a jpeg-only Accept transcodes to raster regardless of capability" do
      base = [
        parser: ImagePipe.Parser.Imgproxy,
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test", req_options: [plug: AvifOriginImage]}
        ]
      ]

      for capability <- [%{avif: true}, %{avif: false}] do
        opts = Keyword.put(base, :output_capabilities, capability)

        conn = call_imgproxy("/_/plain/images/cat.avif", opts, "image/jpeg")

        assert conn.status == 200
        # 64x64 solid red has no alpha -> JPEG, never AVIF, for either build.
        assert content_type(conn) == ["image/jpeg"]
      end
    end

    test "a jpeg source with a jpeg-only Accept passes through as jpeg" do
      conn = call_imgproxy("/_/plain/images/beach.jpg", @default_opts, "image/jpeg")

      assert conn.status == 200
      assert content_type(conn) == ["image/jpeg"]
    end

    test "explicit avif is rejected before source fetch on an avif-less build" do
      opts = [
        parser: ImagePipe.Parser.Imgproxy,
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]}
        ],
        output_capabilities: %{avif: false}
      ]

      conn = call_imgproxy("/_/f:avif/plain/images/beach.jpg", opts)

      assert conn.status == 501
      # OriginShouldNotFetch flunks/raises if the source is fetched; reaching 501
      # without that proves the rejection happened pre-fetch.
    end

    test "explicit avif succeeds on a capable build" do
      opts = Keyword.put(@default_opts, :output_capabilities, %{avif: true})

      conn = call_imgproxy("/_/f:avif/plain/images/beach.jpg", opts)

      assert conn.status == 200
      assert content_type(conn) == ["image/avif"]
      assert get_resp_header(conn, "vary") == []
    end
  end
```

- [ ] **Step 3: Run the wire tests to verify they fail (then pass after prior tasks)**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs`
Expected: With Tasks 3–5 already implemented, these PASS. If you are running Task 6 in isolation against an un-implemented earlier task, expect the corresponding case to FAIL (e.g. avif not dropped, or explicit avif returns 200 instead of 501). Confirm failures map to the missing behavior, then ensure Tasks 3–5 are complete.

- [ ] **Step 4: Confirm `OriginShouldNotFetch` semantics**

Open `test/support/image_pipe/imgproxy_wire_conformance_test/origin_should_not_fetch.ex` and confirm its `call/2` fails the test (raises or `flunk`) when invoked. If instead it sends a `:origin_fetch` message, replace the comment-only assertion in the explicit-rejection test with `refute_received :origin_fetch` after the request. Do not change the helper.

- [ ] **Step 5: Commit**

```bash
git add test/image_pipe/imgproxy_wire_conformance_test.exs
git commit -m "Add wire-level output capability tests (#98)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Full suite, lint, and docs touch-up

**Files:**
- Modify: `docs/imgproxy_support_matrix.md` (status note)

- [ ] **Step 1: Run the full test suite**

Run: `mise exec -- mix test`
Expected: PASS.

- [ ] **Step 2: Compile with warnings-as-errors and lint**

Run: `mise exec -- mix compile --warnings-as-errors`
Run: `mise exec -- mix credo --strict`
Expected: clean (address any new findings in the files you touched).

- [ ] **Step 3: Update the support matrix**

In `docs/imgproxy_support_matrix.md`, under "Soft format fallback for unsupported AVIF/WebP encoders"-relevant areas, update the output-format detection section to note that ImagePipe now probes AVIF/WebP write support at boot, filters unproducible formats from automatic negotiation, transcodes unaccepted modern source formats to raster, and rejects explicit unsupported formats with 501. Keep it to 2–4 sentences; match the file's existing tone. Example addition under "### Output format detection":

```markdown
ImagePipe probes libvips AVIF/WebP write support at boot. Automatic negotiation
filters out formats the build cannot write; a modern source format the client did
not accept transcodes to raster (PNG/JPEG by alpha). An explicit `format` the
build cannot write is rejected with `501` before source fetch.
```

- [ ] **Step 4: Commit**

```bash
git add docs/imgproxy_support_matrix.md
git commit -m "Document output capability probe and fallback in support matrix

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Notes / invariants to preserve

- **No cache-key version bump.** The capability filter rides on the existing `modern_candidates` material; reshape in place per the greenfield cache guidance.
- **`Capabilities` is only called from inside the `Output` boundary** (`Negotiation`, `Policy`). `Request`/`Runner` go through `Policy.ensure_capable/2`; they never reference `Capabilities` directly.
- **Automatic mode never errors on a missing encoder** — only explicit mode (501). If a wire test ever shows automatic mode returning 5xx for a missing encoder, the source-passthrough rule (Task 4) or the candidate filter (Task 3) is wrong.
- **Residual limitation (by design):** raster-by-alpha may emit PNG to a `Accept: image/jpeg`-only client whose result has alpha. This matches the existing raster fallback; full per-format strict negotiation (406) is out of scope.
```
