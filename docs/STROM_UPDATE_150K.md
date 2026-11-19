# Update 150k - Verified camera render before Blueprint fade

- State machine: preserve the genuine Blueprint and spinner, prepare actual 3D top pose, confirm three WebGL render callbacks on the real active camera, then fade for 5s and fly for 5s (ease-out).
- A hidden THREE mesh (colorWrite/depthWrite disabled) confirms the camera actually used for rendering; shadow/auxiliary camera passes are ignored.
- Keep the 150j camera pose, Blueprint orientation, geometry, existing OrbitControls safeguards, and reverse flight behavior.
- Do not unconditionally start a fade after a timer. If the 3D view remains unready for 30s, return safely to Blueprint and show an error instead of revealing a wrong camera.
- Apply only with successful isolated TypeScript/Vite build and tests; update GitHub and /strom-test/ while leaving /strom/ intact.
