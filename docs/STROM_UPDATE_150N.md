# Update 150n - Blueprint viewport and 3D handoff (forward only)
- Keep original Blueprint DOM and the loading spinner visible until the 3D scene is ready.
- Let the default 3D camera and OrbitControls settle before recording the final target pose.
- Compute the start pose from the actual Blueprint SVG screen transform and the new 3D Canvas rectangle, not from a guessed viewport center.
- Keep an unrotated +X / +Z top-down camera basis equal to the Blueprint axes.
- Freeze the overhead pose during the full 5000ms crossfade.
- Fly from that pose to the verified 3D default over 5000ms with cubic ease-out.
- Release OrbitControls without forcing an extra camera update or changing viewport values.
- Reverse camera animation is intentionally left for a later update.
- No model, data, layout, icon or production changes.
