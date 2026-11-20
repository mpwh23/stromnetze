# Strom 165: ein Kameratreiber, Blueprint und 3D deckungsgleich

## Ursache des Versatzes (bis 164b)
`Building3DWorkspace.tsx` erzeugte die OrbitControls, meldete sie aber nie im
R3F-Store an. `CameraFlight150` fand sie deshalb nicht (`get().controls` war `null`)
und konnte sie nicht sperren. In jedem Frame lief nach dem Kameraflug noch
`controls.update()` und drehte die Kamera per `lookAt` auf die Hausmitte. Der Fehler
war null, wenn der Blueprint auf das Haus zentriert war, und wuchs mit Pan und Zoom.

## Aenderungen
- OrbitControls im R3F-Store angemeldet; waehrend Blende und Flug wirklich gesperrt.
- `CameraFlight150.tsx` neu: ein Treiber, ein `useFrame`, eine Kalibrierung.
  Die Kalibrierungen 150r, 154, 156, 164 und die Diagnosen 150q, 155, 158 sind entfernt,
  ebenso die unbenutzten Module 153 und 163.
- Die Draufsicht wird aus dem Blueprint berechnet, wie er im Moment der Blende im
  Browser steht (Live-Messung), nicht nur aus dem Schnappschuss beim Klick.
- Nachmessung nach dem Zeichnen (`scene.onAfterRender`) mit genau der Kamera, die
  gezeichnet hat. Die Blende startet erst nach zwei bestaetigten Bildern mit hoechstens
  1 CSS-Pixel Abweichung. Sonst Abbruch zurueck zum Blueprint mit Meldung (ca. 4 s statt 30 s).
- Blende mit fast parallelem Blickwinkel (hoechstens 2 Grad, mindestens 1000 m Abstand):
  auch Waende liegen auf ihren Blueprint-Linien. Im Flug oeffnet sich der Blickwinkel
  auf 48 Grad, der Bildmassstab der Rasterebene bleibt dabei stetig.
- Flug um einen wandernden Blickpunkt (Blueprint-Mitte -> Hausmitte), Ease-out.
  Rueckflug ebenfalls Ease-out, 1000 ms; Ziel ist der wieder eingeblendete Blueprint.
- Rueckweg mitten im Hinflug kehrt an der aktuellen Stelle um.
- Zeiten unveraendert: Hinblende 750 ms, Hinflug 2500 ms, Rueckflug 1000 ms, Rueckblende 500 ms.
- 3D-Ansicht und Three.js werden erst beim ersten Oeffnen geladen
  (Startpaket 435 kB statt 1470 kB).
- Klassische Wandansicht: der Blueprint-Zoom wird beim Verlassen exakt wiederhergestellt
  (vorher 0,9 x 1,1 = 0,99 je Durchgang, ueber "Zurueck zu Echtes 3D" blieb er bei 90 %).
- `package.json`: feste Versionen statt `latest` (identisch zu den gesperrten Versionen).
- `tools/strom_stage_promote_to_prod.sh`: bricht ab, wenn sich der Go-Quelltext in
  `backend/` zwischen Produktion und Stage unterscheidet.
- Backend-Quelltext der Produktion (u. a. `central_auth.go`) nach Stage und Git uebernommen,
  falls er dort fehlt. Es wird nichts gebaut und nichts an der Produktion veraendert.
- `db/live_schema_165.sql`: Schema der laufenden Datenbank (ohne Daten), falls lesbar.

## Pruefung
- Vor Auslieferung im echten Browser (Chromium) gegen genau dieses Bundle gemessen:
  Rasterabweichung 0 px auf Hin- und Rueckweg bei Zoom 22 % bis 1000 %, verschobenem
  Blueprint, Wanddetail, nach Drehen/Verschieben in 3D, DPR 1 / 1,25 / 2.
- Das Skript vergleicht den Fingerabdruck des gebauten Bundles mit dem geprueften Bundle
  und bricht vor Git-Push und Deployment ab, wenn er abweicht.
- Im Browser: Konsole `[STROM165]` bzw. `localStorage['strom.camera165.check']`.

## Nicht enthalten
Eigene Test-API und Test-Datenbank, Anmeldung an der API, Umzug der Browser-Speicher-Daten
in die Datenbank und das Aufteilen von `App.tsx`. Diese Punkte greifen in Produktion,
Datenbank oder nginx ein und gehoeren nicht in einen Frontend-Patch der Testumgebung.
Nur Testumgebung `/strom-test/`; Produktion `/strom/` unveraendert.
