# STROM 148 - Treppenraum-Identitaet, Etagenprojektion, Dachschraegen

- Nach dem Kopieren sind Aufwaerts- und Abwaerts-Treppenraeume unabhaengige
  Raum-Datenbankobjekte. Ihr Paar wird dauerhaft per ID statt per Raumform erkannt.
- Bestehende deckungsgleiche Treppenraum-Paare werden einmalig verknuepft.
- Auf der jeweils angrenzenden Blueprint-Ebene erscheint dieselbe Treppenraumkontur
  als *verknuepfte Projektion*. Sie ist keine neue Datenbank-Raumkopie. Anklicken
  springt zur Quell-Ebene und waehlt den echten Raum zur Bearbeitung.
- Eine Blueprint-Dachschraege wird nach Raumwahl per zwei Punkten entlang
  ihrer Startlinie erzeugt. Neigung, Beginnhoehe, Ausrichtung und Linienenden
  sind parametrisch bearbeitbar. Unbegrenzt viele Schraegenelemente je Raum.
- Alle Dachschraegen eines Raumes werden zu einer gemeinsamen untersten
  Dachflaechen-Huelle geschnitten. Dadurch gibt es bei kreuzenden Schraegenelementen
  keine deckungsgleichen doppelten 3D-Flaechen.
- Echte 3D-Flaechen im Wanddetail und 3D Haus; Dachflaeche in 3D anklicken,
  dieselben Parameter bearbeiten und speichern. Beide Ansichten lesen dieselbe Datenquelle.
- Keine Veraenderung der bestehenden Wand-Triangulation oder Treppenstufen.
- Vorerst wie die Blueprint-Ebenen im lokalen Browser gespeichert, noch nicht
  in der Go-Datenbank. Geraeteuebergreifende Synchronisierung folgt separat.
- Dachschraegen verschneiden WANDKOERPER noch nicht automatisch. Realer Dach-
  /Waendeschnitt wird als spaetere gezielte Ausbaustufe umgesetzt.
