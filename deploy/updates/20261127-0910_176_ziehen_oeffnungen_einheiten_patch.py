#!/usr/bin/env python3
"""Update 176: Blueprint - nur ausgewaehlte Objekte verschieben (sonst Ansicht), Tueren/Fenster orange,
Fenster als H, Masse an Oeffnungen; Ebenenfenster - Masseinheit im Feld (m/dm/cm/mm), Z=0 als Icon."""
import hashlib, os, pathlib

root = pathlib.Path(os.environ['STROM176_ROOT']) / 'frontend'
res = pathlib.Path(os.environ['STROM176_RESOURCES'])
F = {'app': root / 'src/App.tsx', 'css': root / 'src/styles.css', 'menu': root / 'src/components/LevelMenu173.tsx', 'icons': root / 'src/components/iconSet169.ts'}
EXPECTED = {
    'app': 'c699e4cf50507ad0280d8febacde7b113f21754a63555ef40530791b45019a69',
    'css': 'ba802bcf53e9c243b6c6fb85bf676dad4fd6f7553c049352ba92567148e1bfa7',
    'menu': '1a7e6f1ee78230180b43450904ae235c2e89f8cbbdce165d087eb544a9c0c709',
    'icons': 'd17be41bebe2ce9c7cd7389a19190a510de7f74f9b9e0e1f1252759270a40848',
}
for key, path in F.items():
    have = hashlib.sha256(path.read_bytes()).hexdigest()
    if have != EXPECTED[key]:
        raise RuntimeError(f'176: {path.name} entspricht nicht Stand 175 ({have})')


def edit(text, label, old, new, count=1):
    have = text.count(old)
    if have != count:
        raise RuntimeError(f'176: Textstelle "{label}" {have}x gefunden (erwartet: {count})')
    return text.replace(old, new)


# ------------------------------------------------------------------ App.tsx
app = F['app'].read_text(encoding='utf-8')
if 'STROM176_' in app:
    raise RuntimeError('176: bereits installiert')
app = edit(app, 'Ziehen nur ausgewaehlt',
  "  function startRoomDrag(event: ReactMouseEvent<SVGGElement>, room: Room) {\n"
  "    if (tool !== 'select') return\n"
  "    const point = eventToMeters(event)\n"
  "    if (!point) return\n",
  "  function startRoomDrag(event: ReactMouseEvent<SVGGElement>, room: Room) {\n"
  "    if (tool !== 'select') return\n"
  "    // STROM176_SELECT_BEFORE_DRAG: Nur ein bereits ausgewaehltes Objekt wird verschoben. Sonst verschiebt\n"
  "    // Ziehen die Ansicht (wie neben einem Objekt); ein Klick ohne Ziehen waehlt das Objekt aus.\n"
  "    if (!allSelected && room.id !== selectedRoomId) {\n"
  "      if (event.button !== 0 || !canvasScrollRef.current) return\n"
  "      event.preventDefault()\n"
  "      panDragRef.current = {\n"
  "        startX: event.clientX,\n"
  "        startY: event.clientY,\n"
  "        scrollLeft: canvasScrollRef.current.scrollLeft,\n"
  "        scrollTop: canvasScrollRef.current.scrollTop,\n"
  "        moved: false,\n"
  "      }\n"
  "      return\n"
  "    }\n"
  "    const point = eventToMeters(event)\n"
  "    if (!point) return\n")
app = edit(app, 'Raumname ziehen nur ausgewaehlt',
  "    if ((roomLayerAssignments[room.id] ?? defaultLayerId) !== activeLayerId) return\n"
  "    event.preventDefault()\n"
  "    event.stopPropagation()\n"
  "    setAllSelected(false)\n"
  "    onSelectRoom(room.id)\n"
  "    setTitleDrag({\n",
  "    if ((roomLayerAssignments[room.id] ?? defaultLayerId) !== activeLayerId) return\n"
  "    event.preventDefault()\n"
  "    event.stopPropagation()\n"
  "    // STROM176: Raumname eines nicht ausgewaehlten Raums: Ansicht verschieben (Klick waehlt aus).\n"
  "    if (room.id !== selectedRoomId && canvasScrollRef.current) {\n"
  "      panDragRef.current = { startX: event.clientX, startY: event.clientY, scrollLeft: canvasScrollRef.current.scrollLeft, scrollTop: canvasScrollRef.current.scrollTop, moved: false }\n"
  "      return\n"
  "    }\n"
  "    setAllSelected(false)\n"
  "    onSelectRoom(room.id)\n"
  "    setTitleDrag({\n")
app = edit(app, 'Klick nach Verschieben der Ansicht waehlt nicht aus',
  "  function selectSingleRoom(id: string) {\n    setAllSelected(false)\n",
  "  function selectSingleRoom(id: string) {\n"
  "    // STROM176: Nach dem Verschieben der Ansicht nicht zusaetzlich auswaehlen.\n"
  "    if (suppressCanvasClickRef.current) { suppressCanvasClickRef.current = false; return }\n"
  "    setAllSelected(false)\n")
app = edit(app, 'Oeffnungen: Aufruf',
  "              rooms={activeLayerRooms}\n            />\n            {blueprintDoorPreview136 && tool === 'door' && (",
  "              rooms={activeLayerRooms}\n"
  "              showDimensions={dimensionsVisible && tool === 'select'}\n"
  "              wallHeightM={blueprintDoorWallHeight136}\n"
  "            />\n            {blueprintDoorPreview136 && tool === 'door' && (")
app = edit(app, 'Hinweistext Auswahl',
  "Auswahlmodus: Raum anklicken und ziehen. Leere Flaeche ziehen verschiebt die Ansicht.",
  "Auswahlmodus: Klick waehlt einen Raum aus; nur ein ausgewaehlter Raum laesst sich ziehen, sonst verschiebt Ziehen die Ansicht.")
a = app.find('function BlueprintWallObjectConnections(')
b = app.find('type BlueprintWallSegment = {', a)
if a < 0 or b < 0 or app.count('function BlueprintWallObjectConnections(') != 1:
    raise RuntimeError('176: Oeffnungs-Darstellung nicht gefunden')
old_fn = app[a:b]
if "item.objectType === 'door' && item.groupId && !isFullWallOpenGroupId(item.groupId)" not in old_fn:
    raise RuntimeError('176: Oeffnungs-Darstellung unerwartet')
app = app[:a] + (res / 'openings176.tsx.txt').read_text(encoding='utf-8') + app[b:]
F['app'].write_text(app, encoding='utf-8')

# ------------------------------------------------------------------ LevelMenu173.tsx: Masse im Feld, Z=0 als Icon
menu = F['menu'].read_text(encoding='utf-8')
menu = edit(menu, 'Menue: Import', "import { useState, type ReactNode } from 'react'\n",
  "import { useEffect, useRef, useState, type ReactNode } from 'react'\n")
menu = edit(menu, 'Menue: Eingabefeld',
  "const mm173 = (m: number) => Math.round(m * 1000)\n",
  "const mm173 = (m: number) => Math.round(m * 1000)\n\n"
  "/** STROM176_UNIT_INPUT: Laenge mit Einheit lesen (m, dm, cm, mm; Komma oder Punkt). Ergebnis in mm, sonst null. */\n"
  "export function parseLengthMm176(text: string): number | null {\n"
  "  const clean = text.trim().toLowerCase().replace(/\\s+/g, '').replace(',', '.')\n"
  "  const match = /^([+-]?(?:\\d+\\.?\\d*|\\.\\d+))(mm|cm|dm|m)?$/.exec(clean)\n"
  "  if (!match) return null\n"
  "  const factor = { mm: 1, cm: 10, dm: 100, m: 1000 }[(match[2] || 'mm') as 'mm' | 'cm' | 'dm' | 'm']\n"
  "  const value = Number(match[1]) * factor\n"
  "  return Number.isFinite(value) ? Math.round(value) : null\n"
  "}\n\n"
  "/** Zahl im Feld, 'mm' grau dahinter; beim Bearbeiten nur die Zahl. Enter/Verlassen uebernimmt, Escape verwirft. */\n"
  "function MmField176({ valueMm, label, title, onCommit }: { valueMm: number; label: string; title: string; onCommit: (mm: number) => void }) {\n"
  "  const [editing, setEditing] = useState(false)\n"
  "  const [text, setText] = useState(String(valueMm))\n"
  "  const justFocused = useRef(false) // Mausklick soll die Markierung beim Fokussieren nicht aufheben\n"
  "  useEffect(() => { if (!editing) setText(String(valueMm)) }, [valueMm, editing])\n"
  "  const commit = () => {\n"
  "    setEditing(false)\n"
  "    const mm = parseLengthMm176(text)\n"
  "    if (mm === null) { setText(String(valueMm)); return }\n"
  "    setText(String(mm))\n"
  "    if (mm !== valueMm) onCommit(mm)\n"
  "  }\n"
  "  return (\n"
  "    <span className={`mm-field176 ${editing ? 'editing' : ''}`} title={title}>\n"
  "      <input type=\"text\" inputMode=\"decimal\" aria-label={label} value={editing ? text : String(valueMm)}\n"
  "        onMouseDown={(event) => event.stopPropagation()} onClick={(event) => event.stopPropagation()} onDragStart={(event) => event.preventDefault()}\n"
  "        onFocus={(event) => { setEditing(true); setText(String(valueMm)); justFocused.current = true; event.currentTarget.select() }}\n"
  "        onMouseUp={(event) => { if (justFocused.current) { event.preventDefault(); justFocused.current = false } }}\n"
  "        onChange={(event) => setText(event.target.value)}\n"
  "        onBlur={commit}\n"
  "        onKeyDown={(event) => {\n"
  "          if (event.key === 'Enter') event.currentTarget.blur()\n"
  "          if (event.key === 'Escape') { setText(String(valueMm)); setEditing(false); window.setTimeout(() => (event.target as HTMLInputElement).blur(), 0) }\n"
  "        }} />\n"
  "      {!editing && <span className=\"mm-unit176\" aria-hidden=\"true\">mm</span>}\n"
  "    </span>\n"
  "  )\n"
  "}\n")
menu = edit(menu, 'Menue: Z=0 als Icon',
  "                  <label className=\"layer-zero-marker151\" title={levels.length === 1 ? 'Einzige Ebene: automatisch Z=0' : 'Diese Ebene als Z=0 festlegen'}\n"
  "                    onMouseDown={(event) => event.stopPropagation()} onClick={(event) => event.stopPropagation()}>\n"
  "                    <input type=\"radio\" name={radioName}\n"
  "                      aria-label={`${layer.name} als Z=0-Ebene auswählen`}\n"
  "                      checked={zeroId === layer.id}\n"
  "                      disabled={levels.length === 1}\n"
  "                      onChange={() => props.onZero(layer.id)} />\n"
  "                    <span aria-hidden=\"true\">0</span>\n"
  "                  </label>\n",
  "                  {/* STROM176_ZERO_ICON: Nullhoehe als Icon-Knopf, genau einer aktiv (wie ein Radiobutton). */}\n"
  "                  <button type=\"button\" role=\"radio\" data-radio-group={radioName}\n"
  "                    className={`layer-zero-marker151 layer-zero176 ${zeroId === layer.id ? 'active' : ''}`}\n"
  "                    aria-checked={zeroId === layer.id} aria-label={`${layer.name} als Z=0-Ebene auswählen`}\n"
  "                    title={levels.length === 1 ? 'Einzige Ebene: automatisch Nullhöhe (Z = 0)' : zeroId === layer.id ? 'Nullhöhe (Z = 0) liegt auf dieser Ebene' : 'Diese Ebene als Nullhöhe (Z = 0) festlegen'}\n"
  "                    disabled={levels.length === 1 && zeroId === layer.id}\n"
  "                    onMouseDown={(event) => event.stopPropagation()}\n"
  "                    onClick={(event) => { event.stopPropagation(); if (zeroId !== layer.id) props.onZero(layer.id) }}>\n"
  "                    <StromIcon name=\"zero-level\" title=\"Nullhöhe\" />\n"
  "                  </button>\n")
menu = edit(menu, 'Menue: Hoehe',
  "                  <label className=\"layer-height-control\" title=\"Geschosshoehe dieser Ebene in Millimetern\">\n"
  "                    <span>Höhe (mm)</span>\n"
  "                    <input\n"
  "                      key={`${layer.id}-${mm173(layer.heightM)}`}\n"
  "                      aria-label={`Geschosshoehe ${layer.name} in Millimetern`}\n"
  "                      type=\"number\" min=\"100\" max=\"10000\" step=\"10\"\n"
  "                      defaultValue={mm173(layer.heightM)}\n"
  "                      onMouseDown={(event) => event.stopPropagation()}\n"
  "                      onClick={(event) => event.stopPropagation()}\n"
  "                      onDragStart={(event) => event.preventDefault()}\n"
  "                      onBlur={(event) => props.onHeight(layer.id, Number(event.currentTarget.value))}\n"
  "                      onKeyDown={(event) => { if (event.key === 'Enter') event.currentTarget.blur() }}\n"
  "                    />\n"
  "                  </label>\n",
  "                  <label className=\"layer-height-control\">\n"
  "                    <span>Höhe</span>\n"
  "                    <MmField176 valueMm={mm173(layer.heightM)} label={`Geschosshoehe ${layer.name} in Millimetern`}\n"
  "                      title=\"Geschosshöhe; Eingabe z. B. 2600, 2,6 m, 260 cm\" onCommit={(mm) => props.onHeight(layer.id, mm)} />\n"
  "                  </label>\n")
menu = edit(menu, 'Menue: Bodendicke',
  "                  <label className=\"layer-height-control layer-slab-control149\" title=\"Bodendicke der Etage unterhalb des fertigen Fußbodens, in Millimetern\">\n"
  "                    <span>Bodendicke (mm)</span>\n"
  "                    <input\n"
  "                      key={`${layer.id}-slab-${mm173(layer.slabThicknessM)}`}\n"
  "                      aria-label={`Bodendicke ${layer.name} in Millimetern`}\n"
  "                      type=\"number\" min=\"0\" max=\"1500\" step=\"10\"\n"
  "                      defaultValue={mm173(layer.slabThicknessM)}\n"
  "                      onMouseDown={(event) => event.stopPropagation()}\n"
  "                      onClick={(event) => event.stopPropagation()}\n"
  "                      onDragStart={(event) => event.preventDefault()}\n"
  "                      onBlur={(event) => props.onSlab(layer.id, Number(event.currentTarget.value))}\n"
  "                      onKeyDown={(event) => { if (event.key === 'Enter') event.currentTarget.blur() }}\n"
  "                    />\n"
  "                  </label>\n",
  "                  <label className=\"layer-height-control layer-slab-control149\">\n"
  "                    <span>Bodendicke</span>\n"
  "                    <MmField176 valueMm={mm173(layer.slabThicknessM)} label={`Bodendicke ${layer.name} in Millimetern`}\n"
  "                      title=\"Bodendicke unter dem fertigen Fußboden; Eingabe z. B. 200, 20 cm, 0,2 m\" onCommit={(mm) => props.onSlab(layer.id, mm)} />\n"
  "                  </label>\n")
F['menu'].write_text(menu, encoding='utf-8')

# ------------------------------------------------------------------ Icon Nullhoehe
icons = F['icons'].read_text(encoding='utf-8')
icons = edit(icons, 'Icon zero-level', "\n}\n/** Fruehere Namen",
  "\n  \"zero-level\": [\"layer\", \"<path d=\\\"M3 17.5h18\\\"/><path class=\\\"at\\\" d=\\\"M7 8h10l-5 9.5z\\\"/><path class=\\\"a\\\" d=\\\"M7 8h10l-5 9.5z\\\"/>\"],\n}\n/** Fruehere Namen")
F['icons'].write_text(icons, encoding='utf-8')

CSS = """
/* STROM176_OPENINGS: Tueren und Fenster orange wie das Treppensymbol; Fenster als H. */
.blueprint-openings176 .blueprint-door176 polygon.blueprint-wall-connection-door { fill: rgba(180, 83, 9, 0.16); stroke: #b45309; }
.blueprint-openings176 .blueprint-door176 .blueprint-wall-door-edge { stroke: #b45309; }
.blueprint-openings176 .blueprint-window176 polygon.blueprint-window-cut176 { fill: #fffaf3; stroke: none; }
.blueprint-openings176 .blueprint-window176 line.blueprint-window-jamb176 { stroke: #b45309; stroke-width: 3; stroke-linecap: butt; }
.blueprint-openings176 .blueprint-window176 line.blueprint-window-glass176 { stroke: #b45309; stroke-width: 2.2; stroke-linecap: butt; }
.blueprint-openings176 .blueprint-opening-dims176 { fill: #9a3412; font-size: calc(var(--floorplan-small-text-size, 12px) * 0.78); font-weight: 700;
  paint-order: stroke; stroke: rgba(255,255,255,0.95); stroke-width: calc(var(--floorplan-label-stroke, 4px) * 0.7); stroke-linejoin: round; }
/* STROM176_UNIT_INPUT + STROM176_ZERO_ICON: Ebenenfenster */
.level-menu173 .mm-field176 { position: relative; display: block; width: 100%; }
.level-menu173 .layer-row > .layer-height-control .mm-field176 input { padding-right: 26px !important; text-align: right !important; }
.level-menu173 .layer-row > .layer-height-control .mm-field176.editing input { padding-right: 6px !important; }
.level-menu173 .mm-unit176 { position: absolute; right: 6px; top: 50%; transform: translateY(-50%); color: #94a3b8; font-size: 11px; font-weight: 600; pointer-events: none; }
.canvas-layer-menu .layer-row > button.layer-zero176 { grid-area: datum; display: inline-flex; align-items: center; justify-content: center; color: #8b99ad; }
.canvas-layer-menu .layer-row > button.layer-zero176 .strom-icon { opacity: .55; }
.canvas-layer-menu .layer-row > button.layer-zero176.active { background: #2563eb; color: #fff; }
.canvas-layer-menu .layer-row > button.layer-zero176.active .strom-icon { opacity: 1; }
.canvas-layer-menu .layer-row > button.layer-zero176:disabled { opacity: 1; cursor: default; }
"""
css = F['css'].read_text(encoding='utf-8')
F['css'].write_text(css.rstrip('\n') + '\n' + CSS, encoding='utf-8')
print('176: Quelltext gepatcht')
