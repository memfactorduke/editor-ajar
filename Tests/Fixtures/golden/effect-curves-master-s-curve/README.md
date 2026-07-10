# effect-curves-master-s-curve

FR-COL-002 golden: color curves on a 96×96 mid-tone checkerboard.

**Tolerances (do not loosen):** deltaE ≤ 1, SSIM ≥ 0.99, alpha ≤ 1.

**Reference status:** VALID solid-gray placeholder pending GPU establishment (ADR-0011 / NFR-QUAL-001).
`reference.png` is a valid 96×96 PNG so the harness can compare and report FAIL-with-numbers
(not error) until a Metal-produced reference is reviewed in.

Control points are static for M8; secondary curves (hue-vs-hue etc.) remain v1.x.
