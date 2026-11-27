#!/usr/bin/env python3
"""Update 175: Eigenschaften in 3D Haus und Wanddetail oben wie im Blueprint;
Fensterpositionen in Bildschirmkoordinaten, beim Ansichtswechsel gehalten."""
import hashlib, os, pathlib

root = pathlib.Path(os.environ['STROM175_ROOT']) / 'frontend'
res = pathlib.Path(os.environ['STROM175_RESOURCES'])
F = {
    'app': root / 'src/App.tsx', 'css': root / 'src/styles.css', 'ws': root / 'src/components/Building3DWorkspace.tsx',
    'drag': root / 'src/components/floatDrag173.ts',
}
EXPECTED = {
    'app': '694733fcacc01a9ce26146a8c57abe9bbec90c3744f6bb8094e9a19a8970fab6',
    'css': '3268588f6e22cc36a02c8c1629bb729244a05be4f695471a866841b08c1bbdb0',
    'ws': '61402c1b4a4420f1abca4c2a35f1e4441b8c8a06971c50663317a14da48ca5d6',
    'drag': 'cfb3cfc4368b4669c2c7714305f2fcb9604317d207f42469843b733287bb5a71',
}
for key, path in F.items():
    have = hashlib.sha256(path.read_bytes()).hexdigest()
    if have != EXPECTED[key]:
        raise RuntimeError(f'175: {path.name} entspricht nicht Stand 174 ({have})')


def edit(text, label, old, new, count=1):
    have = text.count(old)
    if have != count:
        raise RuntimeError(f'175: Textstelle "{label}" {have}x gefunden (erwartet: {count})')
    return text.replace(old, new)


# ------------------------------------------------------------------ App.tsx: gemeinsame Fenster-IDs
app = F['app'].read_text(encoding='utf-8')
app = edit(app, 'Blueprint-Ebenenmenue', 'floatId="blueprint-levels"', 'floatId="levels" // STROM175: gleiche Position in allen Ansichten')
app = edit(app, 'Wand-Ebenenmenue', "ref={floatRef173('wall-levels')}", "ref={floatRef173('levels')}")
app = edit(app, 'Dachschraege', "ref={floatRef173('blueprint-roof')}", "ref={floatRef173('roof')}")
F['app'].write_text(app, encoding='utf-8')

# ------------------------------------------------------------------ Building3DWorkspace.tsx
ws = F['ws'].read_text(encoding='utf-8')
ws = edit(ws, '3D: Import', "import LevelMenu173 from './LevelMenu173' // STROM173_LEVEL_MENU\n",
  "import LevelMenu173 from './LevelMenu173' // STROM173_LEVEL_MENU\nimport { floatRef173 } from './floatDrag173'\n")
ws = edit(ws, '3D: eine Ebene ist nicht "Alle Etagen"',
  "  const allLevelsVisible174 = layers173.every(",
  "  const allLevelsVisible174 = layers173.length > 1 && layers173.every(")
ws = edit(ws, '3D: Ebenenmenue-ID', "floatId={variant === 'wall' ? 'wall3d-levels' : 'house3d-levels'}", "floatId=\"levels\"")
OLD_ASIDE_START = "        <aside className=\"building3d-inspector\">\n"
OLD_ASIDE_END = "        </aside>\n"
a = ws.find(OLD_ASIDE_START)
b = ws.find(OLD_ASIDE_END, a)
if a < 0 or b < 0 or ws.count(OLD_ASIDE_START) != 1:
    raise RuntimeError('175: Seitenleiste nicht eindeutig')
aside = ws[a:b + len(OLD_ASIDE_END)]
for part in ['<RoofEditor148 floorId={floor.id} roofId={selectedRoof148}', '{selectedDoor && <DoorForm model={model} door={selectedDoor} rooms={rooms} rawObjects={objects} onSaved={reloadDoors} />}',
             'onClick={() => void shiftSelectedRoom((xMm / 1000) - centroid.x, (yMm / 1000) - centroid.y)}']:
    if part not in aside:
        raise RuntimeError('175: Inhalt der Seitenleiste unerwartet: ' + part[:40])
ws = ws[:a] + ws[b + len(OLD_ASIDE_END):]
TOPBAR = (
  "      {/* STROM175_PROPERTIES_TOP: Eigenschaften oben wie im Blueprint (vorher rechte Seitenleiste). */}\n"
  "      <section className={`properties-topbar building3d-properties175 ${!selectedRoom && !selectedDoor ? 'empty' : ''}`} aria-label={variant === 'wall' ? 'Wanddetail Eigenschaften' : '3D-Eigenschaften'}>\n"
  "        <div className=\"properties-title\"><span className=\"eyebrow\">Eigenschaften</span><strong>{selectedDoor ? 'Tür' : selectedRoom ? (selectedRoom.roomType === 'stair' ? 'Treppenraum' : selectedRoom.name.startsWith('__strom_outer_wall__') ? 'Aussenwand' : 'Raum') : 'Keine Auswahl'}</strong></div>\n"
  "        {!selectedRoom && !selectedDoor && <p>{variant === 'wall' ? 'Wand anklicken zum Bearbeiten, oder Raum bzw. blau angedeutete Tür anklicken. Gleiche Daten wie im Blueprint.' : 'Raum oder blau angedeutete Tür anklicken. Werte werden hier live angezeigt; gleiche Daten wie im Blueprint.'}</p>}\n"
  "        {selectedRoom && !selectedDoor && (\n"
  "          <>\n"
  "            <div className=\"property-readout\"><span>{selectedRoom.name.startsWith('__strom_outer_wall__') ? 'Aussenwand' : selectedRoom.name}</span><span>{selectedRoom.vertices.length} Eckpunkte · {fmtMm(floor.heightM)} mm Höhe</span></div>\n"
  "            {movable ? (\n"
  "              <>\n"
  "                <label>Mittelpunkt X mm<input type=\"number\" value={xMm} step={100} onChange={(event) => setXmm(Number(event.target.value))} /></label>\n"
  "                <label>Mittelpunkt Y mm<input type=\"number\" value={yMm} step={100} onChange={(event) => setYmm(Number(event.target.value))} /></label>\n"
  "                <button type=\"button\" disabled={busy} onClick={() => void shiftSelectedRoom((xMm / 1000) - centroid.x, (yMm / 1000) - centroid.y)} title=\"Raumposition speichern\">Position speichern</button>\n"
  "                <div className=\"building3d-directional building3d-directional175\" role=\"group\" aria-label=\"Feinverschiebung um 100 mm\">\n"
  "                  <button type=\"button\" disabled={busy} title=\"Raum um 100 mm nach links verschieben\" onClick={() => void shiftSelectedRoom(-0.1, 0)}>X −100</button>\n"
  "                  <button type=\"button\" disabled={busy} title=\"Raum um 100 mm nach oben verschieben\" onClick={() => void shiftSelectedRoom(0, -0.1)}>Y −100</button>\n"
  "                  <button type=\"button\" disabled={busy} title=\"Raum um 100 mm nach unten verschieben\" onClick={() => void shiftSelectedRoom(0, 0.1)}>Y +100</button>\n"
  "                  <button type=\"button\" disabled={busy} title=\"Raum um 100 mm nach rechts verschieben\" onClick={() => void shiftSelectedRoom(0.1, 0)}>X +100</button>\n"
  "                </div>\n"
  "              </>\n"
  "            ) : <div className=\"property-readout\"><span>Spezialobjekt</span><span>im Blueprint bearbeitbar</span></div>}\n"
  "          </>\n"
  "        )}\n"
  "        {selectedDoor && <DoorForm model={model} door={selectedDoor} rooms={rooms} rawObjects={objects} onSaved={reloadDoors} />}\n"
  "        {message && <p className=\"building3d-notice\" role=\"status\">{message}</p>}\n"
  "      </section>\n"
  "      <div className=\"building3d-content\">\n")
ws = edit(ws, '3D: Eigenschaften oben', "      <div className=\"building3d-content\">\n", TOPBAR)
ws = edit(ws, '3D: Dachschraege schwebend',
  "          {/* STROM173_LEVEL_MENU: dasselbe Ebenenmenue wie im Blueprint */}\n",
  "          {selectedRoof148 && <div ref={floatRef173('roof')} className=\"strom-roof-floating148\"><RoofEditor148 floorId={floor.id} roofId={selectedRoof148}\n"
  "            onClose={()=>setSelectedRoof148('')} onChanged={()=>setRoofRevision148(value=>value+1)}/></div>}\n"
  "          {/* STROM173_LEVEL_MENU: dasselbe Ebenenmenue wie im Blueprint */}\n")
F['ws'].write_text(ws, encoding='utf-8')

# ------------------------------------------------------------------ Verschieben in Bildschirmkoordinaten
F['drag'].write_text((res / 'floatDrag175.ts').read_text(encoding='utf-8'), encoding='utf-8')

CSS = """
/* STROM175_PROPERTIES_TOP: 3D-Eigenschaften als Leiste oben wie im Blueprint. */
.building3d-layout > .building3d-properties175 { flex: 0 0 auto; margin: 0; border: 0; border-bottom: 1px solid #dce3ef; border-radius: 0; box-shadow: none; min-height: 76px; align-items: end; }
.building3d-layout > .building3d-properties175.empty { align-items: center; }
.building3d-properties175 > p { margin: 0; font-size: 0.86rem; color: #64748b; }
.building3d-properties175 label { min-width: 120px; font-size: 0.78rem; }
.building3d-properties175 input { height: 34px; }
.building3d-properties175 .properties-title { min-width: 112px; }
.building3d-properties175 .property-readout { min-width: 150px; }
.building3d-properties175 button { white-space: nowrap; height: 34px; padding: 0 12px; cursor: pointer; border-radius: 9px; border: 1px solid #bdcce2; color: #1e3a8a; background: #fff; font-size: 13px; font-weight: 700; box-shadow: none; }
.building3d-properties175 button:hover:not(:disabled) { background: #e6efff; }
.building3d-properties175 button:disabled { opacity: .55; cursor: wait; }
.building3d-properties175 .building3d-directional175 { display: inline-grid; grid-template-columns: repeat(4, auto); gap: 4px; }
.building3d-properties175 .building3d-directional175 button { padding: 0 8px; }
.building3d-properties175 .building3d-inspector-section { display: flex; align-items: end; gap: 0.65rem; margin: 0; padding: 0; border: 0; }
.building3d-properties175 .building3d-inspector-section h3 { margin: 0 0 6px; font-size: 0.85rem; white-space: nowrap; }
.building3d-properties175 .building3d-inspector-section p { margin: 0 0 6px; font-size: 0.75rem; max-width: 190px; }
.building3d-properties175 .building3d-notice { margin: 0; padding: 6px 9px; font-size: 0.8rem; max-width: 320px; }
.building3d-layout > .building3d-content { grid-template-columns: minmax(0, 1fr) !important; }
/* STROM175: Wanddetail-Zeichenflaeche (isolation) liegt ueber ihrer Eigenschaftenleiste, damit gehaltene Fenster sichtbar bleiben. */
.canvas-card.wall-detail-card { z-index: 11; }
.building3d-view .strom-roof-floating148 { position: absolute; z-index: 54; right: 16px; top: 90px; max-height: calc(100% - 100px); overflow: auto; }
"""
css = F['css'].read_text(encoding='utf-8')
F['css'].write_text(css.rstrip('\n') + '\n' + CSS, encoding='utf-8')
print('175: Quelltext gepatcht')
