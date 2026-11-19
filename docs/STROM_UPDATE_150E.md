# Update 150e – Kameraflug ohne blockierenden Ladekreis
- Fix: enter camera flight does not wait for R3F OrbitControls to register.
- Detect completed first WebGL frame using the next R3F useFrame callback, independent of renderer info counters.
- Keep live Blueprint and loading spinner, then cross-fade for 500 ms and ease-out camera fly for 1500 ms.
- 9-second defensive guard prevents an infinite loading overlay if canvas readiness cannot be reported.
- Reverse flight, camera quaternion preservation and existing 3D controls remain unchanged.
- Isolated GitHub build, Stage update, /strom-test/ only; production /strom/ untouched.
