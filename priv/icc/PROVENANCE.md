# ICC profile provenance

These three profiles are **CC0 / public-domain substitutes** shipped for the
imgproxy `cp`/`icc` color-profile target (feature #119). They are **not** the
vendor-authored profiles. Each substitute's **primaries match the named vendor
target** (so the gamut conversion is correct), but the embedded profile
`description` text and the tone-response-curve (TRC) representation differ from
whatever a given vendor ships. Where this produces an observable divergence
from upstream imgproxy, see the divergence note in
[`docs/imgproxy_support_matrix.md`](../../docs/imgproxy_support_matrix.md).

All three files are taken verbatim from
[saucecontrol/Compact-ICC-Profiles](https://github.com/saucecontrol/Compact-ICC-Profiles),
which releases every profile in the collection under
[CC0 1.0 Universal](https://github.com/saucecontrol/Compact-ICC-Profiles/blob/master/license)
(public domain). They are small ICC v4 matrix profiles (480 bytes each).

| File | Target atom | Source / generation + license | SHA-256 |
|------|-------------|-------------------------------|---------|
| `sRGB.icc` | `:srgb` | `sRGB-v4.icc` from [saucecontrol/Compact-ICC-Profiles](https://raw.githubusercontent.com/saucecontrol/Compact-ICC-Profiles/master/profiles/sRGB-v4.icc) — CC0 1.0. sRGB primaries, D65. | `c56e1685d888f5edb92fe07f2750f387f8fe8e91b32ff8fb0b56bfbbb9458353` |
| `DisplayP3.icc` | `:display_p3` | `DisplayP3-v4.icc` from [saucecontrol/Compact-ICC-Profiles](https://raw.githubusercontent.com/saucecontrol/Compact-ICC-Profiles/master/profiles/DisplayP3-v4.icc) — CC0 1.0. Display-P3 (DCI-P3) primaries, D65 white, sRGB TRC. | `cb51de38e482ee974c0c76b9689e16aad04bad16e226fed2f30c842d15ff3a3d` |
| `AdobeRGB.icc` | `:adobe_rgb` | `AdobeCompat-v4.icc` from [saucecontrol/Compact-ICC-Profiles](https://raw.githubusercontent.com/saucecontrol/Compact-ICC-Profiles/master/profiles/AdobeCompat-v4.icc) — CC0 1.0. Adobe RGB 1998 primaries, D65, gamma ~2.2. | `1e35b53d118eba6835a7bac06137ea87cd5ad6eee97b20a88b29ab6356b00e43` |

Verify integrity with:

```sh
shasum -a 256 priv/icc/*.icc
```
