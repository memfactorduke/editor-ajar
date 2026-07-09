# lut-invert-strength-1

FR-COL-004 golden: 8³ invert `.cube` LUT on a 64×8 RGB gradient (trilinear coverage).

| Strength | Fixture |
|----------|---------|
| 0 | `lut-invert-strength-0` |
| 0.5 | `lut-invert-strength-half` |
| 1 | `lut-invert-strength-1` |

**Source layout (64×8 `pixelsBGRA`):**
- Rows 0–3: horizontal black→white luminance ramp (covers lattice interiors on the gray axis).
- Rows 4–7: horizontal red→blue hue ramp (G=0; covers off-axis trilinear cells).

**Tolerances (do not loosen):** deltaE ≤ 1, SSIM ≥ 0.99, alpha ≤ 1.

**Reference status:** pending GPU establishment (ADR-0017 §6 style). `reference.png` is a valid
64×8 solid-gray placeholder so the harness can compare and report FAIL-with-numbers (not error)
until a Metal-produced reference is reviewed in.

Strength 1 is full-strength invert (output ≈ 1 − source along the sampled LUT path).
