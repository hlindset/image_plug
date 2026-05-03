## Project guidelines

- Use `mise exec -- ...` to run things in this repo with the correct versions of things
- This project is a greenfield, unreleased library; backwards compatibility should not be a concern at this point in time

## Native API guidelines

- Treat ImagePlug's native API as path-oriented and declarative. URL option order must not define processing order; parsing should produce a `ProcessingRequest`, and `PipelinePlanner` owns the fixed transform order.
- Keep ImagePlug's core model product-neutral, while allowing deliberate compatibility targets when explicitly chosen. Compatibility parsers should translate into `ProcessingRequest` when semantics match cleanly; dialect-specific quirks should stay isolated in the parser/adapter layer and should not force ordered command semantics into the native API contract.

## Transform guidelines

- Keep transforms product-neutral and composable. Transform modules should express reusable image operations over `TransformState` with explicit parameter structs, not parser-specific or vendor-specific concepts; parsers for dialects such as imgproxy, Thumbor, TwicPics, imgix, Cloudinary, or any other product should translate their syntax into `ProcessingRequest` when semantics match cleanly, or remain isolated compatibility adapters when they need dialect-specific ordered behavior.
- Be conservative with optimized decoding. Only use sequential access for transform chains proven safe for one-pass reads; crop, focus, cover, letterboxing, output-only requests, unknown transforms, and no-geometry requests should continue to use random access.

## Request safety guidelines

- Preserve request safety boundaries: parser and planner validation failures should return before origin fetch or cache access, origin fetching should use non-bang Req flows with bounded redirects/timeouts/content-type/body limits, and decoded input pixel limits should remain explicit.

## Cache guidelines

- Cache behavior is part of the contract. Cache only successful encoded responses; keep keys deterministic and based on resolved origin identity, canonical processing request fields, configured vary inputs, and normalized `Accept` for `format:auto`; cache errors fail open by default unless `fail_on_cache_error: true`.

## Elixir architecture guidelines

- Prefer Elixir extension points with explicit behaviours (`ImagePlug.ParamParser`, `ImagePlug.Transform`, `ImagePlug.Cache`), `@impl` annotations, typed parameter structs, and tagged `{:ok, value}` / `{:error, reason}` returns at runtime boundaries. Reserve raises for invalid initialization/configuration.
- Validate public options explicitly, preferably with `NimbleOptions` or adapter-owned `validate_options/1`, and reject unknown or malformed options before side effects.
- Use pattern matching, small private functions, and `with`/`case` pipelines to keep success paths linear while preserving precise error tags. Avoid catch-all rescues except where the boundary intentionally degrades to a safe default, such as transform metadata falling back to random access.

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
- Add StreamData property tests when correctness depends on invariants across many input shapes or orderings, such as canonicalization, filesystem safety, parser order-insensitivity, cache keys, normalization, and round-trip behavior. Keep focused example tests for specific edge cases and error messages.
- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

  - Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages
