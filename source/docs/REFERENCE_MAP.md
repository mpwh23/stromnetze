# strom Referenzkarte fuer kleine Aenderungen

Diese Datei dient als Orientierung, damit kleine Aenderungen den Gesamtzusammenhang beachten.

## Gemeinsame UI-Muster

- Hauptwerkzeugleiste: in `App.tsx` nach `canvas-toolbox` suchen.
- Treppen-Floating-Toolbar: in `StairLayoutPanel` nach `stair-editor-toolbar` suchen.
- Eigenschaftenleisten: nach `properties-topbar` und `stair-editor-properties` suchen.
- Canvas/SVG-Interaktion: Drag/drop-Handler nie per Teilstring ersetzen; immer ganzen SVG-Startblock pruefen.

## Pflichtpruefungen vor Produktion

```bash
cd ~/deploy
./strom_stage_build_test.sh
./strom_stage_promote_to_prod.sh
```
