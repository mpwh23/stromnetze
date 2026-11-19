# Update 150c – plan-matched immersive camera transition
- Keeps the genuine, mounted Blueprint visible while the 3D Canvas initializes.
- Shows a spinner until at least one complete WebGL frame has been rendered.
- Cross-fades the existing Blueprint to the top-down 3D pose for 250 ms.
- Only then begins the original 750 ms cubic ease-out camera flight.
- Stabilizes the reverse camera flight and avoids a final OrbitControls snap.
- GitHub build, Stage and /strom-test/ only; no changes to /strom/ production.
