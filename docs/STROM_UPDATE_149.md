# STROM update 149c

- Blueprint level list is top-first and 3D elevations match that physical ordering.
- Clear room height (heightM) and the under-floor slab thickness (slabThicknessM) are separate values.
- Floor thickness defaults to 0 mm for existing stored levels, preventing unintended shifts; user can edit up to 1500 mm.
- Upper-floor slab thickness is included in the stair rise from the lower floor.
- Slabs are rendered as extruded volumes below finished floor levels.
- Roof slopes remain confined to one room when initially drawn. Different pitches and directions in a room are supported.
- Blueprint roof start line is selectable, movable and endpoint-rotatable. An existing plane from any level can be inherited, including the world-space absolute height.
- 3D walls are physically surface-clipped by roof planes from adjacent rooms, with section caps computed from solid wall pieces (doors/windows excluded).
- The original geometry builder, room/door API and production deployment remain unchanged.
- Browser-local layer and roof metadata is not yet synchronized across devices; DB persistence remains a later independent migration.
