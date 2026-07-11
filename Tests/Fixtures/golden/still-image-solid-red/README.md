# still-image-solid-red (FR-MED-002 / #246)

Solid red 16×16 still rendered as a timeline source through ImageIO decode.

**Reference establishment (ADR-0017 §6):** `reference.png` is authored as a true solid red
PNG so local hardware can validate the still path immediately. If CI (macos-14) diverges,
follow the standard golden workflow: fail gate → download `golden-frame-actuals` →
review → commit CI-canonical `reference.png` in an explicit reviewed commit.
