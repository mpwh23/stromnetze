# Strom 173: Ein Ebenenmenue, verschiebbare Fenster

## Ebenenmenue (Vorlage: Blueprint)
- Neue Komponente `components/LevelMenu173.tsx`, genutzt im Blueprint, in "3D Haus" und im Wanddetail-3D.
  Gleiche Darstellung und Bedienung: Z=0-Auswahl, Auge, Name, Geschosshoehe, Bodendicke, Reihenfolge per Griff,
  "Neue Ebene", "Ebene loeschen" (mit Rueckfrage, loescht die Objekte der Ebene).
- Die 3D-Ansichten schreiben in dieselben Blueprint-Daten (`building/levelStore173.ts`).
- Auge im 3D Haus: wie im Blueprint. Bei "Alle Etagen AUS" blendet das Auge einer anderen Ebene diese ein
  (Alle Etagen AN); danach blendet es sie aus/ein. Die aktive Ebene wird immer angezeigt.
  Im Wanddetail-3D zeigt das Auge genau diese Ebene (Wanddetail zeigt immer eine Ebene).
- Alle Ebenenmenues sind standardmaessig aufgeklappt (Blueprint, 3D Haus, Wanddetail-3D, klassische Wandansicht);
  die Ebenenwahl klappt das Menue nicht mehr zu.

## Verschiebbare Fenster (`components/floatDrag173.ts`)
- Verschiebbar: Ebenenmenues (Griff links neben dem Kopf), Treppen-/Durchgangs-/Aussenwand-Fenster, Tuer,
  Aussparung (Fenster und Hinweis), Abstand, Rechteck-/Polygon-Einstellungen, Dachschraege.
  Bereits vorher verschiebbar: Treppeneditor, Wandansicht-Fenster, Objektbibliothek.
- Ziehen an freien Flaechen oder am Griff; Knoepfe/Eingaben bleiben bedienbar; nach dem Ziehen loest der
  Klick nichts aus. Position je Fenster im Browser gespeichert; Doppelklick auf freie Flaeche/Griff: Standardplatz.
- Mindestens 48 px eines Fensters bleiben im sichtbaren Bereich.

## Nebenbefund behoben
- Icons (169) wurden bei jedem Neuzeichnen der Elternkomponente neu erzeugt; ein Klick genau in diesem Moment
  ging verloren (gemessen beim Knopf "Neue Ebene" nach einer Hoehenaenderung). `StromIcon` ist jetzt `memo`,
  und Icons sind nie selbst Klickziel (`pointer-events: none`), der Knopf darunter erhaelt den Klick.

Nur Testumgebung `/strom-test/`; Produktion `/strom/` und Backend unveraendert.
