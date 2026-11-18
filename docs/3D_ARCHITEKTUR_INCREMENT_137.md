# STROM 137 – Architekturinkrement 1: echtes 3D / gemeinsames Modell

## Ziel
Blueprint bleibt die erste und fuehrende 2D-Zeichenoberflaeche. Die bestehende
Room- und WallObject-API bildet die kanonische Datenbasis. 2D und Three.js lesen
dieselben Objekte; 3D speichert keine separate Kopie von Raum- oder Tuerdaten.

## Neu
- `frontend/src/building/model.ts`: pure Ableitung des Gebaeudemodells aus
  Floor, Room[] und WallObject[] mit Metern als Einheit. Wanddurchbrueche werden
  durch echte 3D-Wandsegmente realisiert (keine optische Uebermalung).
- `frontend/src/components/Building3DWorkspace.tsx`: Three.js + React Three
  Fiber, Orbit-Kamera, Auswahl, transparente/deckende Waende, Raumbearbeitung
  und Bearbeitung der gespeicherten Tueren.
- Im Menuepunkt `3D Haus` wird die bisherige Platzhaltergrafik durch echtes
  browserseitiges WebGL ersetzt. Das bisherige SVG-Wanddetail bleibt erhalten.
- 2D -> 3D: neuer/verschobener Raum oder neue Tuer wird beim Eintritt in die
  3D-Ansicht aus dem API-Zustand gerendert.
- 3D -> 2D: Raummittelpunkt kann um 100 mm verschoben oder numerisch gesetzt
  werden, Tuer-Breite/-Hoehe/-Position kann ueber den 3D-Inspector gespeichert
  werden. Danach zeigt Blueprint denselben API-Datensatz.

## Bewusste Grenzen von Inkrement 1
- Nur die gegenwaertig vom Backend gelieferte Etage; spaeter werden alle
  Etagen in einem absoluten Koordinatensystem zusammengefuehrt.
- Treppenlayout und deren Etagenkanten werden bisher teilweise im Browser-
  localStorage gespeichert. Das muss in einer spaeteren, verlustfreien
  Datenmigration in die kanonische DB-Schicht aufgenommen werden.
- Dach, Dachoeffnungen, Deckenplatten, Wandvereinigungen, 3D-Drag-Gizmos und
  bauliche Materialkataloge sind fuer spaetere Inkremente vorgesehen.
- Polygonale Raeume werden bereits als 3D-Bodenflaechen gezeigt; die Waende
  werden als einzelne echte Quadersegmente mit Tuerausschnitten abgebildet.
- Noch keine generelle Zusammenlegung angrenzender, aber nicht deckungsgleicher
  Raumwandelemente. Exakt deckungsgleiche Kanten werden dedupliziert.

## Sicherheitsprinzip
- Keine Migration oder Loeschung produktiver Daten, kein DB-Schema-Update.
- Eigenes 3D-Modell wird ausschliesslich aus bestehenden API-Objekten erzeugt.
- Deploy arbeitet zuerst auf einer temporaeren Quellkopie, prueft den Build,
  pusht den geaenderten Source nach GitHub und deployed danach Stage.
- Production /var/www/strom und /home/mpwh/strom bleiben unberuehrt.
