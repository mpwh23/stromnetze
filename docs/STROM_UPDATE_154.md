# Stromnetze 154 - pixel-aligned Blueprint and Three.js axes at camera handoff

- The 153 camera fit wrongly used selected floor *geometry bounds* as reference. The
  154 fit instead uses the click-time full Blueprint affine XY -> CSS-screen mapping.
- Fit the 3D canonical grid origin and 1m X/Y steps to the Blueprint raster, using
  the EXACT marker matrix that CanonicalGrid152 uses to position its grid.
- Project a true top-down camera above the corresponding Blueprint viewport centre.
  Compute its height from vertical FOV, viewport size and Blueprint px per metre.
  Refine with the live 3D projection, using a single scale and a Jacobian pan.
- Support architectural Z0 separately from arbitrary current floor elevations.
  Grid plane lies at world Y=0 (architectural Z=0); do not assume the floor is y=0.
- Keep the red, green and blue axes and one-pixel grid styling from 153 unchanged.
- No modifications to 5s fade, 5s flight, existing easing, settled final camera,
  nor reverse-flight implementation; only the entry start pose is changed.
- On unable-to-align, keep previous camera and never block navigation.
- Read diagnostics in browser console [Strom 154], storage
  strom.camera154.gridAlignment (origin and 1m basis errors in CSS pixels).
- Isolated frontend TypeScript/Vite build + 5 numerical viewport cases before push;
  deploy exclusively /strom-test/, production /strom/ untouched.
