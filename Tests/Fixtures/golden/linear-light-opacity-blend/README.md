# Linear-Light Opacity Blend

This fixture composites a 50% opaque Rec.709 red pixel over an opaque Rec.709 blue pixel.

Expected output is BGRA `[180, 0, 180, 255]`: the red and blue channels are first blended at
0.5 in linear light, then Rec.709-encoded. A gamma-space blend would produce `[128, 0, 128, 255]`,
which this fixture is intended to reject.
