# Stromnetze 161b – camera exit fix after 161 source-mismatch

## Why 161 failed
161 expected a precise `const top = overheadPose(...)` expression in the
pre-160 camera's reverse branch. The actual 159b branch has a different
expression, so the isolated checkout failed before any changes were deployed.

## Implementation
- Recover ONLY `CameraFlight150.tsx` from the verified backup made immediately
  before 160 (`20261119-203527` preferred); never roll back the Blueprint,
  model, axes, other UI or 159b timing modules.
- Undo the competing reverse driver introduced by 160 and remove its helper.
- Save the real, calibrated entry pose and temporary lens offset at the first
  3D fade frame. The entire working forward camera prepare/fade remains exact.
- On reverse, reuse the original `flight.current` assignment, capturing the
  *current* 3D camera as its start. After this assignment, override ONLY its
  destination pose with the saved blueprint top and its lens offset. No
  assumptions about the name or implementation of the old `overheadPose` call.
- Use ONE existing `useFrame` driver for both directions. Reverse 1000ms with
  ease-out and progressive view offset; original forward 750ms fade + 2500ms
  flight and reverse fade 500ms remain defined by unmodified transition code.
- Keep any app/backend/3D scene data and production deployment untouched.

## Verification
A full frontend TypeScript/Vite build and a TSX/behavioral regression run
happen in an isolated Git checkout BEFORE the Git push. A Stage backup and
second build run before deployment to `/var/www/strom-test/` only.
Actual browser camera motion still requires user-side visual verification.
