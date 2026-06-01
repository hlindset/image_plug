# SSRF protection for origin fetches and redirects: design

**Status:** reviewed design, ready for implementation planning. Closes issue #48
(`type:security`, `priority:P1`, `area:source`, `status:partial`). Supersedes the
two research comments on #48 — this document keeps what they got right (the
factual gap analysis, deny-private-by-default posture, product-neutral policy in
the `Source` boundary) and corrects/extends them where the code review turned up
non-obvious consequences (see *Why the prior notes were incomplete*).

**Revised after a three-reviewer parallel pass** (security-correctness,
Elixir/Req feasibility, architecture/conventions). The feasibility reviewer
verified findings against the actual **Req 0.5.17 / Finch 0.22 / Mint 1.8** source
(vendored in a sibling worktree). Accepted feedback is folded in below; the
biggest change is that the **Req-request-step mechanism was disproven and replaced
by an owned redirect loop** (see *How the guard runs*).

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
  — not the host, not the scheme, not the address. A trusted `root_url` path, or
  any allowlisted host with an open redirect, can bounce to loopback/private/
  arbitrary hosts.

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
2. **An owned redirect loop with a plain-function guard** in the fetch path. The
   guard runs before every connection — origin and each redirect hop — re-checking
   scheme, `allowed_hosts`, resolving the host via an injected resolver, and
   running the address policy. We follow redirects ourselves rather than letting
   Req do it (see below), so the guard is ordinary code we call, not a framework
   hook.

`resolve/3` is unchanged except in role: it stays the cheap, I/O-free
`allowed_hosts` gate that feeds the cache key. **All DNS and address work happens
at fetch time**, inside the source side-effect boundary, before the actual TCP
connect — never in `resolve/3` (which must stay side-effect-free for cache-key
derivation).

### How the guard runs: an owned redirect loop (NOT a Req request step)

The first draft proposed prepending a **Req request step** that would re-run on
each redirect hop. **This was disproven against Req 0.5.17 source:**
`Req.Steps.redirect/1` is a *response* step that rebuilds the request and calls
`Req.Request.run_request/1` with `current_request_steps` already drained to `[]`
(`req/lib/req/request.ex:1117`); it does not re-seed request steps from
`request_steps`. **So request steps run on the origin only, and every redirect hop
connects unchecked** — exactly the gap we must close. A request-step guard would
be silently open on hops 2..N. Rejected.

**Mechanism we use instead — own the loop:**

- Disable Req's redirect following (`max_redirects: 0` / `redirect: false`).
- The fetch path runs a bounded loop (≤ `max_redirects` + 1 iterations). Each
  iteration:
  1. **Guard the target URL** (plain function — order in *Order of checks*).
     Reject ⇒ return a typed `{:source, …}` error; **no connection is opened**,
     because the guard runs before the request.
  2. Open a single streaming request to that exact URL with redirects disabled.
  3. On `2xx`: hand back the streaming body — done.
  4. On `3xx` with a `Location`: compute the next absolute target via
     `URI.merge(current_url, location)` (mirroring Req's own
     `URI.merge(URI.parse(location))` semantics so relative, protocol-relative,
     and scheme-changing redirects normalize to a concrete scheme+host), then
     loop. Hop count exhausted ⇒ error.
  5. Any other status / error ⇒ error.

This lives in `ReqStream` (which owns the `Stream.resource` lazy open), with the
guard passed in from `HTTP` as a product-neutral closure
(`validate_target :: (URI.t()) -> :ok | {:source, reason}`). Because the loop
runs inside the stream's init thunk, laziness is preserved; intermediate `3xx`
responses are opened and cancelled, and the final `2xx` body streams as today.

**Why this is strictly better than the step approach, beyond just working:**

- The guard runs **before** we open each connection in *our* code, so
  "fail-closed before connect" is a structural property of this module, not a bet
  on Req's halt semantics. (The `plug:` adapter can't prove "halt ⇒ no socket"
  anyway; owning the loop removes the need to.)
- We control the error tag end-to-end. (A Req request step's `halt` error is
  flattened to `:bad_status` by `ReqStream.open_response`'s blanket
  `{:error, _} -> {:error, :bad_status}` arm, so guard-specific tags like
  `:denied_address` would never surface — another reason the step approach was a
  dead end.)

### Plug-adapter testability is preserved

The owned loop runs under `req_options: [plug: plug]` just as well: each hop's
plug response drives the next loop iteration, and the injected resolver means no
real DNS. An acceptance test needs no real socket and no real DNS.

## `ImagePipe.Source.HTTP.AddressPolicy`

Nested under `HTTP` (its only consumer), inside the existing `Source` boundary.
IP classification is conceptually transport-agnostic, but `File` is local and `S3`
hits fixed endpoints, so HTTP is the only source that connects to arbitrary
resolved hosts. Per the repo rule "add it when the future caller appears, with a
test," we do **not** promote it to a shared `Source`-level module until a second
source needs it.

**Boundary export:** `AddressPolicy` is an **internal** `Source`-boundary module,
consumed only by its sibling `HTTP`. It is intentionally **not** added to the
`Source` boundary `exports:` list (`lib/image_pipe/source.ex`) — exporting it would
violate "export only behaviours and stable entry points, not implementation
helpers." Sibling modules in the same boundary do not need an export to call it.

### Classification

`classify/1 :: :inet.ip_address() -> category` where category is one of:

```
:loopback | :unspecified | :link_local | :private | :unique_local |
:multicast | :broadcast | :cgnat | :reserved | :public
```

**Two hard rules, both load-bearing for fail-closed:**

1. **Canonicalize on the parsed tuple, inside `classify/1`, for *both* the literal
   branch and the resolver branch.** `:inet.parse_address("::ffff:10.0.0.1")`
   returns the **8-element IPv6 tuple** `{0,0,0,0,0,65535,2560,1}`, *not*
   `{10,0,0,1}`. So an IP-literal host that skips DNS must still be canonicalized
   or a mapped-literal private target slips through. Unwrap must be **tuple-based**
   (detect `elem(addr,5) == 0xffff`, rebuild embedded v4 from groups 6–7) so the
   hex spelling `::ffff:7f00:1` — which parses to the *same* tuple as
   `::ffff:127.0.0.1` — is caught identically. A string match on `"::ffff:"` would
   miss it.
2. **`classify/1` is total and defaults to DENY, never `:public`.** Unknown /
   unmatched IPv6 prefixes must classify to a blocked category (`:reserved`), not
   fall through to `:public`. A property test asserts *no* unknown v6 prefix
   returns `:public`. Given the sparse v6 space, the safe shape is an explicit
   public-range allowlist → `:public`, everything else → blocked.

**Default-blocked set** (exact ranges owned by this module + its property tests,
not pinned in prose — mirroring the cache-key guidance). Must include at minimum:

- IPv4: `0.0.0.0/8` (whole "this host" block, not just `0.0.0.0`), loopback
  `127.0.0.0/8`, link-local `169.254.0.0/16` (covers `169.254.169.254` cloud
  metadata), private `10/8` `172.16/12` `192.168/16`, CGNAT `100.64.0.0/10`,
  multicast `224.0.0.0/4`, broadcast `255.255.255.255`, benchmark `198.18.0.0/15`,
  documentation `192.0.2.0/24` `198.51.100.0/24` `203.0.113.0/24`.
- IPv6: unspecified `::`, loopback `::1`, link-local `fe80::/10`, unique-local
  `fc00::/7`, multicast `ff00::/8`, NAT64 `64:ff9b::/96`, 6to4 `2002::/16`
  (**unwrap** the embedded v4 `2002:V4HI:V4LO::/16` and classify *that* — a 6to4
  address embedding `10.x`/`127.x` must be denied), plus IPv4-mapped (rule 1).

The literal-encoding IPv4 bypasses (`http://2130706433/`, `http://0x7f.1/`,
`http://0177.0.0.1/`, `http://127.1/`, `http://0/`) are **already canonicalized by
`:inet.parse_address/1`** to their real tuples — do **not** hand-roll octal/hex/
dword decoding; route every literal through `:inet.parse_address` then `classify`.

### Policy decision

The validated policy compiles to a single internal predicate
`(ip :: :inet.ip_address(), category :: atom) -> boolean()`. Both config forms
(below) compile to this shape.

**Multi-address responses: allow only if *every* returned address is present,
well-formed, and allowed.** Block-if-any: we cannot control which address Finch
dials, a mixed public/private answer is a rebinding signal, and a malformed/
unparseable entry from a custom resolver counts as a denial (not skipped).

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
(allow) / `false` (deny), and **replaces** the built-in decision (it does not
merge with the keyword toggles).

### NimbleOptions spelling (verified)

```elixir
address_policy: [
  type: {:or, [
    {:fun, 2},
    keyword_list: [
      allow_loopback: [type: :boolean, default: false],
      allow_link_local: [type: :boolean, default: false],
      allow_private: [type: :boolean, default: false],
      # ... remaining category toggles ...
      allow: [type: {:list, :string}, default: []]
    ]
  ]}
]
```

The keyword-list subtype inside `{:or, …}` must use the 2-tuple form
`keyword_list: [<nested schema>]` (per-key validation), **not** the bare atom
`:keyword_list` (which validates "any keyword list" with no nesting). CIDR strings
in `allow:` need a `{:custom, …}` parse/validate (NimbleOptions does not parse
CIDRs). The `{:fun, 2}` subtype is unambiguous against `keyword_list`, so order is
safe; test both forms.

## Resolver injection

The guard resolves hostnames through an injected resolver rather than calling
`:inet` directly, for two reasons: testability (point 2 of *Why the prior notes
were incomplete*) and as a genuine extension point (custom/caching/pinning
resolvers).

- New `HTTP` option `address_resolver`, validated as a function; **default =
  built-in `:inet`/`:inet_res`-based resolver** returning
  `{:ok, [:inet.ip_address()]} | {:error, term}`.
- The built-in `:inet` resolver is the library default whenever `address_resolver`
  is omitted; the **stub resolver is test-only** (injected per-test via the option
  / a shared test helper), never the production default.
- **IP-literal hosts skip DNS** — feed the **unbracketed** host (the codebase
  stores IPv6 hosts unbracketed in `URL.host`; `:inet.parse_address("[::1]")`
  fails) to `:inet.parse_address/1`; success ⇒ classify the literal directly.
- **Fail closed on every failure mode:** resolver `{:error, _}`, `{:ok, []}`, a
  malformed address entry, **or a raised exception** from the resolver ⇒ reject
  the fetch. The host-supplied resolver and policy-function calls are wrapped so a
  raise becomes a denial, never an open path or an unhandled crash that bypasses
  the guard.

## Redirect host policy: re-enforce scheme + `allowed_hosts` on every hop

The guard re-checks each hop's **scheme** and **host**:

- **Scheme:** must be `:http` or `:https`. `Location: file:///…`, `gopher://`,
  `data:`, etc. are rejected before the host/address checks. (`resolve/3` guards
  scheme only on the *original* URL; the per-hop guard re-asserts it.)
- **Host:** **downcased** (mirroring `resolve/3`'s `String.downcase`), then checked
  against the **same** `allowed_hosts` list. A redirect to any host outside the
  allowlist is rejected **regardless of its IP**.

The host/scheme are read from the **`URI.merge`'d absolute target** (step 4 of the
loop), never the raw `Location` header, so protocol-relative (`//evil/…`),
relative (`/other.jpg`), and scheme-downgrade (`https→http`) redirects normalize
before checking. Rationale for re-enforcing the allowlist on hops:

- `allowed_hosts` is the library's declared trust boundary (`required: true`);
  letting a redirect walk out of it is incoherent and turns any allowlisted host
  with an open redirect into a general relay.
- Redirects to arbitrary *public* hosts are also a real problem here: they exfil
  request contents (e.g. signed-URL query params) and let an attacker serve bytes
  that get cached under our identity — IP policy alone catches none of that.
- It does not contradict #48; strict re-check is strictly additive.

**No configurable opt-out for off-allowlist redirects** in this issue (YAGNI /
shrink-surface). Add it *with* the first real caller that needs it, plus that
caller's test.

## Order of checks in the guard (per hop, before any connect)

1. **Scheme** ∈ {`:http`, `:https`} on the merged target. Fail ⇒
   `{:source, :denied_scheme}`.
2. **`allowed_hosts`** membership on the downcased target host. Fail ⇒
   `{:source, :denied_host}`.
3. **Resolve** host → addresses (literal ⇒ canonicalize+classify directly; else
   injected resolver). Resolver error / empty / raise ⇒ fail closed.
4. **`AddressPolicy.allow?`** over the address(es), block-if-any. Fail ⇒
   `{:source, :denied_address}`.

All four are fail-closed and run before connect. (Final tag spellings owned by
code; the `denied_*` set here is the design intent.)

## Wiring

- `HTTP.fetch/3` builds the guard closure over
  `{allowed_hosts, compiled_policy, resolver}` and the redirect bound, and hands
  it to `ReqStream` as `validate_target` + a redirect limit. It passes
  `max_redirects: 0` to Req so Req never follows redirects itself.
- `ImagePipe.Source.ReqStream` owns the redirect loop inside its
  `Stream.resource` open thunk: validate target → open one request (redirects
  disabled) → on `3xx` merge `Location`, re-validate, re-open → on `2xx` stream.
  It stays product-neutral (`HTTP` owns the policy closure). Guard rejections
  surface with their own `{:source, …}` reason — **do not** collapse them through
  the existing `{:error, _} -> {:error, :bad_status}` arm.
- `HTTP.fetch/3` must **strip `:address_policy` and `:address_resolver` from
  `req_options`** before they reach Req (add to `@internal_option_keys`), or Req's
  `validate_options` will reject the unregistered keys.
- `resolve/3`: unchanged.

## Boundary / architecture notes

- `AddressPolicy` lives in the `Source` boundary, **unexported** (see above); no
  new cross-boundary deps (pure IP math; `Source` already deps only on
  `Error`/`Plan`/`Telemetry`).
- DNS + address policy are source side effects → fetch path only, never
  `resolve/3`. Preserves the request-safety rule that planner/parser validation
  returns before source fetch while DNS (a side effect) sits inside fetch.
- No concrete-transform-module references introduced; this is source-only work.

## Telemetry

A denied-address/host/scheme rejection is a returned `{:error, {:source, …}}`,
i.e. a **normal `:stop`** of the existing `[:source, :fetch]` span with an error
result — **not** an `:exception`. Today `source.ex`'s `result_metadata/1` turns
that into `%{result: :source_error, error: …}` for free, so the rejection is
already observable.

To additionally surface **category + canonicalized IP** (which `result_metadata/1`
does not carry today), thread those values back through the adapter's error return
so the span's stop metadata can include them, using the shared `Telemetry`
helpers rather than ad-hoc emission. Category + IP are **product-neutral and
PII-free** (sensitivity-not-cardinality rule), so they are fine to emit. **Do not
emit the full source URL** — it may embed signed-URL secrets.

## Deferred: DNS-rebinding / IP-pinning (fast-follow, separate issue)

Resolve-and-validate leaves a TOCTOU window: after the guard validates a host's
addresses, Finch re-resolves at connect time, so a rebind can still slip a private
IP past us. Owning the redirect loop does **not** close this — each hop's
`Req.get` still lets Finch re-resolve the host we validated. Closing it means
**pinning the connection to the validated IP** — rewrite the hop host to the IP,
carry the original hostname for `Host` header + TLS SNI, and verify the cert
against the original name.

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
- Document the redirect behavior (every hop re-checked against scheme +
  `allowed_hosts` + address policy).
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
   origin allowlisted, plug returns `302` → `http://127.0.0.1/x`; assert blocked,
   and assert the guard fired **on the redirect target specifically** (deny on
   hop 2, not merely a non-2xx final status). Cover both the `allowed_hosts`
   re-check path (target not allowlisted) and the address-policy path (target
   allowlisted but private).
3. **`root_url`-based request whose origin response redirects to a blocked
   target** — same as (2) but via a `root_url`-built source URL.
4. **Explicit allow / opt-out for private origins** — `address_policy:
   [allow_private: true]` and the precise `allow: ["10.0.5.0/24"]` form both let a
   matching private target through; a private target *outside* the CIDR is still
   blocked. Plus the **function form**: `fn _ip, cat -> cat == :public end` blocks,
   a permissive function allows.

Named regression / edge cases (security review):

- **`169.254.169.254`** (cloud metadata) — explicit named test, blocked as
  link-local.
- **IPv4-mapped literal** `https://[::ffff:10.0.0.1]/x` — blocked (canonicalizes
  to private), and the hex spelling `::ffff:7f00:1` — blocked as loopback.
- **NAT64 / 6to4** — `64:ff9b::…` blocked; `2002:…` embedding a private/loopback
  v4 blocked.
- **Non-http(s) redirect** — `Location: file:///etc/passwd` rejected (scheme).
- **Protocol-relative / scheme-downgrade redirect** — `Location: //evil/x` and
  `https→http` normalize via `URI.merge` and are checked against the allowlist.
- **Uppercase redirect host** — `Location: https://ASSETS.EXAMPLE.COM/x` matches
  `allowed_hosts: ["assets.example.com"]` (downcased).
- **IPv6 zone-id literal** in a redirect target is denied (link-local), not
  silently NXDOMAIN'd.

Unit / property tests on `AddressPolicy`:

- Property: `classify/1` canonicalization (mapped/6to4 classify by embedded v4),
  category boundaries, and **no unknown v6 prefix returns `:public`** (totality /
  deny-default).
- Function-form fail-closed: non-boolean return ⇒ deny; raised exception ⇒ deny.
- Resolver fail-closed: `{:error, _}` / empty / malformed entry / raise ⇒ reject.

Existing-test migration (unavoidable, per *Why the prior notes were incomplete*
#3): every current `plug:`-based HTTP test that uses a non-resolving hostname gets
a shared **test-only stub resolver** mapping that host to a public IP, so
default-deny does not break them. Keep this in the test setup/helper, not per-test,
and ensure it is never the library default.

Update the misleading **"redirects cannot bypass allowed host policy"** test
(`test/image_pipe/source/http_test.exs`) to set `max_redirects > 0` so it actually
exercises an enabled-redirect bypass attempt rather than passing only because
`max_redirects: 0` rejects the 302. Do **not** introduce `*_characterization_test`
parity pins during the existing-test churn.

## Scope

**One PR.** The two-slice split considered during brainstorming was dropped: the
pure `AddressPolicy` module is not independently shippable value (it does nothing
until wired), unlike the object-gravity slices. One coherent PR: module +
property tests → owned-redirect-loop wiring in `ReqStream`/`HTTP` → config +
resolver plumbing → existing-test migration → acceptance + edge tests → docs.

Out of scope: IP-pinning / rebinding closure (fast-follow issue), any
configurable off-allowlist-redirect opt-out, promoting `AddressPolicy` to a
shared `Source`-level module.

## Open questions

- Final error-tag spellings for the `denied_*` set — owned by code, decided at
  implementation.
- Whether `address_resolver` is a documented public option or an internal-but-real
  seam — leaning documented, since it is a legitimate extension point; confirm
  during planning.
