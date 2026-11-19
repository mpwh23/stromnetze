# Stromnetze 156 - Blueprint-centred camera with pixel-stable projection

- Analysis of screenshot 155: the 3D canvas is 280 px narrower, 130.3 px taller,
  and begins 107.2 px higher than the Blueprint viewport. The Canvas centre is
  -140 px/-42.05 px from Blueprint centre. At 82.63 px/metre this equals precisely
  the observed camera -1.694 m X and -0.509 m plan Y.
- Preserve calibrated true 3D grid projection from update 154, then rebase the
  camera eye and orbit target to the VISIBLE Blueprint viewport centre using
  the click-time screen matrix and the canonical 3D floor-reference matrix.
- Use Three.js camera.setViewOffset to compensate the 3D canvas vs Blueprint
  rectangle difference on the same frame; pixel-projected axes do not jump.
- Hold this temporary lens shift while Blueprint fades for 5 s, then ease the
  shift to zero simultaneously with the existing 5 s camera flight.
- Never alter 3D room geometry, the canonical grid/axes colors, camera angles,
  default flight endpoint or transition durations.
- Show diagnostic values using ARCHITECTURAL X=width, Y=depth, Z=height; retain
  separate raw Three.js axes in localStorage for compatibility. Add the ray
  intersection at the Blueprint centre and temporary camera lens offset.
- Logs: localStorage `strom.camera156.center` and `strom.camera155.handoff`.
- Local syntax and viewport-geometry tests; full Pi Vite build before Git push.
- Isolated GitHub source sync, Stage backup; deployment ONLY /strom-test/.
