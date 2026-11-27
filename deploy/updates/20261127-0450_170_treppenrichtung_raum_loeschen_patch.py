#!/usr/bin/env python3
"""Update 170: Treppenrichtung (Abfrage, ausgegraute Gegenrichtung) und Raum loeschen."""
import hashlib, os, pathlib

root = pathlib.Path(os.environ['STROM170_ROOT']) / 'frontend'
F = {'app': root / 'src/App.tsx', 'css': root / 'src/styles.css'}
EXPECTED = {
    'app': '5110b63d00cd31f5672085caabfbadfac21bfc6b9040e02701545605c118af7f',
    'css': '27893b0f9507b79ee999c242e2163b5f8eae85bfe986d5cbad18ccda3f7a6425',
}
for key, path in F.items():
    have = hashlib.sha256(path.read_bytes()).hexdigest()
    if have != EXPECTED[key]:
        raise RuntimeError(f'170: {path.name} entspricht nicht Stand 169 ({have})')

APP_EDITS = [
 # ---------------- Raum loeschen (App) ----------------
 ('Loeschen: Zustand',
  "  const [deleteConfirmRoomId, setDeleteConfirmRoomId] = useState<string>('')\n",
  "  const [deleteConfirmRoomId, setDeleteConfirmRoomId] = useState<string>('')\n"
  "  // STROM170_ROOM_DELETE: Fortschritt und Fehler im Bestaetigungsfenster selbst anzeigen.\n"
  "  const [deleteBusy170, setDeleteBusy170] = useState(false)\n"
  "  const [deleteError170, setDeleteError170] = useState('')\n"),
 ('Loeschen: Anfrage',
  "  function requestDeleteSelectedRoom() {\n    if (!selectedRoomId) return\n    setDeleteConfirmRoomId(selectedRoomId)\n  }\n",
  "  function requestDeleteSelectedRoom() {\n    if (!selectedRoomId) return\n    setDeleteError170('')\n    setDeleteConfirmRoomId(selectedRoomId)\n  }\n\n"
  "  // STROM170_ROOM_DELETE: Tueren, Fenster und Steckdosen des Raums zuerst entfernen.\n"
  "  // Ein Fremdschluessel in wall_objects verhindert sonst das Loeschen von Raeumen mit Wandobjekten.\n"
  "  async function deleteWallObjectsOfRoom170(roomId: string, floorId: string) {\n"
  "    let objects: Awaited<ReturnType<typeof getWallObjects>>\n"
  "    try { objects = await getWallObjects(floorId) }\n"
  "    catch (err) { throw new Error(`Wandobjekte konnten nicht gelesen werden: ${err instanceof Error ? err.message : String(err)}`) }\n"
  "    for (const item of objects.filter((entry) => entry.roomId === roomId)) {\n"
  "      try { await deleteWallObjectFromApi(item.id) }\n"
  "      catch (err) { throw new Error(`Wandobjekt (${item.objectType}) konnte nicht entfernt werden: ${err instanceof Error ? err.message : String(err)}`) }\n"
  "    }\n"
  "  }\n"),
 ('Loeschen: Bestaetigen',
  "  async function confirmDeleteSelectedRoom() {\n"
  "    if (!deleteConfirmRoomId) return\n"
  "    try {\n"
  "      setError(null)\n"
  "      captureUndoSnapshot()\n"
  "      await deleteRoom(deleteConfirmRoomId)\n"
  "      setRooms((current) => current.filter((item) => item.id !== deleteConfirmRoomId))\n"
  "      if (selectedRoomId === deleteConfirmRoomId) setSelectedRoomId('')\n"
  "      setDeleteConfirmRoomId('')\n"
  "      await reload()\n"
  "    } catch (err) {\n"
  "      setError(err instanceof Error ? err.message : String(err))\n"
  "    }\n"
  "  }\n",
  "  async function confirmDeleteSelectedRoom() {\n"
  "    const roomId = deleteConfirmRoomId\n"
  "    const target = rooms.find((item) => item.id === roomId)\n"
  "    if (!roomId || !target || deleteBusy170) return\n"
  "    setDeleteBusy170(true)\n"
  "    setDeleteError170('')\n"
  "    try {\n"
  "      setError(null)\n"
  "      captureUndoSnapshot()\n"
  "      await deleteWallObjectsOfRoom170(roomId, target.floorId)\n"
  "      try { await deleteRoom(roomId) }\n"
  "      catch (err) { throw new Error(`Server hat das Loeschen abgelehnt: ${err instanceof Error ? err.message : String(err)}`) }\n"
  "      setRooms((current) => current.filter((item) => item.id !== roomId))\n"
  "      if (selectedRoomId === roomId) setSelectedRoomId('')\n"
  "      setDeleteConfirmRoomId('')\n"
  "      await reload()\n"
  "    } catch (err) {\n"
  "      const message = err instanceof Error ? err.message : String(err)\n"
  "      setDeleteError170(message)\n"
  "      setError(message)\n"
  "      console.warn('STROM170 Raum loeschen fehlgeschlagen', message)\n"
  "    } finally {\n"
  "      setDeleteBusy170(false)\n"
  "    }\n"
  "  }\n"),
 ('Undo: Raumtyp behalten',
  "          await createRoom({\n            floorId: room.floorId,\n            name: room.name,\n            shapeType: room.shapeType,\n            wallThicknessM: room.wallThicknessM,\n",
  "          await createRoom({\n            floorId: room.floorId,\n            name: room.name,\n            shapeType: room.shapeType,\n            roomType: room.roomType, // STROM170: Treppenraum bleibt nach Rueckgaengig ein Treppenraum\n            wallThicknessM: room.wallThicknessM,\n"),
 ('Loeschen: Fenster',
  "        <ConfirmDeleteModal\n          room={deleteConfirmRoom}\n          onCancel={() => setDeleteConfirmRoomId('')}\n          onConfirm={() => void confirmDeleteSelectedRoom()}\n        />\n",
  "        <ConfirmDeleteModal\n          room={deleteConfirmRoom}\n          busy={deleteBusy170}\n          error={deleteError170}\n"
  "          onCancel={() => { if (!deleteBusy170) { setDeleteConfirmRoomId(''); setDeleteError170('') } }}\n"
  "          onConfirm={() => void confirmDeleteSelectedRoom()}\n        />\n"),
 ('Loeschen: Fenster-Komponente',
  "function ConfirmDeleteModal({ room, onCancel, onConfirm }: { room: Room; onCancel: () => void; onConfirm: () => void }) {\n"
  "  return (\n"
  "    <div className=\"modal-backdrop\" role=\"presentation\" onMouseDown={(event) => { if (event.target === event.currentTarget) onCancel() }}>\n"
  "      <section className=\"confirm-modal\" role=\"dialog\" aria-modal=\"true\" aria-label=\"Raum loeschen bestaetigen\">\n"
  "        <div>\n"
  "          <span className=\"eyebrow\">Loeschen</span>\n"
  "          <h2>Raum loeschen?</h2>\n"
  "          <p>Der Raum <strong>{room.name}</strong> wird aus dem Blueprint entfernt.</p>\n"
  "        </div>\n"
  "        <div className=\"button-row\">\n"
  "          <button type=\"button\" onClick={onCancel}>Abbrechen</button>\n"
  "          <button type=\"button\" className=\"danger\" onClick={onConfirm}>Loeschen</button>\n"
  "        </div>\n",
  "function ConfirmDeleteModal({ room, busy = false, error = '', onCancel, onConfirm }: { room: Room; busy?: boolean; error?: string; onCancel: () => void; onConfirm: () => void }) {\n"
  "  // STROM170_ROOM_DELETE: Enter bestaetigt, Escape bricht ab; Fortschritt und Fehler sichtbar.\n"
  "  const confirmRef170 = useRef<HTMLButtonElement | null>(null)\n"
  "  useEffect(() => { confirmRef170.current?.focus() }, [])\n"
  "  const stair170 = isStairRoom(room)\n"
  "  return (\n"
  "    <div className=\"modal-backdrop\" role=\"presentation\" onMouseDown={(event) => { if (event.target === event.currentTarget) onCancel() }}\n"
  "      onKeyDown={(event) => { if (event.key === 'Escape') { event.preventDefault(); onCancel() } }}>\n"
  "      <section className=\"confirm-modal confirm-modal-delete170\" role=\"dialog\" aria-modal=\"true\" aria-label=\"Raum loeschen bestaetigen\" aria-busy={busy}>\n"
  "        <div>\n"
  "          <span className=\"eyebrow\">Loeschen</span>\n"
  "          <h2>{stair170 ? 'Treppenraum loeschen?' : 'Raum loeschen?'}</h2>\n"
  "          <p>Der {stair170 ? 'Treppenraum' : 'Raum'} <strong>{room.name}</strong> wird mit seinen Tueren, Fenstern und Steckdosen aus dem Blueprint entfernt.</p>\n"
  "          {error && <p className=\"confirm-modal-error170\" role=\"alert\">Loeschen fehlgeschlagen: {error}</p>}\n"
  "        </div>\n"
  "        <div className=\"button-row\">\n"
  "          <button type=\"button\" className=\"confirm-modal-cancel170\" onClick={onCancel} disabled={busy}>Abbrechen</button>\n"
  "          <button type=\"button\" ref={confirmRef170} className=\"danger confirm-modal-confirm170\" onClick={onConfirm} disabled={busy}>{busy ? 'Wird geloescht ...' : error ? 'Erneut versuchen' : 'Loeschen'}</button>\n"
  "        </div>\n"),
 # ---------------- Blueprint: Entf im Treppeneditor, Treppeneditor schliessen ----------------
 ('Entf nicht im Treppeneditor',
  "      if (event.key === 'Delete' && (selectedRoom || allSelected)) {\n",
  "      // STROM170: Im Treppeneditor loescht Entf nicht den ganzen Raum.\n"
  "      if (event.key === 'Delete' && !stairPanelOpen && (selectedRoom || allSelected)) {\n"),
 ('Entf: Abhaengigkeit',
  "  }, [tool, selectedRoom, allSelected, roomDrag, groupDrag, polygonEdgeDrag, vertexDrag, rectHandleDrag, zoom, onDeleteSelectedRoom, onPersistRoom, onCaptureUndoSnapshot])\n",
  "  }, [tool, selectedRoom, allSelected, roomDrag, groupDrag, polygonEdgeDrag, vertexDrag, rectHandleDrag, zoom, onDeleteSelectedRoom, onPersistRoom, onCaptureUndoSnapshot, stairPanelOpen])\n"),
 # ---------------- Treppenrichtung ----------------
 ('Richtung: Hilfswerte',
  "  const selectedStairDirection147 = selectedRoom ? stairDirections147[selectedRoom.id] : undefined\n",
  "  const selectedStairDirection147 = selectedRoom ? stairDirections147[selectedRoom.id] : undefined\n"
  "  // STROM170_STAIR_DIRECTION: Gegenrichtung bleibt ausgegraut, bis sie angelegt ist.\n"
  "  const stairUnassigned170 = selectedRoom ? stairRoomsHere147.find((room) => room.id !== selectedRoom.id && !stairDirections147[room.id]) ?? null : null\n"
  "  const stairMissing170 = (direction: StairDirection147) => Boolean(selectedStairDirection147) && selectedStairDirection147 !== direction\n"
  "    && !(direction === 'up' ? stairUp147 : stairDown147) && !stairUnassigned170\n"
  "  const stairCreating170 = useRef(false)\n"
  "  const [stairCreateBusy170, setStairCreateBusy170] = useState(false)\n"
  "  useEffect(() => {\n"
  "    // Raum geloescht oder abgewaehlt: Treppeneditor schliessen, Auswahlwerkzeug aktiv.\n"
  "    if (!selectedRoom && (stairPanelOpen || tool === 'stair')) { setStairPanelOpen(false); setTool('select') }\n"
  "  }, [selectedRoom, stairPanelOpen, tool])\n"),
 ('Richtung: Auswahl',
  "    const other = direction === 'up' ? stairUp147 : stairDown147\n"
  "    if (other) { onSelectRoom(other.id); return }\n"
  "    const currentDirection = stairDirections147[selectedRoom.id]\n"
  "    const matchingUnassigned = stairRoomsHere147.find((room) => room.id !== selectedRoom.id && !stairDirections147[room.id])\n"
  "    if (currentDirection && currentDirection !== direction && matchingUnassigned) {\n"
  "      storeStairDirections147({ ...stairDirections147, [matchingUnassigned.id]: direction })\n"
  "      onSelectRoom(matchingUnassigned.id)\n"
  "      return\n"
  "    }\n",
  "    // STROM170: vorhandene Richtung anklicken zeigt den zugehoerigen Treppenraum.\n"
  "    const other = direction === 'up' ? stairUp147 : stairDown147\n"
  "    if (other) { onSelectRoom(other.id); return }\n"
  "    const currentDirection = stairDirections147[selectedRoom.id]\n"
  "    const matchingUnassigned = stairRoomsHere147.find((room) => room.id !== selectedRoom.id && !stairDirections147[room.id])\n"
  "    if (currentDirection && currentDirection !== direction && matchingUnassigned) {\n"
  "      storeStairDirections147({ ...stairDirections147, [matchingUnassigned.id]: direction })\n"
  "      onSelectRoom(matchingUnassigned.id)\n"
  "      return\n"
  "    }\n"
  "    // STROM170: noch nicht angelegte Gegenrichtung ist ausgegraut und aendert nichts.\n"
  "    if (currentDirection && currentDirection !== direction) return\n"),
 ('Richtung tauschen',
  "  async function createOtherStair147() {\n",
  "  // STROM170: Fehlgriff korrigieren, solange nur eine Richtung existiert.\n"
  "  function swapStairDirection170() {\n"
  "    if (!selectedRoom || !isStairRoom(selectedRoom) || !selectedStairDirection147 || stairRoomsHere147.length !== 1) return\n"
  "    storeStairDirections147({ ...stairDirections147, [selectedRoom.id]: selectedStairDirection147 === 'up' ? 'down' : 'up' })\n"
  "  }\n\n"
  "  async function createOtherStair147() {\n"),
 ('Gegenrichtung: einmalig',
  "    if (stairRoomsHere147.length > 1 || (stairUp147 && stairDown147)) return\n"
  "    const opposite: StairDirection147 = selectedStairDirection147 === 'up' ? 'down' : 'up'\n"
  "    try {\n",
  "    if (stairRoomsHere147.length > 1 || (stairUp147 && stairDown147)) return\n"
  "    if (stairCreating170.current) return // Doppelklick legt keine zweite Gegenrichtung an\n"
  "    stairCreating170.current = true\n"
  "    setStairCreateBusy170(true)\n"
  "    const opposite: StairDirection147 = selectedStairDirection147 === 'up' ? 'down' : 'up'\n"
  "    try {\n"),
 ('Gegenrichtung: Auswahl bleibt',
  "      setStairPanelOpen(false)\n      await onReload()\n      onSelectRoom(created.id)\n    } catch (err) { onError(err instanceof Error ? err.message : String(err)) }\n  }\n",
  "      setStairPanelOpen(false)\n      await onReload()\n"
  "      // STROM170: Auswahl bleibt; die Gegenrichtung ist jetzt anklickbar.\n"
  "      onSelectRoom(selectedRoom.id)\n"
  "    } catch (err) { onError(err instanceof Error ? err.message : String(err)) }\n"
  "    finally { stairCreating170.current = false; setStairCreateBusy170(false) }\n  }\n"),
 ('Richtung: Fenster',
  "          <div className=\"strom-stair-direction-floating147\" aria-label=\"Treppenraumrichtung\">\n"
  "            <div className=\"strom-stair-direction-title147\">Treppenraum · Richtung</div>\n"
  "            <div className=\"strom-stair-direction-actions147\">\n"
  "              <button type=\"button\" className={selectedStairDirection147 === 'up' ? 'active' : ''}\n"
  "                title=\"Aufwärts: führt von dieser Ebene zur nächsthöheren\"\n"
  "                aria-pressed={selectedStairDirection147 === 'up'}\n"
  "                onClick={() => chooseStairDirection147('up')}><StromIcon name=\"stair-up\" title=\"Aufwärts\" size={18} /> Aufwärts</button>\n"
  "              <button type=\"button\" className={selectedStairDirection147 === 'down' ? 'active' : ''}\n"
  "                title=\"Abwärts: führt von dieser Ebene zur nächsttieferen\"\n"
  "                aria-pressed={selectedStairDirection147 === 'down'}\n"
  "                onClick={() => chooseStairDirection147('down')}><StromIcon name=\"stair-down\" title=\"Abwärts\" size={18} /> Abwärts</button>\n"
  "            </div>\n"
  "            {!selectedStairDirection147 && <small>Richtung für diesen Treppenraum zuerst festlegen</small>}\n"
  "            {selectedStairDirection147 && stairRoomsHere147.length === 1 && (\n"
  "              <button type=\"button\" className=\"strom-stair-create147\" title=\"Zweiten unabhängigen Treppenraum auf derselben Grundfläche erstellen; vorhandene Stufen nicht kopieren\"\n"
  "                onClick={() => void createOtherStair147()}><StromIcon name=\"new-object\" title=\"Gegenrichtung anlegen\" size={18} /> Gegenrichtung anlegen</button>\n"
  "            )}\n"
  "            {stairRoomsHere147.length > 2 && <small>Hinweis: Mehr als zwei überlappende Treppenräume gefunden</small>}\n"
  "            {stairRoomsHere147.length === 2 && <small>Aufwärts: {stairUp147 ? 'vorhanden' : 'offen'} · Abwärts: {stairDown147 ? 'vorhanden' : 'offen'}</small>}\n"
  "          </div>\n",
  "          <div className={`strom-stair-direction-floating147 ${selectedStairDirection147 ? '' : 'strom-stair-ask170'}`} role=\"group\" aria-label=\"Treppenraumrichtung\">\n"
  "            <div className=\"strom-stair-direction-title147\">{selectedStairDirection147 ? `Treppenraum · ${selectedStairDirection147 === 'up' ? 'Aufwärts' : 'Abwärts'}` : 'Neue Treppe · Richtung wählen'}</div>\n"
  "            {!selectedStairDirection147 && <p className=\"strom-stair-question170\">Führt diese Treppe von hier nach oben oder nach unten?</p>}\n"
  "            <div className=\"strom-stair-direction-actions147\">\n"
  "              <button type=\"button\" data-direction170=\"up\" className={`${selectedStairDirection147 === 'up' ? 'active' : ''} ${stairMissing170('up') ? 'strom-stair-missing170' : ''}`.trim()}\n"
  "                title={stairMissing170('up') ? 'Aufwärts ist noch nicht angelegt – über „Gegenrichtung anlegen“ erstellen' : stairUp147 && selectedStairDirection147 !== 'up' ? 'Aufwärts-Treppenraum anzeigen' : 'Aufwärts: führt von dieser Ebene zur nächsthöheren'}\n"
  "                aria-pressed={selectedStairDirection147 === 'up'} disabled={stairMissing170('up')}\n"
  "                onClick={() => chooseStairDirection147('up')}><StromIcon name=\"stair-up\" title=\"Aufwärts\" size={18} /> Aufwärts</button>\n"
  "              <button type=\"button\" data-direction170=\"down\" className={`${selectedStairDirection147 === 'down' ? 'active' : ''} ${stairMissing170('down') ? 'strom-stair-missing170' : ''}`.trim()}\n"
  "                title={stairMissing170('down') ? 'Abwärts ist noch nicht angelegt – über „Gegenrichtung anlegen“ erstellen' : stairDown147 && selectedStairDirection147 !== 'down' ? 'Abwärts-Treppenraum anzeigen' : 'Abwärts: führt von dieser Ebene zur nächsttieferen'}\n"
  "                aria-pressed={selectedStairDirection147 === 'down'} disabled={stairMissing170('down')}\n"
  "                onClick={() => chooseStairDirection147('down')}><StromIcon name=\"stair-down\" title=\"Abwärts\" size={18} /> Abwärts</button>\n"
  "            </div>\n"
  "            {selectedStairDirection147 && stairRoomsHere147.length === 1 && (\n"
  "              <div className=\"strom-stair-create-row170\">\n"
  "                <button type=\"button\" className=\"strom-stair-create147\" disabled={stairCreateBusy170} title=\"Zweiten unabhängigen Treppenraum auf derselben Grundfläche erstellen; vorhandene Stufen nicht kopieren\"\n"
  "                  onClick={() => void createOtherStair147()}><StromIcon name=\"new-object\" title=\"Gegenrichtung anlegen\" size={18} /> {stairCreateBusy170 ? 'Wird angelegt …' : 'Gegenrichtung anlegen'}</button>\n"
  "                <button type=\"button\" className=\"strom-stair-swap170\" title=\"Falsche Richtung gewählt? Richtung dieses Treppenraums umkehren\" onClick={swapStairDirection170}>Richtung ändern</button>\n"
  "              </div>\n"
  "            )}\n"
  "            {stairRoomsHere147.length > 2 && <small>Hinweis: Mehr als zwei überlappende Treppenräume gefunden</small>}\n"
  "            {stairUp147 && stairDown147 && <small>Beide Richtungen angelegt · Richtung anklicken zeigt den Treppenraum</small>}\n"
  "          </div>\n"),
]

CSS = """
/* STROM170_STAIR_DIRECTION: Abfrage nach dem Anlegen, ausgegraute Gegenrichtung. */
.strom-stair-direction-floating147.strom-stair-ask170 { border-color: #2563eb; box-shadow: 0 0 0 3px rgba(37,99,235,.18), 0 7px 25px rgba(30,51,88,.14); }
.strom-stair-question170 { margin: 0; max-width: 260px; font-size: 13px; line-height: 1.35; color: #243955; }
.strom-stair-direction-actions147 button.strom-stair-missing170,
.strom-stair-direction-actions147 button:disabled { background: #f1f3f6; border-color: #dde2e8; color: #9aa5b4; cursor: not-allowed; }
.strom-stair-direction-actions147 button.strom-stair-missing170 .strom-icon { opacity: .45; filter: grayscale(1); }
.strom-stair-create-row170 { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
.strom-stair-create147:disabled { opacity: .6; cursor: progress; }
.strom-stair-swap170 { border: 0; background: none; padding: 2px 0; color: #62738d; font-size: 11px; text-decoration: underline; cursor: pointer; box-shadow: none; }
.strom-stair-swap170:hover { color: #234467; background: none; }
/* STROM170_ROOM_DELETE: Loeschen ist die Hauptaktion, Fehler sichtbar im Fenster. */
.confirm-modal-delete170 .button-row { display: flex; justify-content: flex-end; gap: 8px; }
.confirm-modal-delete170 .confirm-modal-cancel170 { background: #fff; color: #334155; border: 1px solid #cbd5e1; }
.confirm-modal-delete170 .confirm-modal-confirm170 { background: #dc2626; border-color: #dc2626; color: #fff; }
.confirm-modal-delete170 .confirm-modal-confirm170:hover:not(:disabled) { background: #b91c1c; }
.confirm-modal-delete170 button:disabled { opacity: .65; cursor: progress; }
.confirm-modal-delete170 .confirm-modal-error170 { margin: 0 0 .9rem; padding: 8px 10px; border-radius: 10px; background: #fef2f2; border: 1px solid #fecaca; color: #991b1b; font-size: 13px; overflow-wrap: anywhere; }
"""

text = F['app'].read_text(encoding='utf-8')
if 'STROM170_' in text:
    raise RuntimeError('170: App.tsx enthaelt bereits STROM170')
for label, old, new in APP_EDITS:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f'170: Textstelle "{label}" {count}x gefunden (erwartet: 1)')
    text = text.replace(old, new)
F['app'].write_text(text, encoding='utf-8')
css = F['css'].read_text(encoding='utf-8')
F['css'].write_text(css.rstrip('\n') + '\n' + CSS, encoding='utf-8')
print('170: Quelltext gepatcht')
