The source pixel is BGRA `[0, 200, 120, 255]`, which is a red subject with green spill.
With full green spill suppression, the expected keyed output is BGRA `[0, 120, 120, 255]`:
green is reduced from 200 to the red-channel level 120 while blue, red, and alpha stay stable.
