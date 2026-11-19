# Stromnetze Update 150 – icon uniformity and immersive view transitions
- Replaces text-symbol UI icons with consistent, accessible, handcrafted monochrome SVG-line glyphs (no icon fonts).
- 3D enters from a plan-matched top-down view of the active Blueprint layer, using the captured on-screen viewport when available.
- Camera moves to the existing default view in 750 ms using cubic ease-out; all old camera configuration is preserved.
- Going from 3D house or wall detail to Blueprint runs the reverse camera movement before switching.
- Existing 149e geometry, roof slopes, stairs, databases and production frontend remain unchanged.
- Current reference style: reduced CAD/Affinity-like SVG geometry. Original historical v7 SVG file was not mounted as a resource.
