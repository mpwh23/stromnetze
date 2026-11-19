# Update 150d – Kamerafahrt ohne Winkelsprung
- Blueprint remains mounted until WebGL has painted the 3D start pose.
- Existing loading spinner retained; fade duration 500 ms.
- Forward and reverse camera flights are 1500 ms, cubic ease-out.
- Preserve the actual camera quaternion before each flight; no rederived camera roll.
- Stable OrbitControls access avoids animation restarts when controls mount.
- Reverse navigation timeout exceeds the full 1500 ms flight.
- Deployment only to /strom-test/ after isolated GitHub build and Stage checks.
