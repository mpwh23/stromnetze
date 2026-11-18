# STROM Update 143 - Staircases and cross-level snapping

- 3D Haus and Wanddetail continue to use the exact same React Three Fiber scene.
- Read stair layouts under their original `strom-stair-layout:<roomId>` keys. Load them for each retained Blueprint level, not just the active room-filtered level.
- Staircase elevations respect per-level heights; stairs from other levels are drawn translucently. No database or localStorage migration.
- A non-zero count of stored staircase layouts is shown in the 3D status bar for diagnosis.
- Layer assignment data remain read-only in the new adapter.
- New Blueprint toggle "Nachbarebenen": off by default, stored independently per Floor ID in `strom.floorplan.layers.<floorId>.snapVisibleNeighbors143`.
- When enabled AND ordinary snapping is enabled: visible ghost levels may be used as snap anchors for creation, room movement, group movement and resize operations.
- Hidden/filtered levels never serve as snap anchors; ghosts remain non-selectable and are not changed.
- All existing wall volume, wall editor popup, camera, doors and database data remain unchanged.
