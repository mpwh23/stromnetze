# Stromnetze 163: exakt zentrierte Blueprint-Kamera

## Geometrische Invariante
- Klickzeitpunkt: SVG-Screenmatrix und das **sichtbare Blueprint-Viewport-Rechteck**
  werden gemeinsam im selben `BlueprintFrame150` gespeichert. Keine veralteten
  localStorage-Viewportwerte oder Haus-Bounding-Box als Ersatz.
- Mittelpunkt: Mittelpunkt des sichtbaren Blueprint-Viewports, per invertierter
  SVG-Matrix in Blueprint-X/Y-Meter umgerechnet; dann mit realer Floor-
  `matrixWorld` in Three-Welt X/Z transformiert.
- Z: Kamera exakt senkrecht nach unten, ueber der echten aktiven Geschosshoehe;
  Kamera-Three-Y = Geschosshoehe + (proportional aus Zoom und FOV ermittelte Hoehe).
- Bildmassstab: 3D-Meterprojektion stimmt mit 1-m-Achsen der Blueprint-SVG-Matrix
  ueberein, unabhaengig von Zoom und Scrollposition.
- Canvas-Ausschnitt: 3D-Canvas ist oft ein anderes DOM-Rechteck; nur dessen
  zeitweiliger **off-axis lens shift** kompensiert den Pixelversatz. Die
  physikalische Kameraposition wird nicht zu diesem Zweck versetzt.
- Kontrolle: drei Basiswerte 0/0, X+1, Y+1 im selben Browser-CSS-Pixelraum;
  nur akzeptiert, wenn max. Fehler <= 0,75 CSS-Pixel.
- Rueckflug benutzt weiterhin den gespeicherten tatsaechlich sichtbaren
  Hinflug-Startzustand aus Patch 162 und wird nicht neu implementiert.
- Animation, Achsenfarben, Slider, UI und Zeitwerte bleiben erhalten.
- Deployment nur nach `/var/www/strom-test/`, Produktion `/strom/` unveraendert.

Browserdiagnose: `localStorage['strom.camera163.alignment']`.
