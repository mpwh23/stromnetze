# Stromnetze 153 — identical blueprint/3D axis styling and centered crossfade

- Blueprint XY coordinates are authoritative. A line is 1 CSS pixel regardless
  of zoom, in both Blueprint SVG and Three.js WebGL grid.
- Blueprint X zero axis (horizontal) red, Y zero axis (vertical) green.
  3D X axis red, plan Y = Three Z green, architectural Z = Three Y blue.
- The Blueprint selected-level Z=0 datum from 151 is preserved; 3D vertical
  camera height is correctly computed above actual world floor elevation.
- At the final concealed frame, Blueprint click-time xMin/xMax/yMin/yMax yield
  screen centre (xMax-xMin)/2+xMin, similarly Y, in CSS viewport pixels.
- The camera is panned via the actual Three projection Jacobian, never by
  assigning pixel values to world coordinates. Physical scale is uniform.
- Original entry/exit durations, easing, camera finish and scene geometry
  remain untouched; added alignment runs before 5-second fade starts.
- Browser diagnostics: console [Strom 153] and storage strom.camera153.alignment.
- Build/validation in isolated temporary tree, deploy only /strom-test/.
