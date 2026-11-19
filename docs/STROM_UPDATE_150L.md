# Update 150l - stable frame handshake instead of missing WebGL sentinel

- Diagnoses and fixes a stuck loading spinner caused by relying only on hidden mesh `onAfterRender`.
- Keeps Blueprint and loading spinner visible until the active R3F camera has been aligned and held through three stable frame ticks and two browser paint opportunities.
- Then fades over 5 seconds before starting the 5-second ease-out camera flight.
- Preserves geometric orientation, both camera directions, and OrbitControls safeguards.
- If the 3D Canvas fails to initialize, the existing 30-second safety guard returns to Blueprint with an error rather than spinning forever.
- Runs in isolated Git checkout with strict TypeScript/Vite build and regression tests before GitHub push; deploys to /strom-test/ only.
