# Stromnetze 155 - real Blueprint viewport + live 3D camera measurements

- Blueprint diagnostic panel remains the same and is now fixed bottom-left.
- At the instant the final starting camera pose is applied, **before releasing the fade**,
  measure the ACTUAL Canvas/R3F camera in world coordinates, not requested props.
- Show actual visible Blueprint viewport min/max and midpoint in architecture metres:
  inverse of the **click-time** saved SVG affine mapping on the four viewport corners.
- Show Blueprint viewport global screen pixel limits and screen centre.
- Show real 3D world camera position X/Y/Z (Three.js Y is height), precise
  centre-of-projection ray through NDC(0,0), ray intersection with elevation 0,
  Euler XYZ angles in degrees, and actual horizontal/vertical perspective FOV.
- Show differences of 3D canvas and Blueprint viewport screen rectangles, to detect
  CSS viewport offsets. Preserve existing Blueprint drawing and cyan floor values.
- Inspect full values at localStorage `strom.camera155.handoff` and console [STROM 155].
- No adjustments to grid, start pose, controls, 5-second fade/flight or return flight.
- Stage backup + isolated TypeScript/Vite build + real Three.js projection tests;
  deploy only /strom-test/ (production /strom/ unchanged).
