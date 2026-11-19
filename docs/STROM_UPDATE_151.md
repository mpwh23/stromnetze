# Stromnetze Update 151 — one canonical Blueprint coordinate system

- Canonical architectural coordinates: Blueprint X/Y (metres), level height Z (metres).
- Three.js render axes: world X=Blueprint X, world Y=height Z, world Z=Blueprint Y. Model room vertices, dimensions and ruler values are not rescaled or recentered.
- Each floorplan has exactly one selectable finished-floor Z=0 reference level in the Blueprint layer list.
- Single storey: its level automatically has Z=0. Multiple storeys: radio marker picks the level; defaults to bottom entry to preserve existing position until changed.
- All level elevations for 3D and stairs, Blueprint level options, and cross-level roof-plane inheritance share the same coordinate datum. Lower levels receive negative heights.
- The vertical zero reference is saved in browser localStorage per floor ID, consistent with existing level metadata storage. The database has not been migrated.
- Camera flight and its existing five-second diagnostic timings, loading indicator, and viewport overlays remain unchanged.
- Build and structural regression must pass before GitHub push and /strom-test/ deployment. Production is not updated.
