# Strom 164b: orthographic canvas aspect and exact Blueprint-to-3D grid transform

- One click-time Blueprint SVG matrix in CSS pixels and one visible viewport.
- Exactly the displayed 3D grid's matrixWorld is the 3D coordinate reference.
- Camera architectural XY above Blueprint viewport centre, optical axis vertical.
- Eye height from one closed-form FOV/pixel-scale formula, no iterations.
- Ortho camera horizontal span is derived exactly from real canvas CSS aspect;
  top/bottom and left/right centred before zoom. This removes the 445.040 CSS px
  horizontal mismatch in the failing 164 orthographic test.
- On calibration failure, restore original orthographic frustum as well as pose.
- Only an exact projection shift for different canvas/viewport DOM rectangles.
- Origin, 1m and 5m basis verified by the real Three.js projection before fade.
- 1m minor lines 1 CSS px; 5m major lines 2 CSS px in BP and 3D.
- 3D major widths use instanced planar geometry (not unsupported glLineWidth).
- Existing axis colors, all animation timings, endpoint, reverse driver untouched.
- All prerequisites / TypeScript / actual THREE regressions checked before push.
- Test deployment only. Production unchanged.
- Browser record: localStorage['strom.camera164.alignment'].
