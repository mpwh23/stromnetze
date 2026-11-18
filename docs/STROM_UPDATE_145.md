# Update 145: Floating Ebenenwahl und Wandoberflaechen
- Blueprint floating Ebenenauswahl bleibt unveraendert.
- Wanddetail und 3D Haus zeigen dieselbe floating Ebenenauswahl mit exakt den Blueprint Ebenen-IDs, Namen und Hoehen. Beim Wechsel wird derselbe localStorage active key verwendet.
- Der 144a Toolbar Selector wird durch den Floating Selector oben rechts ersetzt.
- Das 139-Wandvolumen bleibt die Datenquelle. Die 144a Dreieck-Filterung wird durch eine coplanare Oberflaechenvereinigung ersetzt: vollstaendige und teilweise ueberlappende Koplanar-Dreiecke ergeben eine einzelne sichtbare Deckflaeche. Ungeruehrte Ebenen behalten alle Originaldreiecke.
- Der 144a FrontSide-only Transparenzmodus wird zurueckgenommen, Material hat DoubleSide und transparenten Tiefentest/Depthwrite; keine Aenderung an Tueren, Raumkoordinaten, Treppen oder Wandauswahl.
- Nur Stage; keine Datenmigration und keine Produktionsaenderung.
