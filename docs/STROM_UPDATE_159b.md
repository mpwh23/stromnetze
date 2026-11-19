# STROM 159b - Uebergangszeiten und Koordinatenfenster (robuster Fix)

Voraussetzung: erfolgreiches Update 158b (inkl. 157 optische Achse).

## Hinweg: Blueprint -> Wanddetail / 3D
- Der vorhandene Ladekreis bleibt sichtbar, bis Three.js und Kamera fertig ausgerichtet sind; kein kuenstlicher Timer. Der bisherige 30-s-Fehler-Schutz bleibt bestehen.
- Danach Blueprint-Blende in exakt 750 ms (CSS und Ready-Event-Timer synchron).
- Anschliessend 2500 ms Kameraflug mit unveraendertem `easeOut(t)=1-(1-t)^3`.

## Rueckweg: Wanddetail / 3D -> Blueprint
- 1000 ms Rueckflug entlang derselben Kameraposen, inverser `t^3`-Kurve und Lens-Offset-Kalibrierung aus Version 158b.
- Erst wenn die Rueckflug-Endpose erreicht wurde: 500 ms Blende zum originalen Blueprint.

## Anzeige
- Neues Koordinaten-Debugfenster wird nicht mehr in das DOM eingefuegt; alte Overlays werden per CSS ausgeblendet.
- Messdaten von 150p und 155 in Browser-Konsole und LocalStorage erhalten; 155-Quellcode bleibt unveraendert. Grid/Axis-Fit, Kamerapositionen, Blendenfolge und Restversatz unveraendert.

## Deployment
- Unveraenderter Mac/Pi/Git-Workflow: isolierter Patch, npm Build, Regressionstests, GitHub-Push, Backup, nur /strom-test/ ausrollen. Produktion /strom/ nicht anfassen.
