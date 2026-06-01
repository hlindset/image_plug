# SSRF Protection for Origin Fetches and Redirects — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Block `ImagePipe.Source.HTTP` from connecting to loopback/private/internal addresses — on the origin request and on every redirect hop — with an explicit per-deployment opt-out.

**Architecture:** A pure classifier module (`ImagePipe.Source.HTTP.AddressPolicy`) decides whether a resolved IP is allowed under a compiled policy. A guard module (`ImagePipe.Source.HTTP.TargetGuard`) turns a target URL into an allow/deny decision (scheme → `allowed_hosts` → resolve → classify). `ImagePipe.Source.ReqStream` stops delegating redirect-following to Req (`redirect: false`) and instead owns a bounded redirect loop that runs the guard before opening *each* connection; denials raise `ImagePipe.Source.StreamError` with a `:denied_*` reason. The Req-request-step approach was rejected during review — verified against Req 0.5.17 source, request steps do not re-run on redirect hops.

**Tech Stack:** Elixir, Req 0.5.17 (Finch 0.22 / Mint 1.8), NimbleOptions, ExUnit + StreamData (`~> 1.0`, already a dep), Erlang `:inet`.

**Spec:** `docs/superpowers/specs/2026-06-01-ssrf-protection-design.md`. Read it before starting; this plan implements it.

---

## Background an implementer needs

- **Run everything via mise:** `mise exec -- mix test path`, `mise exec -- mix format`, `mise exec -- mix credo --strict`, `mise exec -- mix compile --warnings-as-errors`. Never call `mix` bare.
- **`:inet` IP tuples:** IPv4 is a 4-tuple `{a,b,c,d}`; IPv6 is an 8-tuple `{a,b,c,d,e,f,g,h}` of 16-bit groups. `:inet.parse_address(charlist)` returns `{:ok, tuple} | {:error, :einval}`. **Pass it a charlist** (`~c"127.0.0.1"` or `String.to_charlist/1`), not a binary. It canonicalizes octal/hex/dword IPv4 literals (`~c"2130706433"` → `{127,0,0,1}`).
- **IPv4-mapped IPv6 gotcha (verified):** `:inet.parse_address(~c"::ffff:10.0.0.1")` returns the **8-tuple** `{0,0,0,0,0,65535,2560,1}`, *not* `{10,0,0,1}`. `2560 = 0x0A00` → `10.0`, next group `1` → `0.1`. So `classify/1` must unwrap on the tuple.
- **The codebase stores IPv6 hosts unbracketed** in `%URL{host: "::1"}`; `build_url/1` adds brackets only for the wire URL. So feed the unbracketed host to `:inet.parse_address`.
- **How stream errors surface today:** `ReqStream.stream/2` builds a `Stream.resource`. Its init thunk (`open_response`) returns either a success state map or `{:error, reason}`. The reducer clause `{:error, reason} -> raise StreamError, reason: reason` turns that into a raised `StreamError`. The existing redirect test asserts `assert_raise Source.StreamError, fn -> Enum.to_list(stream) end` then `assert error.reason == :bad_status`. We follow that exact pattern with `:denied_*` reasons.
- **Existing tests use Req's plug adapter:** `req_options: [plug: fn conn -> ... end]`. Request steps and our guard still run, but no real socket/DNS. The guard's resolver is injected so tests stub DNS.
- **Why existing tests will break:** they fetch the non-resolving hostname `assets.example.com`. Once the guard does real DNS, that's NXDOMAIN → fail-closed. Task 7 adds a shared test-only stub resolver to fix them.

---

## File Structure

**Create:**
- `lib/image_pipe/source/http/address_policy.ex` — pure: `classify/1`, CIDR parse/match, `compile/1`, `allow?/2`.
- `lib/image_pipe/source/http/target_guard.ex` — `validate/4` (scheme → host → resolve → policy), `default_resolver/1`.
- `test/image_pipe/source/http/address_policy_test.exs`
- `test/image_pipe/source/http/target_guard_test.exs`
- `docs/source-network-policy.md` — host-facing docs.

**Modify:**
- `lib/image_pipe/source/req_stream.ex` — own the redirect loop; accept `validate_target` + `max_redirects`; `redirect: false`.
- `lib/image_pipe/source/http.ex` — new options in schema; strip new keys from `req_options`; build the guard closure; pass it + redirect bound to `ReqStream`.
- `test/image_pipe/source/http_test.exs` — shared stub resolver; migrate existing tests; new acceptance/edge tests; fix the misleading redirect test.
- `README.md` — link the new doc and mention `address_policy` by the source example.

**Boundary note:** `AddressPolicy` and `TargetGuard` live in the existing `ImagePipe.Source` boundary as internal siblings of `HTTP`. **Do not** add them to the `Source` boundary `exports:` list in `lib/image_pipe/source.ex` — they are implementation modules consumed only within the boundary.

---

## Task 1: `AddressPolicy.classify/1` — IPv4 categories

**Files:**
- Create: `lib/image_pipe/source/http/address_policy.ex`
- Test: `test/image_pipe/source/http/address_policy_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule ImagePipe.Source.HTTP.AddressPolicyTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Source.HTTP.AddressPolicy

  describe "classify/1 IPv4" do
    test "categorizes well-known IPv4 ranges" do
      assert AddressPolicy.classify({127, 0, 0, 1}) == :loopback
      assert AddressPolicy.classify({127, 5, 5, 5}) == :loopback
      assert AddressPolicy.classify({0, 0, 0, 0}) == :unspecified
      assert AddressPolicy.classify({0, 1, 2, 3}) == :unspecified
      assert AddressPolicy.classify({169, 254, 169, 254}) == :link_local
      assert AddressPolicy.classify({10, 0, 0, 1}) == :private
      assert AddressPolicy.classify({172, 16, 0, 1}) == :private
      assert AddressPolicy.classify({172, 31, 255, 255}) == :private
      assert AddressPolicy.classify({172, 32, 0, 1}) == :public
      assert AddressPolicy.classify({192, 168, 1, 1}) == :private
      assert AddressPolicy.classify({100, 64, 0, 1}) == :cgnat
      assert AddressPolicy.classify({224, 0, 0, 1}) == :multicast
      assert AddressPolicy.classify({255, 255, 255, 255}) == :broadcast
      assert AddressPolicy.classify({198, 18, 0, 1}) == :reserved
      assert AddressPolicy.classify({192, 0, 2, 5}) == :reserved
      assert AddressPolicy.classify({93, 184, 216, 34}) == :public
      assert AddressPolicy.classify({8, 8, 8, 8}) == :public
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/source/http/address_policy_test.exs`
Expected: FAIL — `ImagePipe.Source.HTTP.AddressPolicy.classify/1 is undefined (module not available)`.

- [ ] **Step 3: Write minimal implementation**

```elixir
defmodule ImagePipe.Source.HTTP.AddressPolicy do
  @moduledoc false

  @type category ::
          :loopback
          | :unspecified
          | :link_local
          | :private
          | :unique_local
          | :multicast
          | :broadcast
          | :cgnat
          | :reserved
          | :public

  @spec classify(:inet.ip_address()) :: category()
  def classify({a, b, c, d}) do
    classify_v4(a, b, c, d)
  end

  defp classify_v4(0, _, _, _), do: :unspecified
  defp classify_v4(127, _, _, _), do: :loopback
  defp classify_v4(169, 254, _, _), do: :link_local
  defp classify_v4(10, _, _, _), do: :private
  defp classify_v4(172, b, _, _) when b in 16..31, do: :private
  defp classify_v4(192, 168, _, _), do: :private
  defp classify_v4(100, b, _, _) when b in 64..127, do: :cgnat
  defp classify_v4(a, _, _, _) when a in 224..239, do: :multicast
  defp classify_v4(255, 255, 255, 255), do: :broadcast
  # benchmarking 198.18.0.0/15
  defp classify_v4(198, b, _, _) when b in 18..19, do: :reserved
  # documentation 192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24
  defp classify_v4(192, 0, 2, _), do: :reserved
  defp classify_v4(198, 51, 100, _), do: :reserved
  defp classify_v4(203, 0, 113, _), do: :reserved
  # 240.0.0.0/4 reserved (future use)
  defp classify_v4(a, _, _, _) when a in 240..255, do: :reserved
  defp classify_v4(_, _, _, _), do: :public
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/source/http/address_policy_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/source/http/address_policy.ex test/image_pipe/source/http/address_policy_test.exs
git commit -m "feat(source): AddressPolicy.classify/1 for IPv4 ranges"
```

---

## Task 2: `classify/1` — IPv6 + canonicalization (mapped, NAT64, 6to4), deny-default

**Files:**
- Modify: `lib/image_pipe/source/http/address_policy.ex`
- Test: `test/image_pipe/source/http/address_policy_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
  describe "classify/1 IPv6 and canonicalization" do
    test "categorizes native IPv6 ranges" do
      assert AddressPolicy.classify({0, 0, 0, 0, 0, 0, 0, 0}) == :unspecified
      assert AddressPolicy.classify({0, 0, 0, 0, 0, 0, 0, 1}) == :loopback
      assert AddressPolicy.classify({0xFE80, 0, 0, 0, 0, 0, 0, 1}) == :link_local
      assert AddressPolicy.classify({0xFC00, 0, 0, 0, 0, 0, 0, 1}) == :unique_local
      assert AddressPolicy.classify({0xFD00, 0, 0, 0, 0, 0, 0, 1}) == :unique_local
      assert AddressPolicy.classify({0xFF00, 0, 0, 0, 0, 0, 0, 1}) == :multicast
      assert AddressPolicy.classify({0x2606, 0x2800, 0, 0, 0, 0, 0, 1}) == :public
    end

    test "unwraps IPv4-mapped IPv6 and classifies by embedded v4 (dotted and hex spellings)" do
      # ::ffff:10.0.0.1  and  ::ffff:0a00:1  are the same tuple
      assert AddressPolicy.classify({0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001}) == :private
      assert AddressPolicy.classify({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001}) == :loopback
      assert AddressPolicy.classify({0, 0, 0, 0, 0, 0xFFFF, 0x5DB8, 0xD822}) == :public
    end

    test "blocks NAT64 and unwraps 6to4 by embedded v4" do
      # 64:ff9b::/96 NAT64
      assert AddressPolicy.classify({0x64, 0xFF9B, 0, 0, 0, 0, 0x0A00, 0x0001}) == :reserved
      # 2002:V4HI:V4LO::/16 6to4 embedding 127.0.0.1 -> loopback
      assert AddressPolicy.classify({0x2002, 0x7F00, 0x0001, 0, 0, 0, 0, 0}) == :loopback
      # 6to4 embedding a public v4 -> public
      assert AddressPolicy.classify({0x2002, 0x5DB8, 0xD822, 0, 0, 0, 0, 0}) == :public
    end

    test "unknown IPv6 never defaults to :public (deny-default)" do
      # 3fff::/20 reserved-ish unknown range must not be :public
      refute AddressPolicy.classify({0x3FFF, 0, 0, 0, 0, 0, 0, 1}) == :public
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/source/http/address_policy_test.exs`
Expected: FAIL — `classify/1` has no IPv6 clause (FunctionClauseError).

- [ ] **Step 3: Write minimal implementation**

Add an 8-tuple clause to `classify/1` and supporting private functions. Replace the single `classify({a,b,c,d})` head region with both heads:

```elixir
  @spec classify(:inet.ip_address()) :: category()
  def classify({a, b, c, d}), do: classify_v4(a, b, c, d)

  def classify({_, _, _, _, _, _, _, _} = v6) do
    case canonicalize_v6(v6) do
      {:v4, {a, b, c, d}} -> classify_v4(a, b, c, d)
      {:v6, v6} -> classify_v6(v6)
    end
  end

  # IPv4-mapped ::ffff:0:0/96
  defp canonicalize_v6({0, 0, 0, 0, 0, 0xFFFF, g, h}), do: {:v4, embed_v4(g, h)}
  # 6to4 2002::/16 embeds v4 in the next two groups
  defp canonicalize_v6({0x2002, g, h, _, _, _, _, _}), do: {:v4, embed_v4(g, h)}
  defp canonicalize_v6(v6), do: {:v6, v6}

  defp embed_v4(g, h) do
    <<a, b>> = <<g::16>>
    <<c, d>> = <<h::16>>
    {a, b, c, d}
  end

  defp classify_v6({0, 0, 0, 0, 0, 0, 0, 0}), do: :unspecified
  defp classify_v6({0, 0, 0, 0, 0, 0, 0, 1}), do: :loopback
  # NAT64 64:ff9b::/96 — treat as non-public; we did not embed-unwrap it
  defp classify_v6({0x64, 0xFF9B, 0, 0, 0, 0, _, _}), do: :reserved
  defp classify_v6({a, _, _, _, _, _, _, _}) when a >= 0xFE80 and a <= 0xFEBF, do: :link_local
  defp classify_v6({a, _, _, _, _, _, _, _}) when a >= 0xFC00 and a <= 0xFDFF, do: :unique_local
  defp classify_v6({a, _, _, _, _, _, _, _}) when a >= 0xFF00, do: :multicast
  # Global unicast 2000::/3 is the only public v6 space; everything else denies.
  defp classify_v6({a, _, _, _, _, _, _, _}) when a >= 0x2000 and a <= 0x3FFF, do: :public
  defp classify_v6(_), do: :reserved
```

Note on `3fff::/20`: it falls in `2000::/3` so the generic rule would call it `:public`. The test only requires `3fff:...` to be non-public *if* you treat it as reserved; IANA reserved `3fff::/20` for documentation (RFC 9637). Add a clause **before** the `2000..3FFF` public clause:

```elixir
  defp classify_v6({0x3FFF, b, _, _, _, _, _, _}) when b < 0x1000, do: :reserved
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/source/http/address_policy_test.exs`
Expected: PASS (both Task 1 and Task 2 describe blocks).

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/source/http/address_policy.ex test/image_pipe/source/http/address_policy_test.exs
git commit -m "feat(source): AddressPolicy IPv6 classify + mapped/NAT64/6to4 canonicalization"
```

---

## Task 3: CIDR parsing + membership

**Files:**
- Modify: `lib/image_pipe/source/http/address_policy.ex`
- Test: `test/image_pipe/source/http/address_policy_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
  describe "CIDR" do
    test "parse_cidr/1 accepts valid v4/v6 CIDRs and rejects junk" do
      assert {:ok, _} = AddressPolicy.parse_cidr("10.0.5.0/24")
      assert {:ok, _} = AddressPolicy.parse_cidr("2001:db8::/32")
      assert :error = AddressPolicy.parse_cidr("10.0.5.0")
      assert :error = AddressPolicy.parse_cidr("10.0.5.0/33")
      assert :error = AddressPolicy.parse_cidr("nonsense")
      assert :error = AddressPolicy.parse_cidr("2001:db8::/129")
    end

    test "in_cidr?/2 matches membership" do
      {:ok, cidr} = AddressPolicy.parse_cidr("10.0.5.0/24")
      assert AddressPolicy.in_cidr?({10, 0, 5, 7}, cidr)
      assert AddressPolicy.in_cidr?({10, 0, 5, 0}, cidr)
      assert AddressPolicy.in_cidr?({10, 0, 5, 255}, cidr)
      refute AddressPolicy.in_cidr?({10, 0, 6, 1}, cidr)
      refute AddressPolicy.in_cidr?({10, 0, 5, 7, 0, 0, 0, 0}, cidr)

      {:ok, cidr6} = AddressPolicy.parse_cidr("2001:db8::/32")
      assert AddressPolicy.in_cidr?({0x2001, 0x0DB8, 1, 2, 3, 4, 5, 6}, cidr6)
      refute AddressPolicy.in_cidr?({0x2001, 0x0DB9, 0, 0, 0, 0, 0, 0}, cidr6)
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/source/http/address_policy_test.exs`
Expected: FAIL — `parse_cidr/1`/`in_cidr?/2` undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
  @type cidr :: {non_neg_integer(), 0..128, 32 | 128}

  @spec parse_cidr(String.t()) :: {:ok, cidr()} | :error
  def parse_cidr(string) when is_binary(string) do
    with [addr, prefix] <- String.split(string, "/", parts: 2),
         {:ok, tuple} <- :inet.parse_address(String.to_charlist(addr)),
         {prefix_int, ""} <- Integer.parse(prefix),
         bits when bits in [32, 128] <- tuple_bits(tuple),
         true <- prefix_int >= 0 and prefix_int <= bits do
      {:ok, {tuple_to_int(tuple), prefix_int, bits}}
    else
      _ -> :error
    end
  end

  @spec in_cidr?(:inet.ip_address(), cidr()) :: boolean()
  def in_cidr?(ip, {net_int, prefix, bits}) do
    if tuple_bits(ip) == bits do
      shift = bits - prefix
      Bitwise.bsr(tuple_to_int(ip), shift) == Bitwise.bsr(net_int, shift)
    else
      false
    end
  end

  defp tuple_bits({_, _, _, _}), do: 32
  defp tuple_bits({_, _, _, _, _, _, _, _}), do: 128

  defp tuple_to_int({a, b, c, d}), do: (a <<< 24) + (b <<< 16) + (c <<< 8) + d

  defp tuple_to_int({a, b, c, d, e, f, g, h}) do
    [a, b, c, d, e, f, g, h]
    |> Enum.reduce(0, fn group, acc -> (acc <<< 16) + group end)
  end
```

Add `import Bitwise` near the top of the module (after `@moduledoc false`). The `<<<` / `>>>` operators come from `Bitwise`; `Bitwise.bsr/2` is the function form.

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/source/http/address_policy_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/source/http/address_policy.ex test/image_pipe/source/http/address_policy_test.exs
git commit -m "feat(source): AddressPolicy CIDR parse + membership"
```

---

## Task 4: `compile/1` + `allow?/2` (toggles, CIDR allow, function form, fail-closed)

**Files:**
- Modify: `lib/image_pipe/source/http/address_policy.ex`
- Test: `test/image_pipe/source/http/address_policy_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
  describe "compile/1 + allow?/2" do
    test "default keyword policy denies all non-public, allows public" do
      pred = AddressPolicy.compile([])
      assert AddressPolicy.allow?(pred, [{93, 184, 216, 34}])
      refute AddressPolicy.allow?(pred, [{10, 0, 0, 1}])
      refute AddressPolicy.allow?(pred, [{127, 0, 0, 1}])
    end

    test "category toggles open whole categories" do
      pred = AddressPolicy.compile(allow_private: true)
      assert AddressPolicy.allow?(pred, [{10, 0, 0, 1}])
      refute AddressPolicy.allow?(pred, [{127, 0, 0, 1}])
    end

    test "CIDR allow opens exactly the named range" do
      pred = AddressPolicy.compile(allow: ["10.0.5.0/24"])
      assert AddressPolicy.allow?(pred, [{10, 0, 5, 7}])
      refute AddressPolicy.allow?(pred, [{10, 0, 6, 7}])
    end

    test "block-if-any: one bad address denies the whole set" do
      pred = AddressPolicy.compile([])
      refute AddressPolicy.allow?(pred, [{93, 184, 216, 34}, {10, 0, 0, 1}])
    end

    test "malformed / empty address set denies" do
      pred = AddressPolicy.compile([])
      refute AddressPolicy.allow?(pred, [])
      refute AddressPolicy.allow?(pred, [:not_an_ip])
    end

    test "function form replaces built-in decision" do
      pred = AddressPolicy.compile(fn _ip, category -> category == :public end)
      assert AddressPolicy.allow?(pred, [{93, 184, 216, 34}])
      refute AddressPolicy.allow?(pred, [{10, 0, 0, 1}])
    end

    test "function form fails closed on non-boolean return and on raise" do
      pred_bad = AddressPolicy.compile(fn _ip, _cat -> :yes end)
      refute AddressPolicy.allow?(pred_bad, [{93, 184, 216, 34}])

      pred_raise = AddressPolicy.compile(fn _ip, _cat -> raise "boom" end)
      refute AddressPolicy.allow?(pred_raise, [{93, 184, 216, 34}])
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/source/http/address_policy_test.exs`
Expected: FAIL — `compile/1` / `allow?/2` undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
  @type predicate :: (:inet.ip_address(), category() -> boolean())

  @category_toggles %{
    allow_loopback: :loopback,
    allow_unspecified: :unspecified,
    allow_link_local: :link_local,
    allow_private: :private,
    allow_unique_local: :unique_local,
    allow_multicast: :multicast,
    allow_broadcast: :broadcast,
    allow_cgnat: :cgnat,
    allow_reserved: :reserved
  }

  @spec compile(keyword() | predicate()) :: predicate()
  def compile(fun) when is_function(fun, 2) do
    fn ip, category -> safe_bool(fun, ip, category) end
  end

  def compile(opts) when is_list(opts) do
    allowed_categories =
      for {toggle, category} <- @category_toggles, Keyword.get(opts, toggle, false), into: MapSet.new() do
        category
      end

    cidrs =
      opts
      |> Keyword.get(:allow, [])
      |> Enum.map(fn cidr ->
        {:ok, parsed} = parse_cidr(cidr)
        parsed
      end)

    fn ip, category ->
      category == :public or
        MapSet.member?(allowed_categories, category) or
        Enum.any?(cidrs, &in_cidr?(ip, &1))
    end
  end

  @spec allow?(predicate(), [:inet.ip_address()]) :: boolean()
  def allow?(_predicate, []), do: false

  def allow?(predicate, addresses) when is_list(addresses) do
    Enum.all?(addresses, fn
      {_, _, _, _} = ip -> predicate.(ip, classify(ip))
      {_, _, _, _, _, _, _, _} = ip -> predicate.(ip, classify(ip))
      _other -> false
    end)
  end

  defp safe_bool(fun, ip, category) do
    case fun.(ip, category) do
      true -> true
      _ -> false
    end
  rescue
    _ -> false
  end
```

Note: `compile/1` for the keyword form assumes CIDRs already validated at the config boundary (Task 5), so `{:ok, parsed} = parse_cidr(cidr)` is safe.

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/source/http/address_policy_test.exs`
Expected: PASS.

- [ ] **Step 5: Add a property test for deny-default totality**

```elixir
  describe "property: classify is total and deny-default" do
    use ExUnitProperties

    property "no IPv4 tuple crashes classify/1" do
      check all a <- integer(0..255), b <- integer(0..255), c <- integer(0..255), d <- integer(0..255) do
        assert AddressPolicy.classify({a, b, c, d}) in [
                 :loopback, :unspecified, :link_local, :private, :unique_local,
                 :multicast, :broadcast, :cgnat, :reserved, :public
               ]
      end
    end

    property "default policy never allows a non-public IPv4" do
      pred = AddressPolicy.compile([])
      check all a <- integer(0..255), b <- integer(0..255), c <- integer(0..255), d <- integer(0..255) do
        ip = {a, b, c, d}
        if AddressPolicy.classify(ip) != :public do
          refute AddressPolicy.allow?(pred, [ip])
        end
      end
    end
  end
```

Move `use ExUnitProperties` to the top of the test module (next to `use ExUnit.Case`) rather than inside `describe` if the formatter/compiler complains; keep `property` blocks where shown.

- [ ] **Step 6: Run, format, commit**

Run: `mise exec -- mix test test/image_pipe/source/http/address_policy_test.exs`
Expected: PASS.
Run: `mise exec -- mix format`

```bash
git add lib/image_pipe/source/http/address_policy.ex test/image_pipe/source/http/address_policy_test.exs
git commit -m "feat(source): AddressPolicy compile/allow + deny-default property tests"
```

---

## Task 5: `TargetGuard.validate/4` + `default_resolver/1`

**Files:**
- Create: `lib/image_pipe/source/http/target_guard.ex`
- Test: `test/image_pipe/source/http/target_guard_test.exs`

The guard takes a URL string, the `allowed_hosts` list, a compiled `AddressPolicy` predicate, and a resolver function `(host_string) -> {:ok, [ip]} | {:error, term}`. It returns `:ok | {:error, :denied_scheme | :denied_host | :denied_address}`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule ImagePipe.Source.HTTP.TargetGuardTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Source.HTTP.{AddressPolicy, TargetGuard}

  defp default_policy, do: AddressPolicy.compile([])

  defp resolver(map) do
    fn host -> Map.fetch(map, host) end
  end

  test "allows a public host that resolves to a public IP" do
    res = resolver(%{"assets.example.com" => {:ok, [{93, 184, 216, 34}]}})
    assert TargetGuard.validate("https://assets.example.com/x.jpg", ["assets.example.com"], default_policy(), res) == :ok
  end

  test "denies non-http(s) scheme before host checks" do
    assert TargetGuard.validate("file:///etc/passwd", ["assets.example.com"], default_policy(), resolver(%{})) ==
             {:error, :denied_scheme}
  end

  test "denies a host outside allowed_hosts, case-insensitively matched" do
    res = resolver(%{"assets.example.com" => {:ok, [{93, 184, 216, 34}]}})
    assert TargetGuard.validate("https://ASSETS.EXAMPLE.COM/x", ["assets.example.com"], default_policy(), res) == :ok
    assert TargetGuard.validate("https://evil.example/x", ["assets.example.com"], default_policy(), res) ==
             {:error, :denied_host}
  end

  test "denies when the host resolves to a private IP" do
    res = resolver(%{"assets.example.com" => {:ok, [{10, 0, 0, 1}]}})
    assert TargetGuard.validate("https://assets.example.com/x", ["assets.example.com"], default_policy(), res) ==
             {:error, :denied_address}
  end

  test "classifies IP-literal hosts directly without calling the resolver" do
    res = fn _ -> flunk("resolver should not be called for a literal") end
    assert TargetGuard.validate("https://10.0.0.1/x", ["10.0.0.1"], default_policy(), res) == {:error, :denied_address}
    assert TargetGuard.validate("https://93.184.216.34/x", ["93.184.216.34"], default_policy(), res) == :ok
  end

  test "classifies bracketed IPv6 literal hosts" do
    res = fn _ -> flunk("resolver should not be called for a literal") end
    assert TargetGuard.validate("http://[::1]/x", ["::1"], default_policy(), res) == {:error, :denied_address}
  end

  test "fails closed on resolver error, empty, and raise" do
    assert TargetGuard.validate("https://h/x", ["h"], default_policy(), resolver(%{"h" => {:error, :nxdomain}})) ==
             {:error, :denied_address}
    assert TargetGuard.validate("https://h/x", ["h"], default_policy(), resolver(%{"h" => {:ok, []}})) ==
             {:error, :denied_address}
    raise_res = fn _ -> raise "dns boom" end
    assert TargetGuard.validate("https://h/x", ["h"], default_policy(), raise_res) == {:error, :denied_address}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/source/http/target_guard_test.exs`
Expected: FAIL — `TargetGuard` undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
defmodule ImagePipe.Source.HTTP.TargetGuard do
  @moduledoc false

  alias ImagePipe.Source.HTTP.AddressPolicy

  @type resolver :: (String.t() -> {:ok, [:inet.ip_address()]} | {:error, term()})

  @spec validate(String.t(), [String.t()], AddressPolicy.predicate(), resolver()) ::
          :ok | {:error, :denied_scheme | :denied_host | :denied_address}
  def validate(url, allowed_hosts, predicate, resolver) when is_binary(url) do
    uri = URI.parse(url)

    with :ok <- check_scheme(uri),
         host = String.downcase(uri.host || ""),
         :ok <- check_host(host, allowed_hosts),
         {:ok, addresses} <- resolve(host, resolver) do
      if AddressPolicy.allow?(predicate, addresses), do: :ok, else: {:error, :denied_address}
    end
  end

  defp check_scheme(%URI{scheme: scheme}) when scheme in ["http", "https"], do: :ok
  defp check_scheme(_uri), do: {:error, :denied_scheme}

  defp check_host(host, allowed_hosts) do
    if host != "" and host in allowed_hosts, do: :ok, else: {:error, :denied_host}
  end

  defp resolve(host, resolver) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> {:ok, [ip]}
      {:error, _} -> resolve_via(host, resolver)
    end
  end

  defp resolve_via(host, resolver) do
    case resolver.(host) do
      {:ok, addresses} when is_list(addresses) -> {:ok, addresses}
      _other -> {:error, :denied_address}
    end
  rescue
    _ -> {:error, :denied_address}
  end

  @spec default_resolver(String.t()) :: {:ok, [:inet.ip_address()]} | {:error, term()}
  def default_resolver(host) do
    charlist = String.to_charlist(host)

    v4 = case :inet.getaddrs(charlist, :inet) do
      {:ok, addrs} -> addrs
      {:error, _} -> []
    end

    v6 = case :inet.getaddrs(charlist, :inet6) do
      {:ok, addrs} -> addrs
      {:error, _} -> []
    end

    case v4 ++ v6 do
      [] -> {:error, :nxdomain}
      addresses -> {:ok, addresses}
    end
  end
end
```

Note: `URI.parse("http://[::1]/x").host` returns `"::1"` (brackets stripped) — feed that to `:inet.parse_address`. The empty-resolve case `{:ok, []}` is caught because `AddressPolicy.allow?(_, [])` is `false`, but we map resolver-empty to `{:error, :denied_address}` here for an explicit fail-closed signal; both deny.

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/source/http/target_guard_test.exs`
Expected: PASS.

- [ ] **Step 5: Format + commit**

Run: `mise exec -- mix format`

```bash
git add lib/image_pipe/source/http/target_guard.ex test/image_pipe/source/http/target_guard_test.exs
git commit -m "feat(source): TargetGuard.validate + default DNS resolver"
```

---

## Task 6: `ReqStream` owns the redirect loop

**Files:**
- Modify: `lib/image_pipe/source/req_stream.ex`
- Test: existing `test/image_pipe/source/req_stream_test.exs` if present; otherwise covered via Task 8 wire tests. (Check: `ls test/image_pipe/source/req_stream_test.exs`.)

This task changes `ReqStream.stream/2` to (a) disable Req redirect-following and (b) follow redirects itself, running an injected `validate_target` closure before each connect.

- [ ] **Step 1: Write the failing test** (new file `test/image_pipe/source/req_stream_test.exs`)

```elixir
defmodule ImagePipe.Source.ReqStreamTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Source.ReqStream
  alias ImagePipe.Source.StreamError

  test "runs validate_target before connecting and raises the denial reason" do
    plug = fn _conn -> flunk("must not connect when target is denied") end

    stream =
      ReqStream.stream(
        [url: "https://blocked.example/x", plug: plug],
        validate_target: fn _url -> {:error, :denied_address} end
      )

    error = assert_raise StreamError, fn -> Enum.to_list(stream) end
    assert error.reason == :denied_address
  end

  test "follows a redirect itself and validates the hop target" do
    plug = fn
      %{request_path: "/redirect.jpg"} = conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://hop.example/other.jpg")
        |> Plug.Conn.send_resp(302, "")

      conn ->
        send(self(), {:got, conn.host, conn.request_path})
        Plug.Conn.send_resp(conn, 200, "image bytes")
    end

    seen = self()

    stream =
      ReqStream.stream(
        [url: "https://assets.example.com/redirect.jpg", plug: plug],
        validate_target: fn url ->
          send(seen, {:validated, url})
          :ok
        end,
        max_redirects: 1
      )

    assert Enum.join(stream) == "image bytes"
    assert_received {:validated, "https://assets.example.com/redirect.jpg"}
    assert_received {:validated, "https://hop.example/other.jpg"}
    assert_received {:got, "hop.example", "/other.jpg"}
  end

  test "denies a redirect hop before connecting to it" do
    plug = fn
      %{request_path: "/redirect.jpg"} = conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://internal.example/x")
        |> Plug.Conn.send_resp(302, "")

      %{host: "internal.example"} -> flunk("must not connect to denied hop")
      conn -> Plug.Conn.send_resp(conn, 200, "ok")
    end

    stream =
      ReqStream.stream(
        [url: "https://assets.example.com/redirect.jpg", plug: plug],
        validate_target: fn
          "https://internal.example/x" -> {:error, :denied_host}
          _ -> :ok
        end,
        max_redirects: 3
      )

    error = assert_raise StreamError, fn -> Enum.to_list(stream) end
    assert error.reason == :denied_host
  end

  test "exhausting max_redirects fails with too_many_redirects" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://assets.example.com/loop")
      |> Plug.Conn.send_resp(302, "")
    end

    stream =
      ReqStream.stream(
        [url: "https://assets.example.com/loop", plug: plug],
        validate_target: fn _ -> :ok end,
        max_redirects: 1
      )

    error = assert_raise StreamError, fn -> Enum.to_list(stream) end
    assert error.reason == :too_many_redirects
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/source/req_stream_test.exs`
Expected: FAIL — current `stream/2` ignores `validate_target`/`max_redirects` and lets Req follow redirects.

- [ ] **Step 3: Write the implementation**

Replace `ReqStream.stream/2` and `open_response/2` with a redirect-following loop. Keep `stream_response/1`, `next_message/2`, `parse_message/2`, `cancel_response/1`, and `timeout/4` unchanged. New top:

```elixir
  @spec stream(keyword(), keyword()) :: Enumerable.t()
  def stream(req_options, runtime_opts) when is_list(req_options) and is_list(runtime_opts) do
    Stream.resource(
      fn -> open_response(req_options, runtime_opts) end,
      fn
        %{response: %Req.Response{}} = state -> stream_response(state)
        {:done, %{response: %Req.Response{} = response}} -> {:halt, response}
        {:error, reason} -> raise StreamError, reason: reason
      end,
      fn
        %{response: %Req.Response{} = response} -> cancel_response(response)
        {:done, %{response: %Req.Response{} = response}} -> cancel_response(response)
        _other -> :ok
      end
    )
  end

  defp open_response(req_options, runtime_opts) do
    validate = Keyword.get(runtime_opts, :validate_target, fn _url -> :ok end)
    max_redirects = Keyword.get(runtime_opts, :max_redirects, 0)
    follow(req_options, runtime_opts, validate, max_redirects)
  end

  defp follow(req_options, runtime_opts, validate, redirects_left) do
    url = Keyword.fetch!(req_options, :url)

    case validate.(url) do
      :ok -> request_and_route(req_options, runtime_opts, validate, redirects_left)
      {:error, reason} -> {:error, reason}
    end
  end

  defp request_and_route(req_options, runtime_opts, validate, redirects_left) do
    case Req.get(request_options(req_options),
           receive_timeout: timeout(req_options, runtime_opts, :receive_timeout, @default_receive_timeout),
           pool_timeout: timeout(req_options, runtime_opts, :pool_timeout, @default_pool_timeout),
           connect_options: connect_options(req_options, runtime_opts)
         ) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        %{
          response: response,
          receive_timeout: timeout(req_options, runtime_opts, :receive_timeout, @default_receive_timeout)
        }

      {:ok, %Req.Response{status: status} = response} when status in 300..399 ->
        route_redirect(response, req_options, runtime_opts, validate, redirects_left)

      {:ok, %Req.Response{} = response} ->
        cancel_response(response)
        {:error, :bad_status}

      {:error, _exception} ->
        {:error, :bad_status}
    end
  end

  defp route_redirect(response, req_options, runtime_opts, validate, redirects_left) do
    location = location_header(response)
    cancel_response(response)

    cond do
      redirects_left <= 0 ->
        {:error, :too_many_redirects}

      is_nil(location) ->
        {:error, :bad_status}

      true ->
        next_url =
          req_options
          |> Keyword.fetch!(:url)
          |> URI.parse()
          |> URI.merge(location)
          |> URI.to_string()

        follow(Keyword.put(req_options, :url, next_url), runtime_opts, validate, redirects_left - 1)
    end
  end

  defp location_header(%Req.Response{} = response) do
    case Req.Response.get_header(response, "location") do
      [value | _] -> value
      [] -> nil
    end
  end
```

And update `request_options/1` to disable Req's own redirect following:

```elixir
  defp request_options(req_options) do
    Keyword.merge(req_options,
      into: :self,
      retry: false,
      redirect: false
    )
  end
```

Add the `runtime_opts` keys `:validate_target` and `:max_redirects` to whatever the caller passes (Task 7). `URI.merge/2` accepts a string second arg and resolves relative, protocol-relative, and scheme-changing locations against the base URI.

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/source/req_stream_test.exs`
Expected: PASS.

- [ ] **Step 5: Format + commit**

Run: `mise exec -- mix format`

```bash
git add lib/image_pipe/source/req_stream.ex test/image_pipe/source/req_stream_test.exs
git commit -m "feat(source): ReqStream owns the redirect loop with a target guard"
```

---

## Task 7: Wire options + guard into `HTTP`, migrate existing tests

**Files:**
- Modify: `lib/image_pipe/source/http.ex`
- Modify: `test/image_pipe/source/http_test.exs`

- [ ] **Step 1: Add the new options to the schema and strip them from `req_options`**

In `lib/image_pipe/source/http.ex`, extend `@internal_option_keys` and `@options_schema`:

```elixir
  @internal_option_keys [
    :url,
    :base_url,
    :method,
    :body,
    :params,
    :into,
    :retry,
    :redirect,
    :max_redirects,
    :address_policy,
    :address_resolver
  ]
```

```elixir
  @options_schema NimbleOptions.new!(
                    allowed_hosts: [type: {:list, :string}, required: true],
                    req_options: [type: :keyword_list, default: []],
                    receive_timeout: [type: :non_neg_integer],
                    connect_timeout: [type: :non_neg_integer],
                    pool_timeout: [type: :non_neg_integer],
                    max_redirects: [type: :non_neg_integer, default: 0],
                    address_policy: [
                      type: {:or, [{:fun, 2}, {:custom, __MODULE__, :validate_address_policy_kw, []}]},
                      default: []
                    ],
                    address_resolver: [type: {:fun, 1}],
                    stable: [type: {:in, [:auto, :trusted]}, default: :auto],
                    internal_cache: [type: {:in, [:auto, :enabled, :disabled]}, default: :auto],
                    http_cache: [type: {:in, [:inherit, :disabled, :enabled]}, default: :inherit]
                  )
```

Add the custom validator (validates the keyword form, including parsing each CIDR in `allow:`):

```elixir
  @doc false
  def validate_address_policy_kw(value) when is_list(value) do
    allowed_keys = [
      :allow_loopback, :allow_unspecified, :allow_link_local, :allow_private,
      :allow_unique_local, :allow_multicast, :allow_broadcast, :allow_cgnat,
      :allow_reserved, :allow
    ]

    cond do
      not Keyword.keyword?(value) ->
        {:error, "address_policy keyword list expected"}

      Enum.any?(Keyword.keys(value), &(&1 not in allowed_keys)) ->
        {:error, "unknown address_policy key"}

      Enum.any?(Keyword.get(value, :allow, []), &(ImagePipe.Source.HTTP.AddressPolicy.parse_cidr(&1) == :error)) ->
        {:error, "invalid CIDR in address_policy :allow"}

      true ->
        {:ok, value}
    end
  end

  def validate_address_policy_kw(_value), do: {:error, "address_policy keyword list expected"}
```

- [ ] **Step 2: Build the guard closure and pass it to `ReqStream`**

Replace `fetch/3` so it no longer hands `max_redirects` to Req as a follow count, and instead passes `validate_target` + `max_redirects` as stream options:

```elixir
  @impl Source
  def fetch(%Resolved{fetch: fetch}, opts, runtime_opts) do
    req_options =
      opts
      |> Keyword.fetch!(:req_options)
      |> sanitize_req_options(fetch[:strip_byte_headers])
      |> Keyword.merge(url: fetch[:url], method: :get)

    stream_options =
      Keyword.take(opts, [:receive_timeout, :pool_timeout, :connect_timeout])
      |> Keyword.merge(runtime_opts)
      |> Keyword.put(:validate_target, build_target_guard(opts))
      |> Keyword.put(:max_redirects, Keyword.fetch!(opts, :max_redirects))

    {:ok, %Response{stream: ReqStream.stream(req_options, stream_options)}}
  end

  defp build_target_guard(opts) do
    allowed_hosts = Keyword.fetch!(opts, :allowed_hosts)
    predicate = AddressPolicy.compile(Keyword.fetch!(opts, :address_policy))
    resolver = Keyword.get(opts, :address_resolver, &TargetGuard.default_resolver/1)

    fn url -> normalize_guard_result(TargetGuard.validate(url, allowed_hosts, predicate, resolver)) end
  end

  defp normalize_guard_result(:ok), do: :ok
  defp normalize_guard_result({:error, reason}), do: {:error, reason}
```

Add the aliases at the top of the module:

```elixir
  alias ImagePipe.Source.HTTP.AddressPolicy
  alias ImagePipe.Source.HTTP.TargetGuard
```

(`normalize_guard_result/1` is a seam in case HTTP later wants to remap tags; keep it trivial for now.)

- [ ] **Step 3: Add the shared test-only stub resolver and migrate existing tests**

In `test/image_pipe/source/http_test.exs`, add a helper near the top of the module and thread it through `validate_options` calls that perform a real fetch. Hostname-based fetch tests must map their host to a public IP:

```elixir
  @public_ip {93, 184, 216, 34}

  defp stub_resolver(extra \\ %{}) do
    base = %{"assets.example.com" => {:ok, [@public_ip]}}
    map = Map.merge(base, extra)
    fn host -> Map.get(map, host, {:error, :nxdomain}) end
  end
```

For each test that calls `Source.fetch/3` (the ones currently using `req_options: [plug: ...]`), add `address_resolver: stub_resolver()` to the `HTTP.validate_options(...)` opts. Tests that only call `HTTP.resolve/3` (no fetch) need no change, because `resolve/3` does no DNS.

Example migration of the "configured max redirects allows bounded redirects" test — add the resolver and, because the existing plug redirects to a *relative* path `/other.jpg` on the same host, also map nothing extra:

```elixir
    assert {:ok, opts} =
             HTTP.validate_options(
               allowed_hosts: ["assets.example.com"],
               max_redirects: 1,
               address_resolver: stub_resolver(),
               req_options: [plug: plug]
             )
```

Run the file and fix each failing fetch test the same way:

Run: `mise exec -- mix test test/image_pipe/source/http_test.exs`
Expected after migration: PASS (other than the deliberately-broken "redirects cannot bypass" test handled in Step 4).

- [ ] **Step 4: Fix the misleading "redirects cannot bypass allowed host policy" test**

Find that test and change it to actually enable redirects (`max_redirects: 1`) and redirect to an off-allowlist host, asserting the guard denies the hop:

```elixir
  test "an enabled redirect to an off-allowlist host is denied" do
    plug = fn
      %{request_path: "/redirect.jpg"} = conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://evil.example/x.jpg")
        |> Plug.Conn.send_resp(302, "")

      _conn ->
        flunk("must not connect to the off-allowlist redirect target")
    end

    source = %URL{scheme: :https, host: "assets.example.com", port: nil, path: ["redirect.jpg"], query: nil}

    assert {:ok, opts} =
             HTTP.validate_options(
               allowed_hosts: ["assets.example.com"],
               max_redirects: 1,
               address_resolver: stub_resolver(),
               req_options: [plug: plug]
             )

    assert {:ok, resolved} = HTTP.resolve(source, opts, [])
    assert {:ok, %Response{} = response} = Source.fetch(resolved, [sources: %{https: {HTTP, opts}}], max_body_bytes: 20)

    error = assert_raise Source.StreamError, fn -> Enum.to_list(response.stream) end
    assert error.reason == :denied_host
  end
```

- [ ] **Step 5: Run the whole HTTP suite + format + commit**

Run: `mise exec -- mix test test/image_pipe/source/http_test.exs`
Expected: PASS.
Run: `mise exec -- mix format`

```bash
git add lib/image_pipe/source/http.ex test/image_pipe/source/http_test.exs
git commit -m "feat(source): wire address_policy/resolver guard into HTTP fetch + redirects"
```

---

## Task 8: Acceptance + edge wire tests

**Files:**
- Modify: `test/image_pipe/source/http_test.exs`

These assert the spec's acceptance criteria end-to-end through `Source.fetch/3` + the plug adapter. Use the `stub_resolver/1` helper from Task 7.

- [ ] **Step 1: Add acceptance + edge tests**

```elixir
  describe "SSRF guard" do
    defp fetch_stream(opts_kw, source) do
      {:ok, opts} = HTTP.validate_options(opts_kw)
      {:ok, resolved} = HTTP.resolve(source, opts, [])
      {:ok, %Response{} = response} = Source.fetch(resolved, [sources: %{https: {HTTP, opts}}], max_body_bytes: 64)
      response.stream
    end

    defp ok_plug do
      fn conn -> Plug.Conn.send_resp(conn, 200, "image bytes") end
    end

    test "origin host resolving to a private address is blocked (DNS branch)" do
      source = %URL{scheme: :https, host: "assets.example.com", path: ["x.jpg"]}

      stream =
        fetch_stream(
          [
            allowed_hosts: ["assets.example.com"],
            address_resolver: stub_resolver(%{"assets.example.com" => {:ok, [{10, 0, 0, 5}]}}),
            req_options: [plug: ok_plug()]
          ],
          source
        )

      error = assert_raise Source.StreamError, fn -> Enum.to_list(stream) end
      assert error.reason == :denied_address
    end

    test "origin IP-literal private host is blocked (literal branch, no resolver)" do
      source = %URL{scheme: :https, host: "10.0.0.5", path: ["x.jpg"]}

      stream =
        fetch_stream(
          [allowed_hosts: ["10.0.0.5"], req_options: [plug: ok_plug()]],
          source
        )

      error = assert_raise Source.StreamError, fn -> Enum.to_list(stream) end
      assert error.reason == :denied_address
    end

    test "169.254.169.254 cloud metadata literal is blocked" do
      source = %URL{scheme: :https, host: "169.254.169.254", path: ["latest", "meta-data"]}

      stream =
        fetch_stream(
          [allowed_hosts: ["169.254.169.254"], req_options: [plug: ok_plug()]],
          source
        )

      error = assert_raise Source.StreamError, fn -> Enum.to_list(stream) end
      assert error.reason == :denied_address
    end

    test "trusted origin redirecting to a loopback target is blocked on the hop" do
      plug = fn
        %{request_path: "/redirect.jpg"} = conn ->
          conn
          |> Plug.Conn.put_resp_header("location", "http://127.0.0.1/x")
          |> Plug.Conn.send_resp(302, "")

        _conn ->
          flunk("must not connect to loopback redirect target")
      end

      source = %URL{scheme: :https, host: "assets.example.com", path: ["redirect.jpg"]}

      stream =
        fetch_stream(
          [
            allowed_hosts: ["assets.example.com", "127.0.0.1"],
            max_redirects: 1,
            address_resolver: stub_resolver(),
            req_options: [plug: plug]
          ],
          source
        )

      error = assert_raise Source.StreamError, fn -> Enum.to_list(stream) end
      assert error.reason == :denied_address
    end

    test "non-http(s) redirect scheme is rejected" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "file:///etc/passwd")
        |> Plug.Conn.send_resp(302, "")
      end

      source = %URL{scheme: :https, host: "assets.example.com", path: ["redirect.jpg"]}

      stream =
        fetch_stream(
          [
            allowed_hosts: ["assets.example.com"],
            max_redirects: 1,
            address_resolver: stub_resolver(),
            req_options: [plug: plug]
          ],
          source
        )

      error = assert_raise Source.StreamError, fn -> Enum.to_list(stream) end
      assert error.reason == :denied_scheme
    end

    test "allow_private opt-in lets a private origin through" do
      source = %URL{scheme: :https, host: "assets.example.com", path: ["x.jpg"]}

      stream =
        fetch_stream(
          [
            allowed_hosts: ["assets.example.com"],
            address_policy: [allow_private: true],
            address_resolver: stub_resolver(%{"assets.example.com" => {:ok, [{10, 0, 0, 5}]}}),
            req_options: [plug: ok_plug()]
          ],
          source
        )

      assert Enum.join(stream) == "image bytes"
    end

    test "precise CIDR allow lets only the named range through" do
      source = %URL{scheme: :https, host: "in.example", path: ["x.jpg"]}

      base = [
        allowed_hosts: ["in.example"],
        address_policy: [allow: ["10.0.5.0/24"]],
        req_options: [plug: ok_plug()]
      ]

      ok_stream =
        fetch_stream(
          Keyword.put(base, :address_resolver, stub_resolver(%{"in.example" => {:ok, [{10, 0, 5, 9}]}})),
          source
        )

      assert Enum.join(ok_stream) == "image bytes"

      blocked_stream =
        fetch_stream(
          Keyword.put(base, :address_resolver, stub_resolver(%{"in.example" => {:ok, [{10, 0, 6, 9}]}})),
          source
        )

      error = assert_raise Source.StreamError, fn -> Enum.to_list(blocked_stream) end
      assert error.reason == :denied_address
    end

    test "function-form policy replaces the built-in decision" do
      source = %URL{scheme: :https, host: "assets.example.com", path: ["x.jpg"]}

      blocked =
        fetch_stream(
          [
            allowed_hosts: ["assets.example.com"],
            address_policy: fn _ip, category -> category == :public end,
            address_resolver: stub_resolver(%{"assets.example.com" => {:ok, [{10, 0, 0, 5}]}}),
            req_options: [plug: ok_plug()]
          ],
          source
        )

      error = assert_raise Source.StreamError, fn -> Enum.to_list(blocked) end
      assert error.reason == :denied_address
    end
  end
```

Note: when a redirect target's host is in `allowed_hosts` but its IP is blocked, the failure is `:denied_address`; when the host is *not* in `allowed_hosts`, it's `:denied_host` (Task 7 Step 4). The loopback test allowlists `127.0.0.1` deliberately to exercise the address path rather than the host path.

- [ ] **Step 2: Run + format + commit**

Run: `mise exec -- mix test test/image_pipe/source/http_test.exs`
Expected: PASS.
Run: `mise exec -- mix format`

```bash
git add test/image_pipe/source/http_test.exs
git commit -m "test(source): SSRF guard acceptance + edge wire tests"
```

---

## Task 9: Docs

**Files:**
- Create: `docs/source-network-policy.md`
- Modify: `README.md`

- [ ] **Step 1: Write `docs/source-network-policy.md`**

```markdown
# Source network policy (SSRF protection)

`ImagePipe.Source.HTTP` validates the destination of every origin fetch — and of
every redirect hop — before connecting. By default it refuses to connect to any
address that is not public.

## Default policy

For each request, and again for each redirect, the adapter:

1. Requires an `http`/`https` scheme.
2. Requires the (case-insensitive) host to be in `allowed_hosts` — redirects may
   not leave the allowlist.
3. Resolves the host to IP addresses and **denies the fetch if any resolved
   address is not public** (loopback, unspecified, link-local, private, CGNAT,
   unique-local, multicast, broadcast, or otherwise reserved).

IPv4 literal encodings (decimal, octal, hex) and IPv4-mapped / NAT64 / 6to4 IPv6
forms are canonicalized before classification, so they cannot be used to smuggle
an internal address past the check.

A denied fetch raises `ImagePipe.Source.StreamError` with `reason:
:denied_scheme`, `:denied_host`, or `:denied_address` when the response stream is
consumed.

## Allowing private origins

Set `address_policy` on the source adapter. It accepts either a keyword list or a
function.

### Keyword list

```elixir
sources: [
  url: {ImagePipe.Source.HTTP,
    allowed_hosts: ["assets.internal"],
    address_policy: [
      allow_private: true,         # opens ALL RFC1918 ranges
      allow: ["10.0.5.0/24"]       # OR open exactly one range, precisely
    ]
  }
]
```

Toggles: `allow_loopback`, `allow_unspecified`, `allow_link_local`,
`allow_private`, `allow_unique_local`, `allow_multicast`, `allow_broadcast`,
`allow_cgnat`, `allow_reserved`. `allow:` is a list of CIDR strings. Omitting
`address_policy` denies everything that is not public.

### Function

```elixir
address_policy: fn _ip, category -> category == :public end
```

The function receives the canonicalized IP tuple and its category and returns a
boolean. It replaces the built-in decision. A non-boolean return or a raised
exception is treated as **deny** (fail-closed).

## Custom DNS resolution

`address_resolver` overrides how hostnames resolve, e.g. a caching resolver:

```elixir
address_resolver: fn host -> {:ok, [{93, 184, 216, 34}]} end
```

It returns `{:ok, [ip_tuple]}` or `{:error, term}`. Any error, an empty list, or a
raise denies the fetch.

## Known limitation: DNS rebinding

This is **resolve-and-validate**, not connection-pinned: after the policy
validates the resolved addresses, the HTTP client re-resolves the hostname when it
actually connects. A DNS-rebinding attacker who returns a public address to our
lookup and a private address at connect time can still slip past. Closing this
requires pinning the connection to the validated IP and is tracked separately.
```

- [ ] **Step 2: Link it from `README.md`**

Under the `## Documentation` list, add a bullet:

```markdown
- [Source network policy](docs/source-network-policy.md) documents the default
  SSRF protection on HTTP/HTTPS sources, how to allow private origins
  (`address_policy`), custom DNS resolution (`address_resolver`), and the
  DNS-rebinding limitation.
```

And after the source-adapter example block (the `allowed_hosts` snippet around line 93), add a sentence:

```markdown
By default, HTTP/HTTPS sources refuse to connect to non-public addresses and
re-check the policy on every redirect hop. See
[Source network policy](docs/source-network-policy.md) to allow private origins.
```

- [ ] **Step 3: Commit** (docs only — no compile/test gate needed for pure doc edits)

```bash
git add docs/source-network-policy.md README.md
git commit -m "docs(source): document SSRF protection and address_policy config"
```

---

## Task 10: Full gate + open the IP-pinning follow-up

**Files:** none (verification + issue).

- [ ] **Step 1: Run the full precommit gate**

Run: `mise run precommit`
Expected: PASS — `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test` all green.

If credo flags `AddressPolicy` for too many functions or a `Bitwise` import style, address per its suggestion (e.g. `import Bitwise, only: [...]`).

- [ ] **Step 2: Open the tracked IP-pinning / rebinding follow-up issue**

Run:

```bash
gh issue create \
  --title "SSRF: pin connections to validated IPs (close DNS-rebinding window)" \
  --label "type:security,area:source" \
  --body "Follow-up to #48. The shipped SSRF guard is resolve-and-validate: after validating resolved addresses, Finch re-resolves at connect time, leaving a DNS-rebinding TOCTOU window. Closing it requires pinning the connection to the validated IP (rewrite host->IP, carry original hostname for Host header + TLS SNI, verify cert against the original name). Costs: per-request SNI/transport_opts plumbing through Req 0.5.17 -> Finch 0.22 -> Mint 1.8 (needs a version spike), a real-HTTPS test harness (the plug adapter has no TLS), and HTTP/2 connection-coalescing analysis. See docs/superpowers/specs/2026-06-01-ssrf-protection-design.md (Deferred section)."
```

- [ ] **Step 3: Final commit if the gate required any fixups**

```bash
git add -A
git commit -m "chore(source): satisfy precommit gate for SSRF protection"
```

---

## Self-Review notes (for the implementer)

- **Spec coverage:** Task 1–4 = `AddressPolicy` (classify, canonicalization, CIDR, compile/allow, deny-default property). Task 5 = `TargetGuard` (scheme/host/resolve/policy order, literal branch, fail-closed). Task 6 = owned redirect loop. Task 7 = config (`address_policy` both forms + `address_resolver`), key-stripping, existing-test migration, fixed misleading test. Task 8 = all four acceptance criteria + named edge cases (169.254.169.254, mapped/NAT64/6to4 covered in Task 2, non-http redirect, protocol-relative via `URI.merge`). Task 9 = docs incl. rebinding limitation. Task 10 = gate + follow-up issue.
- **`AddressPolicy`/`TargetGuard` stay unexported** from the `Source` boundary — do not touch `lib/image_pipe/source.ex` `exports:`.
- **Telemetry:** intentionally not added here (denials surface via `StreamError` reason, like `:bad_status`); the spec's telemetry section documents why and defers richer category+IP telemetry.
- **Type consistency:** the guard returns `:denied_scheme | :denied_host | :denied_address`; `ReqStream` adds `:too_many_redirects` and reuses `:bad_status`; all are `StreamError.reason` atoms asserted on directly in tests.
