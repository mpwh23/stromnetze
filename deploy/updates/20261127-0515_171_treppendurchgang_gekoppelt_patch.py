#!/usr/bin/env python3
"""Update 171: Treppendurchgang auswaehlen und als gekoppelten Treppenraum auf der Nachbarebene anlegen."""
import hashlib, os, pathlib

root = pathlib.Path(os.environ['STROM171_ROOT']) / 'frontend'
res = pathlib.Path(os.environ['STROM171_RESOURCES'])
F = {'app': root / 'src/App.tsx', 'css': root / 'src/styles.css'}
EXPECTED = {
    'app': '81c462abda7caa427fa8f9833cf9836a854f39830aa67f2fc4180912b939b38a',
    'css': '181003ca32cba688a38d5b5e3d75ac76a952f68313f5dcc9dee85fb1b8cc232b',
}
for key, path in F.items():
    have = hashlib.sha256(path.read_bytes()).hexdigest()
    if have != EXPECTED[key]:
        raise RuntimeError(f'171: {path.name} entspricht nicht Stand 170 ({have})')
target_module = root / 'src/building/stairFlights171.ts'
if target_module.exists():
    raise RuntimeError('171: stairFlights171.ts existiert bereits')

APP_EDITS = [
 ('Import',
  "import { readStairPairs148, saveStairPairs148, linkStairs148, inferLegacyStairPairs148, linkedStairPortals148, type StairPairs148 } from './building/stairLinks148'\n",
  "import { readStairPairs148, saveStairPairs148, linkStairs148, inferLegacyStairPairs148, linkedStairPortals148, type StairPairs148 } from './building/stairLinks148'\n"
  "import { baseStairName171, readStairFlights171, saveStairFlights171, stairFlightPartner171, stairLayoutOwner171, type StairFlights171 } from './building/stairFlights171'\n"),
 ('Stufen-Schluessel',
  "  return `strom-stair-layout:${roomId}`\n",
  "  // STROM171_STAIR_FLIGHT: gekoppelter Treppenraum liest/schreibt die Stufen des Eigentuemers.\n"
  "  return `strom-stair-layout:${stairLayoutOwner171(roomId)}`\n"),
 ('Kanten-Schluessel',
  "  return `strom-stair-edge-assignments:${roomId}`\n",
  "  return `strom-stair-edge-assignments:${stairLayoutOwner171(roomId)}` // STROM171_STAIR_FLIGHT\n"),
 ('Zustand',
  "  const [stairPairs148, setStairPairs148] = useState<StairPairs148>(() => readStairPairs148(floor.id, window.localStorage))\n",
  "  const [stairPairs148, setStairPairs148] = useState<StairPairs148>(() => readStairPairs148(floor.id, window.localStorage))\n"
  "  // STROM171_STAIR_FLIGHT: Kopplung ueber Ebenen (gekoppelter Raum -> Eigentuemer) und gewaehlter Durchgang.\n"
  "  const [stairFlights171, setStairFlights171] = useState<StairFlights171>(() => readStairFlights171(floor.id, window.localStorage))\n"
  "  const [selectedPortal171, setSelectedPortal171] = useState('')\n"),
 ('Etagenwechsel',
  "    setStairPairs148(readStairPairs148(floor.id, window.localStorage))\n",
  "    setStairPairs148(readStairPairs148(floor.id, window.localStorage))\n"
  "    setStairFlights171(readStairFlights171(floor.id, window.localStorage))\n"
  "    setSelectedPortal171('')\n"),
 ('Kopplung: Hilfswerte und Abgleich',
  "  }, [selectedRoom, stairPanelOpen, tool])\n",
  "  }, [selectedRoom, stairPanelOpen, tool])\n\n"
  "  // STROM171_STAIR_FLIGHT: gekoppelter Treppenraum auf der Nachbarebene.\n"
  "  const stairPartnerId171 = selectedRoom && isStairRoom(selectedRoom) ? stairFlightPartner171(stairFlights171, selectedRoom.id) : null\n"
  "  const stairPartnerRoom171 = stairPartnerId171 ? rooms.find((room) => room.id === stairPartnerId171) ?? null : null\n"
  "  useEffect(() => { if (selectedRoomId) setSelectedPortal171('') }, [selectedRoomId])\n"
  "  useEffect(() => { setSelectedPortal171('') }, [activeLayerId])\n"
  "  const stairSeenRooms171 = useRef<Set<string>>(new Set())\n"
  "  useEffect(() => {\n"
  "    // Geloeschte Raeume aus der Kopplung entfernen; faellt der Eigentuemer weg, behaelt der\n"
  "    // verbleibende Treppenraum die Stufen als eigene Daten.\n"
  "    // Nur Raeume, die schon einmal geladen waren (frisch angelegte erscheinen erst nach dem Neuladen).\n"
  "    if (!rooms.length || rooms.some((room) => room.floorId !== floor.id)) return\n"
  "    const ids = new Set(rooms.map((room) => room.id))\n"
  "    const seen = stairSeenRooms171.current\n"
  "    const gone = (id: string) => seen.has(id) && !ids.has(id)\n"
  "    ids.forEach((id) => seen.add(id))\n"
  "    const next: StairFlights171 = { ...stairFlights171 }\n"
  "    let changed = false\n"
  "    for (const [coupled, owner] of Object.entries(stairFlights171)) {\n"
  "      if (!gone(coupled) && !gone(owner)) continue\n"
  "      changed = true\n"
  "      delete next[coupled]\n"
  "      if (ids.has(coupled) && gone(owner)) {\n"
  "        for (const prefix of ['strom-stair-layout:', 'strom-stair-edge-assignments:']) {\n"
  "          const raw = window.localStorage.getItem(prefix + owner)\n"
  "          if (raw && !window.localStorage.getItem(prefix + coupled)) window.localStorage.setItem(prefix + coupled, raw)\n"
  "        }\n"
  "      }\n"
  "    }\n"
  "    if (!changed) return\n"
  "    try { saveStairFlights171(floor.id, next); setStairFlights171(next) }\n"
  "    catch (err) { onError(`Treppenkopplung konnte nicht gespeichert werden: ${String(err)}`) }\n"
  "  }, [floor.id, rooms, stairFlights171])\n"
  "  const stairSyncPrev171 = useRef<Map<string, string>>(new Map())\n"
  "  useEffect(() => {\n"
  "    // Grundriss gekoppelt: geaenderte Seite gewinnt, sonst der Eigentuemer. Nicht waehrend des Ziehens.\n"
  "    if (roomDrag || groupDrag || polygonEdgeDrag || vertexDrag || rectHandleDrag) return\n"
  "    const sig = (room: Room) => JSON.stringify(room.vertices.map((point) => [round3(point.x), round3(point.y)]))\n"
  "    const byId = new Map(rooms.map((room) => [room.id, room]))\n"
  "    const prev = stairSyncPrev171.current\n"
  "    for (const [coupledId, ownerId] of Object.entries(stairFlights171)) {\n"
  "      const owner = byId.get(ownerId), coupled = byId.get(coupledId)\n"
  "      if (!owner || !coupled) continue\n"
  "      const so = sig(owner), sc = sig(coupled)\n"
  "      if (so === sc) continue\n"
  "      const ownerChanged = prev.has(ownerId) && prev.get(ownerId) !== so\n"
  "      const coupledChanged = prev.has(coupledId) && prev.get(coupledId) !== sc\n"
  "      const source = coupledChanged && !ownerChanged ? coupled : owner\n"
  "      const target = source === owner ? coupled : owner\n"
  "      void onPersistRoom({ ...target, shapeType: source.shapeType, vertices: source.vertices.map((point) => ({ ...point })), areaM2: polygonAreaM2(source.vertices) })\n"
  "    }\n"
  "    stairSyncPrev171.current = new Map(rooms.map((room) => [room.id, sig(room)]))\n"
  "  }, [rooms, stairFlights171, roomDrag, groupDrag, polygonEdgeDrag, vertexDrag, rectHandleDrag])\n"),
 ('Anlegen aus Durchgang',
  "  // STROM170: Fehlgriff korrigieren, solange nur eine Richtung existiert.\n",
  "  // STROM171_STAIR_FLIGHT: Treppendurchgang -> gekoppelter Treppenraum auf dieser Ebene.\n"
  "  async function createCoupledStair171(source: Room) {\n"
  "    if (stairCreating170.current) return\n"
  "    if (Object.entries(stairFlights171).some(([coupled, owner]) => owner === source.id && (roomLayerAssignments[coupled] ?? defaultLayerId) === activeLayerId)) return\n"
  "    stairCreating170.current = true\n"
  "    setStairCreateBusy170(true)\n"
  "    const here: StairDirection147 = stairDirections147[source.id] === 'down' ? 'up' : 'down'\n"
  "    try {\n"
  "      onError(null)\n"
  "      onCaptureUndoSnapshot()\n"
  "      const created = await createRoom({\n"
  "        floorId: floor.id,\n"
  "        name: `${baseStairName171(source.name)} (${here === 'up' ? 'aufwärts' : 'abwärts'})`,\n"
  "        shapeType: source.shapeType,\n"
  "        roomType: 'stair',\n"
  "        wallThicknessM: source.wallThicknessM,\n"
  "        vertices: source.vertices.map((point) => ({ ...point })),\n"
  "      })\n"
  "      setRoomLayerAssignments((current) => ({ ...current, [created.id]: activeLayerId }))\n"
  "      storeStairDirections147({ ...stairDirections147, [created.id]: here })\n"
  "      const nextFlights: StairFlights171 = { ...stairFlights171, [created.id]: source.id }\n"
  "      saveStairFlights171(floor.id, nextFlights)\n"
  "      setStairFlights171(nextFlights)\n"
  "      setSelectedPortal171('')\n"
  "      await onReload()\n"
  "      onSelectRoom(created.id)\n"
  "    } catch (err) { onError(err instanceof Error ? err.message : String(err)) }\n"
  "    finally { stairCreating170.current = false; setStairCreateBusy170(false) }\n"
  "  }\n\n"
  "  // STROM170: Fehlgriff korrigieren, solange nur eine Richtung existiert.\n"),
 ('Name der Gegenrichtung ohne doppelten Zusatz',
  "        name: `${selectedRoom.name} (${opposite === 'up' ? 'aufwärts' : 'abwärts'})`,\n",
  "        name: `${baseStairName171(selectedRoom.name)} (${opposite === 'up' ? 'aufwärts' : 'abwärts'})`, // STROM171\n"),
 ('Richtung tauschen nur ungekoppelt',
  "    if (!selectedRoom || !isStairRoom(selectedRoom) || !selectedStairDirection147 || stairRoomsHere147.length !== 1) return\n",
  "    if (!selectedRoom || !isStairRoom(selectedRoom) || !selectedStairDirection147 || stairRoomsHere147.length !== 1 || stairPartnerId171) return\n"),
 ('Durchgaenge ohne gekoppelte',
  "  const stairPortals148 = linkedStairPortals148(rooms,layers,roomLayerAssignments,stairDirections147,activeLayerId)\n",
  "  const stairPortals148 = linkedStairPortals148(rooms,layers,roomLayerAssignments,stairDirections147,activeLayerId)\n"
  "    .filter(({ room }) => { // STROM171: hier bereits als gekoppelter Treppenraum vorhanden\n"
  "      const partner = stairFlightPartner171(stairFlights171, room.id)\n"
  "      return !partner || !rooms.some((item) => item.id === partner) || (roomLayerAssignments[partner] ?? defaultLayerId) !== activeLayerId\n"
  "    })\n"),
 ('Durchgang anklicken',
  "              <g key={`stair-portal148-${room.id}`} className=\"strom-stair-portal148\"\n"
  "                onClick={event=>{event.stopPropagation();setActiveLayerId(sourceLayerId);onSelectRoom(room.id);setTool('select')}}>\n"
  "                <title>{`Treppenraum ${room.name} aus ${layers.find(l=>l.id===sourceLayerId)?.name||'Nachbarebene'} bearbeiten`}</title>\n",
  "              <g key={`stair-portal148-${room.id}`} className={`strom-stair-portal148 ${selectedPortal171 === room.id ? 'selected' : ''}`} data-portal171={room.id}\n"
  "                onClick={event=>{event.stopPropagation();setSelectedPortal171(room.id);onSelectRoom('');setTool('select')}}>\n"
  "                <title>{`Treppendurchgang aus ${layers.find(l=>l.id===sourceLayerId)?.name||'Nachbarebene'}: anklicken, um hier einen gekoppelten Treppenraum anzulegen`}</title>\n"),
 ('Durchgang: Fenster',
  "        {selectedRoom && isStairRoom(selectedRoom) && (roomLayerAssignments[selectedRoom.id] ?? defaultLayerId) === activeLayerId && (\n",
  "        {/* STROM171_STAIR_FLIGHT: gewaehlter Treppendurchgang */}\n"
  "        {(() => {\n"
  "          const portal171 = stairPortals148.find((item) => item.room.id === selectedPortal171)\n"
  "          if (!portal171 || selectedRoom) return null\n"
  "          const sourceName171 = layers.find((layer) => layer.id === portal171.sourceLayerId)?.name || 'Nachbarebene'\n"
  "          const here171: StairDirection147 = stairDirections147[portal171.room.id] === 'down' ? 'up' : 'down'\n"
  "          return (\n"
  "            <div className=\"strom-stair-direction-floating147 strom-stair-ask170 strom-stair-portal-panel171\" role=\"group\" aria-label=\"Treppendurchgang\">\n"
  "              <div className=\"strom-stair-direction-title147\">Treppendurchgang · aus {sourceName171}</div>\n"
  "              <p className=\"strom-stair-question170\">„{portal171.room.name}“ kommt {here171 === 'down' ? 'von unten' : 'von oben'} hier an. Auf dieser Ebene als {here171 === 'down' ? 'Abwärts' : 'Aufwärts'}-Treppe anlegen? Stufen und Grundriss bleiben mit {sourceName171} gekoppelt.</p>\n"
  "              <div className=\"strom-stair-create-row170\">\n"
  "                <button type=\"button\" className=\"strom-stair-create147\" disabled={stairCreateBusy170} onClick={() => void createCoupledStair171(portal171.room)}>\n"
  "                  <StromIcon name={here171 === 'down' ? 'stair-down' : 'stair-up'} size={18} /> {stairCreateBusy170 ? 'Wird angelegt …' : `Treppe hier anlegen (${here171 === 'down' ? 'abwärts' : 'aufwärts'})`}</button>\n"
  "                <button type=\"button\" className=\"strom-stair-swap170\" onClick={() => { setSelectedPortal171(''); setActiveLayerId(portal171.sourceLayerId); onSelectRoom(portal171.room.id) }}>Zur Treppe in {sourceName171}</button>\n"
  "              </div>\n"
  "            </div>\n"
  "          )\n"
  "        })()}\n"
  "        {selectedRoom && isStairRoom(selectedRoom) && (roomLayerAssignments[selectedRoom.id] ?? defaultLayerId) === activeLayerId && (\n"),
 ('Richtungsfenster: Kopplung anzeigen',
  "            {selectedStairDirection147 && stairRoomsHere147.length === 1 && (\n"
  "              <div className=\"strom-stair-create-row170\">\n",
  "            {stairPartnerRoom171 && (\n"
  "              <button type=\"button\" className=\"strom-stair-link171\" title=\"Gekoppelten Treppenraum auf der Nachbarebene anzeigen\"\n"
  "                onClick={() => { setActiveLayerId(roomLayerAssignments[stairPartnerRoom171.id] ?? defaultLayerId); onSelectRoom(stairPartnerRoom171.id) }}>\n"
  "                <StromIcon name=\"snap-layers\" size={16} />\n"
  "                <span>Gekoppelt mit „{stairPartnerRoom171.name}“ · {layers.find((layer) => layer.id === (roomLayerAssignments[stairPartnerRoom171.id] ?? defaultLayerId))?.name || 'Nachbarebene'}<small>Stufen und Grundriss gemeinsam</small></span>\n"
  "              </button>\n"
  "            )}\n"
  "            {selectedStairDirection147 && stairRoomsHere147.length === 1 && (\n"
  "              <div className=\"strom-stair-create-row170\">\n"),
 ('Richtung aendern nur ungekoppelt',
  "                <button type=\"button\" className=\"strom-stair-swap170\" title=\"Falsche Richtung gewählt? Richtung dieses Treppenraums umkehren\" onClick={swapStairDirection170}>Richtung ändern</button>\n",
  "                {!stairPartnerId171 && <button type=\"button\" className=\"strom-stair-swap170\" title=\"Falsche Richtung gewählt? Richtung dieses Treppenraums umkehren\" onClick={swapStairDirection170}>Richtung ändern</button>}\n"),
 ('Klick ins Leere hebt Durchgang auf',
  "    ;(event.currentTarget as unknown as HTMLElement).focus({ preventScroll: true })\n"
  "    if (tool !== 'select' || event.button !== 0) return\n",
  "    ;(event.currentTarget as unknown as HTMLElement).focus({ preventScroll: true })\n"
  "    if (!(event.target as Element).closest?.('.strom-stair-portal148')) setSelectedPortal171('') // STROM171\n"
  "    if (tool !== 'select' || event.button !== 0) return\n"),
]

CSS = """
/* STROM171_STAIR_FLIGHT: Treppendurchgang auswaehlen, Kopplung ueber Ebenen. */
.strom-stair-portal148:hover polygon { fill:rgba(57,128,214,.2); }
.strom-stair-portal148.selected polygon { fill:rgba(37,99,235,.22); stroke:#2563eb; stroke-width:4; stroke-dasharray:none; }
.strom-stair-portal-panel171 .strom-stair-question170 { max-width: 300px; }
.strom-stair-link171 { display:flex; align-items:flex-start; gap:7px; text-align:left; border:1px solid #d8ccf5; border-radius:8px;
  background:#f6f2ff; color:#4c2a92; padding:7px 10px; font-weight:650; font-size:12px; cursor:pointer; }
.strom-stair-link171 .strom-icon { flex:0 0 auto; margin-top:1px; }
.strom-stair-link171 span { display:flex; flex-direction:column; gap:2px; }
.strom-stair-link171 small { color:#6b5a95; font-weight:500; font-size:11px; }
.strom-stair-link171:hover { background:#ede5ff; }
"""

text = F['app'].read_text(encoding='utf-8')
if 'STROM171_' in text:
    raise RuntimeError('171: App.tsx enthaelt bereits STROM171')
for label, old, new in APP_EDITS:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f'171: Textstelle "{label}" {count}x gefunden (erwartet: 1)')
    text = text.replace(old, new)
F['app'].write_text(text, encoding='utf-8')
css = F['css'].read_text(encoding='utf-8')
F['css'].write_text(css.rstrip('\n') + '\n' + CSS, encoding='utf-8')
target_module.write_text((res / 'stairFlights171.ts').read_text(encoding='utf-8'), encoding='utf-8')
print('171: Quelltext gepatcht')
