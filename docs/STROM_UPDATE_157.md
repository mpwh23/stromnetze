# Stromnetze 157 - Kamerasichtachse korrekt messen

- Die Kamera befindet sich ueber dem Plan (architektonisch Z=+22.048 m) und blickt physikalisch nach unten (0,0,-1).
- Auf dem Bildschirm ist die entgegengesetzte geometrische Sichtachse Z+ zur Kamera gewuenscht; sie ergibt sich aus der realen Kamera-Quaternion (kein hartkodierter Messwert).
- Der bisherige Wert (-0.077,-0.023,-0.997) ist der durch das verschobene 3D-CANVAS-Zentrum laufende Projektionsstrahl und nicht die eigentliche optische Achse. Er bleibt in den Browser-Diagnosedaten erhalten.
- Die Bildschirmanzeige verwendet jetzt die korrekt benannte optische Achse 'Blickachse zur Kamera XYZ (Plan)' (0,0,1) bei exakt senkrechter Kamera.
- Kamera, Blueprint, Lens-/Canvas-Versatz, Navigation, Kameraflug und Geometrie bleiben unveraendert.
- Nur /strom-test/ wird bereitgestellt; /strom/ bleibt unveraendert. Vor Git-Push: isolierter TypeScript-/Vite-Build und Kameratest.
