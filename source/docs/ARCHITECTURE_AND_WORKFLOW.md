# strom Architektur- und Arbeitsworkflow

Dieses Projekt verwendet ab Update 118 einen stabilen Produktionsstand und eine getrennte Testumgebung.

## Pfade

- Produktion Quelle: `/home/mpwh/strom`
- Produktion Web: `/var/www/strom`
- Produktion URL: `/strom/`
- Test Quelle: `/home/mpwh/strom_stage`
- Test Web: `/var/www/strom-test`
- Test URL: `/strom-test/`

## Arbeitsregel

Aenderungen werden nicht direkt in der Produktion entwickelt. Kleine Aenderungen werden zuerst in `/home/mpwh/strom_stage` eingespielt, dort gebaut und unter `/strom-test/` geprueft. Erst danach wird die Testversion in die Produktion uebernommen.

## Robuste Patch-Regel

- Kein Regex-Flickwerk in grossen JSX-Bloecken.
- Betroffene Komponenten vollstaendig ersetzen oder in eigene Dateien auslagern.
- Jeder Patch muss erst in der Testumgebung bauen.
- Produktion wird nur nach erfolgreichem Build ueberschrieben.

## Langfristige Frontend-Struktur

Die Anwendung ist aktuell historisch in `frontend/src/App.tsx` gebuendelt. Neue groessere Funktionen sollen schrittweise ausgelagert werden:

- `frontend/src/components/` fuer wiederverwendbare UI-Komponenten
- `frontend/src/features/blueprint/` fuer Blueprint-Editor
- `frontend/src/features/stair-editor/` fuer Treppen-Floating-Window
- `frontend/src/features/wall-detail/` fuer Wanddetailansicht
- `frontend/src/lib/` fuer Geometrie, Persistenz und Utility-Funktionen

Bis zur vollstaendigen Auslagerung gilt: Zuerst stabile Testumgebung, dann Promotion.
