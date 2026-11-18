# Update 141a – Wandhover im echten 3D-Wanddetail

- TypeScript/R3F: `event.faceIndex` kann `null` liefern; `?? undefined` passt die Signatur von `pickWallHoverPlane` korrekt an.

- Dieselbe `selectWallEdgeFrom3DHit`-Funktion wie beim Klick ermittelt die betroffene Raumkante beim Mouseover.
- Nur im Wanddetail werden die EXAKTEN vertikalen Oberflaechendreiecke des massiven Wandmodells blau halbtransparent hervorgehoben.
- Die Hoverflaeche wird auf die ausgewaehlte Wandkante begrenzt; keine separate Wandgeometrie wird erzeugt.
- Tuer- und Fensteroeffnungen bleiben offen, weil ihre Dreiecke im massiven Originalmodell fehlen.
- Beim Verlassen der Wand verschwindet das Highlight. Das Overlay ist nicht anklickbar und blockiert deshalb keine Auswahl.
- 3D Haus, Blueprint, Geometrie, Datenbank und vorhandene Wandbearbeitungs-Popups werden nicht geaendert.
- Fallback beim Hover auf eine Wandoberkante: Naechste vertikale reale Wandflaeche ermitteln.
