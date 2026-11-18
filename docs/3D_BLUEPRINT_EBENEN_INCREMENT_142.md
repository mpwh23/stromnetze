# Update 142 – Blueprint-Ebenen, Etagenhoehen, Raumauswahl und Treppen im echten 3D

## Bestandspruefung und Korrekturen
- Bisherige Ebene-IDs, Namen, Reihenfolge, Raumzuordnungen, Titelpositionen und gespeicherte Treppenlayouts bleiben bestehen.
- Vorhandene Blueprint-Modi: aktiv, Nachbarebenen als Ghost ohne/mit Bemassung und alle Ghost-Ebenen.
- Ghost-Bereiche: graue Konturen, 50 % Transparenz, ohne Flaechenfuellung und ohne Klick-Interaktion.
- Sichtbarkeitsmodus wird jetzt pro Floor beibehalten; ein Klick auf das Auge einer inaktiven Ebene wechselt in einen Modus, in dem diese auch sichtbar werden kann.
- Beim asynchronen Raum-Reload werden bestehende Raum-zu-Ebene-Zuordnungen nicht mehr vorzeitig geloescht.
- FloorplanEditor wird bei Wechsel der Backend-Floor-ID neu gestartet, damit keine alte Ebenenliste in eine neue Etage gespeichert wird.

## Geschosshoehen
- Pro Blueprint-Ebene ist eine eigene Hoehe in Millimetern im Ebenenmenue editierbar.
- Bestehende Ebenen ohne eigene Hoehe verwenden die Backend-Floor-Hoehe als Standard.
- Das 3D-Wandvolumen und die Treppenstufen der gewaehlten Ebene nutzen diese Hoehe; die Hoehen der unteren Ebenen bestimmen die absolute Lage.

## Echter 3D-Renderer
- Dieselbe React-Three-Fiber-Szene wird in 3D Haus und Wanddetail weiterverwendet.
- 3D zeigt nur die aktuell im Blueprint aktive Etage; Ghost-Ebenen werden nicht als ungewollt ueberlagerte Wandvolumen gerendert.
- Auswahl eines Raumbodens erscheint blau, auch beim Mouseover; bestehender Wandhover und Wand-Popup bleiben intakt.
- Geradlaeufige Treppen, Biegungen und Absatze werden als geschlossene 3D-Volumen aus bereits gespeicherten Treppenelementen gezeichnet.
- Treppen-Reihenfolge: Start an 'Diese Etage', dann Pfeile; Gesamtstufenhoehe = Etagenhoehe / Stufenanzahl.

## Bestehende Architekturgrenze
- Blueprint-Ebenen und Treppenlayouts liegen vorerst weiter in den vorhandenen Browser-localStorage-Schluesseln.
- Dadurch sind Ebenenhoehen und Layouts noch nicht automatisch zwischen verschiedenen Browsern synchron.
- Eine spaetere Datenbankmigration fuer Etagen und Treppen ist erforderlich, bevor alle Geschosse gleichzeitig als ein Gebaeude bearbeitet werden.
- Keine Datenbank- oder Backend-Aenderung und keine Migration in diesem Update.

## Unveraendert
- Volumenunion / massive Waende aus 139.
- Wandbearbeitung und Frontalansicht aus 140a.
- Wand-Mouseover aus 141a.
- Blueprint-Werkzeugleiste, Tueren, Bemaszung, SVG-Design, Geometrie und bestehende Daten.
