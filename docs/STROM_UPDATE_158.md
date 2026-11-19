# Stromnetze 158 - Rueckflug und exakte Blueprint-Blende

- Messung aus Screenshots: vor Wechsel gepruefte 3D-Bodengrenzen auf 0.0/0.1 CSS px an Blueprint-Bodengrenzen. Ein groesserer Versatz des sichtbaren Kontur-Overlays ist dadurch nicht belegt. Keine frei erfundenen globalen X/Y-Shifts!
- Den bereits auf X=0/Y=0 und +1m-Achsen kalibrierten Kamera-Startpunkt samt optischem ViewOffset aus dem Hinweg merken; Rueckflug an diesen Punkt.
- Vor dem Rueckflug Achsen/Raster gegen die damals wirklich sichtbare Blueprint-Matrix erneut kalibrieren. Keine Modelldaten, Grundrissachsen oder Grid-Geometrien umrechnen oder verschieben.
- Drei reale Projektionspunkte (0,0), (+1,0), (0,+1) und Senkrechtachse am Ende messen; Browser-Diagnose `strom.camera158.returnAlignment`.
- Rueckflug ueber 5000 ms mit Zeitinverse `t^3` der bestehenden Vorwaerts-Kurve `1-(1-t)^3`.
- Projektion umgekehrt animieren: ViewOffset 0 -> Originalwert, Kamera/Orbit-Target/Up/Zoom von aktueller 3D-Pose zum kalibrierten Blueprint-Punkt. Kamera blickt real entlang -Z des Plans; Achse zur Kamera +Z.
- Original-BP waehrend des Rueckflugs verdeckt wieder einblenden und auf die VOR dem Hinweg aufgenommene echte DOM-Position/-Groesse fixieren; erst nach 5000-ms-Rueckflug die Ueberblendung 5000 ms starten.
- 3D erst nach komplettem Crossfade demontieren, Blueprints danach regulär wieder editierbar.
- Nur /strom-test/ deployen; /strom/ bleibt unberuehrt. Vor Git-Push in isoliertem Checkout TypeScript/Vite-Build und Regressionstests.
