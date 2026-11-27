# Strom 175: Eigenschaften oben, Fensterpositionen beim Ansichtswechsel gehalten

## Eigenschaften
- 3D Haus und Wanddetail-3D: Die Eigenschaften stehen jetzt wie im Blueprint als Leiste oben zwischen Werkzeugleiste und Ansicht
  (vorher rechte Seitenleiste). Inhalt: Auswahl (Raum/Treppenraum/Aussenwand/Tuer), Mittelpunkt X/Y, Position speichern,
  Feinverschiebung ±100 mm, Tuer bearbeiten, Meldungen. Die 3D-Ansicht nutzt die volle Breite.
- Dachschraege-Editor im 3D schwebt wie im Blueprint ueber der Ansicht (verschiebbar).
- 3D Haus: bei nur einer Ebene steht "Alle Etagen" nicht mehr auf AN.

## Fensterpositionen
- Positionen werden in Bildschirmkoordinaten gehalten (`position: fixed`), nicht mehr relativ zur jeweiligen Ansicht.
- Das Ebenenfenster hat in Blueprint, 3D Haus, Wanddetail-3D und klassischer Wandansicht dieselbe ID und bleibt beim
  Ansichtswechsel an derselben Stelle - auch wenn es nie verschoben wurde (letzte Position der Sitzung).
- Rechts abgelegte Fenster halten den Abstand zum rechten Fensterrand (Fenstergroesse aendern).
- Doppelklick auf Griff/freie Flaeche: Standardplatz. Bisherige Verschiebungen aus 173 werden einmal uebernommen.
- Klassische Wandansicht: Zeichenflaeche liegt ueber ihrer Eigenschaftenleiste, damit gehaltene Fenster nicht verdeckt werden.

Nur Testumgebung `/strom-test/`; Produktion `/strom/` und Backend unveraendert.
