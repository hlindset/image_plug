# Cross-process `assert_receive {:DOWN, ...}` liveness checks (e.g. the
# SourceSession.Producer tests) can exceed the default 100ms budget under CI
# scheduler load (oversubscribed cores plus libvips/NIF work on dirty
# schedulers), producing flaky timeouts. Give those waits more slack; it does
# not slow down the passing path, which delivers the message near-instantly.
ExUnit.start(capture_log: true, assert_receive_timeout: 2_000, exclude: [:image_vision])
{:ok, _} = Application.ensure_all_started(:req)
