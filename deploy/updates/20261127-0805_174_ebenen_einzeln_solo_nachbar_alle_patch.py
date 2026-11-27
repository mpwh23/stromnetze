#!/usr/bin/env python3
"""Update 174: beliebige Ebenen einblenden (Blueprint, 3D Haus, Wanddetail); Vorgaben Solo/Nachbar/Alle."""
import hashlib, os, pathlib

root = pathlib.Path(os.environ['STROM174_ROOT']) / 'frontend'
res = pathlib.Path(os.environ['STROM174_RESOURCES'])
F = {
    'app': root / 'src/App.tsx', 'css': root / 'src/styles.css', 'ws': root / 'src/components/Building3DWorkspace.tsx',
    'menu': root / 'src/components/LevelMenu173.tsx', 'store': root / 'src/building/levelStore173.ts',
}
EXPECTED = {
    'app': '98e49eb8dffab88a308595fada958815622fcf92c86c5aca545f9ca779bb1854',
    'css': '6dc2586e94661e4794803882bbbb464d2b4df153cf84969bcaa787b78597305a',
    'ws': '7cf24815a78ad367403ee6769b733cbed62d7abd38f62466b5967dbd841e58c6',
    'menu': 'a9ba085cb63b927467c8ad652ba10aeedee6df5c4798784e8c808d5c7ac5cb0a',
    'store': '710b33676b2b1cd1270f0ad38a5452ffa9f67099e65ba314794f38b91833ca89',
}
for key, path in F.items():
    have = hashlib.sha256(path.read_bytes()).hexdigest()
    if have != EXPECTED[key]:
        raise RuntimeError(f'174: {path.name} entspricht nicht Stand 173 ({have})')
module = root / 'src/building/levelVisibility174.ts'
if module.exists():
    raise RuntimeError('174: levelVisibility174.ts existiert bereits')


def edit(text, label, old, new, count=1):
    have = text.count(old)
    if have != count:
        raise RuntimeError(f'174: Textstelle "{label}" {have}x gefunden (erwartet: {count})')
    return text.replace(old, new)


# ------------------------------------------------------------------ App.tsx (Blueprint)
app = F['app'].read_text(encoding='utf-8')
app = edit(app, 'Import', "import LevelMenu173 from './components/LevelMenu173' // STROM173_LEVEL_MENU\n",
  "import LevelMenu173 from './components/LevelMenu173' // STROM173_LEVEL_MENU\n"
  "import { applyPreset174, derivePreset174, migrateVisibility174, modeFromPreset174, presetFromMode174, type VisibilityPreset174 } from './building/levelVisibility174'\n")
app = edit(app, 'Laden mit Umstellung',
  "function loadFloorplanLayers(floorId: string): FloorplanLayer[] {\n  return normalizeLayers(",
  "function loadFloorplanLayers(floorId: string): FloorplanLayer[] {\n"
  "  migrateVisibility174(floorId, window.localStorage) // STROM174_LEVEL_VISIBILITY: einmalige Umstellung\n"
  "  return normalizeLayers(")
app = edit(app, 'Darstellung je Ebene',
  "    if (active) return { visible: layerVisible, ghost: false, dimensions: true, interactive: layerVisible }\n"
  "    if (!layerVisible) return { visible: false, ghost: false, dimensions: false, interactive: false }\n"
  "    if (layerVisibilityMode === 'active') return { visible: false, ghost: false, dimensions: false, interactive: false }\n"
  "    if (layerVisibilityMode === 'allGhostNoDims') return { visible: true, ghost: true, dimensions: false, interactive: false }\n"
  "    const adjacent = Math.abs(index - activeLayerIndex) === 1\n"
  "    return {\n"
  "      visible: adjacent,\n"
  "      ghost: adjacent,\n"
  "      dimensions: adjacent && layerVisibilityMode === 'adjacentGhostDims',\n"
  "      interactive: false,\n"
  "    }\n",
  "    // STROM174_LEVEL_VISIBILITY: aktive Ebene immer sichtbar; jede andere nach ihrem eigenen Schalter.\n"
  "    if (active) return { visible: true, ghost: false, dimensions: true, interactive: true }\n"
  "    if (!layerVisible) return { visible: false, ghost: false, dimensions: false, interactive: false }\n"
  "    void index\n"
  "    return { visible: true, ghost: true, dimensions: layerVisibilityMode === 'adjacentGhostDims', interactive: false }\n")
app = edit(app, 'Werkzeugleiste: Vorgaben durchschalten',
  "  function cycleLayerVisibilityMode() {\n"
  "    const order: LayerVisibilityMode[] = ['active', 'adjacentGhostNoDims', 'adjacentGhostDims', 'allGhostNoDims']\n"
  "    const index = order.indexOf(layerVisibilityMode)\n"
  "    setLayerVisibilityMode(order[(index + 1) % order.length])\n"
  "  }\n",
  "  // STROM174_LEVEL_VISIBILITY: Vorgaben setzen die Schalter aller Ebenen.\n"
  "  function applyLevelPreset174(preset: VisibilityPreset174, dims = false, activeId = activeLayerId) {\n"
  "    setLayers((current) => applyPreset174(current, activeId, preset))\n"
  "    setLayerVisibilityMode(modeFromPreset174(preset, dims) as LayerVisibilityMode)\n"
  "  }\n"
  "  function cycleLayerVisibilityMode() {\n"
  "    // Solo -> Nachbar -> Nachbar mit Bemassung -> Alle -> Solo\n"
  "    if (levelPreset174 === 'solo') applyLevelPreset174('neighbors')\n"
  "    else if (levelPreset174 === 'neighbors' && layerVisibilityMode !== 'adjacentGhostDims') applyLevelPreset174('neighbors', true)\n"
  "    else if (levelPreset174 === 'neighbors') applyLevelPreset174('all')\n"
  "    else applyLevelPreset174('solo')\n"
  "  }\n")
app = edit(app, 'Neue Ebene (Treppeneditor): solo',
  "    setLayers((current) => [...current, layer])\n    setActiveLayerId(layer.id)\n    setLayerVisibilityMode('active')\n    return layer\n",
  "    setLayers((current) => applyPreset174([...current, layer], layer.id, 'solo'))\n    setActiveLayerId(layer.id)\n    setLayerVisibilityMode('active')\n    return layer\n")
app = edit(app, 'Neue Ebene: solo',
  "    setLayers((current) => [...current, layer])\n    setActiveLayerId(layer.id)\n    setLayerVisibilityMode('active')\n  }\n",
  "    setLayers((current) => applyPreset174([...current, layer], layer.id, 'solo'))\n    setActiveLayerId(layer.id)\n    setLayerVisibilityMode('active')\n  }\n")
app = edit(app, 'Ebene waehlen',
  "  function selectLayer(id: string) {\n"
  "    setLayers((current) => current.map((layer) => layer.id === id && !layer.visible ? { ...layer, visible: true } : layer))\n",
  "  function selectLayer(id: string) {\n"
  "    // STROM174: Solo/Nachbar wandern mit der aktiven Ebene; eigene Auswahl bleibt, die neue Ebene wird sichtbar.\n"
  "    if (levelPreset174 === 'solo' || levelPreset174 === 'neighbors') setLayers((current) => applyPreset174(current, id, levelPreset174 as VisibilityPreset174))\n"
  "    else setLayers((current) => current.map((layer) => layer.id === id && !layer.visible ? { ...layer, visible: true } : layer))\n")
app = edit(app, 'Auge',
  "    // In 'only current' mode, clicking an inactive eye should SHOW the chosen\n"
  "    // level, not silently flip its internal flag to false.\n"
  "    if (id !== activeLayerId && layerVisibilityMode === 'active') {\n"
  "      if (!target.visible) setLayers((current) => current.map((layer) => layer.id === id ? { ...layer, visible: true } : layer))\n"
  "      setLayerVisibilityMode('allGhostNoDims')\n"
  "      return\n"
  "    }\n"
  "    setLayers((current) => current.map((layer) => layer.id === id ? { ...layer, visible: !layer.visible } : layer))\n",
  "    // STROM174: Das Auge schaltet genau diese Ebene um; die aktive Ebene bleibt immer sichtbar.\n"
  "    if (id === activeLayerId) return\n"
  "    setLayers((current) => current.map((layer) => layer.id === id ? { ...layer, visible: layer.visible === false } : layer))\n")
app = edit(app, 'Vorgabe ableiten',
  "  function renderStateForLayer(layerId: string) {\n",
  "  const levelPreset174 = derivePreset174(layers, activeLayerId, presetFromMode174(layerVisibilityMode))\n"
  "  const toolbarMode174: LayerVisibilityMode = levelPreset174 === 'solo' ? 'active' : levelPreset174 === 'all' ? 'allGhostNoDims'\n"
  "    : levelPreset174 === 'neighbors' ? (layerVisibilityMode === 'adjacentGhostDims' ? 'adjacentGhostDims' : 'adjacentGhostNoDims') : 'allGhostNoDims'\n"
  "  const toolbarLabel174 = levelPreset174 === 'custom' ? 'Eigene Ebenenauswahl' : visibilityModeLabel(toolbarMode174)\n\n"
  "  function renderStateForLayer(layerId: string) {\n")
app = edit(app, 'Werkzeugleiste: Knopf',
  "<button title={visibilityModeLabel(layerVisibilityMode)} data-tooltip={visibilityModeLabel(layerVisibilityMode)} aria-label=\"Ebenen-Sichtbarkeit umschalten\" onMouseDown={(event) => event.preventDefault()} onClick={cycleLayerVisibilityMode}>{visibilityModeIcon(layerVisibilityMode)}</button>",
  "<button title={`${toolbarLabel174} (Klick: Solo, Nachbar, Nachbar mit Bemaßung, Alle)`} data-tooltip={toolbarLabel174} aria-label=\"Ebenen-Sichtbarkeit umschalten\" onMouseDown={(event) => event.preventDefault()} onClick={cycleLayerVisibilityMode}>{visibilityModeIcon(toolbarMode174)}</button>")
app = edit(app, 'Menue: Vorgaben',
  "          onAdd={addLayer}\n          onDelete={requestDeleteActiveLayer}\n        />\n",
  "          onAdd={addLayer}\n          onDelete={requestDeleteActiveLayer}\n"
  "          preset={levelPreset174}\n"
  "          onPreset={(preset) => applyLevelPreset174(preset)}\n"
  "        />\n")
F['app'].write_text(app, encoding='utf-8')

# ------------------------------------------------------------------ LevelMenu173.tsx
menu = F['menu'].read_text(encoding='utf-8')
menu = edit(menu, 'Menue: Import', "import { floatRef173 } from './floatDrag173'\n",
  "import { floatRef173 } from './floatDrag173'\n"
  "import type { DerivedPreset174, VisibilityPreset174 } from '../building/levelVisibility174'\n")
menu = edit(menu, 'Menue: Props', "  note?: ReactNode\n}\n",
  "  note?: ReactNode\n"
  "  preset?: DerivedPreset174\n"
  "  onPreset?: (preset: VisibilityPreset174) => void\n"
  "}\n")
menu = edit(menu, 'Menue: Auge-Titel',
  "  const eyeTitle = props.eyeTitle ?? ((_id: string, visible: boolean) => visible\n"
  "    ? 'Ebene aktuell sichtbar - klicken zum manuellen Ausblenden'\n"
  "    : 'Ebene aktuell ausgeblendet - klicken zum manuellen Einblenden')\n",
  "  const eyeTitle = props.eyeTitle ?? ((id: string, visible: boolean) => id === activeId ? 'Aktive Ebene ist immer sichtbar'\n"
  "    : visible ? 'Ebene eingeblendet - klicken zum Ausblenden' : 'Ebene ausgeblendet - klicken zum Einblenden')\n"
  "  const presets174: { id: VisibilityPreset174; label: string; icon: string; title: string }[] = [\n"
  "    { id: 'solo', label: 'Solo', icon: 'layers-current', title: 'Solo: nur die aktuelle Ebene einblenden' },\n"
  "    { id: 'neighbors', label: 'Nachbar', icon: 'layers-neighbor', title: 'Nachbar: aktuelle Ebene und die unmittelbar darüber und darunter einblenden' },\n"
  "    { id: 'all', label: 'Alle', icon: 'layers-all', title: 'Alle Ebenen einblenden' },\n"
  "  ]\n")
menu = edit(menu, 'Menue: Knoepfe',
  "          <div className=\"layer-menu-actions\" aria-label=\"Ebenenaktionen\">\n",
  "          <div className=\"layer-menu-actions layer-menu-actions174\" aria-label=\"Ebenenaktionen\">\n"
  "            {props.onPreset && (\n"
  "              <div className=\"layer-visibility-presets174\" role=\"group\" aria-label=\"Ebenen einblenden\">\n"
  "                {presets174.map((item) => (\n"
  "                  <button key={item.id} type=\"button\" data-preset174={item.id} className={props.preset === item.id ? 'active' : ''}\n"
  "                    aria-pressed={props.preset === item.id} title={item.title} onClick={() => props.onPreset?.(item.id)}>\n"
  "                    <StromIcon name={item.icon} size={16} /> {item.label}\n"
  "                  </button>\n"
  "                ))}\n"
  "              </div>\n"
  "            )}\n")
F['menu'].write_text(menu, encoding='utf-8')

# ------------------------------------------------------------------ levelStore173.ts: Umstellung auch beim Lesen im 3D
store = F['store'].read_text(encoding='utf-8')
store = edit(store, 'Store: Import', "import type { Floor } from '../types'\n",
  "import type { Floor } from '../types'\nimport { migrateVisibility174 } from './levelVisibility174'\n")
store = edit(store, 'Store: Umstellung',
  "  const result: RawLayer173[] = []\n",
  "  if (typeof window !== 'undefined' && storage === window.localStorage) migrateVisibility174(floor.id, window.localStorage) // STROM174\n"
  "  const result: RawLayer173[] = []\n")
F['store'].write_text(store, encoding='utf-8')

# ------------------------------------------------------------------ Building3DWorkspace.tsx
ws = F['ws'].read_text(encoding='utf-8')
ws = edit(ws, '3D: Import', "import { readZeroLevel151, writeZeroLevel151 } from '../building/coordinateReference151'\n",
  "import { readZeroLevel151, writeZeroLevel151 } from '../building/coordinateReference151'\n"
  "import { applyPreset174, derivePreset174, modeFromPreset174, presetFromMode174, type VisibilityPreset174 } from '../building/levelVisibility174'\n")
ws = edit(ws, '3D: kein eigener Alle-Etagen-Zustand', "  const [showAllLevels146, setShowAllLevels146] = useState(false)\n", "")
ws = edit(ws, '3D: Sichtbarkeit aus den Ebenen',
  "  const levelVisible173 = (id: string) => layers173.find((layer) => layer.id === id)?.visible !== false\n",
  "  const levelVisible173 = (id: string) => layers173.find((layer) => layer.id === id)?.visible !== false\n"
  "  // STROM174_LEVEL_VISIBILITY: weitere Etagen = alle eingeblendeten Ebenen (3D Haus und Wanddetail).\n"
  "  const showAllLevels146 = layers173.some((layer) => layer.id !== activeLevel.id && layer.visible !== false)\n"
  "  const allLevelsVisible174 = layers173.every((layer) => layer.id === activeLevel.id || layer.visible !== false)\n"
  "  const storedMode174 = (() => { try { return JSON.parse(window.localStorage.getItem(`strom.floorplan.layers.${floor.id}.visibilityMode`) || 'null') } catch { return null } })()\n"
  "  const levelPreset174 = derivePreset174(layers173, activeLevel.id, presetFromMode174(storedMode174))\n"
  "  function applyLevelPreset174(preset: VisibilityPreset174, activeId = activeLevel.id) {\n"
  "    window.localStorage.setItem(`strom.floorplan.layers.${floor.id}.visibilityMode`, JSON.stringify(modeFromPreset174(preset)))\n"
  "    writeRawLayers173(floor, applyPreset174(readRawLayers173(floor), activeId, preset))\n"
  "  }\n")
ws = edit(ws, '3D: Zeilenzustand',
  "    if (variant === 'house' && showAllLevels146 && levelVisible173(id)) return { visible: true, ghost: true }\n",
  "    if (levelVisible173(id)) return { visible: true, ghost: true }\n")
ws = edit(ws, '3D: Ebene waehlen',
  "  function selectLevel173(id: string) {\n    if (!levelVisible173(id)) patchRawLayer173(floor, id, { visible: true })\n",
  "  function selectLevel173(id: string) {\n"
  "    if (levelPreset174 === 'solo' || levelPreset174 === 'neighbors') applyLevelPreset174(levelPreset174, id)\n"
  "    else if (!levelVisible173(id)) patchRawLayer173(floor, id, { visible: true })\n")
ws = edit(ws, '3D: Auge',
  "    if (id === activeLevel.id) return\n"
  "    if (variant !== 'house') { selectLevel173(id); return }\n"
  "    if (!showAllLevels146) {\n"
  "      // Wie im Blueprint: Im Modus 'nur aktuelle Ebene' blendet das Auge die Ebene EIN.\n"
  "      if (!levelVisible173(id)) patchRawLayer173(floor, id, { visible: true })\n"
  "      setShowAllLevels146(true)\n"
  "      return\n"
  "    }\n"
  "    patchRawLayer173(floor, id, { visible: !levelVisible173(id) })\n",
  "    if (id === activeLevel.id) return\n"
  "    // STROM174: genau diese Ebene ein-/ausblenden (3D Haus und Wanddetail).\n"
  "    patchRawLayer173(floor, id, { visible: !levelVisible173(id) })\n")
ws = edit(ws, '3D: neue Ebene solo',
  "    writeRawLayers173(floor, [...current, layer])\n",
  "    writeRawLayers173(floor, applyPreset174([...current, layer], layer.id, 'solo'))\n")
ws = edit(ws, '3D: Wanddetail zeigt weitere Etagen',
  "  const extraLevels146 = showAllLevels146 && variant === 'house'\n",
  "  const extraLevels146 = showAllLevels146\n")
ws = edit(ws, '3D: Alle-Etagen-Knopf',
  "            <button type=\"button\" className={showAllLevels146 ? 'active' : ''} aria-pressed={showAllLevels146}\n",
  "            <button type=\"button\" className={allLevelsVisible174 ? 'active' : ''} aria-pressed={allLevelsVisible174}\n")
ws = edit(ws, '3D: Alle-Etagen-Klick',
  "              onClick={() => setShowAllLevels146((value) => !value)}>\n",
  "              onClick={() => applyLevelPreset174(allLevelsVisible174 ? 'solo' : 'all')}>\n")
ws = edit(ws, '3D: Alle-Etagen-Text',
  "Alle Etagen {showAllLevels146 ? 'AN' : 'AUS'}\n", "Alle Etagen {allLevelsVisible174 ? 'AN' : 'AUS'}\n")
ws = edit(ws, '3D: Szene fuer beide Varianten',
  "showAllLevels146={variant === 'house' && showAllLevels146}", "showAllLevels146={showAllLevels146}")
ws = edit(ws, '3D: Auge-Titel',
  "              : variant === 'wall' ? 'Wanddetail zeigt genau eine Ebene - klicken, um diese Ebene zu zeigen'\n", "")
ws = edit(ws, '3D: Vorgaben im Menue',
  "            onDelete={() => { if (layers173.length > 1) setLevelDelete173(activeLevel.id) }}\n",
  "            onDelete={() => { if (layers173.length > 1) setLevelDelete173(activeLevel.id) }}\n"
  "            preset={levelPreset174}\n"
  "            onPreset={(preset) => applyLevelPreset174(preset)}\n")
F['ws'].write_text(ws, encoding='utf-8')

CSS = """
/* STROM174_LEVEL_VISIBILITY: Vorgaben Solo / Nachbar / Alle neben Neu/Loeschen. */
.level-menu173 .layer-menu-actions174 { justify-content: space-between; gap: 8px; flex-wrap: wrap; }
.level-menu173 .layer-visibility-presets174 { display: inline-flex; gap: 2px; padding: 2px; border: 1px solid #d7e1ee; border-radius: 11px; background: #f3f6fb; margin-right: auto; }
.level-menu173 .layer-visibility-presets174 button { display: inline-flex; align-items: center; gap: 4px; height: 28px; padding: 0 8px; border: 0; border-radius: 9px;
  background: transparent; box-shadow: none; color: #334a68; font-size: 11.5px; font-weight: 750; }
.level-menu173 .layer-visibility-presets174 button:hover { background: #e6eefb; }
.level-menu173 .layer-visibility-presets174 button.active { background: #2563eb; color: #fff; }
"""
css = F['css'].read_text(encoding='utf-8')
F['css'].write_text(css.rstrip('\n') + '\n' + CSS, encoding='utf-8')
module.write_text((res / 'levelVisibility174.ts').read_text(encoding='utf-8'), encoding='utf-8')
print('174: Quelltext gepatcht')
