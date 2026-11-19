# Stromnetze 150o – Blueprint / 3D crossfade calibration
- Fix only the remaining crossfade offset, not the already-correct angles or 150n camera flight.
- Save the real SVG-to-screen transform before switching views, while Blueprint still has its original layout.
- Preserve the live Blueprint layout rectangle during loading and fade, avoiding reflow.
- Map this frozen Blueprint screen transform to the new 3D Canvas rectangle.
- Keep load spinner, settled end camera, fixed start during 5 s fade, 5 s ease-out forward flight.
- Reverse flight deliberately unchanged.
- Build in isolated checkout, push through Pi root deploy key, stage backup, deploy only /strom-test/.
