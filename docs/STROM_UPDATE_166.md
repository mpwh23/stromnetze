# Strom 166: Rueckweg gespiegelt, Waende wachsen aus dem Blueprint

## Rueckweg (3D -> Blueprint)
- Genau der Hinweg rueckwaerts, doppelt so schnell:
  Kamerafahrt 1250 ms mit Ease-in in die Draufsicht (Hinweg 2500 ms Ease-out),
  danach Blende 375 ms (Hinblende 750 ms `ease`, rueckwaerts: `cubic-bezier(.75,0,.75,.9)`),
  danach Wechsel auf den an derselben Stelle liegenden Blueprint.
- Kamera und Wandhoehe haengen an einer Zeitachse t; der Rueckweg spielt t rueckwaerts ab.
  Wird mitten im Hinflug zurueckgeschaltet, kehrt der Rueckweg an genau dieser Stelle um.
- Vor der Blende wird wie in 165 nachgemessen (Raster <= 1 CSS-Pixel).

## Hinweg (Blueprint -> 3D)
- Die 3D-Szene startet mit Wandhoehe 0 (technisch 1 %: 2,6 m -> 2,6 cm, knapp ueber dem Boden),
  die Waende liegen in der Blende flach auf ihren Blueprint-Linien.
- Waehrend der Kamerafahrt wachsen Waende, Tueren, Treppen und Daecher mit Ease-in-out auf
  ihre volle Hoehe, genau bis zum Fahrtende. Boden, Deckenplatte und Raster bleiben unveraendert.
- Weitere Etagen ("Alle Etagen") sinken auf dem Rueckweg mit ab und werden dabei ausgeblendet,
  sodass die Draufsicht am Ende genau die aktive Ebene des Blueprints zeigt.

## Pruefung
- Vor Auslieferung im echten Browser (Chromium) gegen genau dieses Bundle gemessen.
- Das Skript vergleicht den Fingerabdruck des gebauten Bundles mit dem geprueften Bundle
  und bricht vor Git-Push und Deployment ab, wenn er abweicht.
- Nur Testumgebung `/strom-test/`; Produktion `/strom/` unveraendert.
