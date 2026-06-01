# SSRF protection for origin fetches and redirects: design

**Status:** reviewed design, ready for implementation planning. Closes issue #48
(`type:security`, `priority:P1`, `area:source`, `status:partial`). Supersedes the
two research comments on #48 — this document keeps what they got right (the
factual gap analysis, deny-private-by-default posture, product-neutral policy in
the `Source` boundary) and corrects/extends them where the code review turned up
non-obvious consequences (see *Why the prior notes were incomplete*).

**Threat-model scope:** **resolve-and-validate**, not connection-pinned. We
resolve each host through an injectable resolver, classify every returned
address, and reject before connect. The DNS-rebinding (TOCTOU) window between our
validation and Finch's own connect-time re-resolution stays **open and
documented**; closing it (IP-pinning) is a tracked fast-follow, not this issue.
See *Deferred: DNS-rebinding / IP-pinning*.

## Problem

`ImagePipe.Source.HTTP` can be made to connect to internal infrastructure:

- **Origin host resolves to a private address.** `allowed_hosts` is an exact
  hostname allowlist; an allowlisted host can still resolve (now or via DNS
  change) to a loopback/link-local/private/internal IP. Nothing checks resolved
  addresses today.
- **Redirects escape every check.** `allowed_hosts` is enforced only in
  `resolve/3` against the *original* URL (`lib/image_pipe/source/http.ex:53`).
  When `max_redirects > 0`, `fetch/3` passes the count straight to `Req.get`
  (`lib/image_pipe/source/http.ex:96`) and nothing re-validates redirect targets
  — not the host, not the address. A trusted `root_url` path, or any allowlisted
  host with an open redirect, can bounce to loopback/private/arbitrary hosts.

Default posture is currently safe only because `max_redirects` defaults to `0`.
The moment a deployment opts into redirects, both gaps above are live.

## Why the prior notes were incomplete

The two #48 comments are factually correct but miss three things that shape the
design:

1. **`allowed_hosts` already narrows the real surface.** It is `required: true`,
   so the residual SSRF surface is exactly three vectors: (a) an allowlisted host
   resolving to a non-public IP, (b) a redirect leaving the allowlist, (c) DNS
   rebinding. The feature targets these three, not "we have no protection."
2. **The test harness uses Req's `plug:` adapter — there is no real socket or DNS
   in tests** (every test in `test/image_pipe/source/http_test.exs` passes
   `req_options: [plug: plug]`). A transport-layer check (the `net.Dialer.Control`
   equivalent imgproxy uses) would therefore never run in any test and would exist
   only in production. This forces the validation **up into the source application
   layer** and forces DNS resolution to be an **injectable seam**.
3. **Turning on default-deny breaks the existing suite.** Those plug-based tests
   fetch the hostname `assets.example.com`, which does not really resolve. Once
   the guard does DNS, real `:inet` returns `NXDOMAIN` and every existing HTTP
   test fails. The resolver injection (point 2) is what lets those tests stub the
   lookup. This is unavoidable churn, called out in *Tests*.

## Design overview

Two pieces:

1. **`ImagePipe.Source.HTTP.AddressPolicy`** — a pure, I/O-free module: canonicalize
   an IP, classify it into a category, and decide allow/deny against a validated
   policy. Owns the bypass-canonicalization that is the security-critical core.
2. **A Req request step**, built in `HTTP.fetch/3` and prepended to the Req
   pipeline, that on the initial request *and every redirect hop* re-checks
   `allowed_hosts`, resolves the host via an injected resolver, and runs the
   address policy — halting the request (no connect) on any failure.

`resolve/3` is unchanged except in role: it stays the cheap, I/O-free
`allowed_hosts` gate that feeds the cache key. **All DNS and address work happens
at fetch time**, inside the source side-effect boundary, before the actual TCP
connect — never in `resolve/3` (which must stay side-effect-free for cache-key
derivation).

### Why a Req request step (not a transport hook)

- A request step runs **before the adapter connects**; `Req.Request.halt/2` with
  an error means the connection never opens — fail-closed.
- Req's redirect follower re-issues the redirected request through the **same
  request pipeline**, so a prepended step runs again on **every hop**. One step
  covers origin + all redirects uniformly; no separate redirect-loop code.
- Request steps **also run under the `plug:` adapter**, so the guard fires in
  tests. Combined with the injected resolver, an acceptance test needs no real
  socket and no real DNS.

**Load-bearing assumption to verify first (spike):** that request steps genuinely
re-run on each redirect hop in **Req 0.5.17** specifically (deps are not vendored
on disk in this worktree; this rests on Req's documented redirect behavior, not
its source). Implementation step one is a focused test asserting it. **Fallback if
false:** own the redirect loop ourselves — pass `max_redirects: 0` to Req and
follow `Location` manually, running the same guard per hop. Same testability, more
code, fully under our control.

## `ImagePipe.Source.HTTP.AddressPolicy`

Nested under `HTTP` (its only consumer), inside the existing `Source` boundary.
IP classification is conceptually transport-agnostic, but `File` is local and `S3`
hits fixed endpoints, so HTTP is the only source that connects to arbitrary
resolved hosts. Per the repo rule "add it when the future caller appears, with a
test," we do **not** promote it to a shared `Source`-level module until a second
source needs it.

### Classification

`classify/1 :: :inet.ip_address() -> category` where category is one of:

```
:loopback | :unspecified | :link_local | :private | :unique_local |
:multicast | :broadcast | :cgnat | :reserved | :public
```

**Canonicalization is part of classification and is the security core.** Before
classifying, unwrap:

- IPv4-mapped IPv6 (`::ffff:a.b.c.d`) → classify by the embedded IPv4.
- IPv4-compatible / deprecated-embedding forms → same.

The concrete default-blocked set (the exact ranges per category) is **owned by
this module and its property tests**, not pinned in this prose — mirroring the
cache-key guidance ("which fields compose the key is owned by the module and its
tests"). Default intent: **everything that is not `:public` is denied.** Includes
at minimum loopback (`127.0.0.0/8`, `::1`), unspecified (`0.0.0.0`, `::`),
link-local (`169.254.0.0/16`, `fe80::/10`), private (`10/8`, `172.16/12`,
`192.168/16`), unique-local (`fc00::/7`), CGNAT (`100.64.0.0/10`), multicast,
broadcast, and reserved/benchmark/documentation ranges.

### Policy decision

The validated policy compiles to a single internal predicate
`(ip :: :inet.ip_address(), category :: atom) -> boolean()`. Both config forms
(below) compile to this shape.

**Multi-address responses: block if *any* returned address is disallowed.** We
cannot control which address Finch ultimately selects, and a mixed
public/private answer is itself a rebinding signal. Conservative default; can
relax behind config later if a real caller needs it.

## Config: `address_policy`

A new `HTTP` option, validated via `NimbleOptions` (host config = a real
boundary). Accepts **either** form:

### Keyword-list form (ergonomic default)

```elixir
url: {ImagePipe.Source.HTTP,
  allowed_hosts: ["assets.example.com"],
  max_redirects: 3,
  address_policy: [
    allow_loopback: false,
    allow_link_local: false,
    allow_private: false,          # coarse blanket toggle (opens ALL of RFC1918)
    allow: ["10.0.5.0/24"]         # precise CIDR opt-in (opens exactly this)
  ]
}
```

- Coarse `allow_*` booleans flip whole categories.
- `allow:` is a list of exact CIDR strings for the "just this internal host"
  case — strictly more precise than `allow_private: true`.
- Omitting `address_policy` entirely ⇒ **default-deny all non-public.**

### Function form (escape hatch)

```elixir
address_policy: fn _ip, category -> category == :public end
# or
address_policy: fn ip, _category -> ip in my_pinned_set end
```

A 2-arity function receives the **canonicalized IP and our computed category** —
the host never re-implements the bypass-canonicalization. It returns `true`
(allow) / `false` (deny). It is a host-implementable value crossing the boundary,
so we **validate its return and fail closed**: a non-boolean return is treated as
**deny**. `NimbleOptions` validates up front that `address_policy` is a keyword
list *or* a 2-arity function.

The function form **replaces** the built-in decision (it does not merge with the
keyword toggles). A function that wants to defer to defaults composes them in its
own body.

## Resolver injection

The guard resolves hostnames through an injected resolver rather than calling
`:inet` directly, for two reasons: testability (point 2 above) and as a genuine
extension point (custom/caching/pinning resolvers).

- New `HTTP` option `address_resolver` (or equivalent), validated as a function;
  **default = built-in `:inet`/`:inet_res`-based resolver** returning
  `{:ok, [:inet.ip_address()]} | {:error, term}`.
- **IP-literal hosts skip DNS** — `:inet.parse_address/1` succeeds ⇒ classify the
  literal directly, no resolver call.
- Resolver error (NXDOMAIN, timeout, empty answer) ⇒ **fail closed** (reject the
  fetch). This is a host-implementable return crossing the boundary, so its shape
  is validated at the boundary.

## Redirect host policy: re-enforce `allowed_hosts` on every hop

The guard re-checks each hop's host against the **same** `allowed_hosts` list. A
redirect to any host outside the allowlist is rejected **regardless of its IP**.
Rationale:

- `allowed_hosts` is the library's declared trust boundary (`required: true`);
  letting a redirect walk out of it is incoherent and turns any allowlisted host
  with an open redirect into a general relay.
- Redirects to arbitrary *public* hosts are also a real problem here: they exfil
  request contents (e.g. signed-URL query params) and let an attacker serve bytes
  that get cached under our identity — IP policy alone catches none of that.
- It does not contradict #48 ("apply the policy to every hop" is about the IP
  gap); strict re-check is strictly additive.
- Redirects are already opt-in (`max_redirects` default `0`) and the deployment
  owns `allowed_hosts` — a host that legitimately 302s to a CDN edge adds that
  edge host.

**No configurable opt-out for off-allowlist redirects** in this issue (YAGNI /
shrink-surface). Add it *with* the first real caller that needs it, plus that
caller's test.

## Order of checks in the guard (per hop)

1. `allowed_hosts` membership on the hop host. Fail ⇒ halt `{:source, :denied_host}`.
2. Resolve host → addresses (literal ⇒ classify directly; else injected resolver).
   Resolver error ⇒ halt (fail closed).
3. `AddressPolicy.allow?` over the address(es), block-if-any. Fail ⇒ halt
   `{:source, :denied_address}` (final tag owned by code).

All three are fail-closed and run before connect.

## Wiring

- `HTTP.fetch/3` builds the guard as a closure over
  `{allowed_hosts, compiled_policy, resolver}` and hands it to the Req pipeline.
- `ImagePipe.Source.ReqStream` gains a small generic addition: accept a
  `request_steps:` option and **prepend** them to the Req request, so it stays
  product-neutral and `HTTP` owns the SSRF policy. (`ReqStream` currently calls
  `Req.get(request_options, …)`; this becomes a `Req.new |> prepend_request_steps
  |> Req.get`-style construction, or equivalent, with the steps threaded through.)
- `resolve/3`: unchanged.

## Boundary / architecture notes

- `AddressPolicy` lives in the `Source` boundary; no new cross-boundary deps.
- DNS + address policy are source side effects → fetch path only, never
  `resolve/3`. Preserves the request-safety rule that planner/parser validation
  returns before source fetch while DNS (a side effect) sits inside fetch.
- Telemetry: a denied-address rejection is a meaningful source-stage outcome. Emit
  it on the existing `[:source, …]` span metadata. The **category and the IP are
  not sensitive** per the telemetry guidelines (product-neutral, low/PII-free);
  do **not** emit full source URLs (they may embed signed-URL secrets).

## Deferred: DNS-rebinding / IP-pinning (fast-follow, separate issue)

Resolve-and-validate leaves a TOCTOU window: after the guard validates a host's
addresses, Finch re-resolves at connect time, so a rebind can still slip a private
IP past us. Closing it means **pinning the connection to the validated IP** —
rewrite the hop host to the IP, carry the original hostname for `Host` header +
TLS SNI, and verify the cert against the original name.

Why it is a separate issue, not this one:

- The *logic* is small (the guard already holds the validated IP), but the cost
  is concentrated in **TLS plumbing** (threading SNI/`server_name_indication`
  per-request through Req 0.5.17 → Finch 0.22 → Mint 1.8 and confirming cert
  hostname verification still passes — needs a version-specific spike), a
  **real-HTTPS test harness** (self-signed cert, loopback HTTPS server,
  connect-to-IP-verify-against-name — the `plug:` adapter has no TLS), and
  **HTTP/2 connection-coalescing** analysis (a pooled h2 connection whose cert SAN
  covers another host can sidestep the pin).
- That is roughly as much effort again as this whole feature, almost all in test
  infrastructure and risk, not behavior.

**Action:** open a tracked follow-up issue capturing the spike notes above so they
are not lost. The #48 docs must state the rebinding residual plainly.

## Documentation

- Document the default network policy (deny-all-non-public) and both
  `address_policy` config forms, with the precise-CIDR vs blanket-toggle
  distinction.
- Document the redirect behavior (every hop re-checked against `allowed_hosts` +
  address policy).
- **State the DNS-rebinding residual explicitly** and link the fast-follow issue.

## Tests

All wire-level tests use real `ImagePipe.call/2`-style fetches through the `plug:`
adapter, per repo test guidelines.

Acceptance criteria (from #48), mapped to mechanics:

1. **Origin host resolving to a blocked private address** — two forms:
   (a) literal-IP host `https://10.0.0.1/x` with `allowed_hosts: ["10.0.0.1"]`
   (no resolver needed; classify literal); (b) hostname + **stub resolver**
   mapping it to a private IP (exercises the DNS branch). Assert rejected before
   any plug invocation.
2. **Public/trusted origin redirecting to a blocked private/loopback target** —
   origin allowlisted, plug returns `302` → `http://127.0.0.1/x`; assert blocked.
   Cover both the `allowed_hosts` re-check path (target not allowlisted) and the
   address-policy path (target allowlisted but private).
3. **`root_url`-based request whose origin response redirects to a blocked
   target** — same as (2) but via a `root_url`-built source URL.
4. **Explicit allow / opt-out for private origins** — `address_policy:
   [allow_private: true]` and the precise `allow: ["10.0.5.0/24"]` form both let a
   matching private target through; a private target *outside* the CIDR is still
   blocked. Plus the **function form**: `fn _ip, cat -> cat == :public end` blocks,
   a permissive function allows.

Unit / property tests on `AddressPolicy`:

- Property tests for `classify/1`: canonicalization (IPv4-mapped IPv6 classifies
  as its embedded v4), category boundaries, and that the default policy denies
  every non-`:public` category.
- Function-form fail-closed: a function returning a non-boolean ⇒ deny.
- Resolver fail-closed: resolver `{:error, _}` / empty ⇒ reject.

Existing-test migration (unavoidable, per *Why the prior notes were incomplete*
#3): every current `plug:`-based HTTP test that uses a non-resolving hostname gets
a shared **stub resolver** mapping that host to a public IP, so default-deny does
not break them. Keep this in the test setup/helper, not per-test.

Update the misleading **"redirects cannot bypass allowed host policy"** test
(`test/image_pipe/source/http_test.exs`) to set `max_redirects > 0` so it actually
exercises an enabled-redirect bypass attempt rather than passing only because
`max_redirects: 0` rejects the 302.

## Scope

**One PR.** The two-slice split considered during brainstorming was dropped: the
pure `AddressPolicy` module is not independently shippable value (it does nothing
until wired), unlike the object-gravity slices. One coherent PR: module +
property tests → request-step wiring + `ReqStream` change → config + resolver
plumbing → existing-test migration → acceptance tests → docs.

Out of scope: IP-pinning / rebinding closure (fast-follow issue), any
configurable off-allowlist-redirect opt-out, promoting `AddressPolicy` to a
shared `Source`-level module.

## Open questions

- Final error tag spelling for an address rejection (`{:source, :denied_address}`
  vs a more specific tag) — owned by code, decided at implementation.
- Whether `address_resolver` is a documented public option or an internal-but-real
  seam — leaning documented, since it is a legitimate extension point; confirm
  during planning.
