# Update 152 - canonical 3D zero axes

- Blueprint X/Y metres are used to lay out the visible 3D grid, not the
  footprint centre of the room or a guessed camera target.
- The zero axes intersect at the actual rendered 3D position of Blueprint
  (X=0, Y=0); the grid follows the selected-level real floor transform.
- Architectural Z=0 from update 151 remains the height reference (Three Y=0).
- Grid markers are rendered in the Three.js scene root; old GridHelper/Grid/axes
  helpers are hidden to prevent mismatched zero-axis overlays.
- Existing building geometry, user room coordinates, camera pose, animation,
  loading spinner and diagnostics are not modified.
- The source is tested in an isolated copy; /strom-test/ only, never /strom/.
