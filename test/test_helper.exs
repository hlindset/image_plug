# Cross-process `assert_receive {:DOWN, ...}` liveness checks (e.g. the
# SourceSession.Producer tests) can exceed the default 100ms budget under CI
# scheduler load (oversubscribed cores plus libvips/NIF work on dirty
# schedulers), producing flaky timeouts. Give those waits more slack; it does
# not slow down the passing path, which delivers the message near-instantly.
# `:imgproxy_triage` quarantines recorded-but-unresolved imgproxy differential
# discrepancies (see the lane README + issues #194-#197); run them with
# `--include imgproxy_triage`.
ExUnit.start(
  capture_log: true,
  assert_receive_timeout: 2_000,
  exclude: [:image_vision, :imgproxy_triage]
)

{:ok, _} = Application.ensure_all_started(:req)
