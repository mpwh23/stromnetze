# Update 150j – camera start pose fixed during crossfade
- Forward transition: hold the same active R3F camera at the intended bird's-eye pose throughout the Blueprint -> 3D crossfade.
- Handle delayed R3F camera registration without restarting the camera flight.
- Preserve 5,000ms fade, 5,000ms eased flight in both directions for visual diagnostics.
- Keep live Blueprint preview, spinner, geometry, pan/zoom settings and 3D OrbitControls intact.
- Fail-safe: isolated full TypeScript/Vite build before GitHub push, backup and deployment only to /strom-test/.
