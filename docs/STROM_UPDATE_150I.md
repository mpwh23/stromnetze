# Update 150i – 5-second camera transition analysis
- TEMPORARY ANALYSIS: 5000ms Blueprint-to-3D crossfade and 5000ms camera movement (including reverse flyover).
- Loading spinner, frozen live Blueprint preview, easing, camera axes and 3D model are unchanged.
- No attempt to mask an orientation/position jump: this timing-only update is for observation.
- After visual diagnostics, reduce durations to the agreed production timings.
- Isolated build before GitHub push; Stage backup; deployment only to /strom-test/.
