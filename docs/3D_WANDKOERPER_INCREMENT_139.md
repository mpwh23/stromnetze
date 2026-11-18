# STROM 139 - Gemeinsames Wandvolumen und Wanddetail als echtes 3D

## Anlass
Im Stand 138 wurden parallele Raumkanten bereits zu physischen Wandabschnitten
verbunden. An dicken Aussenwaenden ohne definierte Raumkontur blieben kleine
Hohlraeume und an Wandvorsprüngen sichtbare doppelte Oberflaechen.

## Neue dreidimensionale Wanddarstellung
- Die `BuildingWall`-Wandabschnitte werden zu einem gemeinsamen Volumen vereint.
- Wenn eine explizite Aussenwandkontur vorhanden ist, gilt ihr gesamtes Inneres
  ohne Raumzuweisung als vollstaendiges Bauteilvolumen. Definierte Raumflaechen
  bleiben hohl; modellierte Tueren und Fenster bleiben ausgeschnitten.
- Die Ebenen werden durch alle Bauteil- und Oeffnungshoehen aufgeteilt.
- Eine planare Scanline-Zerlegung bildet den exakten Grundriss der Volumen-Union
  inkl. schraegem Wandverlauf. Es werden ausschliesslich sichtbare Grenzflaechen
  trianguliert; doppelte interne Quaderflaechen werden nicht gerendert.
- Keine neuen Datenbanktabellen, kein lokaler zweiter Datenstand.

## Wanddetail und Fensterhoehe
- Wanddetail startet nun in demselben echten WebGL-Renderer wie 3D Haus.
- Die alte SVG-basierte Wandbearbeitung wird als optionale Altansicht erhalten,
  damit ihre spezifischen Objekt- und Wanddialoge vorerst nutzbar bleiben.
- 3D Haus und Wanddetail fuellen die Hoehe des verfuegbaren Workspace aus.
- Aenderungen von Raumposition und Tuerparametern bleiben im gemeinsamen API-
  Modell gespeichert und erscheinen bei der naechsten Blueprint-Darstellung.

## Grenzen
- Die neue Union wird zurzeit pro Etage gebildet, noch nicht etagenuebergreifend.
- Wanddetail-Objektauswahl/Popup wird fuer neu gerenderte 3D-Wandflaechen in
  weiteren Inkrementen ebenfalls direkt in den WebGL-Editor migriert; die
  bisherige Wandbearbeitung ist bis dahin weiterhin erreichbar.

## Deployment
- Stage zuerst; Temp-Copy-Build, Tests, GitHub-Push, dann Stage-Deployment.
- Produktionsanwendung und vorhandene Daten werden nicht direkt angepasst.
