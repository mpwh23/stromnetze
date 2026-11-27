# Strom 170: Treppenrichtung und Raum loeschen

## Treppenrichtung (Blueprint)
- Nach "Treppe einzeichnen" + OK erscheint die Abfrage "Neue Treppe · Richtung wählen"
  (hervorgehoben, Frage: nach oben oder nach unten?). Beide Richtungen sind waehlbar.
- Nach der Wahl ist die andere Richtung ausgegraut und nicht anklickbar (vorher: Klick drehte
  die Richtung des Treppenraums still um).
- "Gegenrichtung anlegen" erstellt den zweiten Treppenraum auf derselben Grundflaeche; danach ist die
  Richtung nicht mehr ausgegraut und der Knopf verschwindet. Die Auswahl bleibt auf der aktuellen Richtung
  (vorher: Sprung auf den neuen Raum). Doppelklick legt nur einen Raum an.
- Klick auf eine vorhandene Richtung waehlt den zugehoerigen Treppenraum aus (Eigenschaften, Treppeneditor).
- "Richtung ändern" (kleiner Link) korrigiert einen Fehlgriff, solange nur eine Richtung existiert.
- Wird eine Richtung geloescht, ist sie beim verbleibenden Treppenraum wieder ausgegraut und neu anlegbar.

## Raum loeschen
- Vor dem Loeschen eines Raums werden seine Wandobjekte (Tueren, Fenster, Steckdosen) entfernt.
  Hintergrund: Die Tabelle wall_objects ist nicht im Repo-Schema beschrieben; verweist ihr Fremdschluessel
  ohne ON DELETE CASCADE auf rooms, lehnt PostgreSQL das Loeschen ab (Fehler 23503). Das Fenster blieb dann
  stehen, die Fehlermeldung lag unsichtbar hinter dem abgedunkelten Hintergrund.
- Bestaetigungsfenster: zeigt Fortschritt und Fehler selbst an ("Erneut versuchen"), Enter bestaetigt,
  Escape bricht ab, "Loeschen" ist die rote Hauptaktion.
- Entf im geoeffneten Treppeneditor loescht nicht mehr den ganzen Raum.
- Rueckgaengig nach dem Loeschen stellt einen Treppenraum wieder als Treppenraum her (vorher normaler Raum).
- Das Script liest am Ende (nur lesend) die Fremdschluessel auf rooms aus der Datenbank und zeigt sie an.

Nur Testumgebung `/strom-test/`; Produktion `/strom/` und Backend unveraendert.
