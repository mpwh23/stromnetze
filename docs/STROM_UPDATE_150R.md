# Stromnetze update 150r — actual 3D-world floor projection and camera calibration
- Blueprint bounds: use live polygon.getScreenCTM() coordinates saved at click by update 150p. Do not infer screen position from an assumed SVG origin or outer root matrix.
- Actual 3D floor: add invisible, non-rendered reference points as siblings of real active-level FloorSlab149 meshes. Their parent matrixWorld includes the real level/group elevation, rotation and position. Also works when slabThicknessM=0.
- Exclude ghost-floor meshes from start-pose camera matching. Use actual projected world vertices in 150q cyan diagnostic.
- Fit the 3D camera's start pose to real Blueprint bounding extrema (pan + zoom/altitude only); do not rotate the camera or change the default end pose.
- No loading waits; preserve 5000 ms blend, 5000 ms eased flight, spinner, existing exit flight and 3D geometry.
- Full tsc/vite build + geometry regression before Git push; deploy only /strom-test/.
