#!/usr/bin/env python3
"""Update 173: ein Ebenenmenue (Vorlage Blueprint) in Blueprint und 3D, standardmaessig offen;
alle schwebenden Fenster und Menues verschiebbar."""
import hashlib, os, pathlib

root = pathlib.Path(os.environ['STROM173_ROOT']) / 'frontend'
res = pathlib.Path(os.environ['STROM173_RESOURCES'])
F = {'app': root / 'src/App.tsx', 'css': root / 'src/styles.css', 'ws': root / 'src/components/Building3DWorkspace.tsx', 'icon': root / 'src/components/StromIcon.tsx'}
EXPECTED = {
    'icon': 'b206eff4f9bfb53f26d7b8634326f676263c80fd33e6bbf917bdf836cefe98b5',
    'app': '2a1206eeeef609effef4e53440dd9210e5c6f1b9a7235dafca8d65e1ec1cf6c7',
    'css': '5573f729e56042eb94740a58999f62556b902426fd552dd1a78fe1ae1dc00ed3',
    'ws': 'ba5a14ba3cb8bdb80c5a6ea1ff3afa8c62b7c699a8338b7147bed352caaf3b61',
}
for key, path in F.items():
    have = hashlib.sha256(path.read_bytes()).hexdigest()
    if have != EXPECTED[key]:
        raise RuntimeError(f'173: {path.name} entspricht nicht Stand 172 ({have})')
NEW = {
    'components/floatDrag173.ts': 'floatDrag173.ts',
    'components/LevelMenu173.tsx': 'LevelMenu173.tsx',
    'building/levelStore173.ts': 'levelStore173.ts',
}
for rel in NEW:
    if (root / 'src' / rel).exists():
        raise RuntimeError(f'173: {rel} existiert bereits')


def edit(text, label, old, new, count=1):
    have = text.count(old)
    if have != count:
        raise RuntimeError(f'173: Textstelle "{label}" {have}x gefunden (erwartet: {count})')
    return text.replace(old, new)


def replace_between(text, label, start, end, new):
    a = text.find(start)
    if a < 0 or text.count(start) != 1:
        raise RuntimeError(f'173: Anfang "{label}" nicht eindeutig')
    b = text.find(end, a)
    if b < 0:
        raise RuntimeError(f'173: Ende "{label}" fehlt')
    return text[:a] + new + text[b:]


# ------------------------------------------------------------------ App.tsx
app = F['app'].read_text(encoding='utf-8')
if 'STROM173_' in app:
    raise RuntimeError('173: bereits installiert')
app = edit(app, 'Import', "import StromIcon from './components/StromIcon'\n",
  "import StromIcon from './components/StromIcon'\n"
  "import LevelMenu173 from './components/LevelMenu173' // STROM173_LEVEL_MENU\n"
  "import { floatRef173 } from './components/floatDrag173' // STROM173_FLOAT_DRAG\n")

# Blueprint: Ebenenmenue -> gemeinsame Komponente, standardmaessig offen
app = edit(app, 'Blueprint: offen', "  const [layersOpen, setLayersOpen] = useState(false)\n"
  "  const [blueprintWallObjects, setBlueprintWallObjects]",
  "  const [layersOpen, setLayersOpen] = useState(true) // STROM173: Ebenenmenue standardmaessig offen\n"
  "  const [blueprintWallObjects, setBlueprintWallObjects]")
app = edit(app, 'Blueprint: offen nach Etagenwechsel',
  "    setLayerDeleteRequestId('')\n    setLayersOpen(false)\n",
  "    setLayerDeleteRequestId('')\n    setLayersOpen(true)\n")
app = replace_between(app, 'Blueprint-Ebenenmenue',
  "        <div className={`canvas-layer-menu ${layersOpen ? 'open' : ''}`} aria-label=\"Ebenen\">\n",
  "        {layerDeleteRequest && (\n",
  "        {/* STROM173_LEVEL_MENU: gemeinsames Ebenenmenue (auch in den 3D-Ansichten) */}\n"
  "        <LevelMenu173\n"
  "          floatId=\"blueprint-levels\"\n"
  "          levels={layers.map((layer) => ({ id: layer.id, name: layer.name, visible: layer.visible !== false, heightM: layer.heightM ?? floor.heightM, slabThicknessM: layer.slabThicknessM ?? 0 }))}\n"
  "          activeId={activeLayerId}\n"
  "          zeroId={resolveZeroLevel151(layers, zeroLevel151)}\n"
  "          radioName={`layer-zero151-${floor.id}`}\n"
  "          open={layersOpen}\n"
  "          onToggleOpen={() => setLayersOpen((current) => !current)}\n"
  "          rowState={(id) => { const state = effectiveLayerState(id); return { visible: state.visible, ghost: state.ghost } }}\n"
  "          onSelect={selectLayer}\n"
  "          onToggleVisible={toggleLayerVisibility}\n"
  "          onRename={renameLayer}\n"
  "          onHeight={setLayerHeightM}\n"
  "          onSlab={setLayerSlab149}\n"
  "          onZero={(id) => { writeZeroLevel151(floor.id, id, window.localStorage); setZeroLevel151(id) }}\n"
  "          onMove={moveLayerBefore}\n"
  "          onAdd={addLayer}\n"
  "          onDelete={requestDeleteActiveLayer}\n"
  "        />\n")

# 3D-Ansichten: Neuladen der Raeume nach dem Loeschen einer Ebene
app = edit(app, '3D: Raeume neu laden',
  "onBackToBlueprint={() => handleViewModeClick('floorplan')}\n",
  "onBackToBlueprint={() => handleViewModeClick('floorplan')}\n onReloadRooms173={reload}\n", 2)

# Klassische Wandansicht: Menue offen, beim Waehlen nicht schliessen, verschiebbar
app = edit(app, 'Wand: offen', "  const [layersOpen, setLayersOpen] = useState(false)\n", "  const [layersOpen, setLayersOpen] = useState(true) // STROM173\n")
app = edit(app, 'Wand: offen nach Wechsel',
  "    setRoomLayerAssignments(loadLayerAssignments(floor.id))\n    setLayersOpen(false)\n    setSelectedWall(null)\n",
  "    setRoomLayerAssignments(loadLayerAssignments(floor.id))\n    setLayersOpen(true)\n    setSelectedWall(null)\n")
app = edit(app, 'Wand: Auswahl schliesst nicht',
  "    onSelectRoom('')\n    setSelectedWall(null)\n    setLayersOpen(false)\n  }\n",
  "    onSelectRoom('')\n    setSelectedWall(null)\n  }\n")
app = edit(app, 'Wand: Menue verschiebbar',
  "        <div className={`canvas-layer-menu wall-layer-menu ${layersOpen ? 'open' : ''}`} aria-label=\"Ebenen\">\n",
  "        <div ref={floatRef173('wall-levels')} className={`canvas-layer-menu wall-layer-menu ${layersOpen ? 'open' : ''}`} aria-label=\"Ebenen\">\n"
  "          <span className=\"float-grip173\" title=\"Ebenenmenü verschieben (Doppelklick: zurück an den Standardplatz)\" aria-hidden=\"true\"><StromIcon name=\"drag-dots\" size={16} /></span>\n")

# Schwebende Fenster im Blueprint verschiebbar
FLOATS = [
 ('Aussenwand-Angebot', '<div className="strom-stair-direction-floating147 strom-stair-ask170 strom-outer-offer172" role="group"',
  '<div ref={floatRef173(\'blueprint-info\')} className="strom-stair-direction-floating147 strom-stair-ask170 strom-outer-offer172" role="group"'),
 ('Treppendurchgang', '<div className="strom-stair-direction-floating147 strom-stair-ask170 strom-stair-portal-panel171" role="group"',
  '<div ref={floatRef173(\'blueprint-info\')} className="strom-stair-direction-floating147 strom-stair-ask170 strom-stair-portal-panel171" role="group"'),
 ('Treppenrichtung', "<div className={`strom-stair-direction-floating147 ${selectedStairDirection147 ? '' : 'strom-stair-ask170'}`} role=\"group\"",
  "<div ref={floatRef173('blueprint-info')} className={`strom-stair-direction-floating147 ${selectedStairDirection147 ? '' : 'strom-stair-ask170'}`} role=\"group\""),
 ('Aussparung Hilfe', '<div className="canvas-settings recess-help">', '<div ref={floatRef173(\'blueprint-recess-help\')} className="canvas-settings recess-help">'),
 ('Tuer', '<div className="canvas-settings blueprint-door-settings136" aria-label="Tuerparameter">',
  '<div ref={floatRef173(\'blueprint-door\')} className="canvas-settings blueprint-door-settings136" aria-label="Tuerparameter">'),
 ('Dachschraege', '<div className="strom-roof-floating148">', '<div ref={floatRef173(\'blueprint-roof\')} className="strom-roof-floating148">'),
 ('Aussparung', '    <div className="recess-floating">\n', '    <div ref={floatRef173(\'blueprint-recess\')} className="recess-floating">\n'),
 ('Abstand', '    <div className="distance-floating-panel">\n', '    <div ref={floatRef173(\'blueprint-distance\')} className="distance-floating-panel">\n'),
 ('Rechteck', '      <div className="canvas-settings">\n        <label>Name<input value={rectInput.name}',
  '      <div ref={floatRef173(\'blueprint-draft\')} className="canvas-settings">\n        <label>Name<input value={rectInput.name}'),
 ('Polygon', '      <div className="canvas-settings">\n        <label>Name<input value={polygonName}',
  '      <div ref={floatRef173(\'blueprint-draft\')} className="canvas-settings">\n        <label>Name<input value={polygonName}'),
]
for label, old, new in FLOATS:
    app = edit(app, label, old, new)
F['app'].write_text(app, encoding='utf-8')

# ------------------------------------------------------------------ Building3DWorkspace.tsx
ws = F['ws'].read_text(encoding='utf-8')
ws = edit(ws, '3D: Importe', "import { getWallObjects, updateWallObject as updateWallObjectApi } from '../api'\n",
  "import { deleteRoom, getWallObjects, updateWallObject as updateWallObjectApi } from '../api'\n"
  "import LevelMenu173 from './LevelMenu173' // STROM173_LEVEL_MENU\n"
  "import { moveRawLayer173, patchRawLayer173, readRawLayers173, writeRawLayers173, LEVELS_CHANGED173 } from '../building/levelStore173'\n"
  "import { readZeroLevel151, writeZeroLevel151 } from '../building/coordinateReference151'\n")
ws = edit(ws, '3D: Prop', "onOpenLegacyWallDetail, onSelectWall, wallEditor, objectsRevision }: {\n",
  "onOpenLegacyWallDetail, onSelectWall, wallEditor, objectsRevision, onReloadRooms173 }: {\n"
  "  onReloadRooms173?: () => Promise<void>\n")
ws = edit(ws, '3D: offen', "  const [levelsOpen145, setLevelsOpen145] = useState(false)\n",
  "  const [levelsOpen145, setLevelsOpen145] = useState(true) // STROM173: Ebenenmenue standardmaessig offen\n"
  "  const [levelDelete173, setLevelDelete173] = useState('')\n")
ws = edit(ws, '3D: Ebenenliste',
  "  const levelOptions144 = useMemo(() => listBlueprintLevelOptions144(floor, window.localStorage), [floor, levelRevision])\n",
  "  const levelOptions144 = useMemo(() => listBlueprintLevelOptions144(floor, window.localStorage), [floor, levelRevision])\n"
  "  // STROM173_LEVEL_MENU: dieselbe Ebenenliste wie im Blueprint, inklusive Sichtbarkeit.\n"
  "  const layers173 = useMemo(() => readRawLayers173(floor), [floor, levelRevision])\n"
  "  const levelVisible173 = (id: string) => layers173.find((layer) => layer.id === id)?.visible !== false\n")
ws = edit(ws, '3D: weitere Etagen nach Sichtbarkeit',
  "    ? sceneLevels146.filter((entry146) => entry146.id !== activeLevel.id) : []\n",
  "    ? sceneLevels146.filter((entry146) => entry146.id !== activeLevel.id && levelVisible173(entry146.id)) : [] // STROM173: Auge im Ebenenmenue\n")
ws = edit(ws, '3D: Handler',
  "  const levelFloor = useMemo(() => active3DFloor(floor, activeLevel), [floor, activeLevel])\n",
  "  // STROM173_LEVEL_MENU: Bedienung wie im Blueprint, gespeichert in denselben Blueprint-Daten.\n"
  "  function levelRowState173(id: string) {\n"
  "    if (id === activeLevel.id) return { visible: true, ghost: false }\n"
  "    if (variant === 'house' && showAllLevels146 && levelVisible173(id)) return { visible: true, ghost: true }\n"
  "    return { visible: false, ghost: false }\n"
  "  }\n"
  "  function selectLevel173(id: string) {\n"
  "    if (!levelVisible173(id)) patchRawLayer173(floor, id, { visible: true })\n"
  "    chooseWallDetailLevel144(id)\n"
  "  }\n"
  "  function toggleLevel173(id: string) {\n"
  "    if (id === activeLevel.id) return\n"
  "    if (variant !== 'house') { selectLevel173(id); return }\n"
  "    if (!showAllLevels146) {\n"
  "      // Wie im Blueprint: Im Modus 'nur aktuelle Ebene' blendet das Auge die Ebene EIN.\n"
  "      if (!levelVisible173(id)) patchRawLayer173(floor, id, { visible: true })\n"
  "      setShowAllLevels146(true)\n"
  "      return\n"
  "    }\n"
  "    patchRawLayer173(floor, id, { visible: !levelVisible173(id) })\n"
  "  }\n"
  "  function addLevel173() {\n"
  "    const current = readRawLayers173(floor)\n"
  "    const active = current.find((layer) => layer.id === activeLevel.id)\n"
  "    const layer = { id: `layer-${Date.now()}`, name: `Ebene ${current.length + 1}`, visible: true, heightM: active?.heightM ?? floor.heightM, slabThicknessM: 0 }\n"
  "    window.localStorage.setItem(`strom.floorplan.layers.${floor.id}.visibilityMode`, JSON.stringify('active'))\n"
  "    writeRawLayers173(floor, [...current, layer])\n"
  "    chooseWallDetailLevel144(layer.id)\n"
  "  }\n"
  "  async function confirmDeleteLevel173() {\n"
  "    const id = levelDelete173\n"
  "    const current = readRawLayers173(floor)\n"
  "    setLevelDelete173('')\n"
  "    if (!id || current.length <= 1) return\n"
  "    let assignments: Record<string, string> = {}\n"
  "    try { assignments = JSON.parse(window.localStorage.getItem(`strom.floorplan.layers.${floor.id}.roomAssignments`) || '{}') || {} } catch { assignments = {} }\n"
  "    const targetRooms = rooms.filter((room) => (assignments[room.id] || 'layer-main') === id)\n"
  "    const remaining = current.filter((layer) => layer.id !== id)\n"
  "    const oldIndex = current.findIndex((layer) => layer.id === id)\n"
  "    const fallback = remaining[Math.max(0, Math.min(remaining.length - 1, oldIndex - 1))] ?? remaining[0]\n"
  "    try {\n"
  "      onCaptureUndo()\n"
  "      onSelectRoom('')\n"
  "      onSelectWall?.(null)\n"
  "      await Promise.all(targetRooms.map((room) => deleteRoom(room.id)))\n"
  "      const nextAssignments = { ...assignments }\n"
  "      for (const [roomId, layerId] of Object.entries(nextAssignments)) if (layerId === id) delete nextAssignments[roomId]\n"
  "      window.localStorage.setItem(`strom.floorplan.layers.${floor.id}.roomAssignments`, JSON.stringify(nextAssignments))\n"
  "      try {\n"
  "        const offsets = JSON.parse(window.localStorage.getItem(`strom.floorplan.titleOffsets.${floor.id}`) || '{}') || {}\n"
  "        targetRooms.forEach((room) => { delete offsets[room.id] })\n"
  "        window.localStorage.setItem(`strom.floorplan.titleOffsets.${floor.id}`, JSON.stringify(offsets))\n"
  "      } catch { /* Beschriftungsversatz ist optional */ }\n"
  "      window.localStorage.setItem(`strom.floorplan.layers.${floor.id}.active`, JSON.stringify(fallback.id))\n"
  "      writeRawLayers173(floor, remaining)\n"
  "      await onReloadRooms173?.()\n"
  "    } catch (error) {\n"
  "      setMessage(`Ebene konnte nicht geloescht werden: ${error instanceof Error ? error.message : String(error)}`)\n"
  "      await onReloadRooms173?.()\n"
  "    }\n"
  "  }\n"
  "  const levelDeleteLayer173 = layers173.find((layer) => layer.id === levelDelete173) ?? null\n"
  "  const levelDeleteCount173 = levelDeleteLayer173 ? (() => {\n"
  "    let assignments: Record<string, string> = {}\n"
  "    try { assignments = JSON.parse(window.localStorage.getItem(`strom.floorplan.layers.${floor.id}.roomAssignments`) || '{}') || {} } catch { assignments = {} }\n"
  "    return rooms.filter((room) => (assignments[room.id] || 'layer-main') === levelDeleteLayer173.id).length\n"
  "  })() : 0\n\n"
  "  const levelFloor = useMemo(() => active3DFloor(floor, activeLevel), [floor, activeLevel])\n")
ws = replace_between(ws, '3D-Ebenenmenue',
  "          {/* STROM145_FLOATING_LEVELS: reuse the Blueprint floating layer-menu classes. */}\n",
  "          <div className=\"building3d-help\">",
  "          {/* STROM173_LEVEL_MENU: dasselbe Ebenenmenue wie im Blueprint */}\n"
  "          <LevelMenu173\n"
  "            floatId={variant === 'wall' ? 'wall3d-levels' : 'house3d-levels'}\n"
  "            className=\"building3d-floating-levels145\"\n"
  "            levels={layers173.map((layer) => ({ id: layer.id, name: layer.name, visible: layer.visible !== false, heightM: layer.heightM ?? floor.heightM, slabThicknessM: layer.slabThicknessM ?? 0 }))}\n"
  "            activeId={activeLevel.id}\n"
  "            zeroId={readZeroLevel151(floor.id, layers173, window.localStorage)}\n"
  "            radioName={`layer-zero151-3d-${floor.id}`}\n"
  "            open={levelsOpen145}\n"
  "            onToggleOpen={() => setLevelsOpen145((value) => !value)}\n"
  "            rowState={levelRowState173}\n"
  "            eyeTitle={(id, visible) => id === activeLevel.id ? 'Aktive Ebene wird immer angezeigt'\n"
  "              : variant === 'wall' ? 'Wanddetail zeigt genau eine Ebene - klicken, um diese Ebene zu zeigen'\n"
  "              : visible ? 'Ebene eingeblendet - klicken zum Ausblenden' : 'Ebene ausgeblendet - klicken zum Einblenden'}\n"
  "            onSelect={selectLevel173}\n"
  "            onToggleVisible={toggleLevel173}\n"
  "            onRename={(id, name) => patchRawLayer173(floor, id, { name })}\n"
  "            onHeight={(id, millimetres) => { const heightM = Math.min(10, Math.max(0.1, Math.round(millimetres) / 1000)); if (Number.isFinite(millimetres) && heightM !== (layers173.find((layer) => layer.id === id)?.heightM ?? floor.heightM)) patchRawLayer173(floor, id, { heightM }) }}\n"
  "            onSlab={(id, millimetres) => { const slabThicknessM = Math.min(1.5, Math.max(0, Math.round(millimetres) / 1000)); if (Number.isFinite(millimetres) && slabThicknessM !== (layers173.find((layer) => layer.id === id)?.slabThicknessM ?? 0)) patchRawLayer173(floor, id, { slabThicknessM }) }}\n"
  "            onZero={(id) => { writeZeroLevel151(floor.id, id, window.localStorage); window.dispatchEvent(new Event(LEVELS_CHANGED173)) }}\n"
  "            onMove={(dragId, targetId) => moveRawLayer173(floor, dragId, targetId)}\n"
  "            onAdd={addLevel173}\n"
  "            onDelete={() => { if (layers173.length > 1) setLevelDelete173(activeLevel.id) }}\n"
  "          />\n"
  "          {levelDeleteLayer173 && (\n"
  "            <div className=\"modal-backdrop layer-delete-backdrop\" role=\"presentation\" onMouseDown={(event) => { if (event.target === event.currentTarget) setLevelDelete173('') }}>\n"
  "              <section className=\"confirm-modal layer-delete-modal\" role=\"dialog\" aria-modal=\"true\" aria-label=\"Ebene loeschen bestaetigen\">\n"
  "                <h2>Ebene loeschen?</h2>\n"
  "                <p>Die Ebene <strong>{levelDeleteLayer173.name}</strong> wird geloescht.</p>\n"
  "                {levelDeleteCount173 > 0 && <p className=\"warning-text\">Achtung: Dabei werden auch alle {levelDeleteCount173} Objekte auf dieser Ebene geloescht.</p>}\n"
  "                {levelDeleteCount173 === 0 && <p>Auf dieser Ebene befinden sich keine Objekte.</p>}\n"
  "                <div className=\"button-row\">\n"
  "                  <button type=\"button\" onClick={() => setLevelDelete173('')}>Abbrechen</button>\n"
  "                  <button type=\"button\" className=\"danger\" onClick={() => void confirmDeleteLevel173()}>Ja, Ebene loeschen</button>\n"
  "                </div>\n"
  "              </section>\n"
  "            </div>\n"
  "          )}\n\n          ")
F['ws'].write_text(ws, encoding='utf-8')

# ------------------------------------------------------------------ StromIcon: stabile Klickziele
icon = F['icon'].read_text(encoding='utf-8')
icon = edit(icon, 'Icon: Import', "import { iconAlias169, iconSet169 } from './iconSet169'\n",
  "import { memo } from 'react'\nimport { iconAlias169, iconSet169 } from './iconSet169'\n")
icon = edit(icon, 'Icon: memo', "export default function StromIcon(", "function StromIcon(")
icon = icon.rstrip('\n') + "\n\n// STROM173: Ohne erneutes Zeichnen bei unveraenderten Angaben. Vorher ersetzte jedes Neuzeichnen\n// der Elternkomponente die SVG-Pfade; ein Klick, waehrenddessen ging verloren.\nexport default memo(StromIcon)\n"
F['icon'].write_text(icon, encoding='utf-8')

# ------------------------------------------------------------------ CSS + neue Dateien
CSS = """
/* STROM173_LEVEL_MENU + STROM173_FLOAT_DRAG */
.level-menu173 { display: flex; align-items: center; gap: 6px; }
.canvas-layer-menu .float-grip173 {
  display: inline-flex; align-items: center; justify-content: center; flex: 0 0 auto;
  width: 26px; height: 32px; border-radius: 999px; color: #64748b; cursor: grab; pointer-events: auto !important;
  background: rgba(248,250,252,0.96); border: 1px solid rgba(148,163,184,0.46); box-shadow: 0 10px 22px rgba(15,23,42,0.10);
}
.canvas-layer-menu .float-grip173:hover { color: #1e3a8a; background: #eef4ff; }
.building3d-view .building3d-floating-levels145.level-menu173 { pointer-events: none; }
/* 3D: dieselbe Darstellung wie das Blueprint-Ebenenmenue (.floorplan-layout-Regeln uebernommen). */
.building3d-view .level-menu173 .layer-height-control { display: flex; flex-direction: column; align-items: stretch; gap: 2px; min-width: 0; font-size: 10px; font-weight: 600; color: #526581; }
.building3d-view .level-menu173 .layer-height-control input { width: 100%; min-width: 0; height: 25px; padding: 3px 4px; font-size: 12px; font-variant-numeric: tabular-nums; border: 1px solid #b6c7de; border-radius: 5px; background: white; color: #1f334b; }
.building3d-view .level-menu173 .layer-height-control input:focus { outline: 2px solid #60a5fa; }
.building3d-view .building3d-floating-levels145.level-menu173 .layer-menu-panel { width: auto; max-width: min(420px, 95vw); }
.building3d-floating-levels145.level-menu173 .layer-list { max-height: 260px; }
.building3d-view .building3d-floating-levels145.level-menu173 > button { max-width: 220px; }
[data-float173] { cursor: grab; }
[data-float173] :is(button, input, select, textarea, label, a) { cursor: auto; }
[data-float173] button { cursor: pointer; }
.floating-dragging173, .floating-dragging173 * { cursor: grabbing !important; user-select: none !important; }
/* STROM173: Icons sind nie selbst Klickziel; der Knopf darunter bleibt es auch beim Neuzeichnen. */
svg.strom-icon, svg.strom-icon * { pointer-events: none !important; }
"""
css = F['css'].read_text(encoding='utf-8')
F['css'].write_text(css.rstrip('\n') + '\n' + CSS, encoding='utf-8')
for rel, name in NEW.items():
    (root / 'src' / rel).write_text((res / name).read_text(encoding='utf-8'), encoding='utf-8')
print('173: Quelltext gepatcht')
