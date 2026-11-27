# Strom 174: Ebenen einzeln einblenden, Solo / Nachbar / Alle

- Sichtbarkeit je Ebene ist jetzt die einzige Grundlage (Blueprint, 3D Haus, Wanddetail-3D, gemeinsame Daten).
  Die aktive Ebene ist immer sichtbar; jede andere Ebene hat ihr eigenes Auge.
- Auge: blendet genau diese Ebene ein/aus. Vorher schaltete ein Auge im 3D "Alle Etagen" ein (alle Ebenen erschienen)
  und im Blueprint den Modus "alle Ebenen".
- Neue Knoepfe im Ebenenmenue neben Neu/Loeschen: Solo (nur aktuelle), Nachbar (aktuelle + unmittelbar darueber/darunter),
  Alle. Die passende Vorgabe ist markiert; bei eigener Auswahl keine. Solo und Nachbar wandern beim Ebenenwechsel mit.
- Blueprint: beliebige Ebenen als Schatten (halbtransparent, nicht bearbeitbar). Werkzeugleisten-Knopf schaltet
  Solo > Nachbar > Nachbar mit Bemassung > Alle durch.
- 3D Haus: "Alle Etagen" AN = alle Ebenen eingeblendet; Klick wechselt zwischen Alle und Solo. Offset wie bisher.
- Wanddetail-3D: zeigt jetzt ebenfalls alle eingeblendeten Ebenen (nur die aktive ist bearbeitbar).
- Einmalige Umstellung je Etage (`...visibility174`): Die Schalter werden aus dem bisherigen Modus gesetzt, die Ansicht bleibt gleich.

Nur Testumgebung `/strom-test/`; Produktion `/strom/` und Backend unveraendert.
