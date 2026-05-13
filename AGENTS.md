## Project guidelines

- Use `mise exec -- ...` to run things in this repo with the correct versions of things
- This project is a greenfield, unreleased library; backwards compatibility should not be a concern at this point in time
- Prefer shrinking unsupported API surface over preserving tidy errors for bad internal callers. If a code path exists only to define behavior for impossible internal misuse, delete that behavior and its test instead of adding guards, fallbacks, or replacement tests.

## Native API guidelines

- Treat ImagePlug's native API as path-oriented and declarative. URL option order must not define processing order; parsing should produce an `ImagePlug.Plan`, and current parser/plan modules own the fixed transform order.
- Keep ImagePlug's core model product-neutral, while allowing deliberate compatibility targets when explicitly chosen. Compatibility parsers should translate into `ImagePlug.Plan` when semantics match cleanly; dialect-specific quirks should stay isolated in the parser/adapter layer and should not force ordered command semantics into the native API contract.

## Transform guidelines

- Keep transforms product-neutral and composable. Transform modules should express reusable image operations over `ImagePlug.Transform.State` with explicit parameter structs, not parser-specific or vendor-specific concepts; parsers for dialects such as imgproxy, Thumbor, TwicPics, imgix, Cloudinary, or any other product should translate their syntax into `ImagePlug.Plan` when semantics match cleanly, or remain isolated compatibility adapters when they need dialect-specific ordered behavior.
- Trust operation structs inside the transform boundary. A transform struct missing required callbacks is a programmer error; validation should validate operation fields, not prove that the module implements the transform behaviour.
- Be conservative with optimized decoding. Only use sequential access for transform chains proven safe for one-pass reads; crop, focus, cover, letterboxing, output-only requests, and no-geometry requests should continue to use random access.

## Request safety guidelines

- Preserve request safety boundaries: parser and planner validation failures should return before origin fetch or cache access, origin fetching should use non-bang Req flows with bounded redirects/timeouts/content-type/body limits, and decoded input pixel limits should remain explicit.

## Cache guidelines

- Cache behavior is part of the contract. Cache only successful encoded responses; keep keys deterministic and based on resolved origin identity, canonical plan fields, configured vary inputs, and normalized `Accept` for `format:auto`; cache errors fail open by default unless `fail_on_cache_error: true`.

## Namespace boundary guidelines

- Keep the canonical request model under `ImagePlug.Plan.*`.
- Keep parser behaviours and adapters under `ImagePlug.Parser.*`; parser-specific compatibility quirks should translate into `ImagePlug.Plan` or remain isolated in the parser/adapter layer.
- Keep runtime side effects under `ImagePlug.Runtime.*`, including origin fetch, request execution, response sending, source identity, and runtime options.
- Keep output negotiation, format, policy, and encoding under `ImagePlug.Output.*`.
- Keep transform contracts, operation structs, state, decode planning, materialization, and cache material protocols under `ImagePlug.Transform.*`.
- Runtime code must dispatch through `ImagePlug.Transform` and must not name concrete transform operation modules such as `ImagePlug.Transform.Scale`, `Cover`, `Contain`, `Crop`, or `Focus`.
- Boundary exports should stay narrow. Export behaviours and stable public/internal entry points, not implementation helpers.
- `ImagePlug.SimpleServer` is dev/test support only and must remain outside prod compilation.

## Boundary library guidelines

- Use `Boundary` declarations to enforce the namespace ownership described above. When adding or moving a top-level namespace, define its dependency direction explicitly instead of relying on implicit compile-time reachability.
- Keep `deps:` aligned with architecture direction: parser code may depend on plan and transform construction APIs; runtime may depend on plan, cache, output, and the generic transform contract; cache may depend on plan/output/transform material; output may depend on plan; transform should remain independent of parser/runtime/cache/output.
- Export only behaviours and stable public/internal entry points from each boundary. Do not export implementation helpers just to satisfy a compile error; move the helper to the correct boundary or add a narrow facade.
- Runtime modules may call generic `ImagePlug.Transform` functions such as `transform_name/1`, `metadata/1`, and `execute/2`, but must not alias or reference concrete operation modules. Parser and planner modules may construct exported concrete operation structs when translating syntax into a product-neutral plan.
- Boundary rule changes should come with focused architecture tests, especially for runtime avoiding concrete transform modules and parser-specific structs.

## Elixir architecture guidelines

- Prefer Elixir extension points with explicit behaviours (`ImagePlug.Parser`, `ImagePlug.Transform`, `ImagePlug.Cache`), `@impl` annotations, typed parameter structs, and tagged `{:ok, value}` / `{:error, reason}` returns at runtime boundaries. Reserve raises for invalid initialization/configuration.
- Validate public options explicitly, preferably with `NimbleOptions` or adapter-owned `validate_options/1`, and reject unknown or malformed options before side effects.
- Keep validation at real boundaries: external input parsing, explicit construction APIs, runtime side-effect boundaries, cache key material, and output negotiation. Avoid duplicating validation across trusted internal structs just to make malformed hand-built data fail earlier or prettier.
- For trusted internal behaviour dispatch, call the callback directly and let missing callbacks raise. Do not add runtime duck-typing probes, callback-presence checks, or wrapper functions whose only purpose is to make impossible internal misuse return tidy errors.
- Constructor APIs should accept the narrowest shape that real callers use. Do not accept both keyword lists and maps, existing structs, or negative guard carve-outs such as `is_map(value) and not is_struct(value)` unless there is a real public caller or contract requiring it.
- Use pattern matching, small private functions, and `with`/`case` pipelines to keep success paths linear while preserving precise error tags. Avoid catch-all rescues unless a concrete runtime boundary intentionally degrades to a documented safe default; do not rescue trusted transform callback failures such as `metadata/1`.

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

- For behavior changes, add focused ExUnit coverage at the relevant boundary: parser grammar/order-insensitivity, planner mapping, plug-level no-origin-fetch failures, output negotiation including `Vary: Accept`, cache key/corruption behavior, and origin/decode limit handling.
- Do not test impossible internal misuse. Prefer deleting tests that only assert behavior for bad internal callers, hand-built impossible parser structs, negative guard branches, or exact private validation error strings. Add tests for public behavior and safety boundaries, not for every defensive clause.
- Do not add tests that only police names or modules from abandoned designs, such as asserting stale modules remain deleted. Boundary tests should enforce current architecture ownership and forbidden dependency directions, not memorialize old implementation paths.
- Add StreamData property tests when correctness depends on invariants across many input shapes or orderings, such as canonicalization, filesystem safety, parser order-insensitivity, cache keys, normalization, and round-trip behavior. Keep focused example tests for specific edge cases and error messages.
- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

  - Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages
