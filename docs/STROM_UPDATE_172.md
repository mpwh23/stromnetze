# Strom 172: Treppen je Etage im 3D, Aussenwand einer Nachbarebene uebernehmen

## 3D: Treppen
- Ursache: Die aktive Etage zeichnete ausser bei "Alle Etagen AN" die Treppen ALLER Etagen mit
  (halbtransparent, `activeStairs146 = stairs`). Im Obergeschoss erschien so die Erdgeschoss-Treppe.
- Jetzt zeigt die aktive Etage nur ihre eigenen Treppen; mit "Alle Etagen" bringt jede Etage ihre
  Treppen selbst mit (je Lauf genau einmal). Gilt fuer 3D Haus und Wanddetail-3D.

## Blueprint: Aussenwand uebernehmen
- Hat die aktive Ebene keine Aussenwand und eine Ebene darunter oder darueber eine (jeweils die naechste),
  erscheint das Fenster "<Ebene> · noch keine Außenwand" mit "Von <Ebene> übernehmen (darunter/darüber)".
  Beim Zeigen auf den Knopf wird der Umriss der Vorlage hervorgehoben (gestrichelt sichtbar, solange das Angebot steht).
- Uebernommen werden alle Aussenwand-Objekte der Quellebene: Form, Grundriss, Wandstaerke. Die Kopie ist
  NICHT gekoppelt (z. B. Dachgeschoss darf abweichen).
- "Selbst zeichnen" blendet das Angebot fuer diese Ebene aus und aktiviert das Aussenwand-Werkzeug.
- Angebot nur im Auswahlwerkzeug ohne Auswahl; verschwindet, sobald die Ebene eine Aussenwand hat.

Nur Testumgebung `/strom-test/`; Produktion `/strom/` und Backend unveraendert.
