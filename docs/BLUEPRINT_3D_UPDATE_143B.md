# STROM Update 143b - direct ghost layer snapping and stair visualization

- The 3D workspace must actually mount `StairSolid` meshes inside the 3D scene.
- The existing status display reports stored staircase layouts. Zero layouts means this browser's localStorage has no recognized room-keyed staircase layout; reloading the page cannot create layouts.
- The Blueprint toolbar has a visible SVG-v7 button `Ebenen-Snap AUS/AN` with a tooltip.
- Cross-level snapping uses *only* visible ghost-level polygon vertices/edges; a snapped edge touches the target with a 0 mm clearance.
- A normal/same-level snap remains separate and may still use the W wall offset.
- The ghost snapping operates only while both main snapping and cross-level snapping are enabled.
- No backend/database schema changes; no geometry migration; no production promotion.
