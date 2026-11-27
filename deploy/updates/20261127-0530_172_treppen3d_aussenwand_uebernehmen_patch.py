#!/usr/bin/env python3
"""Update 172: Treppen im 3D nur auf sichtbaren Etagen; Aussenwand einer Nachbarebene uebernehmen."""
import hashlib, os, pathlib

root = pathlib.Path(os.environ['STROM172_ROOT']) / 'frontend'
F = {'app': root / 'src/App.tsx', 'css': root / 'src/styles.css', 'ws': root / 'src/components/Building3DWorkspace.tsx'}
EXPECTED = {
    'app': '2d49c6e725f87b00d7bd3e47c14762e14b726e69eb6faafd0042bc98f76c75d1',
    'css': '6a98072996c6a658dc615bffc39ac02638c6c56594fe7973581afdaf77d0d547',
    'ws': '0d0794b0a54e40f95d22fe6d4bbe3d34c003cd7e72da1debc3a347392a68cea5',
}
for key, path in F.items():
    have = hashlib.sha256(path.read_bytes()).hexdigest()
    if have != EXPECTED[key]:
        raise RuntimeError(f'172: {path.name} entspricht nicht Stand 171 ({have})')

WS_EDITS = [
 ('3D: Treppen nur der sichtbaren Etage',
  "  // 143b already supplies ghost stairs from every level. Suppress those\n"
  "  // copies when dedicated floor groups render the same staircases in 146.\n"
  "  const activeStairs146 = showAllLevels146 && variant === 'house'\n"
  "    ? stairs.filter((surface146) => surface146.levelId === activeLevel.id) : stairs\n",
  "  // STROM172_STAIR_LEVELS: Treppen gehoeren zu ihrer Etage. Die aktive Etage zeigt nur ihre eigenen\n"
  "  // Treppen; weitere Etagen bringen ihre Treppen ueber \"Alle Etagen\" selbst mit (extraLevels146).\n"
  "  // Vorher wurden die Treppen aller Etagen immer halbtransparent mitgezeichnet.\n"
  "  const activeStairs146 = stairs.filter((surface146) => surface146.levelId === activeLevel.id)\n"),
]

APP_EDITS = [
 ('Aussenwand: Hilfswerte',
  "  const stairSeenRooms171 = useRef<Set<string>>(new Set())\n",
  "  // STROM172_OUTER_WALL_ADOPT: Ebene ohne Aussenwand -> Aussenwand der naechsten Ebene darunter/darueber anbieten.\n"
  "  const outerWallsOf172 = (layerId: string) => rooms.filter((room) => isOuterWallRoom(room) && (roomLayerAssignments[room.id] ?? defaultLayerId) === layerId)\n"
  "  const outerWallSources172 = (() => {\n"
  "    const index = layers.findIndex((layer) => layer.id === activeLayerId)\n"
  "    if (index < 0 || outerWallsOf172(activeLayerId).length) return []\n"
  "    const found: { layer: FloorplanLayer; walls: Room[]; relation: 'darunter' | 'darüber' }[] = []\n"
  "    for (let i = index + 1; i < layers.length; i += 1) { const walls = outerWallsOf172(layers[i].id); if (walls.length) { found.push({ layer: layers[i], walls, relation: 'darunter' }); break } }\n"
  "    for (let i = index - 1; i >= 0; i -= 1) { const walls = outerWallsOf172(layers[i].id); if (walls.length) { found.push({ layer: layers[i], walls, relation: 'darüber' }); break } }\n"
  "    return found\n"
  "  })()\n"
  "  const [outerOfferDismissed172, setOuterOfferDismissed172] = useState<Record<string, boolean>>({})\n"
  "  const [outerHover172, setOuterHover172] = useState('')\n"
  "  const [outerAdopting172, setOuterAdopting172] = useState(false)\n"
  "  const outerOffer172 = tool === 'select' && !selectedRoom && !selectedPortal171 && !allSelected\n"
  "    && outerWallSources172.length > 0 && !outerOfferDismissed172[activeLayerId]\n"
  "  const stairSeenRooms171 = useRef<Set<string>>(new Set())\n"),
 ('Aussenwand: uebernehmen',
  "  // STROM171_STAIR_FLIGHT: Treppendurchgang -> gekoppelter Treppenraum auf dieser Ebene.\n",
  "  // STROM172_OUTER_WALL_ADOPT: Kopie (nicht gekoppelt), damit z. B. ein Dachgeschoss abweichen darf.\n"
  "  async function adoptOuterWall172(source: { layer: FloorplanLayer; walls: Room[] }) {\n"
  "    if (outerAdopting172 || outerWallsOf172(activeLayerId).length) return\n"
  "    setOuterAdopting172(true)\n"
  "    try {\n"
  "      onError(null)\n"
  "      onCaptureUndoSnapshot()\n"
  "      const createdIds: string[] = []\n"
  "      for (const wall of source.walls) {\n"
  "        const created = await createRoom({\n"
  "          floorId: floor.id,\n"
  "          name: wall.name,\n"
  "          shapeType: wall.shapeType,\n"
  "          ...(wall.roomType ? { roomType: wall.roomType } : {}),\n"
  "          wallThicknessM: wall.wallThicknessM,\n"
  "          vertices: wall.vertices.map((point) => ({ ...point })),\n"
  "        })\n"
  "        createdIds.push(created.id)\n"
  "      }\n"
  "      setRoomLayerAssignments((current) => {\n"
  "        const next = { ...current }\n"
  "        for (const id of createdIds) next[id] = activeLayerId\n"
  "        return next\n"
  "      })\n"
  "      setOuterHover172('')\n"
  "      await onReload()\n"
  "      if (createdIds[0]) onSelectRoom(createdIds[0])\n"
  "    } catch (err) { onError(err instanceof Error ? err.message : String(err)) }\n"
  "    finally { setOuterAdopting172(false) }\n"
  "  }\n\n"
  "  // STROM171_STAIR_FLIGHT: Treppendurchgang -> gekoppelter Treppenraum auf dieser Ebene.\n"),
 ('Aussenwand: Fenster',
  "        {/* STROM171_STAIR_FLIGHT: gewaehlter Treppendurchgang */}\n",
  "        {/* STROM172_OUTER_WALL_ADOPT: Angebot auf einer Ebene ohne Aussenwand */}\n"
  "        {outerOffer172 && (\n"
  "          <div className=\"strom-stair-direction-floating147 strom-stair-ask170 strom-outer-offer172\" role=\"group\" aria-label=\"Aussenwand uebernehmen\">\n"
  "            <div className=\"strom-stair-direction-title147\">{layers.find((layer) => layer.id === activeLayerId)?.name || 'Ebene'} · noch keine Außenwand</div>\n"
  "            <p className=\"strom-stair-question170\">Außenwand einer Nachbarebene übernehmen? Grundriss und Wandstärke werden kopiert und lassen sich danach hier unabhängig ändern.</p>\n"
  "            <div className=\"strom-outer-offer-actions172\">\n"
  "              {outerWallSources172.map((source) => (\n"
  "                <button key={source.layer.id} type=\"button\" className=\"strom-stair-create147\" data-outer-source172={source.layer.id} disabled={outerAdopting172}\n"
  "                  onMouseEnter={() => setOuterHover172(source.layer.id)} onMouseLeave={() => setOuterHover172('')}\n"
  "                  onFocus={() => setOuterHover172(source.layer.id)} onBlur={() => setOuterHover172('')}\n"
  "                  onClick={() => void adoptOuterWall172(source)}>\n"
  "                  <StromIcon name=\"outer-wall\" size={18} /> {outerAdopting172 ? 'Wird übernommen …' : `Von ${source.layer.name} übernehmen (${source.relation})`}</button>\n"
  "              ))}\n"
  "            </div>\n"
  "            <button type=\"button\" className=\"strom-stair-swap170\" title=\"Angebot ausblenden und die Außenwand selbst zeichnen\"\n"
  "              onClick={() => { setOuterOfferDismissed172((current) => ({ ...current, [activeLayerId]: true })); void chooseTool('outerwall') }}>Selbst zeichnen</button>\n"
  "          </div>\n"
  "        )}\n"
  "        {/* STROM171_STAIR_FLIGHT: gewaehlter Treppendurchgang */}\n"),
 ('Aussenwand: Umriss der Vorlage',
  "            {/* STROM148_ROOF_EDIT: distinct slopes can be placed on one room; click edits parameters. */}\n",
  "            {/* STROM172_OUTER_WALL_ADOPT: Umriss der angebotenen Aussenwand(en) */}\n"
  "            {outerOffer172 && outerWallSources172.flatMap((source) => source.walls.map((wall) => (\n"
  "              <g key={`outer-offer172-${wall.id}`} className={`strom-outer-offer-outline172 ${outerHover172 === source.layer.id ? 'hover' : ''}`} data-outer-outline172={source.layer.id} aria-hidden=\"true\">\n"
  "                <polygon points={pointsToSvg(wall.vertices)} />\n"
  "              </g>\n"
  "            )))}\n"
  "            {/* STROM148_ROOF_EDIT: distinct slopes can be placed on one room; click edits parameters. */}\n"),
]

CSS = """
/* STROM172_OUTER_WALL_ADOPT: Angebot "Aussenwand uebernehmen". */
.strom-outer-offer-actions172 { display:flex; flex-direction:column; align-items:flex-start; gap:6px; }
.strom-outer-offer-outline172 { pointer-events:none; }
.strom-outer-offer-outline172 polygon { fill:rgba(37,99,235,.04); stroke:#2563eb; stroke-width:3; stroke-dasharray:10 7; opacity:.55; }
.strom-outer-offer-outline172.hover polygon { fill:rgba(37,99,235,.1); stroke-width:5; opacity:1; }
"""

app = F['app'].read_text(encoding='utf-8')
ws = F['ws'].read_text(encoding='utf-8')
if 'STROM172_' in app or 'STROM172_' in ws:
    raise RuntimeError('172: bereits installiert')
for text_key, edits in (('app', APP_EDITS), ('ws', WS_EDITS)):
    text = app if text_key == 'app' else ws
    for label, old, new in edits:
        count = text.count(old)
        if count != 1:
            raise RuntimeError(f'172: Textstelle "{label}" {count}x gefunden (erwartet: 1)')
        text = text.replace(old, new)
    if text_key == 'app':
        app = text
    else:
        ws = text
F['app'].write_text(app, encoding='utf-8')
F['ws'].write_text(ws, encoding='utf-8')
css = F['css'].read_text(encoding='utf-8')
F['css'].write_text(css.rstrip('\n') + '\n' + CSS, encoding='utf-8')
print('172: Quelltext gepatcht')
