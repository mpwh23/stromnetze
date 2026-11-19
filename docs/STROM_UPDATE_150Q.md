# Stromnetze 150q – Three-dimensional floor viewport extents (diagnostic)
- Keep existing 150p measurements, overlay and browser-console logging unchanged.
- At the entry fade start, use the actual R3F camera and live canvas DOM rectangle to project all selected model room-footprint vertices at 3D finished-floor Y=0 (X/Z plane).
- Convert projected positions to CSS pixels referenced to the exact saved Blueprint viewport origin, including offscreen positions.
- Append distinctly cyan Xmin/Xmax/Ymin/Ymax and coordinate differences to the 150p overlay. Also store JSON under `strom.camera150q.floorExtents` and log to browser console.
- Do not change 3D geometry, camera settings, controls, 5000 ms fade/flight or return flight.
- Build and test in isolated checkout, push GitHub first, stage then deploy only /strom-test/.
