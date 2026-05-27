## Project guidelines

- Use `mise exec -- ...` to run things in this repo with the correct versions of things
- This project is a greenfield, unreleased library; backwards compatibility should not be a concern at this point in time
- Prefer shrinking unsupported API surface over preserving tidy errors for bad internal callers. If a code path exists only to define behavior for impossible internal misuse, delete that behavior and its test instead of adding guards, fallbacks, or replacement tests.
- Before executing a new Superpowers design or implementation plan, run a parallel subagent review cycle on the plan. Use reviewers with disjoint focus areas, apply accepted feedback, rerun relevant doc checks, and commit the reviewed plan before implementation starts.

## Native API guidelines

- Treat ImagePipe's native API as path-oriented and declarative. URL option order must not define processing order; parsing should produce an `ImagePipe.Plan`, and current parser/plan modules own the fixed transform order.
- Keep ImagePipe's core model product-neutral, while allowing deliberate compatibility targets when explicitly chosen. Compatibility parsers should translate into `ImagePipe.Plan` when semantics match cleanly; dialect-specific quirks should stay isolated in the parser/adapter layer and should not force ordered command semantics into the native API contract.

## Transform guidelines

- Keep transforms product-neutral and composable. Transform modules should express reusable image operations over `ImagePipe.Transform.State` with explicit parameter structs, not parser-specific or vendor-specific concepts; parsers for dialects such as imgproxy, Thumbor, TwicPics, imgix, Cloudinary, or any other product should translate their syntax into `ImagePipe.Plan` when semantics match cleanly, or remain isolated compatibility adapters when they need dialect-specific ordered behavior.
- Trust operation structs inside the transform boundary. A transform struct missing required callbacks is a programmer error; validation should validate operation fields, not prove that the module implements the transform behaviour.
- Be conservative with optimized decoding. Only use sequential access for transform chains proven safe for one-pass reads; crop, focus, cover, letterboxing, output-only requests, and no-geometry requests should continue to use random access.

## Request safety guidelines

- Preserve request safety boundaries: parser and planner validation failures should return before source fetch or cache access, source fetching should use non-bang Req flows with bounded redirects/timeouts/content-type/body limits, and decoded input pixel limits should remain explicit.

## Cache guidelines

- Cache behavior is part of the contract. Cache only successful encoded responses; keep keys deterministic and based on resolved source identity, canonical plan fields, configured vary inputs, and normalized `Accept` for `format:auto`; cache errors fail open by default unless `fail_on_cache_error: true`.
- Cache key and generated ETag material represent response identity, not admission policy. Include inputs that can change successful encoded bytes or the selected response variant: resolved source identity, canonical plan fields, output negotiation, configured vary headers/cookies, cachebuster, representation/key-data versions, and normalized `Accept` for `format:auto`. Don't include safety limits such as `max_body_bytes`, `max_input_pixels`, or static result dimension limits. Those limits decide whether a cache miss may generate a response. They don't decide whether ImagePipe may serve an existing successful cached response.
- Because this library is greenfield and unreleased, don't bump internal cache key data versions for normal feature work or cache-shape changes. Reshape the canonical key data and update tests in place unless the code must still read or preserve old cache entries.

## Telemetry guidelines

- Treat telemetry as part of the runtime observability contract. Use `:telemetry.span/3`-style `:start`, `:stop`, and `:exception` event naming for request and meaningful stage spans.
- Keep telemetry metadata low-cardinality, product-neutral, and safe by default. Don't emit (unless explicit opt-in is designed and documented):
  - Full request paths or source URLs
  - Signatures, tokens, credentials
  - Filenames or other path-derived identifiers
  - Parser-specific structs (dialect paths, parser-internal shapes)
  - Transform internals (operation params, libvips state)
  - Cache adapter internals (cache keys, storage paths)
- Keep backend integrations out of the library. Emit telemetry events only; host applications should attach AppSignal, OpenTelemetry, metrics, or logging handlers themselves.
- Prefer shared telemetry helpers over ad hoc event emission so naming, measurements, metadata merging, and exception behavior stay consistent.
- Do not add per-operation transform spans unless the timing semantics are explicitly designed; libvips operations may be lazy, so stage spans are usually more honest than operation-level timings.

## Namespace boundary guidelines

- Keep the canonical request model under `ImagePipe.Plan.*`.
- Keep parser behaviours and adapters under `ImagePipe.Parser.*`; parser-specific compatibility quirks should translate into `ImagePipe.Plan` or remain isolated in the parser/adapter layer.
- Keep request orchestration and runtime options under `ImagePipe.Request.*`.
- Keep source side effects and source identity under `ImagePipe.Source.*`.
- Keep response delivery under `ImagePipe.Response.*`.
- Keep output negotiation, format, policy, and encoding under `ImagePipe.Output.*`.
- Keep transform contracts, operation structs, state, decode planning, materialization, and cache material protocols under `ImagePipe.Transform.*`.
- Request, source, and response code must dispatch through `ImagePipe.Transform` and must not name concrete transform operation modules such as `ImagePipe.Transform.Scale`, `Cover`, `Contain`, `Crop`, or `Focus`.
- Boundary exports should stay narrow. Export behaviours and stable public/internal entry points, not implementation helpers.
- `ImagePipe.SimpleServer` is dev/test support only and must remain outside prod compilation.

## Boundary library guidelines

- Use `Boundary` declarations to enforce the namespace ownership described above. When adding or moving a top-level namespace, define its dependency direction explicitly instead of relying on implicit compile-time reachability.
- Keep `deps:` aligned with architecture direction. One line per namespace:
  - `parser` → `plan`, transform construction APIs
  - `request` → `plan`, `cache`, `source`, `output`, `response`, `telemetry`, generic transform contract
  - `source` → `plan` only (must not depend on `cache`, `response`, `parser`)
  - `cache` → `plan`, `output`, transform material
  - `output` → `plan`
  - `transform` → nothing in `parser`, `request`, `source`, `cache`, `output`, `response`
- Export only behaviours and stable public/internal entry points from each boundary. Do not export implementation helpers just to satisfy a compile error; move the helper to the correct boundary or add a narrow facade.
- Request, source, and response modules may call generic `ImagePipe.Transform` functions such as `transform_name/1`, `metadata/1`, and `execute/2`, but must not alias or reference concrete operation modules. Parser and planner modules may construct exported concrete operation structs when translating syntax into a product-neutral plan.
- Boundary rule changes should come with focused architecture tests, especially for request/source/response code avoiding concrete transform modules and parser-specific structs.

## Elixir architecture guidelines

- Prefer Elixir extension points with explicit behaviours (`ImagePipe.Parser`, `ImagePipe.Transform`, `ImagePipe.Cache`), `@impl` annotations, typed parameter structs, and tagged `{:ok, value}` / `{:error, reason}` returns at runtime boundaries. Reserve raises for invalid initialization/configuration.
- Validate public options explicitly, preferably with `NimbleOptions` or adapter-owned `validate_options/1`, and reject unknown or malformed options before side effects.
- For trusted internal behaviour dispatch, call the callback directly and let missing callbacks raise. Do not add runtime duck-typing probes, callback-presence checks, or wrapper functions whose only purpose is to make impossible internal misuse return tidy errors.
- Constructor APIs should accept the narrowest shape that real callers use. Do not accept both keyword lists and maps, existing structs, or negative guard carve-outs such as `is_map(value) and not is_struct(value)` unless there is a real public caller or contract requiring it.
- Use pattern matching, small private functions, and `with`/`case` pipelines to keep success paths linear while preserving precise error tags. Avoid catch-all rescues unless a concrete runtime boundary intentionally degrades to a documented safe default; do not rescue trusted transform callback failures such as `metadata/1`.

## Validation guidelines

Validation belongs at boundaries the caller doesn't control. Inside the codebase, trust what another module just produced.

**Validate:**

- Host configuration and option parsing (mount options, request options, parser config, adapter config).
- HTTP request input (headers, query strings, bodies, conditional-request fields).
- Cache reads from external storage and other data crossing a serialization boundary.
- Third-party API responses.
- Return values from host-implementable behaviours such as `ImagePipe.Source`, `ImagePipe.Parser`, and `ImagePipe.Cache` adapters.

**Don't validate:**

- Struct fields already guaranteed by `@enforce_keys` (the struct can't exist without them).
- Values another module in this codebase just constructed and handed you.
- Properties a structural check can't actually prove (determinism, semantic stability, secret-freeness). Document the contract in `@moduledoc`/`@doc` and assert it in producer tests instead.
- Hypothetical future callers that don't exist yet — add the validation when the future caller appears, with a test that exercises it.

**Rule of thumb:** if tempted to add a guard, ask whether the value's producer is in this repo. If yes, write a test against the producer instead. If no, validate at the boundary where the value enters.

**Removing a guard at a real boundary counts as a behavior change.** Justify with a producer test or an unreachable-from-callers analysis, not "it looks unused".

## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you _must_ bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Avoid** nesting multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist.
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mise exec -- mix help task_name`)
- To debug test failures, run tests in a specific file with `mise exec -- mix test test/my_test.exs` or run all previously failed tests with `mise exec -- mix test --failed`
- Run `mise exec -- mix credo --strict` to lint the codebase.
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason
- Before finishing code changes, run the relevant focused tests through `mise exec -- ...`; for broader behavioral or public API changes, also run `mise exec -- mix test` and `mise exec -- mix compile --warnings-as-errors`.

## Test guidelines

### When to add tests

- For behavior changes, add focused ExUnit coverage at the relevant boundary: parser grammar/order-insensitivity, planner mapping, plug-level no-source-fetch failures, output negotiation including `Vary: Accept`, cache key/corruption behavior, and source/decode limit handling.
- For compatibility parsers such as imgproxy, add a compact set of wire-level Plug tests when changing request parsing, planning, output negotiation, caching, or safety behavior. These tests should make real `ImagePipe.call/2` requests and assert user-visible contracts such as status, headers, content type, decoded output dimensions, cache/source access, and response-body equivalence where relevant.
- Keep wire-level compatibility tests representative, not exhaustive. Use them for public contracts such as option-order equivalence, `Accept` negotiation and `Vary`, explicit output formats bypassing negotiation, representative geometry results, request-safety failures before source/cache access, and cache reuse for semantically equivalent requests. Leave grammar edge cases and combinatorial coverage in parser, planner, cache-key, and property tests.
- Add StreamData property tests when correctness depends on invariants across many input shapes or orderings, such as canonicalization, filesystem safety, parser order-insensitivity, cache keys, normalization, and round-trip behavior. Keep focused example tests for specific edge cases and error messages.

### Tests not to write

**Rule of thumb:** before writing a test, ask whether a real producer in this repo can construct the input you are about to assert on. If no in-repo producer creates that shape, you are testing impossible misuse — delete the production code path instead of pinning it with a test. Tests follow the same boundary discipline as validation (see *Elixir architecture guidelines*): assert at boundaries the caller doesn't control, trust what another module in this codebase just produced.

- **No impossible-internal-misuse tests.** Do not hand-build internal structs (parser ops, transform operations, plan pipelines, cache entries) that no real producer in this codebase constructs, just to assert that a validator rejects them or that a negative guard branch fires. Hand-built `%ImagePipe.Transform.Operation.Resize{}`, `%ImagePipe.Plan.Pipeline{}`, or parser-internal struct literals outside parser/planner test files are a strong signal.
- **No name- or existence-policing tests.** Do not assert that a module exists, that a function is exported (`function_exported?/3`, `Code.ensure_loaded?/1`), or that a stale module remains deleted. If a real caller needs the function, that caller's test already exercises it; if no real caller exists, the test is policing a name.
- **No post-migration parity pins.** After a rename or refactor lands, delete the parity, characterization, and "old vs new" tests added to pin it during the transition. Keep them only if they cover behavior no other test asserts. Files named `*_characterization_test.exs` in this greenfield codebase are a smell — they usually mean the refactor is done and the pin has lost its purpose.
- **No private-implementation tests.** Do not assert on exact private validation error strings, bang vs non-bang spellings, or other private helper choices. Test the runtime contract, not the implementation path that satisfies it.
- **No source-text scanning outside architecture tests.** Reading `.ex` files to grep for forbidden references is allowed only in `test/image_pipe/architecture_boundary_test.exs`, and only to enforce namespace boundaries (e.g. request code must not name concrete transform modules). Anywhere else, source scanning is a smell.

### Process discipline

- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

  - Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages
