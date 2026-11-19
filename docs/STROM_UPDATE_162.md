# Stromnetze 162 - viewport-true 3D return to Blueprint

Restores the exact pre-160 camera file from backup 20261119-203527,
preserving the working 159b entrance / Blueprint X/Y coordinates. Only the
return flight behavior is changed:

- Save the *actual rendered* entrance fade camera state after its 156
  projection correction, not a guessed `running.start` or a fresh
  `overheadPose`. Architectural X = Three X, architectural Y = Three Z,
  architectural height Z = Three Y.
- Return starts at the currently displayed 3D camera and its current view.
  Position, orientation, target, zoom and off-axis lens move continuously
  over 1000ms (ease-out) toward the saved visible Blueprint camera.
- At k=0 the current viewport projection is preserved; at k=1 the
  recorded Blueprint lens (including view-offset) is restored.
- Hold exactly this final camera for three R3F/WebGL frames before calling
  the app's reverse fade callback, so the DOM does not change before a
  correctly rendered 3D top-down image is on screen.
- The original entrance calibration, transitions and UI are not rewritten.
  Entry fade 750ms, flight 2500ms, exit flight 1000ms, exit fade 500ms.
- No production deployment, only /var/www/strom-test/.

Safety: Strict backups/source validation; isolated build and regression
before Git push; second build and Stage backup before test deployment.
Browser rendering must still be checked on the real system.
