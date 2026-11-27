# Strom 171: Treppendurchgang als gekoppelter Treppenraum

- Auf der Nachbarebene wird der Treppendurchgang (gestrichelt) jetzt ausgewaehlt statt sofort die Ebene zu wechseln.
  Fenster "Treppendurchgang · aus <Ebene>": "Treppe hier anlegen (abwärts)" bzw. "(aufwärts)" bei einer Abwaerts-Quelle,
  daneben "Zur Treppe in <Ebene>" (bisheriges Verhalten).
- Der neue Treppenraum ist mit der Quelle gekoppelt (ein Treppenlauf, zwei Ebenen):
  - Stufen und Kantenzuordnung sind gemeinsam: Der gekoppelte Raum liest und schreibt die Daten des Eigentuemers
    (`stairLayoutOwner171`, Speicher `strom.floorplan.layers.<floor>.stairFlights171`). Im 3D wird der Lauf einmal gezeichnet.
  - Grundriss gemeinsam: Aendert sich ein Raum, folgt der andere (nicht waehrend des Ziehens; die geaenderte Seite gewinnt).
  - Richtung festgelegt (gegenlaeufig zur Quelle); "Richtung ändern" entfaellt bei gekoppelten Raeumen.
  - Richtungsfenster zeigt "Gekoppelt mit ... · <Ebene>"; Klick wechselt zum Partner.
- Auf der neuen Ebene ist die Gegenrichtung ausgegraut und per "Gegenrichtung anlegen" ergaenzbar (eigener Lauf zur naechsten Ebene,
  dort erscheint wieder ein Treppendurchgang).
- Der Durchgang verschwindet, sobald auf der Ebene der gekoppelte Treppenraum existiert.
- Loeschen: Kopplung wird entfernt; faellt der Eigentuemer weg, behaelt der verbleibende Raum die Stufen als eigene Daten.
- Name der Gegenrichtung ohne doppelten Zusatz ("Treppe (aufwärts)" statt "Treppe (abwärts) (aufwärts)").

Hinweis: Wird eine ganze Ebene verschoben (Aussenwand + Pfeiltasten), folgt der gekoppelte Treppenraum auf der Nachbarebene mit.
Nur Testumgebung `/strom-test/`; Produktion `/strom/` und Backend unveraendert.
