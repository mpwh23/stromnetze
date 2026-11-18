# STROM 138 – Physische Wandkoerper statt getrennter 3D-Wandschalen

## Ursache
In Update 137 wurde jede Raumkante als eigener Quader extrudiert. Nur Kanten
mit exakt denselben Endpunkten wurden dedupliziert. Zwei parallele, leicht
versetzte Wandseiten konnten deshalb als zwei getrennte Quader mit Hohlraum
erscheinen.

## Neue Ableitung
- Normalisierung der Wandkanten auf eine gemeinsame Richtung (unabhaengig
  von der Laufrichtung des Raumpolygons).
- Kopplung von deckungsgleichen bzw. nahen parallelen Wandseiten, deren
  Laengsprojektionen ueberlappen, unter Beruecksichtigung der Rauminnenseite.
- Laengsseitige Aufteilung an den Endpunkten beteiligter Kanten. So koennen
  lange Aussenwandkanten und mehrere kuerzere Raumkanten zusammenwirken.
- Pro Abschnitt ein geschlossener massiver Wandquader, der den Zwischenraum
  zwischen den beschriebenen Wandseiten ausfuellt.
- Tueren und Fenster werden in reale Meterkoordinaten des physischen
  Wandkoerpers projiziert. Ausschnitte gehen durch dessen volle Dicke.
- Zuordnungen zu Raumen und Tuergruppen bleiben erhalten. Blueprint, API und
  Datenbank werden nicht veraendert.

## Grenzen
Die aktuelle Projektion erkennt nahe, parallele Flaechen mit grob passenden
Wandstaerken. Stark schraeg oder nur punktfoermig aneinanderstossende Waende
bleiben getrennte Koerper. In einer spaeteren Phase kann eine globale
Polygonvereinigung/CSG fuer Wandverbindungen folgen.

## Sicherheit
Stage zuerst mit lokaler Arbeitskopie bauen; GitHub-Commit und Push vor
Stage-Deployment. Produktion nicht aendern. Keine Datenbankmigration.
