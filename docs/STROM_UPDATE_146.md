# Update 146: Blueprint zoom / Wanddetail Frontalansicht / 3D Haus / Kanten-Snapping

- Blueprint Zoom max 1000% (state, wheel, zoom buttons, fit/selected, viewport persistent); stair-editor zoom unchanged.
- Wanddetail Objektbibliothek: real SVG icons `door`, `window`, `electrical-socket` from design v7, with readable high contrast and mouseover tooltips.
- Frontalansicht: door is drawn as elevation with frame, leaf and handle, NOT a plan swing-arc; windows with frame, glass and optional mullions; existing drag, resize, wall object persistence and dimensions unchanged.
- 3D Haus options: "Alle Etagen" reads the real Blueprint level list and room assignments, builds separate THREE scene groups, all layers at cumulative true elevations; "Offset" adds 1.15m visual gap per higher level. Neither toggle writes building data; other floor meshes are read-only. 3D Wanddetail remains on active floor.
- Single edge drag in Blueprint: polygon shift is 0/45/90; moving edges snap to other room endpoints and edges at 0 mm, no wall distance, at a zoom-relative tolerance. Rect sides align directly to parallel target edges, other sides fixed. The v143b ghost-layer toggle governs additional neighbor-floor targets. A blue marker explains what snapped.
- Existing building wall solid, 3D hover, stair geometry, Blueprint assignments, database and production untouched. Stage only.
