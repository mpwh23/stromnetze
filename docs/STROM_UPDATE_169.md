# Strom 169: Ein Iconsatz fuer die ganze Anwendung

## Ausgangslage (bis 168)
- Zwei Iconsaetze nebeneinander: `StromIcon` (v7-Sprite `public/strom-icons-v7.svg`, per `<use>` nachgeladen)
  und `StromIcon150` (eigene, abweichende Zeichnungen fuer Navigation, Schliessen und die klassische Wandleiste).
- Mehrere Knoepfe nutzten dasselbe Icon fuer verschiedene Funktionen (z. B. "Alle auswaehlen" = "Auswahl",
  "Dachschraege" = "Polygon", "Bemassung" = "Messen", "Treppe abwaerts" = gespiegeltes "Treppe aufwaerts",
  "Drehen" und "Zuruecksetzen" mit demselben Pfeil).
- Zeichen statt Icons: ▸/▾ (Nutzer & Objekt), 👁/◌ (Ebenen in der klassischen Wandansicht).
- 3D-Leiste (Offset, Waende transparent, Zurueck zum Blueprint, Klassische Wandbearbeitung) ohne Icons;
  Treppenbibliothek mit CSS-Grafiken statt der Entwurfs-Icons 47-54.

## Neu
- Ein Satz mit 69 Icons nach Entwurf v7 (24er Raster, Linie 1,75, runde Enden), eingebettet in
  `components/iconSet169.ts` - kein Nachladen, kein Flackern, keine fehlenden Sprite-Verweise.
- Darstellung wie in Blender / 3ds Max: dunkle Kontur fuer die Form, eine Akzentfarbe fuer den wirksamen Teil;
  Farbe je Funktionsgruppe:
  - blau: Navigation, Zeichnen, Bearbeiten, Objekte
  - rot: Loeschen, Leeren
  - petrol: Ansicht (Zoom, Einpassen, Kamera, transparent)
  - violett: Ebenen
  - orange: Treppen
  - bernstein: Strom / Verteiler
- Aktive Knoepfe: Icon komplett in der Schriftfarbe (weiss auf blau), deaktiviert: ausgegraut.
- Eigene Icons fuer: Alle auswaehlen, Dachschraege, Bemassung, Ebenen-Snap (Magnet), Wandstaerke,
  Treppe auf/ab, Offset der Etagen, Waende transparent, Klassische Wandbearbeitung, Schliessen.
- `StromIcon150` leitet nur noch auf `StromIcon` weiter (alte Namen ueber Aliasliste).
- Sprite-Datei `public/strom-icons-v7.svg` entfernt.
- Iconblatt mit allen Icons (normal / aktiv / deaktiviert): `docs/STROM_ICONSET_169.html`.

## Unveraendert
Funktionen, Tastenkuerzel, Beschriftungen, 3D-Uebergang (165/166) und Blueprint-Zoom (168).

Nur Testumgebung `/strom-test/`; Produktion `/strom/` unveraendert.
