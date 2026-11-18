# STROM Update 147b – Fenster, gepaarte Treppenraeume (JSX-Korrektur)
- Die Frontansicht im Wanddetail zeigt das bestehende Fenster mit Rahmen, Glas und Fensterbank, aber ohne Mittel- oder Quersprosse. Tueren und Bibliotheks-Icons bleiben unveraendert.
- Blueprint: Bei Auswahl eines Treppenraums wird eine kleine schwebende Richtungswahl angezeigt. Zuerst Aufwaerts/Abwaerts festlegen; anschliessend Gegenrichtung anlegen.
- Der zweite Treppenraum ist ein eigenes Raumobjekt mit der exakt gleichen Kontur. `roomType=stair` wird im massiven Wandsolid bereits gesondert behandelt. Sein Treppenlayout beginnt leer und ist unabhaengig editierbar.
- Die UI ermittelt das Treppenpaar aus derselben Ebene und deckungsgleichen Konturen. Aufwaerts/Abwaerts waehlen das jeweilige Raumobjekt aus.
- Die Richtung liegt vorerst im gleichen Browser-Storage-Adapter wie die Blueprint-Ebenen: `strom.floorplan.layers.<floorId>.stairDirections147`. Kein Datenbank-Umbau.
- 3D: Aufwaerts-Treppen unveraendert, Abwaerts-Treppen werden durch eine umschliessende 3D-Gruppe an der Geschossgrundebene gespiegelt. Vorhandene Mesh-Attribute bleiben unveraendert. Keine Geometrie-/Wandmutation. Vor Build werden alle JSX-Attribute auf Duplikate geprueft.
- Dachschraegen sind Gegenstand eines SEPARATEN Entwurfs und werden mit diesem Script NICHT im Projekt gespeichert oder dargestellt.
