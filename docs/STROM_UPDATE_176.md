# Strom 176: Blueprint - Ziehen, Tueren und Fenster; Ebenenfenster - Einheiten, Nullhoehe-Icon

## Blueprint
- Objekte werden nur verschoben, wenn sie vorher ausgewaehlt wurden. Ziehen auf einem nicht ausgewaehlten Objekt
  (auch auf seinem Namen) verschiebt die Ansicht wie neben einem Objekt; ein Klick ohne Ziehen waehlt aus.
  "Alle auswaehlen" + Ziehen verschiebt weiterhin alle.
- Tueren und Fenster in Orange wie das Treppensymbol (#b45309).
- Fenster werden jetzt im Blueprint gezeigt, als "H" in der Wand: Querlinien an beiden Enden senkrecht zur Wand,
  Scheibe als Linie in der Wandmitte.
- Bemassung an: Tueren "Breite × Hoehe", Fenster "Breite × Hoehe · BRH Bruestungshoehe" (Abstand Unterkante zum Boden),
  klein neben der Oeffnung auf der Raumseite.

## Ebenenfenster
- Hoehe und Bodendicke: Einheit steht im Feld ("2600 mm", mm grau). Beim Bearbeiten nur die Zahl (markiert).
  Eingabe in mm, cm, dm, m, mit Komma oder Punkt (z. B. "2,6 m", "260cm", "26 dm", "2600 mm"); gespeichert und angezeigt in mm.
  Enter/Verlassen uebernimmt, Escape oder ungueltige Eingabe verwirft.
- Nullhoehe (Z = 0) als Icon-Knopf (Hoehenkote: Dreieck auf Linie) in der Reihe mit Auge und Griff; genau einer aktiv.

Nur Testumgebung `/strom-test/`; Produktion `/strom/` und Backend unveraendert.
