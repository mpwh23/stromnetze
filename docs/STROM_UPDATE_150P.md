# Stromnetze 150p – Blueprint Viewport Extrema (diagnostic only)
- At the click BEFORE switching to wall / 3D, measure actual rendered room polygons (SVG `polygon.room` points transformed through getScreenCTM).
- Report Xmin/Xmax/Ymin/Ymax in CSS pixels relative to visible Blueprint scroll viewport and workspace; negative values and values beyond viewport are retained.
- Exclude ghost floors for primary bounds; include separately for diagnostic comparison.
- Display a small passive overlay panel and log/store full measurements at localStorage key `strom.camera150p.blueprintExtents`.
- Keep existing 150o flight, camera, zoom, rotation, 5-second fade, 5-second motion, and production completely unchanged.
- Isolated TypeScript/Vite build, regression test, GitHub push before Stage and /strom-test/ update.
