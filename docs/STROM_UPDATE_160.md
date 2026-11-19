# Stromnetze 160 - reverse flight without zoom jump

The forward transition is untouched: 750 ms cross-fade + 2500 ms flight from the current 159b implementation.

At the forward fade, store the actual rendered top-view camera pose (position,
rotation, up, target, zoom) and 156 camera viewOffset. On reverse, use the current
3D camera pose for the START; interpolate for 1000 ms using ease-out to the
stored top-view END, without invoking `overheadPose`, `alignBlueprintCenter156`
or any other field-of-view recalculation. Hold the exact end pose until the
existing 500 ms reverse Blueprint cross-fade unmounts the 3D Canvas.

The prior exit registration remains available as fallback for a directly opened
3D workspace without a captured Blueprint top view.

This is a reconstructed patch because the prior 160 attachment is unavailable.
It checks markers and builds against the real current Stage source before any
Git push. Production `/strom/` is never changed.
