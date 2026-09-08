import { type CSSProperties, ChangeEvent as ReactChangeEvent, DragEvent as ReactDragEvent, MouseEvent as ReactMouseEvent, WheelEvent as ReactWheelEvent, useEffect, useMemo, useRef, useState } from 'react'
import {
  createObject,
  createRoom,
  changeAdminPassword,
  createUser,
  deleteAdminUser,
  deleteObject,
  deleteOpening,
  deleteRoom,
  deleteWallObject as deleteWallObjectFromApi,
  findUserByName,
  getAdminSettings,
  getAdminUsers,
  getDefaultFloor,
  getObjects,
  getOpenings,
  getOverview,
  getRooms,
  getWallObjects,
  getPublicSettings,
  getUsers,
  loginUser,
  updateAdminSettings,
  updateAdminUser,
  updateRoom,
  createWallObject,
  updateWallObject as updateWallObjectApi,
} from './api'
import type { AdminSettingsUpdate, AdminUserUpdate, AppSettings, AppUser, Floor, Opening, Overview, PointM, Room, UserObject, ViewMode, WallObject as ApiWallObject } from './types'

const viewModes: { id: ViewMode; label: string }[] = [
  { id: 'floorplan', label: 'Blueprint' },
  { id: 'wall', label: 'Wanddetail' },
  { id: 'board', label: 'Verteiler' },
  { id: 'threeD', label: '3D Haus' },
]

type Tool = 'select' | 'rectangle' | 'outerwall' | 'polygon' | 'recess' | 'distance' | 'stair'
type DragAxis = 'x' | 'y' | null
type RectHandle = 'left' | 'right' | 'top' | 'bottom'
type RecessEdge = 'top' | 'right' | 'bottom' | 'left'
type SidebarMode = 'normal' | 'compact' | 'rail'
type WallViewTool = 'pan' | 'rotate'

type RectInput = {
  name: string
  wallThicknessM: number
}

type RectDraft = {
  start: PointM
  end: PointM
}

type RecessDraft = {
  start: PointM
  end: PointM
  manualAlongM?: number
  manualDepthM?: number
  manualOffsetM?: number
  manualOffsetFromEnd?: boolean
  edge?: RecessEdge
  phase?: 'idle' | 'drawing' | 'ready'
}

type RecessHandle = 'left' | 'right' | 'top' | 'bottom'
type DimensionLineKey = 'xParts' | 'xTotal' | 'yParts' | 'yTotal'
type DimensionDragAxis = 'horizontal' | 'vertical'
type DimensionOffset = { xParts: number; xTotal: number; yParts: number; yTotal: number }
type TitleOffset = { x: number; y: number }

type RecessHandleDrag = {
  handle: RecessHandle
  originalDraft: RecessDraft
}

type RoomDrag = {
  roomId: string
  start: PointM
  originalVertices: PointM[]
}

type RectHandleDrag = {
  roomId: string
  handle: RectHandle
  originalVertices: PointM[]
}

type VertexDrag = {
  roomId: string
  index: number
}

type PolygonEdgeDrag = {
  roomId: string
  indexA: number
  indexB: number
  start: PointM
  originalVertices: PointM[]
}

type GroupRoomDrag = {
  start: PointM
  originals: { room: Room; vertices: PointM[] }[]
}

type DistanceEdgeAxis = 'vertical' | 'horizontal'
type DistanceEdgeSelection = {
  roomId: string
  edgeIndex: number
  axis: DistanceEdgeAxis
  coord: number
  min: number
  max: number
}
type DistancePair = {
  first: DistanceEdgeSelection
  second: DistanceEdgeSelection
  distanceM: number
}

type FloorplanLayer = { id: string; name: string; visible: boolean }
type LayerVisibilityMode = 'active' | 'adjacentGhostNoDims' | 'adjacentGhostDims' | 'allGhostNoDims'

const defaultLayerId = 'layer-main'

function defaultFloorplanLayers(): FloorplanLayer[] {
  return [{ id: defaultLayerId, name: 'Ebene 1', visible: true }]
}

function layerStorageKey(floorId: string, suffix: string) {
  return `strom.floorplan.layers.${floorId}.${suffix}`
}

function titleOffsetStorageKey(floorId: string) {
  return `strom.floorplan.titleOffsets.${floorId}`
}

function viewportStorageKey(floorId: string) {
  return `strom.floorplan.viewport.${floorId}`
}

function wallRotationStorageKey(floorId: string) {
  return `strom.wall.rotation.${floorId}`
}

function wallHeightStorageKey(floorId: string) {
  return `strom.wall.height.${floorId}`
}

type CanvasViewportState = { zoom: number; left: number; top: number }

function loadCanvasViewport(floorId: string): CanvasViewportState {
  const stored = safeReadJson<Partial<CanvasViewportState>>(viewportStorageKey(floorId), {})
  const zoom = Number(stored?.zoom)
  const left = Number(stored?.left)
  const top = Number(stored?.top)
  return {
    zoom: Number.isFinite(zoom) ? clamp(round2(zoom), 0.22, 2.5) : 1,
    left: Number.isFinite(left) ? Math.max(0, left) : 0,
    top: Number.isFinite(top) ? Math.max(0, top) : 0,
  }
}

function saveCanvasViewport(floorId: string, state: CanvasViewportState) {
  try {
    localStorage.setItem(viewportStorageKey(floorId), JSON.stringify({
      zoom: clamp(round2(state.zoom), 0.22, 2.5),
      left: Math.max(0, Math.round(state.left)),
      top: Math.max(0, Math.round(state.top)),
    }))
  } catch {
    // localStorage kann in privaten Browserkontexten blockiert sein.
  }
}

function loadWallCanvasRotation(floorId: string) {
  const stored = Number(safeReadJson<number | string | null>(wallRotationStorageKey(floorId), 0))
  return Number.isFinite(stored) ? normalizeDegrees(stored) : 0
}

function saveWallCanvasRotation(floorId: string, rotationDeg: number) {
  try {
    localStorage.setItem(wallRotationStorageKey(floorId), JSON.stringify(normalizeDegrees(rotationDeg)))
  } catch {
    // localStorage kann in privaten Browserkontexten blockiert sein.
  }
}

function loadWallHeightM(floorId: string, fallbackHeightM: number) {
  const stored = Number(safeReadJson<number | string | null>(wallHeightStorageKey(floorId), fallbackHeightM))
  const fallback = Number.isFinite(fallbackHeightM) ? fallbackHeightM : 2.5
  return Number.isFinite(stored) ? clamp(round2(stored), 0.1, 10) : clamp(round2(fallback), 0.1, 10)
}

function saveWallHeightM(floorId: string, heightM: number) {
  try {
    localStorage.setItem(wallHeightStorageKey(floorId), JSON.stringify(clamp(round2(heightM), 0.1, 10)))
  } catch {
    // localStorage kann in privaten Browserkontexten blockiert sein.
  }
}

function normalizeDegrees(value: number) {
  if (!Number.isFinite(value)) return 0
  const normalized = ((value % 360) + 360) % 360
  return normalized > 180 ? round2(normalized - 360) : round2(normalized)
}

function safeReadJson<T>(key: string, fallback: T): T {
  try {
    const raw = localStorage.getItem(key)
    if (!raw) return fallback
    return JSON.parse(raw) as T
  } catch {
    return fallback
  }
}

function normalizeLayers(input: unknown): FloorplanLayer[] {
  if (!Array.isArray(input)) return defaultFloorplanLayers()
  const layers = input
    .filter((item): item is Partial<FloorplanLayer> => Boolean(item && typeof item === 'object'))
    .map((item, index) => ({
      id: typeof item.id === 'string' && item.id ? item.id : `layer-${Date.now()}-${index}`,
      name: typeof item.name === 'string' && item.name.trim() ? item.name.trim() : `Ebene ${index + 1}`,
      visible: item.visible !== false,
    }))
  return layers.length > 0 ? layers : defaultFloorplanLayers()
}

function loadFloorplanLayers(floorId: string): FloorplanLayer[] {
  return normalizeLayers(safeReadJson(layerStorageKey(floorId, 'list'), defaultFloorplanLayers()))
}

function loadActiveLayerId(floorId: string, layers: FloorplanLayer[]): string {
  const stored = safeReadJson<string | null>(layerStorageKey(floorId, 'active'), null)
  return layers.some((layer) => layer.id === stored) ? String(stored) : layers[0]?.id ?? defaultLayerId
}

function loadLayerAssignments(floorId: string): Record<string, string> {
  const raw = safeReadJson<Record<string, string>>(layerStorageKey(floorId, 'roomAssignments'), {})
  if (!raw || typeof raw !== 'object') return {}
  return Object.fromEntries(Object.entries(raw).filter(([, value]) => typeof value === 'string'))
}

function normalizeTitleOffset(input?: Partial<TitleOffset> | null): TitleOffset {
  const x = Number(input?.x)
  const y = Number(input?.y)
  return {
    x: Number.isFinite(x) ? x : 0,
    y: Number.isFinite(y) ? y : 0,
  }
}

function loadTitleOffsets(floorId: string): Record<string, TitleOffset> {
  const value = safeReadJson<Record<string, Partial<TitleOffset>>>(titleOffsetStorageKey(floorId), {})
  if (!value || typeof value !== 'object') return {}
  const next: Record<string, TitleOffset> = {}
  Object.entries(value).forEach(([id, offset]) => {
    if (!id) return
    next[id] = normalizeTitleOffset(offset)
  })
  return next
}

function visibilityModeLabel(mode: LayerVisibilityMode) {
  if (mode === 'active') return 'Nur aktuelle Ebene'
  if (mode === 'adjacentGhostNoDims') return 'Nachbarebenen ohne Bemaszung'
  if (mode === 'adjacentGhostDims') return 'Nachbarebenen mit Bemaszung'
  return 'Alle Ebenen ohne Bemaszung'
}

function visibilityModeIcon(mode: LayerVisibilityMode) {
  if (mode === 'active') return '①'
  if (mode === 'adjacentGhostNoDims') return '◐'
  if (mode === 'adjacentGhostDims') return '◑'
  return '◎'
}


type Bounds = { minX: number; maxX: number; minY: number; maxY: number }
type RectM = Bounds & { width: number; height: number }
type RecessPreview = { rect: RectM; edge: RecessEdge; vertices: PointM[]; offsetFromEnd: boolean }

const workspaceMinM = -10
const workspaceMaxM = 50
const canvas = {
  width: 3740,
  height: 3740,
  margin: 70,
  scale: 60,
  minM: workspaceMinM,
  maxM: workspaceMaxM,
}

const storageKeys = {
  userId: 'strom.selectedUserId',
  objectId: 'strom.selectedObjectId',
}

const outerWallNamePrefix = '__strom_outer_wall__'

function isOuterWallRoom(room: Pick<Room, 'name'> | null | undefined) {
  return Boolean(room?.name?.startsWith(outerWallNamePrefix))
}

function isStairRoom(room: (Pick<Room, 'roomType'> & { room_type?: string }) | null | undefined) {
  return (room?.roomType ?? room?.room_type) === 'stair'
}

function outerWallName() {
  return `${outerWallNamePrefix}Aussenwand`
}

function cloneRoomsSnapshot(rooms: Room[]): Room[] {
  return rooms.map((room) => ({
    ...room,
    vertices: room.vertices.map((point) => ({ ...point })),
  }))
}

function roomSnapshotsEqual(a: Room[] | undefined, b: Room[]) {
  if (!a || a.length !== b.length) return false
  const normalize = (list: Room[]) => cloneRoomsSnapshot(list).sort((left, right) => left.id.localeCompare(right.id))
  return JSON.stringify(normalize(a)) === JSON.stringify(normalize(b))
}

export function App() {
  const [viewMode, setViewMode] = useState<ViewMode>('floorplan')
  const [users, setUsers] = useState<AppUser[]>([])
  const [objects, setObjects] = useState<UserObject[]>([])
  const [selectedUser, setSelectedUser] = useState<AppUser | null>(null)
  const [selectedObject, setSelectedObject] = useState<UserObject | null>(null)
  const [adminPanelOpen, setAdminPanelOpen] = useState(false)
  const [adminPassword, setAdminPassword] = useState('')
  const [adminUsers, setAdminUsers] = useState<AppUser[]>([])
  const [adminSettings, setAdminSettings] = useState<AppSettings | null>(null)
  const [deleteObjectConfirmOpen, setDeleteObjectConfirmOpen] = useState(false)
  const [overview, setOverview] = useState<Overview | null>(null)
  const [floor, setFloor] = useState<Floor | null>(null)
  const [rooms, setRooms] = useState<Room[]>([])
  const [openings, setOpenings] = useState<Opening[]>([])
  const [selectedRoomId, setSelectedRoomId] = useState<string>('')
  const [deleteConfirmRoomId, setDeleteConfirmRoomId] = useState<string>('')
  const [error, setError] = useState<string | null>(null)
  const [booting, setBooting] = useState(true)
  const [sidebarMode, setSidebarMode] = useState<SidebarMode>('normal')
  const [undoStack, setUndoStack] = useState<Room[][]>([])
  const livePersistTimers = useRef<Record<string, number>>({})
  const liveUndoTimers = useRef<Record<string, number>>({})
  const liveUndoCaptured = useRef<Record<string, boolean>>({})
  const roomsRef = useRef<Room[]>([])

  useEffect(() => {
    roomsRef.current = rooms
  }, [rooms])

  function captureUndoSnapshot(sourceRooms: Room[] = roomsRef.current) {
    const snapshot = cloneRoomsSnapshot(sourceRooms)
    setUndoStack((current) => {
      if (roomSnapshotsEqual(current[0], snapshot)) return current
      return [snapshot, ...current].slice(0, 25)
    })
  }

  function captureLiveUndoSnapshot(roomId: string) {
    if (!liveUndoCaptured.current[roomId]) {
      captureUndoSnapshot()
      liveUndoCaptured.current[roomId] = true
    }
    window.clearTimeout(liveUndoTimers.current[roomId])
    liveUndoTimers.current[roomId] = window.setTimeout(() => {
      delete liveUndoCaptured.current[roomId]
      delete liveUndoTimers.current[roomId]
    }, 900)
  }

  function clearPendingRoomTimers() {
    Object.values(livePersistTimers.current).forEach((timer) => window.clearTimeout(timer))
    Object.values(liveUndoTimers.current).forEach((timer) => window.clearTimeout(timer))
    livePersistTimers.current = {}
    liveUndoTimers.current = {}
    liveUndoCaptured.current = {}
  }

  async function undoLastAction() {
    const snapshot = undoStack[0]
    if (!snapshot) return
    clearPendingRoomTimers()
    setUndoStack((current) => current.slice(1))
    try {
      setError(null)
      const currentRooms = cloneRoomsSnapshot(roomsRef.current)
      const targetById = new Map(snapshot.map((room) => [room.id, room]))
      const currentById = new Map(currentRooms.map((room) => [room.id, room]))

      for (const room of currentRooms) {
        if (!targetById.has(room.id)) await deleteRoom(room.id)
      }
      for (const room of snapshot) {
        if (currentById.has(room.id)) {
          await updateRoom(room.id, roomToPayload(room))
        } else {
          await createRoom({
            floorId: room.floorId,
            name: room.name,
            shapeType: room.shapeType,
            wallThicknessM: room.wallThicknessM,
            vertices: room.vertices,
          })
        }
      }
      setSelectedRoomId('')
      await reload()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
      await reload()
    }
  }

  async function loadUsersAndStoredSession() {
    try {
      setError(null)
      const [nextUsers, nextSettings] = await Promise.all([getUsers(), getPublicSettings()])
      setUsers(nextUsers)
      setAdminSettings(nextSettings)
      setSelectedUser(null)
      setSelectedObject(null)
      setObjects([])
      localStorage.removeItem(storageKeys.userId)
      if (nextSettings.debugMode && nextSettings.debugUserName.trim()) {
        try {
          const debugUser = await findUserByName(nextSettings.debugUserName.trim())
          if (viewModes.some((mode) => mode.id === nextSettings.debugViewMode)) setViewMode(nextSettings.debugViewMode)
          await activateUser(debugUser)
        } catch (debugErr) {
          setError(debugErr instanceof Error ? debugErr.message : String(debugErr))
        }
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBooting(false)
    }
  }

  async function loadObjectsForUser(user: AppUser) {
    const nextObjects = await getObjects(user.id)
    setObjects(nextObjects)
    setSelectedObject((current) => nextObjects.find((object) => object.id === current?.id) ?? null)
  }

  async function reload() {
    if (!selectedObject) {
      setOverview(null)
      setFloor(null)
      setRooms([])
      setOpenings([])
      setSelectedRoomId('')
      setUndoStack([])
      clearPendingRoomTimers()
      return
    }
    try {
      setError(null)
      const [nextOverview, nextFloor] = await Promise.all([
        getOverview(selectedObject.id),
        getDefaultFloor(selectedObject.id),
      ])
      const [nextRooms, nextOpenings] = await Promise.all([
        getRooms(nextFloor.id),
        getOpenings(nextFloor.id),
      ])
      setOverview(nextOverview)
      setFloor(nextFloor)
      setRooms(nextRooms)
      setOpenings(nextOpenings)
      setSelectedRoomId((current) => nextRooms.some((room) => room.id === current) ? current : '')
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    }
  }

  useEffect(() => { void loadUsersAndStoredSession() }, [])
  useEffect(() => { void reload() }, [selectedObject?.id])

  async function activateUser(authenticated: AppUser) {
    localStorage.setItem(storageKeys.userId, authenticated.id)
    setSelectedUser(authenticated)
    setSelectedObject(null)
    setSelectedRoomId('')
    const nextObjects = await getObjects(authenticated.id)
    setObjects(nextObjects)
    const storedObjectId = localStorage.getItem(storageKeys.objectId) ?? ''
    const storedObject = nextObjects.find((object) => object.id === storedObjectId) ?? nextObjects[0] ?? null
    if (storedObject) {
      localStorage.setItem(storageKeys.objectId, storedObject.id)
      setSelectedObject(storedObject)
    }
  }

  async function beginUser(user: AppUser, password: string) {
    const authenticated = await loginUser(user.id, password)
    await activateUser(authenticated)
  }

  async function beginUserByName(name: string) {
    return await findUserByName(name)
  }

  async function selectObject(object: UserObject) {
    localStorage.setItem(storageKeys.objectId, object.id)
    setSelectedObject(object)
    setSelectedRoomId('')
    setUndoStack([])
    clearPendingRoomTimers()
  }

  async function createObjectForSelectedUser(name: string) {
    if (!selectedUser) return
    const object = await createObject(selectedUser.id, name)
    const nextObjects = await getObjects(selectedUser.id)
    setObjects(nextObjects)
    await selectObject(nextObjects.find((item) => item.id === object.id) ?? object)
  }

  async function deleteSelectedObject() {
    if (!selectedUser || !selectedObject) return
    try {
      setError(null)
      await deleteObject(selectedObject.id, selectedUser.id)
      const nextObjects = await getObjects(selectedUser.id)
      setObjects(nextObjects)
      const nextSelected = nextObjects[0] ?? null
      setSelectedObject(nextSelected)
      setSelectedRoomId('')
      setDeleteObjectConfirmOpen(false)
      if (nextSelected) localStorage.setItem(storageKeys.objectId, nextSelected.id)
      else {
        localStorage.removeItem(storageKeys.objectId)
        setOverview(null)
        setFloor(null)
        setRooms([])
        setOpenings([])
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    }
  }

  async function openAdminPanel(password: string) {
    const [nextAdminUsers, nextSettings] = await Promise.all([getAdminUsers(password), getAdminSettings(password)])
    setAdminPassword(password)
    setAdminUsers(nextAdminUsers)
    setAdminSettings(nextSettings)
    setAdminPanelOpen(true)
  }

  async function updateAdminUserSetting(userId: string, payload: AdminUserUpdate) {
    const updated = await updateAdminUser(userId, adminPassword, payload)
    setAdminUsers((current) => current.map((user) => user.id === updated.id ? updated : user))
    setUsers(await getUsers())
  }

  async function deleteAdminUserSetting(userId: string) {
    await deleteAdminUser(userId, adminPassword)
    setAdminUsers(await getAdminUsers(adminPassword))
    setUsers(await getUsers())
  }

  async function updateAdminAppSettings(payload: AdminSettingsUpdate) {
    const updated = await updateAdminSettings(adminPassword, payload)
    setAdminSettings(updated)
    setUsers(await getUsers())
  }

  async function changeAdminPass(newPassword: string) {
    await changeAdminPassword(adminPassword, newPassword)
    setAdminPassword(newPassword)
  }

  function closeAdminPanel() {
    setAdminPanelOpen(false)
    setAdminPassword('')
    setAdminUsers([])
  }

  function switchUser() {
    localStorage.removeItem(storageKeys.userId)
    localStorage.removeItem(storageKeys.objectId)
    setSelectedUser(null)
    setSelectedObject(null)
    setObjects([])
    setOverview(null)
    setFloor(null)
    setRooms([])
    setOpenings([])
    setSelectedRoomId('')
    setUndoStack([])
    clearPendingRoomTimers()
    setError(null)
  }

  function updateRoomInState(nextRoom: Room) {
    setRooms((current) => current.map((room) => room.id === nextRoom.id ? nextRoom : room))
  }

  async function persistRoomNow(nextRoom: Room) {
    updateRoomInState(nextRoom)
    try {
      setError(null)
      const saved = await updateRoom(nextRoom.id, roomToPayload(nextRoom))
      updateRoomInState({ ...saved, roomType: nextRoom.roomType ?? saved.roomType ?? 'room' })
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
      await reload()
    }
  }

  function updateRoomLive(nextRoom: Room) {
    captureLiveUndoSnapshot(nextRoom.id)
    updateRoomInState(nextRoom)
    window.clearTimeout(livePersistTimers.current[nextRoom.id])
    livePersistTimers.current[nextRoom.id] = window.setTimeout(() => {
      void updateRoom(nextRoom.id, roomToPayload(nextRoom)).catch((err) => {
        setError(err instanceof Error ? err.message : String(err))
        void reload()
      })
    }, 260)
  }

  function requestDeleteSelectedRoom() {
    if (!selectedRoomId) return
    setDeleteConfirmRoomId(selectedRoomId)
  }

  async function confirmDeleteSelectedRoom() {
    if (!deleteConfirmRoomId) return
    try {
      setError(null)
      captureUndoSnapshot()
      await deleteRoom(deleteConfirmRoomId)
      setRooms((current) => current.filter((item) => item.id !== deleteConfirmRoomId))
      if (selectedRoomId === deleteConfirmRoomId) setSelectedRoomId('')
      setDeleteConfirmRoomId('')
      await reload()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    }
  }

  const selectedTitle = useMemo(() => {
    if (!selectedObject) return 'Objekt auswaehlen'
    return viewModes.find((v) => v.id === viewMode)?.label ?? ''
  }, [viewMode, selectedObject])
  const selectedRoom = rooms.find((room) => room.id === selectedRoomId) ?? null
  const deleteConfirmRoom = rooms.find((room) => room.id === deleteConfirmRoomId) ?? null
  const blueprintRoomCount = rooms.filter((room) => !isOuterWallRoom(room) && !isStairRoom(room)).length
  const hasWallDetailAccess = Boolean(selectedObject && floor && blueprintRoomCount > 0)

  useEffect(() => {
    if (viewMode === 'wall' && selectedObject && floor && blueprintRoomCount === 0) {
      setViewMode('floorplan')
    }
  }, [viewMode, selectedObject, floor, blueprintRoomCount])

  function canUseViewMode(mode: ViewMode) {
    if (!selectedObject) return false
    if (mode === 'wall') return hasWallDetailAccess
    return true
  }

  function handleViewModeClick(mode: ViewMode) {
    if (!canUseViewMode(mode)) return
    if (viewMode === 'wall' && mode === 'floorplan' && floor) {
      const storedViewport = loadCanvasViewport(floor.id)
      saveCanvasViewport(floor.id, {
        ...storedViewport,
        zoom: Math.min(2.5, Math.max(0.22, round2(storedViewport.zoom * 1.1))),
      })
    }
    setViewMode(mode)
  }

  if (booting) {
    return <div className="session-shell"><div className="session-card"><h1>strom</h1><p>Lade Nutzerauswahl...</p></div></div>
  }

  if (!selectedUser) {
    if (adminPanelOpen) {
      return (
        <AdminPanel
          users={adminUsers}
          error={error}
          onError={setError}
          onClose={closeAdminPanel}
          settings={adminSettings}
          onUpdateUser={updateAdminUserSetting}
          onDeleteUser={deleteAdminUserSetting}
          onUpdateSettings={updateAdminAppSettings}
          onChangeAdminPassword={changeAdminPass}
        />
      )
    }
    return (
      <SessionStart
        users={users}
        error={error}
        onError={setError}
        acceptNewUser={adminSettings?.acceptNewUser ?? true}
        onSelectUser={beginUser}
        onLoginByName={beginUserByName}
        onCreateUser={async (name, password) => {
          const user = await createUser(name, password)
          const nextUsers = await getUsers()
          setUsers(nextUsers)
          await beginUser(user, password)
        }}
        onOpenAdminPanel={openAdminPanel}
      />
    )
  }

  return (
    <div className={`app-shell sidebar-${sidebarMode}`}>
      <aside className={`sidebar sidebar-${sidebarMode}`}>
        <div className="sidebar-collapse-controls" aria-label="Seitenleiste einklappen">
          {sidebarMode === 'normal' && <button title="Seitenleiste kompakt" aria-label="Seitenleiste kompakt" onClick={() => setSidebarMode('compact')}>›</button>}
          {sidebarMode === 'compact' && <>
            <button title="Seitenleiste ausklappen" aria-label="Seitenleiste ausklappen" onClick={() => setSidebarMode('normal')}>›</button>
            <button title="Seitenleiste minimieren" aria-label="Seitenleiste minimieren" onClick={() => setSidebarMode('rail')}>‹</button>
          </>}
          {sidebarMode === 'rail' && <button title="Seitenleiste kompakt anzeigen" aria-label="Seitenleiste kompakt anzeigen" onClick={() => setSidebarMode('compact')}>›</button>}
        </div>

        {sidebarMode === 'normal' && <>
          <h1>strom</h1>
          <p>Haus-Stromnetz dokumentieren, anzeigen und pruefen.</p>

          <ObjectPanel
            selectedUser={selectedUser}
            objects={objects}
            selectedObject={selectedObject}
            onError={setError}
            onSelectObject={selectObject}
            onCreateObject={createObjectForSelectedUser}
            onDeleteObject={() => setDeleteObjectConfirmOpen(true)}
          />
        </>}

        {sidebarMode !== 'rail' && <nav className={`nav-list ${sidebarMode === 'compact' ? 'compact' : ''}`}>
          {viewModes.map((mode) => (
            <button
              key={mode.id}
              className={mode.id === viewMode ? 'active' : ''}
              onClick={() => handleViewModeClick(mode.id)}
              disabled={!canUseViewMode(mode.id)}
              title={mode.id === 'wall' && !hasWallDetailAccess ? 'Wanddetail wird aktiv, sobald im Blueprint mindestens ein Raum existiert.' : mode.label}
              aria-label={mode.label}
            >
              <span className="nav-icon" aria-hidden="true">{viewModeIcon(mode.id)}</span>
              {sidebarMode === 'normal' && <span className="nav-label">{mode.label}</span>}
            </button>
          ))}
        </nav>}

        {sidebarMode === 'normal' && <section className="panel small">
          <h2>Etage</h2>
          <p>{selectedObject ? (floor ? `${floor.name}, Hoehe ${formatM(floor.heightM)}` : 'Lade Etage...') : 'Bitte Objekt waehlen.'}</p>
        </section>}

        {sidebarMode !== 'rail' && (
          <button type="button" className="sidebar-logout global-sidebar-logout" title="Logout" onClick={switchUser}>
            <span className="nav-icon" aria-hidden="true">⇥</span>
            {sidebarMode === 'normal' && <span>Logout</span>}
          </button>
        )}
      </aside>

      <main className="main-area">
        <header className="topbar">
          <div>
            <span className="eyebrow">Ansicht</span>
            <h2>{selectedTitle}</h2>
          </div>
        </header>

        {error && <div className="error-box">API-Fehler: {error}</div>}

        <section className="workspace">
          {!selectedObject && (
            <div className="hint-box standalone">
              Bitte waehle links in der Seitenleiste ein Objekt aus oder lege ein neues Objekt an. Danach werden Etage und Raeume fuer dieses Objekt geladen.
            </div>
          )}
          {selectedObject && viewMode === 'floorplan' && floor && (
            <FloorplanEditor
              floor={floor}
              rooms={rooms}
              selectedRoomId={selectedRoomId}
              onSelectRoom={setSelectedRoomId}
              onReload={reload}
              onError={setError}
              onPersistRoom={persistRoomNow}
              onRoomPreview={updateRoomInState}
              onLiveRoomChange={updateRoomLive}
              onDeleteSelectedRoom={requestDeleteSelectedRoom}
              onCaptureUndoSnapshot={captureUndoSnapshot}
              canUndo={undoStack.length > 0}
              onUndo={undoLastAction}
            />
          )}
          {selectedObject && viewMode === 'floorplan' && !floor && <div className="hint-box">Fuer dieses Objekt wird eine Etage vorbereitet...</div>}
          {selectedObject && viewMode === 'wall' && floor && hasWallDetailAccess && (
            <WallDetailEditor
              floor={floor}
              rooms={rooms}
              selectedRoomId={selectedRoomId}
              onSelectRoom={setSelectedRoomId}
              canUndo={undoStack.length > 0}
              onUndo={undoLastAction}
            />
          )}
          {selectedObject && viewMode === 'wall' && floor && !hasWallDetailAccess && (
            <div className="hint-box standalone">Wanddetail wird aktiv, sobald im Blueprint mindestens ein Raum angelegt ist.</div>
          )}
          {selectedObject && viewMode === 'board' && <BoardMock />}
          {selectedObject && viewMode === 'threeD' && <ThreeDMock />}
        </section>
      </main>
      {deleteConfirmRoom && (
        <ConfirmDeleteModal
          room={deleteConfirmRoom}
          onCancel={() => setDeleteConfirmRoomId('')}
          onConfirm={() => void confirmDeleteSelectedRoom()}
        />
      )}
      {deleteObjectConfirmOpen && selectedObject && (
        <ConfirmObjectDeleteModal
          object={selectedObject}
          onCancel={() => setDeleteObjectConfirmOpen(false)}
          onConfirm={() => void deleteSelectedObject()}
        />
      )}
    </div>
  )
}

function ConfirmDeleteModal({ room, onCancel, onConfirm }: { room: Room; onCancel: () => void; onConfirm: () => void }) {
  return (
    <div className="modal-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) onCancel() }}>
      <section className="confirm-modal" role="dialog" aria-modal="true" aria-label="Raum loeschen bestaetigen">
        <div>
          <span className="eyebrow">Loeschen</span>
          <h2>Raum loeschen?</h2>
          <p>Der Raum <strong>{room.name}</strong> wird aus dem Blueprint entfernt.</p>
        </div>
        <div className="button-row">
          <button type="button" onClick={onCancel}>Abbrechen</button>
          <button type="button" className="danger" onClick={onConfirm}>Loeschen</button>
        </div>
      </section>
    </div>
  )
}

function SessionStart({
  users,
  error,
  acceptNewUser,
  onError,
  onSelectUser,
  onLoginByName,
  onCreateUser,
  onOpenAdminPanel,
}: {
  users: AppUser[]
  error: string | null
  acceptNewUser: boolean
  onError: (message: string | null) => void
  onSelectUser: (user: AppUser, password: string) => Promise<void>
  onLoginByName: (name: string) => Promise<AppUser>
  onCreateUser: (name: string, password: string) => Promise<void>
  onOpenAdminPanel: (password: string) => Promise<void>
}) {
  const [loginUserTarget, setLoginUserTarget] = useState<AppUser | null>(null)
  const [loginPassword, setLoginPassword] = useState('')
  const [loginName, setLoginName] = useState('')
  const [createOpen, setCreateOpen] = useState(false)
  const [newUserName, setNewUserName] = useState('')
  const [newUserPassword, setNewUserPassword] = useState('')
  const [adminOpen, setAdminOpen] = useState(false)
  const [adminPass, setAdminPass] = useState('')

  async function guarded(action: () => Promise<void>) {
    try {
      onError(null)
      await action()
    } catch (err) {
      onError(err instanceof Error ? err.message : String(err))
    }
  }

  async function submitNameLogin() {
    const name = loginName.trim()
    if (!name) return
    try {
      onError(null)
      const foundUser = await onLoginByName(name)
      setLoginUserTarget(foundUser)
      setLoginPassword('')
    } catch (err) {
      if (acceptNewUser) {
        setNewUserName(name)
        setNewUserPassword('')
        setCreateOpen(true)
        onError(null)
      } else {
        onError('Nutzer existiert nicht und neue Nutzer sind aktuell deaktiviert.')
      }
    }
  }

  return (
    <div className="session-shell">
      <div className="session-card">
        <h1>strom</h1>
        <p className="session-lead">Waehle zuerst einen Nutzer. Die Objektauswahl befindet sich danach in der Seitenleiste.</p>
        {error && <div className="error-box inline">API-Fehler: {error}</div>}
        <section className="panel">
          <div className="session-panel-head">
            <h2>Nutzer</h2>
          </div>
          <div className="login-name-row">
            <label>
              Nutzername
              <input value={loginName} placeholder="Nutzername eingeben" onChange={(event) => setLoginName(event.target.value)} onKeyDown={(event) => { if (event.key === 'Enter') void submitNameLogin() }} />
            </label>
            <button type="button" onClick={() => void submitNameLogin()}>Anmelden</button>
          </div>
          <div className="choice-list">
            {users.map((user) => (
              <button key={user.id} onClick={() => { setLoginUserTarget(user); setLoginPassword('') }}>
                {user.name}
              </button>
            ))}
            {users.length === 0 && <p className="muted">Noch kein Nutzer in der Startliste vorhanden.</p>}
          </div>
          <div className="button-row session-action-row">
            <button type="button" disabled={!acceptNewUser} title={acceptNewUser ? 'Neuen Nutzer anlegen' : 'Neue Nutzer sind im Admin Panel deaktiviert'} onClick={() => { setCreateOpen(true); setNewUserName(''); setNewUserPassword('') }}>Neuer Nutzer</button>
            <button type="button" onClick={() => setAdminOpen(true)}>Admin Panel</button>
          </div>
        </section>
      </div>

      {loginUserTarget && (
        <div className="modal-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) setLoginUserTarget(null) }}>
          <section className="confirm-modal user-modal" role="dialog" aria-modal="true" aria-label="Nutzer anmelden">
            <div>
              <span className="eyebrow">Login</span>
              <h2>{loginUserTarget.name}</h2>
              <label>
                Passwort
                <input autoFocus type="password" value={loginPassword} onChange={(event) => setLoginPassword(event.target.value)} onKeyDown={(event) => { if (event.key === 'Enter') void guarded(() => onSelectUser(loginUserTarget, loginPassword)) }} />
              </label>
            </div>
            <div className="button-row">
              <button type="button" onClick={() => setLoginUserTarget(null)}>Abbrechen</button>
              <button type="button" onClick={() => void guarded(() => onSelectUser(loginUserTarget, loginPassword))}>Anmelden</button>
            </div>
          </section>
        </div>
      )}

      {createOpen && (
        <div className="modal-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) setCreateOpen(false) }}>
          <section className="confirm-modal user-modal" role="dialog" aria-modal="true" aria-label="Neuen Nutzer anlegen">
            <div>
              <span className="eyebrow">Neuer Nutzer</span>
              <h2>Nutzer anlegen</h2>
              <label>
                Name
                <input autoFocus value={newUserName} onChange={(event) => setNewUserName(event.target.value)} />
              </label>
              <label>
                Passwort
                <input type="password" value={newUserPassword} onChange={(event) => setNewUserPassword(event.target.value)} onKeyDown={(event) => { if (event.key === 'Enter') void guarded(async () => { await onCreateUser(newUserName.trim() || 'Neuer Nutzer', newUserPassword); setCreateOpen(false) }) }} />
              </label>
            </div>
            <div className="button-row">
              <button type="button" onClick={() => setCreateOpen(false)}>Abbrechen</button>
              <button type="button" disabled={!acceptNewUser} onClick={() => void guarded(async () => { await onCreateUser(newUserName.trim() || 'Neuer Nutzer', newUserPassword); setCreateOpen(false) })}>Speichern</button>
            </div>
          </section>
        </div>
      )}

      {adminOpen && (
        <div className="modal-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) setAdminOpen(false) }}>
          <section className="confirm-modal user-modal" role="dialog" aria-modal="true" aria-label="Admin Panel Login">
            <div>
              <span className="eyebrow">Admin Panel</span>
              <h2>Admin-Passwort</h2>
              <label>
                Passwort
                <input autoFocus type="password" value={adminPass} onChange={(event) => setAdminPass(event.target.value)} onKeyDown={(event) => { if (event.key === 'Enter') void guarded(() => onOpenAdminPanel(adminPass)) }} />
              </label>
            </div>
            <div className="button-row">
              <button type="button" onClick={() => setAdminOpen(false)}>Abbrechen</button>
              <button type="button" onClick={() => void guarded(() => onOpenAdminPanel(adminPass))}>Oeffnen</button>
            </div>
          </section>
        </div>
      )}
    </div>
  )
}


function AdminPanel({
  users,
  error,
  settings,
  onError,
  onClose,
  onUpdateUser,
  onDeleteUser,
  onUpdateSettings,
  onChangeAdminPassword,
}: {
  users: AppUser[]
  error: string | null
  settings: AppSettings | null
  onError: (message: string | null) => void
  onClose: () => void
  onUpdateUser: (userId: string, payload: AdminUserUpdate) => Promise<void>
  onDeleteUser: (userId: string) => Promise<void>
  onUpdateSettings: (payload: AdminSettingsUpdate) => Promise<void>
  onChangeAdminPassword: (newPassword: string) => Promise<void>
}) {
  const [editingNames, setEditingNames] = useState<Record<string, string>>({})
  const [passwordOpen, setPasswordOpen] = useState(false)
  const [newAdminPassword, setNewAdminPassword] = useState('')
  const [deleteUserTarget, setDeleteUserTarget] = useState<AppUser | null>(null)

  async function guarded(action: () => Promise<void>) {
    try {
      onError(null)
      await action()
    } catch (err) {
      onError(err instanceof Error ? err.message : String(err))
    }
  }

  const effectiveSettings = settings ?? { acceptNewUser: true, debugMode: false, debugUserName: '', debugViewMode: 'floorplan' as ViewMode }

  return (
    <div className="session-shell admin-shell">
      <div className="session-card admin-card">
        <div className="admin-head">
          <div>
            <span className="eyebrow">Admin Panel</span>
            <h1>Nutzer-Einstellungen</h1>
          </div>
          <div className="button-row">
            <button type="button" onClick={() => { setPasswordOpen(true); setNewAdminPassword('') }}>Admin-Passwort aendern</button>
            <button type="button" onClick={onClose}>Zurueck</button>
          </div>
        </div>
        {error && <div className="error-box inline">API-Fehler: {error}</div>}

        <section className="admin-settings-box">
          <label className="check-line">
            <input type="checkbox" checked={effectiveSettings.acceptNewUser} onChange={(event) => void guarded(() => onUpdateSettings({ acceptNewUser: event.target.checked }))} />
            <span>accept new user</span>
          </label>
          <div className="debug-settings-line">
            <label className="check-line">
              <input type="checkbox" checked={effectiveSettings.debugMode} onChange={(event) => void guarded(() => onUpdateSettings({ debugMode: event.target.checked }))} />
              <span>debugmode</span>
            </label>
            <input value={effectiveSettings.debugUserName} placeholder="Nutzername" onChange={(event) => void guarded(() => onUpdateSettings({ debugUserName: event.target.value }))} />
            <select value={effectiveSettings.debugViewMode} onChange={(event) => void guarded(() => onUpdateSettings({ debugViewMode: event.target.value as ViewMode }))}>
              {viewModes.map((mode) => <option key={mode.id} value={mode.id}>{mode.label}</option>)}
            </select>
          </div>
        </section>

        <div className="admin-user-list">
          {users.map((user) => {
            const localName = editingNames[user.id] ?? user.name
            return (
              <section key={user.id} className={`admin-user-row ${user.isAdmin ? 'admin-user-row-admin' : ''}`}>
                <div>
                  <label>
                    Nutzername
                    <input value={localName} onChange={(event) => setEditingNames((current) => ({ ...current, [user.id]: event.target.value }))} onBlur={() => { if (localName.trim() && localName.trim() !== user.name) void guarded(() => onUpdateUser(user.id, { name: localName.trim() })) }} />
                  </label>
                  {user.isAdmin && <span className="admin-badge">admin</span>}
                </div>
                <label className="check-line">
                  <input type="checkbox" checked={Boolean(user.canViewAllObjects)} onChange={(event) => void guarded(() => onUpdateUser(user.id, { canViewAllObjects: event.target.checked }))} />
                  <span>alle Objekte</span>
                </label>
                <label className="check-line">
                  <input type="checkbox" checked={Boolean(user.inList)} onChange={(event) => void guarded(() => onUpdateUser(user.id, { inList: event.target.checked }))} />
                  <span>in list</span>
                </label>
                <button type="button" className="danger ghost-danger" onClick={() => setDeleteUserTarget(user)}>Nutzer loeschen</button>
              </section>
            )
          })}
        </div>
      </div>

      {passwordOpen && (
        <div className="modal-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) setPasswordOpen(false) }}>
          <section className="confirm-modal user-modal" role="dialog" aria-modal="true" aria-label="Admin Passwort aendern">
            <div>
              <span className="eyebrow">Admin</span>
              <h2>Passwort aendern</h2>
              <label>
                Neues Passwort
                <input autoFocus type="password" value={newAdminPassword} onChange={(event) => setNewAdminPassword(event.target.value)} onKeyDown={(event) => { if (event.key === 'Enter') void guarded(async () => { await onChangeAdminPassword(newAdminPassword); setPasswordOpen(false) }) }} />
              </label>
            </div>
            <div className="button-row">
              <button type="button" onClick={() => setPasswordOpen(false)}>Abbrechen</button>
              <button type="button" onClick={() => void guarded(async () => { await onChangeAdminPassword(newAdminPassword); setPasswordOpen(false) })}>Speichern</button>
            </div>
          </section>
        </div>
      )}

      {deleteUserTarget && (
        <div className="modal-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) setDeleteUserTarget(null) }}>
          <section className="confirm-modal user-modal" role="dialog" aria-modal="true" aria-label="Nutzer loeschen">
            <div>
              <span className="eyebrow">Nutzer loeschen</span>
              <h2>{deleteUserTarget.name} loeschen?</h2>
              <p className="warning-text">Beim Loeschen werden auch alle Objekte und Blueprint-Daten dieses Nutzers geloescht.</p>
            </div>
            <div className="button-row">
              <button type="button" onClick={() => setDeleteUserTarget(null)}>Abbrechen</button>
              <button type="button" className="danger" onClick={() => void guarded(async () => { await onDeleteUser(deleteUserTarget.id); setDeleteUserTarget(null) })}>Nutzer loeschen</button>
            </div>
          </section>
        </div>
      )}
    </div>
  )
}


function ObjectPanel({
  selectedUser,
  objects,
  selectedObject,
  onError,
  onSelectObject,
  onCreateObject,
  onDeleteObject,
}: {
  selectedUser: AppUser
  objects: UserObject[]
  selectedObject: UserObject | null
  onError: (message: string | null) => void
  onSelectObject: (object: UserObject) => Promise<void>
  onCreateObject: (name: string) => Promise<void>
  onDeleteObject: () => void
}) {
  const [newObjectOpen, setNewObjectOpen] = useState(false)
  const [newObjectName, setNewObjectName] = useState('')
  const [collapsed, setCollapsed] = useState(true)

  async function guarded(action: () => Promise<void>) {
    try {
      onError(null)
      await action()
    } catch (err) {
      onError(err instanceof Error ? err.message : String(err))
    }
  }

  return (
    <section className={`panel small object-panel ${collapsed ? 'collapsed' : ''}`}>
      <button className="collapse-toggle" onClick={() => setCollapsed((current) => !current)} aria-expanded={!collapsed}>
        <span>Nutzer & Objekt</span>
        <span>{collapsed ? '▸' : '▾'}</span>
      </button>
      {!collapsed && (
        <div className="collapsible-content">
          <div className="user-summary">
            <span className="eyebrow">Nutzer</span>
            <strong>{selectedUser.name}</strong>
          </div>
          <h2>Objekt</h2>
          <div className="choice-list compact">
            {objects.map((object) => {
              const foreign = object.userId !== selectedUser.id
              return (
                <button key={object.id} className={`${object.id === selectedObject?.id ? 'active' : ''} ${foreign ? 'foreign-object' : ''}`} onClick={() => void guarded(() => onSelectObject(object))} title={foreign ? `Fremdes Objekt von ${object.userName ?? 'anderem Nutzer'}` : object.name}>
                  <span>{object.name}</span>
                  {foreign && <small>{object.userName ?? 'fremd'}</small>}
                </button>
              )
            })}
            {objects.length === 0 && <p className="muted">Noch kein Objekt vorhanden.</p>}
          </div>
          <div className="button-row vertical object-actions">
            <button type="button" onClick={() => { setNewObjectOpen(true); setNewObjectName('') }}>Objekt anlegen</button>
            <button type="button" className="danger ghost-danger" disabled={!selectedObject} onClick={onDeleteObject}>Objekt loeschen</button>
          </div>
        </div>
      )}
      {newObjectOpen && (
        <div className="modal-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) setNewObjectOpen(false) }}>
          <section className="confirm-modal user-modal" role="dialog" aria-modal="true" aria-label="Objekt anlegen">
            <div>
              <span className="eyebrow">Objekt</span>
              <h2>Neues Objekt</h2>
              <label>
                Objektname
                <input autoFocus value={newObjectName} placeholder="z. B. Wohnhaus" onChange={(event) => setNewObjectName(event.target.value)} onKeyDown={(event) => { if (event.key === 'Enter') void guarded(async () => { await onCreateObject(newObjectName.trim() || 'Neues Objekt'); setNewObjectOpen(false) }) }} />
              </label>
            </div>
            <div className="button-row">
              <button type="button" onClick={() => setNewObjectOpen(false)}>Abbrechen</button>
              <button type="button" onClick={() => void guarded(async () => { await onCreateObject(newObjectName.trim() || 'Neues Objekt'); setNewObjectOpen(false) })}>Anlegen</button>
            </div>
          </section>
        </div>
      )}
    </section>
  )
}

function ConfirmObjectDeleteModal({ object, onCancel, onConfirm }: { object: UserObject; onCancel: () => void; onConfirm: () => void }) {
  return (
    <div className="modal-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) onCancel() }}>
      <section className="confirm-modal" role="dialog" aria-modal="true" aria-label="Objekt loeschen bestaetigen">
        <div>
          <span className="eyebrow">Objekt loeschen</span>
          <h2>{object.name} loeschen?</h2>
          {object.hasData
            ? <p className="warning-text">Dieses Objekt enthaelt bereits Daten. Beim Loeschen werden auch alle zugeordneten Ebenen, Raeume und Blueprint-Daten entfernt.</p>
            : <p>Dieses Objekt enthaelt noch keine Blueprint-Daten.</p>}
        </div>
        <div className="button-row">
          <button type="button" onClick={onCancel}>Abbrechen</button>
          <button type="button" className="danger" onClick={onConfirm}>Objekt loeschen</button>
        </div>
      </section>
    </div>
  )
}

function RoomPropertiesTopBar({ room, onLiveChange }: { room: Room | null; onLiveChange: (room: Room) => void }) {
  if (!room) return null
  return <EditorPropertiesTopBar
    mode={{ kind: 'selected', room }}
    onRectInputChange={() => undefined}
    onRectDraftChange={() => undefined}
    onPolygonNameChange={() => undefined}
    onPolygonWallThicknessChange={() => undefined}
    onLiveRoomChange={onLiveChange}
  />
}

function FloorplanEditor({
  floor,
  rooms,
  selectedRoomId,
  onSelectRoom,
  onReload,
  onError,
  onPersistRoom,
  onRoomPreview,
  onLiveRoomChange,
  onDeleteSelectedRoom,
  onCaptureUndoSnapshot,
  canUndo,
  onUndo,
}: {
  floor: Floor
  rooms: Room[]
  selectedRoomId: string
  onSelectRoom: (id: string) => void
  onReload: () => Promise<void>
  onError: (message: string | null) => void
  onPersistRoom: (room: Room) => Promise<void>
  onRoomPreview: (room: Room) => void
  onLiveRoomChange: (room: Room) => void
  onDeleteSelectedRoom: () => void
  onCaptureUndoSnapshot: () => void
  canUndo: boolean
  onUndo: () => void
}) {
  const [tool, setTool] = useState<Tool>('select')
  const [rectInput, setRectInput] = useState<RectInput>({ name: 'Neuer Raum', wallThicknessM: 0.12 })
  const [rectDraft, setRectDraft] = useState<RectDraft | null>(null)
  const [polygonName, setPolygonName] = useState('Polygonraum')
  const [polygonWallThicknessM, setPolygonWallThicknessM] = useState(0.12)
  const [polygonDraft, setPolygonDraft] = useState<PointM[]>([])
  const [cursorPoint, setCursorPoint] = useState<PointM | null>(null)
  const [roomDrag, setRoomDrag] = useState<RoomDrag | null>(null)
  const [roomPreview, setRoomPreview] = useState<{ roomId: string; vertices: PointM[] } | null>(null)
  const [rectHandleDrag, setRectHandleDrag] = useState<RectHandleDrag | null>(null)
  const [vertexDrag, setVertexDrag] = useState<VertexDrag | null>(null)
  const [polygonEdgeDrag, setPolygonEdgeDrag] = useState<PolygonEdgeDrag | null>(null)
  const [groupDrag, setGroupDrag] = useState<GroupRoomDrag | null>(null)
  const [groupPreview, setGroupPreview] = useState<Record<string, PointM[]>>({})
  const [allSelected, setAllSelected] = useState(false)
  const [distanceFirstEdge, setDistanceFirstEdge] = useState<DistanceEdgeSelection | null>(null)
  const [distancePair, setDistancePair] = useState<DistancePair | null>(null)
  const [zoom, setZoom] = useState(() => loadCanvasViewport(floor.id).zoom)
  const [scrollPosition, setScrollPosition] = useState(() => {
    const viewport = loadCanvasViewport(floor.id)
    return { left: viewport.left, top: viewport.top }
  })
  const [snapEnabled, setSnapEnabled] = useState(true)
  const [snapWallThicknessM, setSnapWallThicknessM] = useState(0.12)
  const [recessDraft, setRecessDraft] = useState<RecessDraft | null>(null)
  const [recessBaseRoomId, setRecessBaseRoomId] = useState<string>('')
  const [recessHandleDrag, setRecessHandleDrag] = useState<RecessHandleDrag | null>(null)
  const [dimensionsVisible, setDimensionsVisible] = useState(true)
  const [dimensionOffsets, setDimensionOffsets] = useState<Record<string, Partial<DimensionOffset>>>({})
  const [dimensionDrag, setDimensionDrag] = useState<{ roomId: string; line: DimensionLineKey; axis: DimensionDragAxis; shiftPair: boolean; startClientX: number; startClientY: number; startOffset: DimensionOffset } | null>(null)
  const [layers, setLayers] = useState<FloorplanLayer[]>(() => loadFloorplanLayers(floor.id))
  const [activeLayerId, setActiveLayerId] = useState<string>(() => loadActiveLayerId(floor.id, loadFloorplanLayers(floor.id)))
  const [roomLayerAssignments, setRoomLayerAssignments] = useState<Record<string, string>>(() => loadLayerAssignments(floor.id))
  const [layerVisibilityMode, setLayerVisibilityMode] = useState<LayerVisibilityMode>('active')
  const [layersOpen, setLayersOpen] = useState(false)
  const [blueprintWallObjects, setBlueprintWallObjects] = useState<ApiWallObject[]>([])
  const [draggedLayerId, setDraggedLayerId] = useState<string>('')
  const [layerDeleteRequestId, setLayerDeleteRequestId] = useState<string>('')
  const [titleOffsets, setTitleOffsets] = useState<Record<string, TitleOffset>>(() => loadTitleOffsets(floor.id))
  const [titleDrag, setTitleDrag] = useState<{ roomId: string; startClientX: number; startClientY: number; startOffset: TitleOffset } | null>(null)
  const [stairPanelOpen, setStairPanelOpen] = useState(false)
  const [stairPanelRect, setStairPanelRect] = useState({ left: 24, top: 24, width: 820, height: 540 })
  const [stairPanelDrag, setStairPanelDrag] = useState<{ mode: 'move' | 'resize'; startClientX: number; startClientY: number; startRect: { left: number; top: number; width: number; height: number } } | null>(null)
  const canvasScrollRef = useRef<HTMLDivElement | null>(null)
  const panDragRef = useRef<{ startX: number; startY: number; scrollLeft: number; scrollTop: number; moved: boolean } | null>(null)
  const suppressCanvasClickRef = useRef(false)
  const initializedCanvasScrollRef = useRef<string>('')

  const selectedRoom = rooms.find((room) => room.id === selectedRoomId) ?? null
  const recessBaseRoom = recessBaseRoomId ? rooms.find((room) => room.id === recessBaseRoomId) ?? null : null
  const rectPreview = rectDraft ? normalizeRect(rectDraft.start, rectDraft.end) : null
  const rectPreviewArea = rectPreview ? rectPreview.width * rectPreview.height : 0
  const polygonArea = polygonAreaM2(polygonDraft)
  const recessPreview = recessBaseRoom && recessDraft ? buildRecessPreview(recessBaseRoom, recessDraft) : null
  useEffect(() => {
    const nextLayers = loadFloorplanLayers(floor.id)
    setLayers(nextLayers)
    setActiveLayerId(loadActiveLayerId(floor.id, nextLayers))
    setRoomLayerAssignments(loadLayerAssignments(floor.id))
    setTitleOffsets(loadTitleOffsets(floor.id))
    setLayerVisibilityMode('active')
    setLayerDeleteRequestId('')
    setLayersOpen(false)
  }, [floor.id])

  useEffect(() => {
    localStorage.setItem(layerStorageKey(floor.id, 'list'), JSON.stringify(layers))
  }, [floor.id, layers])

  useEffect(() => {
    localStorage.setItem(layerStorageKey(floor.id, 'active'), JSON.stringify(activeLayerId))
  }, [floor.id, activeLayerId])

  useEffect(() => {
    localStorage.setItem(layerStorageKey(floor.id, 'roomAssignments'), JSON.stringify(roomLayerAssignments))
  }, [floor.id, roomLayerAssignments])

  useEffect(() => {
    localStorage.setItem(titleOffsetStorageKey(floor.id), JSON.stringify(titleOffsets))
  }, [floor.id, titleOffsets])

  useEffect(() => {
    if (!stairPanelOpen) return
    const card = canvasScrollRef.current?.parentElement
    if (!card) return
    const maxLeft = Math.max(12, card.clientWidth - stairPanelRect.width - 12)
    const maxTop = Math.max(12, card.clientHeight - stairPanelRect.height - 12)
    setStairPanelRect((current) => ({
      ...current,
      left: clamp(current.left, 12, maxLeft),
      top: clamp(current.top, 12, maxTop),
    }))
  }, [stairPanelOpen, selectedRoomId])

  useEffect(() => {
    if (!stairPanelDrag) return
    const drag = stairPanelDrag
    function onMove(event: MouseEvent) {
      const card = canvasScrollRef.current?.parentElement
      const cardWidth = card?.clientWidth ?? window.innerWidth
      const cardHeight = card?.clientHeight ?? window.innerHeight
      const dx = event.clientX - drag.startClientX
      const dy = event.clientY - drag.startClientY
      if (drag.mode === 'resize') {
        const width = clamp(Math.round(drag.startRect.width + dx), 560, Math.max(560, cardWidth - drag.startRect.left - 12))
        const height = clamp(Math.round(drag.startRect.height + dy), 420, Math.max(420, cardHeight - drag.startRect.top - 12))
        setStairPanelRect((current) => ({ ...current, width, height }))
        return
      }
      const maxLeft = Math.max(12, cardWidth - drag.startRect.width - 12)
      const maxTop = Math.max(12, cardHeight - drag.startRect.height - 12)
      setStairPanelRect({
        ...drag.startRect,
        left: clamp(Math.round(drag.startRect.left + dx), 12, maxLeft),
        top: clamp(Math.round(drag.startRect.top + dy), 12, maxTop),
      })
    }
    function onUp() { setStairPanelDrag(null) }
    window.addEventListener('mousemove', onMove)
    window.addEventListener('mouseup', onUp)
    return () => {
      window.removeEventListener('mousemove', onMove)
      window.removeEventListener('mouseup', onUp)
    }
  }, [stairPanelDrag])

  useEffect(() => {
    const viewport = loadCanvasViewport(floor.id)
    setZoom(viewport.zoom)
    setScrollPosition({ left: viewport.left, top: viewport.top })
    window.requestAnimationFrame(() => {
      const scroll = canvasScrollRef.current
      if (!scroll || initializedCanvasScrollRef.current === floor.id) return
      initializedCanvasScrollRef.current = floor.id
      const fallbackLeft = Math.max(0, mToX(0) - canvas.margin)
      const fallbackTop = Math.max(0, mToY(0) - canvas.margin)
      scroll.scrollLeft = viewport.left > 0 ? viewport.left : fallbackLeft
      scroll.scrollTop = viewport.top > 0 ? viewport.top : fallbackTop
      setScrollPosition({ left: scroll.scrollLeft, top: scroll.scrollTop })
      saveCanvasViewport(floor.id, { zoom: viewport.zoom, left: scroll.scrollLeft, top: scroll.scrollTop })
    })
  }, [floor.id])

  useEffect(() => {
    const layerIds = new Set(layers.map((layer) => layer.id))
    if (!layerIds.has(activeLayerId)) setActiveLayerId(layers[0]?.id ?? defaultLayerId)
    setRoomLayerAssignments((current) => {
      const next: Record<string, string> = {}
      let changed = false
      rooms.forEach((room) => {
        const stored = current[room.id]
        next[room.id] = stored && layerIds.has(stored) ? stored : (activeLayerId && layerIds.has(activeLayerId) ? activeLayerId : layers[0]?.id ?? defaultLayerId)
        if (next[room.id] !== stored) changed = true
      })
      if (Object.keys(current).length !== Object.keys(next).length) changed = true
      return changed ? next : current
    })
  }, [rooms, layers, activeLayerId])

  const layerIndexMap = useMemo(() => new Map(layers.map((layer, index) => [layer.id, index])), [layers])
  const activeLayerIndex = layerIndexMap.get(activeLayerId) ?? 0
  useEffect(() => {
    let cancelled = false
    getWallObjects(floor.id)
      .then((objects) => { if (!cancelled) setBlueprintWallObjects(objects) })
      .catch(() => { if (!cancelled) setBlueprintWallObjects([]) })
    return () => { cancelled = true }
  }, [floor.id, rooms.length])

  const activeLayer = layers.find((layer) => layer.id === activeLayerId) ?? layers[0] ?? defaultFloorplanLayers()[0]
  const activeLayerRooms = useMemo(
    () => rooms.filter((room) => (roomLayerAssignments[room.id] ?? defaultLayerId) === activeLayerId),
    [rooms, roomLayerAssignments, activeLayerId],
  )

  function renderStateForLayer(layerId: string) {
    const layer = layers.find((item) => item.id === layerId)
    const layerVisible = layer?.visible !== false
    const index = layerIndexMap.get(layerId) ?? 0
    const active = layerId === activeLayerId
    if (active) return { visible: true, ghost: false, dimensions: true, interactive: true }
    if (!layerVisible) return { visible: false, ghost: false, dimensions: false, interactive: false }
    if (layerVisibilityMode === 'active') return { visible: false, ghost: false, dimensions: false, interactive: false }
    if (layerVisibilityMode === 'allGhostNoDims') return { visible: true, ghost: true, dimensions: false, interactive: false }
    const adjacent = Math.abs(index - activeLayerIndex) === 1
    return {
      visible: adjacent,
      ghost: adjacent,
      dimensions: adjacent && layerVisibilityMode === 'adjacentGhostDims',
      interactive: false,
    }
  }

  const renderedRooms = useMemo(() => {
    const list = rooms.map((room) => {
      const preview = groupPreview[room.id] ?? (roomPreview?.roomId === room.id ? roomPreview.vertices : null)
      const layerId = roomLayerAssignments[room.id] ?? defaultLayerId
      const state = renderStateForLayer(layerId)
      return { room, vertices: preview ?? room.vertices, layerId, layerIndex: layerIndexMap.get(layerId) ?? 0, renderState: state }
    }).filter((item) => item.renderState.visible)
    return list.sort((a, b) => {
      if (a.layerIndex !== b.layerIndex) return b.layerIndex - a.layerIndex
      const aOuterWall = isOuterWallRoom(a.room)
      const bOuterWall = isOuterWallRoom(b.room)
      if (aOuterWall !== bOuterWall) return aOuterWall ? -1 : 1
      return Number(a.room.id === selectedRoomId) - Number(b.room.id === selectedRoomId)
    })
  }, [rooms, roomPreview, groupPreview, selectedRoomId, roomLayerAssignments, layerIndexMap, layers, activeLayerId, layerVisibilityMode])

  const distanceGuides = useMemo(() => {
    if (!roomDrag && !rectHandleDrag) return []
    if (!roomPreview) return []
    const movingId = roomDrag?.roomId ?? rectHandleDrag?.roomId
    const targets = rooms
      .filter((room) => room.id !== movingId)
      .filter((room) => renderStateForLayer(roomLayerAssignments[room.id] ?? defaultLayerId).visible)
      .map((room) => ({ room, vertices: room.vertices }))
    return buildDistanceGuides(roomPreview.vertices, targets)
  }, [roomDrag, rectHandleDrag, roomPreview, rooms, roomLayerAssignments, layers, activeLayerId, layerVisibilityMode])

  useEffect(() => {
    function handleKeyDown(event: KeyboardEvent) {
      if (isEditableTarget(event.target)) return

      if (tool === 'polygon') {
        if (event.key === 'Backspace') {
          event.preventDefault()
          setPolygonDraft((current) => current.slice(0, -1))
          return
        }
        if (event.key === 'Escape') {
          event.preventDefault()
          setPolygonDraft([])
          setRectDraft(null)
          setRecessDraft(null)
          setRecessBaseRoomId('')
          return
        }
      }

      if (tool === 'recess' && event.key === 'Escape') {
        event.preventDefault()
        cancelRecess()
        return
      }

      if (event.key === 'Delete' && (selectedRoom || allSelected)) {
        event.preventDefault()
        void deleteSelectedFromCanvas()
        return
      }

      if (!selectedRoom || allSelected || roomDrag || groupDrag || polygonEdgeDrag || vertexDrag || rectHandleDrag || tool !== 'select') return
      const step = keyboardStepForZoom(zoom) * (event.shiftKey ? 10 : 1)
      let dx = 0
      let dy = 0
      if (event.key === 'ArrowLeft') dx = -step
      if (event.key === 'ArrowRight') dx = step
      if (event.key === 'ArrowUp') dy = -step
      if (event.key === 'ArrowDown') dy = step
      if (dx !== 0 || dy !== 0) {
        event.preventDefault()
        onCaptureUndoSnapshot()
        if (isOuterWallRoom(selectedRoom)) {
          const selectedLayerId = roomLayerAssignments[selectedRoom.id] ?? defaultLayerId
          void Promise.all(rooms.filter((room) => (roomLayerAssignments[room.id] ?? defaultLayerId) === selectedLayerId).map((room) => {
            const nextVertices = room.vertices.map((point) => clampPoint({ x: round3(point.x + dx), y: round3(point.y + dy) }))
            return onPersistRoom({ ...room, vertices: nextVertices, areaM2: polygonAreaM2(nextVertices) })
          }))
        } else {
          const nextVertices = selectedRoom.vertices.map((point) => clampPoint({ x: round2(point.x + dx), y: round2(point.y + dy) }))
          void onPersistRoom({ ...selectedRoom, vertices: nextVertices, areaM2: polygonAreaM2(nextVertices) })
        }
      }
    }
    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [tool, selectedRoom, allSelected, roomDrag, groupDrag, polygonEdgeDrag, vertexDrag, rectHandleDrag, zoom, onDeleteSelectedRoom, onPersistRoom, onCaptureUndoSnapshot])

  async function finishRectangle(rect: RectM) {
    if (rect.width < 0.1 || rect.height < 0.1) {
      setRectDraft(null)
      return
    }
    try {
      onError(null)
      onCaptureUndoSnapshot()
      const createdRoom = await createRoom({
        floorId: floor.id,
        name: rectInput.name.trim() || 'Neuer Raum',
        shapeType: 'rectangle',
        wallThicknessM: rectInput.wallThicknessM > 0 ? rectInput.wallThicknessM : 0.12,
        vertices: rectangleVertices(rect.minX, rect.minY, rect.width, rect.height),
      })
      setRoomLayerAssignments((current) => ({ ...current, [createdRoom.id]: activeLayerId }))
      setRectDraft(null)
      await onReload()
      onSelectRoom(createdRoom.id)
      setTool('select')
    } catch (err) {
      onError(err instanceof Error ? err.message : String(err))
    }
  }

  async function finishOuterWall(rect: RectM) {
    if (rect.width < 0.1 || rect.height < 0.1) {
      setRectDraft(null)
      return
    }
    try {
      onError(null)
      onCaptureUndoSnapshot()
      const createdRoom = await createRoom({
        floorId: floor.id,
        name: outerWallName(),
        shapeType: 'rectangle',
        wallThicknessM: rectInput.wallThicknessM > 0 ? rectInput.wallThicknessM : 0.12,
        vertices: rectangleVertices(rect.minX, rect.minY, rect.width, rect.height),
      })
      setRoomLayerAssignments((current) => ({ ...current, [createdRoom.id]: activeLayerId }))
      setRectDraft(null)
      await onReload()
      onSelectRoom(createdRoom.id)
      setTool('select')
    } catch (err) {
      onError(err instanceof Error ? err.message : String(err))
    }
  }

  async function finishPolygon() {
    if (polygonDraft.length < 3) return
    try {
      onError(null)
      onCaptureUndoSnapshot()
      const createdRoom = await createRoom({
        floorId: floor.id,
        name: polygonName.trim() || 'Polygonraum',
        shapeType: 'polygon',
        wallThicknessM: polygonWallThicknessM > 0 ? polygonWallThicknessM : 0.12,
        vertices: polygonDraft,
      })
      setRoomLayerAssignments((current) => ({ ...current, [createdRoom.id]: activeLayerId }))
      setPolygonDraft([])
      await onReload()
      onSelectRoom(createdRoom.id)
      setTool('select')
    } catch (err) {
      onError(err instanceof Error ? err.message : String(err))
    }
  }

  async function finishRecess(preview: RecessPreview | null = recessPreview) {
    const baseRoom = recessBaseRoom
    if (!baseRoom || !preview) return
    const nextVertices = normalizeResultPolygon(preview.vertices)
    const nextRoom: Room = {
      ...baseRoom,
      shapeType: isAxisAlignedRectangle(nextVertices) ? 'rectangle' : 'polygon',
      vertices: nextVertices,
      areaM2: polygonAreaM2(nextVertices),
    }
    setRecessDraft(null)
    setRecessHandleDrag(null)
    setRecessBaseRoomId('')
    setTool('select')
    onSelectRoom(baseRoom.id)
    onCaptureUndoSnapshot()
    await onPersistRoom(nextRoom)
  }

  function handleCanvasClick(event: ReactMouseEvent<SVGSVGElement>) {
    event.preventDefault()
    if (suppressCanvasClickRef.current) {
      suppressCanvasClickRef.current = false
      return
    }
    const point = eventToMeters(event)
    if (!point) return

    if (tool === 'rectangle' || tool === 'outerwall') {
      if (!rectDraft) {
        setRectDraft({ start: point, end: point })
      } else {
        const nextRect = normalizeRect(rectDraft.start, point)
        if (tool === 'outerwall') void finishOuterWall(nextRect)
        else void finishRectangle(nextRect)
      }
      return
    }

    if (tool === 'polygon') {
      const rawPoint = point
      if (polygonDraft.length >= 3 && isNearStartPoint(rawPoint, polygonDraft[0])) {
        void finishPolygon()
        return
      }
      setPolygonDraft((current) => {
        const previous = current[current.length - 1]
        const nextPoint = previous && event.shiftKey ? constrainTo45(previous, rawPoint) : rawPoint
        if (previous && distance(previous, nextPoint) < 0.05) return current
        return [...current, nextPoint]
      })
      return
    }

    if (tool === 'recess' && recessBaseRoom) {
      if (event.detail > 1) return
      const bounds = boundsOf(recessBaseRoom.vertices)
      const inside = bounds ? clampPointToBounds(point, bounds) : point
      setRecessDraft((current) => {
        const edge = current?.edge ?? defaultRecessEdge(recessBaseRoom)
        const offset = bounds ? offsetFromPointForEdge(bounds, edge, inside) : 0
        if (!current || current.phase === 'idle') {
          return { start: inside, end: inside, edge, manualAlongM: current?.manualAlongM, manualDepthM: current?.manualDepthM, manualOffsetM: current?.manualOffsetM ?? offset, manualOffsetFromEnd: current?.manualOffsetFromEnd ?? false, phase: 'drawing' }
        }
        if (current.phase === 'drawing') {
          return { ...current, end: inside, manualOffsetM: current.manualOffsetM ?? offset, phase: 'ready' }
        }
        return current
      })
      return
    }

    if (tool === 'distance') {
      setDistanceFirstEdge(null)
      setDistancePair(null)
      return
    }

    if (tool === 'select') {
      setAllSelected(false)
      onSelectRoom('')
    }
  }

  function handleCanvasDoubleClick(event: ReactMouseEvent<SVGSVGElement>) {
    if (tool !== 'polygon') return
    event.preventDefault()
    event.stopPropagation()
    if (polygonDraft.length >= 3) void finishPolygon()
  }

  function handleMouseMove(event: ReactMouseEvent<SVGSVGElement>) {
    
if (dimensionDrag) {
      const deltaX = (event.clientX - dimensionDrag.startClientX) / zoom
      const deltaY = (event.clientY - dimensionDrag.startClientY) / zoom
      setDimensionOffsets((current) => {
        const base = normalizeDimensionOffset(current[dimensionDrag.roomId])
        const next: DimensionOffset = { ...base }
        const pair: DimensionLineKey = dimensionDrag.line === 'xParts' ? 'xTotal'
          : dimensionDrag.line === 'xTotal' ? 'xParts'
          : dimensionDrag.line === 'yParts' ? 'yTotal'
          : 'yParts'
        const delta = dimensionDrag.axis === 'horizontal' ? deltaY : deltaX
        next[dimensionDrag.line] = clamp(dimensionDrag.startOffset[dimensionDrag.line] + delta, -320, 320)
        if (event.shiftKey || dimensionDrag.shiftPair) {
          next[pair] = clamp(dimensionDrag.startOffset[pair] + delta, -320, 320)
        }
        return { ...current, [dimensionDrag.roomId]: next }
      })
      return
    }
    if (titleDrag) {
      const dx = (event.clientX - titleDrag.startClientX) / zoom
      const dy = (event.clientY - titleDrag.startClientY) / zoom
      setTitleOffsets((current) => ({
        ...current,
        [titleDrag.roomId]: {
          x: Math.round((titleDrag.startOffset.x + dx) * 10) / 10,
          y: Math.round((titleDrag.startOffset.y + dy) * 10) / 10,
        },
      }))
      return
    }
    if (panDragRef.current && canvasScrollRef.current) {
      const drag = panDragRef.current
      const dx = event.clientX - drag.startX
      const dy = event.clientY - drag.startY
      if (Math.abs(dx) > 2 || Math.abs(dy) > 2) drag.moved = true
      canvasScrollRef.current.scrollLeft = drag.scrollLeft - dx
      canvasScrollRef.current.scrollTop = drag.scrollTop - dy
      return
    }
    const rawPoint = eventToMeters(event)
    const point = rawPoint && tool === 'polygon' && polygonDraft.length > 0 && event.shiftKey
      ? constrainTo45(polygonDraft[polygonDraft.length - 1], rawPoint)
      : rawPoint
    setCursorPoint(point)
    if (!point) return

    if ((tool === 'rectangle' || tool === 'outerwall') && rectDraft) {
      setRectDraft({ ...rectDraft, end: point })
      return
    }

    if (tool === 'recess' && recessHandleDrag && recessBaseRoom) {
      const next = resizeRecessDraftByHandle(recessBaseRoom, recessHandleDrag.originalDraft, recessHandleDrag.handle, point)
      if (next) setRecessDraft(next)
      return
    }

    if (tool === 'recess' && recessDraft && recessBaseRoom && recessDraft.phase === 'drawing') {
      const bounds = boundsOf(recessBaseRoom.vertices)
      setRecessDraft({ ...recessDraft, end: bounds ? clampPointToBounds(point, bounds) : point })
      return
    }

    if (groupDrag) {
      const rawDx = round2(point.x - groupDrag.start.x)
      const rawDy = round2(point.y - groupDrag.start.y)
      const drag = event.shiftKey ? constrainDragToAxis(rawDx, rawDy) : { dx: rawDx, dy: rawDy, axis: null as DragAxis }
      const nextPreview: Record<string, PointM[]> = {}
      groupDrag.originals.forEach(({ room, vertices }) => {
        nextPreview[room.id] = vertices.map((vertex) => clampPoint({ x: round3(vertex.x + drag.dx), y: round3(vertex.y + drag.dy) }))
      })
      setGroupPreview(nextPreview)
      return
    }

    if (roomDrag) {
      const rawDx = round2(point.x - roomDrag.start.x)
      const rawDy = round2(point.y - roomDrag.start.y)
      const drag = event.shiftKey ? constrainDragToAxis(rawDx, rawDy) : { dx: rawDx, dy: rawDy, axis: null as DragAxis }
      let nextVertices = roomDrag.originalVertices.map((vertex) => clampPoint({ x: round2(vertex.x + drag.dx), y: round2(vertex.y + drag.dy) }))
      if (snapEnabled) {
        nextVertices = snapVerticesToRooms(
          nextVertices,
          rooms.filter((room) => room.id !== roomDrag.roomId && (roomLayerAssignments[room.id] ?? defaultLayerId) === activeLayerId).map((room) => ({ room, vertices: room.vertices })),
          snapWallThicknessM,
          drag.axis,
        )
      }
      setRoomPreview({ roomId: roomDrag.roomId, vertices: nextVertices })
      return
    }

    if (rectHandleDrag) {
      let nextVertices = resizeRectangleByHandle(rectHandleDrag.originalVertices, rectHandleDrag.handle, point)
      if (snapEnabled) {
        nextVertices = snapVerticesToRooms(
          nextVertices,
          rooms.filter((room) => room.id !== rectHandleDrag.roomId && (roomLayerAssignments[room.id] ?? defaultLayerId) === activeLayerId).map((room) => ({ room, vertices: room.vertices })),
          snapWallThicknessM,
          null,
        )
      }
      setRoomPreview({ roomId: rectHandleDrag.roomId, vertices: nextVertices })
      return
    }

    if (polygonEdgeDrag) {
      const rawDx = round2(point.x - polygonEdgeDrag.start.x)
      const rawDy = round2(point.y - polygonEdgeDrag.start.y)
      const drag = event.shiftKey ? constrainDeltaTo45(rawDx, rawDy) : { dx: rawDx, dy: rawDy }
      const nextVertices = polygonEdgeDrag.originalVertices.map((vertex, index) => {
        const moves = index === polygonEdgeDrag.indexA || index === polygonEdgeDrag.indexB
        return moves ? clampPoint({ x: round2(vertex.x + drag.dx), y: round2(vertex.y + drag.dy) }) : vertex
      })
      setRoomPreview({ roomId: polygonEdgeDrag.roomId, vertices: nextVertices })
      return
    }

    if (vertexDrag) {
      const room = rooms.find((item) => item.id === vertexDrag.roomId)
      if (!room) return
      const nextVertices = room.vertices.map((vertex, index) => index === vertexDrag.index ? point : vertex)
      setRoomPreview({ roomId: vertexDrag.roomId, vertices: nextVertices })
    }
  }

  function startRoomDrag(event: ReactMouseEvent<SVGGElement>, room: Room) {
    if (tool !== 'select') return
    const point = eventToMeters(event)
    if (!point) return
    event.preventDefault()
    event.stopPropagation()
    if (allSelected) {
      const originals = activeLayerRooms.map((item) => ({ room: item, vertices: item.vertices }))
      const preview: Record<string, PointM[]> = {}
      originals.forEach(({ room: item, vertices }) => { preview[item.id] = vertices })
      setGroupDrag({ start: point, originals })
      setGroupPreview(preview)
      return
    }
    if (isOuterWallRoom(room)) {
      const layerId = roomLayerAssignments[room.id] ?? defaultLayerId
      const originals = rooms.filter((item) => (roomLayerAssignments[item.id] ?? defaultLayerId) === layerId).map((item) => ({ room: item, vertices: item.vertices }))
      const preview: Record<string, PointM[]> = {}
      originals.forEach(({ room: item, vertices }) => { preview[item.id] = vertices })
      setAllSelected(false)
      onSelectRoom(room.id)
      setGroupDrag({ start: point, originals })
      setGroupPreview(preview)
      return
    }
    setAllSelected(false)
    onSelectRoom(room.id)
    setRoomDrag({ roomId: room.id, start: point, originalVertices: room.vertices })
    setRoomPreview({ roomId: room.id, vertices: room.vertices })
  }

  function startRectHandleDrag(event: ReactMouseEvent<SVGLineElement>, room: Room, handle: RectHandle) {
    if (tool !== 'select' || room.shapeType !== 'rectangle') return
    event.preventDefault()
    event.stopPropagation()
    onSelectRoom(room.id)
    setRectHandleDrag({ roomId: room.id, handle, originalVertices: room.vertices })
    setRoomPreview({ roomId: room.id, vertices: room.vertices })
  }

  function startVertexDrag(event: ReactMouseEvent<SVGCircleElement>, room: Room, index: number) {
    if (tool !== 'select' || room.shapeType !== 'polygon') return
    event.preventDefault()
    event.stopPropagation()
    onSelectRoom(room.id)
    setVertexDrag({ roomId: room.id, index })
    setRoomPreview({ roomId: room.id, vertices: room.vertices })
  }

  function startPolygonEdgeDrag(event: ReactMouseEvent<SVGLineElement>, room: Room, index: number) {
    if (tool !== 'select' || room.shapeType !== 'polygon') return
    const point = eventToMeters(event)
    if (!point) return
    event.preventDefault()
    event.stopPropagation()
    onSelectRoom(room.id)
    const nextIndex = (index + 1) % room.vertices.length
    setPolygonEdgeDrag({ roomId: room.id, indexA: index, indexB: nextIndex, start: point, originalVertices: room.vertices })
    setRoomPreview({ roomId: room.id, vertices: room.vertices })
  }

  async function handleMouseUp() {
    if (dimensionDrag) {
      setDimensionDrag(null)
      return
    }
    if (titleDrag) {
      setTitleDrag(null)
      return
    }
    if (panDragRef.current) {
      suppressCanvasClickRef.current = panDragRef.current.moved
      panDragRef.current = null
      return
    }
    if (recessHandleDrag) {
      setRecessHandleDrag(null)
      return
    }
    if (groupDrag) {
      const preview = groupPreview
      const originals = groupDrag.originals
      setGroupDrag(null)
      setGroupPreview({})
      const changed = originals.some(({ vertices, room }) => maxPointDelta(vertices, preview[room.id] ?? vertices) > 0.005)
      if (changed) {
        onCaptureUndoSnapshot()
        await Promise.all(originals.map(({ room, vertices }) => {
          const nextVertices = preview[room.id] ?? vertices
          return onPersistRoom({ ...room, vertices: nextVertices, areaM2: polygonAreaM2(nextVertices) })
        }))
      }
      return
    }
    const activeRoomId = roomDrag?.roomId ?? rectHandleDrag?.roomId ?? polygonEdgeDrag?.roomId ?? vertexDrag?.roomId ?? ''
    if (activeRoomId && roomPreview?.roomId === activeRoomId) {
      const room = rooms.find((item) => item.id === activeRoomId)
      const original = roomDrag?.originalVertices ?? rectHandleDrag?.originalVertices ?? polygonEdgeDrag?.originalVertices ?? room?.vertices ?? []
      const moved = maxPointDelta(original, roomPreview.vertices) > 0.005
      setRoomDrag(null)
      setRectHandleDrag(null)
      setVertexDrag(null)
      setPolygonEdgeDrag(null)
      setRoomPreview(null)
      if (room && moved) {
        onCaptureUndoSnapshot()
        const nextShape = room.shapeType === 'rectangle' && rectHandleDrag ? 'rectangle' : room.shapeType
        await onPersistRoom({ ...room, shapeType: nextShape, vertices: roomPreview.vertices, areaM2: polygonAreaM2(roomPreview.vertices) })
      }
      return
    }
    setRoomDrag(null)
    setRectHandleDrag(null)
    setVertexDrag(null)
    setPolygonEdgeDrag(null)
    setRoomPreview(null)
  }

  function beginStairPanelMove(event: ReactMouseEvent<HTMLElement>) {
    if ((event.target as HTMLElement).closest('button, input, select, .stair-panel-resize-handle, .stair-editor-body, .stair-editor-properties, .stair-editor-library')) return
    event.preventDefault()
    event.stopPropagation()
    setStairPanelDrag({ mode: 'move', startClientX: event.clientX, startClientY: event.clientY, startRect: stairPanelRect })
  }

  function beginStairPanelResize(event: ReactMouseEvent<HTMLDivElement>) {
    event.preventDefault()
    event.stopPropagation()
    setStairPanelDrag({ mode: 'resize', startClientX: event.clientX, startClientY: event.clientY, startRect: stairPanelRect })
  }

  async function confirmStairRoom() {
    if (!selectedRoom || isOuterWallRoom(selectedRoom)) {
      setStairPanelOpen(false)
      return
    }
    try {
      if (!isStairRoom(selectedRoom)) {
        onError(null)
        onCaptureUndoSnapshot()
        await onPersistRoom({ ...selectedRoom, roomType: 'stair' })
      }
      onSelectRoom(selectedRoom.id)
      setTool('select')
      setStairPanelOpen(false)
    } catch (err) {
      onError(err instanceof Error ? err.message : String(err))
      await onReload()
    }
  }

  async function chooseTool(nextTool: Tool) {
    if (nextTool === 'recess' && !selectedRoom) return
    if (nextTool === 'stair') {
      if (!selectedRoom || isOuterWallRoom(selectedRoom)) return
      setTool('stair')
      setRectDraft(null)
      setRecessHandleDrag(null)
      setDistanceFirstEdge(null)
      setDistancePair(null)
      setRecessDraft(null)
      setRecessBaseRoomId('')
      setPolygonDraft([])
      setAllSelected(false)
      setStairPanelOpen(true)
      onSelectRoom(selectedRoom.id)
      return
    }
    setTool(nextTool)
    setRectDraft(null)
    setRecessHandleDrag(null)
    setDistanceFirstEdge(null)
    setDistancePair(null)
    if (nextTool !== 'select') setAllSelected(false)
    if (nextTool === 'distance') onSelectRoom('')
    if (nextTool === 'recess' && selectedRoom) {
      setRecessBaseRoomId(selectedRoom.id)
      setRecessDraft(defaultRecessDraftForRoom(selectedRoom, defaultRecessEdge(selectedRoom)))
      onSelectRoom('')
    } else {
      setRecessDraft(null)
      setRecessBaseRoomId('')
    }
    if (nextTool !== 'polygon') setPolygonDraft([])
  }

  function changeZoom(next: number) {
    const nextZoom = Math.min(2.5, Math.max(0.22, round2(next)))
    setZoom(nextZoom)
    const scroll = canvasScrollRef.current
    if (scroll) saveCanvasViewport(floor.id, { zoom: nextZoom, left: scroll.scrollLeft, top: scroll.scrollTop })
  }

  function changeRecessSize(axis: 'along' | 'depth', value: number) {
    setRecessDraft((current) => current ? {
      ...current,
      phase: current.phase === 'idle' ? 'ready' : current.phase,
      manualAlongM: axis === 'along' ? Math.max(0.05, round2(value)) : current.manualAlongM,
      manualDepthM: axis === 'depth' ? Math.max(0.05, round2(value)) : current.manualDepthM,
    } : current)
  }

  function changeRecessOffset(value: number) {
    setRecessDraft((current) => current ? {
      ...current,
      phase: current.phase === 'idle' ? 'ready' : current.phase,
      manualOffsetM: Math.max(0, round2(value)),
    } : current)
  }

  function changeRecessEdge(edge: RecessEdge) {
    const baseRoom = recessBaseRoom
    if (!baseRoom) return
    setRecessDraft((current) => ({
      ...(current ?? defaultRecessDraftForRoom(baseRoom, edge)),
      edge,
      manualOffsetM: current?.manualOffsetM,
      manualOffsetFromEnd: current?.manualOffsetFromEnd ?? false,
      phase: current?.phase ?? 'idle',
    }))
  }

function toggleRecessOffsetDirection() {
    const baseRoom = recessBaseRoom
    if (!baseRoom) return
    setRecessDraft((current) => {
      if (!current) return current
      const preview = buildRecessPreview(baseRoom, current)
      const bounds = boundsOf(baseRoom.vertices)
      const nextFromEnd = !Boolean(current.manualOffsetFromEnd)
      let nextOffset = current.manualOffsetM ?? 0
      if (preview && bounds) {
        if (preview.edge === 'top' || preview.edge === 'bottom') {
          nextOffset = nextFromEnd ? bounds.maxX - preview.rect.maxX : preview.rect.minX - bounds.minX
        } else {
          nextOffset = nextFromEnd ? bounds.maxY - preview.rect.maxY : preview.rect.minY - bounds.minY
        }
      }
      return {
        ...current,
        manualOffsetFromEnd: nextFromEnd,
        manualOffsetM: Math.max(0, round2(nextOffset)),
        phase: current.phase === 'idle' ? 'ready' : current.phase,
      }
    })
  }

  function cancelRecess() {
    const previousBaseId = recessBaseRoomId
    setRecessDraft(null)
    setRecessHandleDrag(null)
    setRecessBaseRoomId('')
    setTool('select')
    if (previousBaseId) onSelectRoom(previousBaseId)
  }

  function startRecessHandle(event: ReactMouseEvent<SVGLineElement>, handle: RecessHandle) {
    if (!recessDraft) return
    event.preventDefault()
    event.stopPropagation()
    setRecessHandleDrag({ handle, originalDraft: recessDraft })
  }

  function startDimensionDrag(event: ReactMouseEvent<SVGGElement>, roomId: string, line: DimensionLineKey) {
    event.preventDefault()
    event.stopPropagation()
    const current = normalizeDimensionOffset(dimensionOffsets[roomId])
    setDimensionDrag({
      roomId,
      line,
      axis: line === 'xParts' || line === 'xTotal' ? 'horizontal' : 'vertical',
      shiftPair: event.shiftKey,
      startClientX: event.clientX,
      startClientY: event.clientY,
      startOffset: current,
    })
  }

  function selectAllRooms() {
    if (activeLayerRooms.length === 0) return
    setTool('select')
    setAllSelected(true)
    onSelectRoom('')
    setDistanceFirstEdge(null)
    setDistancePair(null)
  }

  async function deleteSelectedFromCanvas() {
    if (allSelected) {
      await deleteActiveLayerRoomsFromCanvas()
      setAllSelected(false)
      return
    }
    if (selectedRoom) await onDeleteSelectedRoom()
  }

  function selectSingleRoom(id: string) {
    setAllSelected(false)
    setDistanceFirstEdge(null)
    setDistancePair(null)
    onSelectRoom(id)
  }

  function startTitleDrag(event: ReactMouseEvent<SVGGElement>, room: Room) {
    if (tool !== 'select' || isOuterWallRoom(room)) return
    if ((roomLayerAssignments[room.id] ?? defaultLayerId) !== activeLayerId) return
    event.preventDefault()
    event.stopPropagation()
    setAllSelected(false)
    onSelectRoom(room.id)
    setTitleDrag({
      roomId: room.id,
      startClientX: event.clientX,
      startClientY: event.clientY,
      startOffset: normalizeTitleOffset(titleOffsets[room.id]),
    })
  }

  function handleDistanceEdgePick(event: ReactMouseEvent<SVGLineElement>, room: Room, vertices: PointM[], edgeIndex: number) {
    if (tool !== 'distance') return
    event.preventDefault()
    event.stopPropagation()
    suppressCanvasClickRef.current = true
    const edge = buildDistanceEdgeSelection(room.id, vertices, edgeIndex)
    if (!edge) return
    if (!distanceFirstEdge) {
      setDistanceFirstEdge(edge)
      setDistancePair(null)
      return
    }
    if (distanceFirstEdge.roomId === edge.roomId) {
      setDistanceFirstEdge(edge)
      setDistancePair(null)
      return
    }
    if (distanceFirstEdge.axis !== edge.axis) {
      onError('Bitte zwei parallele Kanten waehlen: senkrecht zu senkrecht oder waagerecht zu waagerecht.')
      setDistanceFirstEdge(edge)
      setDistancePair(null)
      return
    }
    onError(null)
    setDistancePair({ first: distanceFirstEdge, second: edge, distanceM: Math.abs(edge.coord - distanceFirstEdge.coord) })
  }

  function changeDistanceBetweenEdges(valueM: number) {
    if (!distancePair) return
    const pair = distancePair
    const firstRoom = rooms.find((room) => room.id === pair.first.roomId)
    const secondRoom = rooms.find((room) => room.id === pair.second.roomId)
    if (!firstRoom || !secondRoom) return
    const first = buildDistanceEdgeSelection(firstRoom.id, firstRoom.vertices, pair.first.edgeIndex)
    const second = buildDistanceEdgeSelection(secondRoom.id, secondRoom.vertices, pair.second.edgeIndex)
    if (!first || !second || first.axis !== second.axis) return

    const firstIsOuterWall = isOuterWallRoom(firstRoom)
    const secondIsOuterWall = isOuterWallRoom(secondRoom)
    const safeDistance = Math.max(0, round3(valueM))

    function moveOneEdge(room: Room, edge: DistanceEdgeSelection, fixedEdge: DistanceEdgeSelection): { room: Room; edge: DistanceEdgeSelection } | null {
      const previousCoord = edge.roomId === pair.first.roomId ? pair.first.coord : pair.second.coord
      const sign = Math.sign(edge.coord - fixedEdge.coord) || Math.sign(previousCoord - fixedEdge.coord) || 1
      const targetCoord = round3(fixedEdge.coord + sign * safeDistance)
      const delta = round3(targetCoord - edge.coord)
      if (Math.abs(delta) < 0.0005) return { room, edge }
      const indexA = edge.edgeIndex
      const indexB = (edge.edgeIndex + 1) % room.vertices.length
      const nextVertices = room.vertices.map((point, index) => {
        if (index !== indexA && index !== indexB) return point
        return edge.axis === 'vertical'
          ? clampPoint({ x: round3(point.x + delta), y: point.y })
          : clampPoint({ x: point.x, y: round3(point.y + delta) })
      })
      const nextRoom = { ...room, vertices: nextVertices, areaM2: polygonAreaM2(nextVertices) }
      const nextEdge = buildDistanceEdgeSelection(nextRoom.id, nextVertices, edge.edgeIndex) ?? edge
      return { room: nextRoom, edge: nextEdge }
    }

    if (firstIsOuterWall || secondIsOuterWall) {
      const targetRoom = firstIsOuterWall ? firstRoom : secondRoom
      const targetEdge = firstIsOuterWall ? first : second
      const fixedEdge = firstIsOuterWall ? second : first
      const moved = moveOneEdge(targetRoom, targetEdge, fixedEdge)
      if (!moved) return
      onLiveRoomChange(moved.room)
      setDistancePair({
        first: firstIsOuterWall ? moved.edge : first,
        second: firstIsOuterWall ? second : moved.edge,
        distanceM: safeDistance,
      })
      return
    }

    const sign = Math.sign(second.coord - first.coord) || Math.sign(pair.second.coord - pair.first.coord) || 1
    const targetCoord = round3(first.coord + sign * safeDistance)
    const delta = round3(targetCoord - second.coord)
    const nextVertices = second.axis === 'vertical'
      ? secondRoom.vertices.map((point) => clampPoint({ x: round3(point.x + delta), y: point.y }))
      : secondRoom.vertices.map((point) => clampPoint({ x: point.x, y: round3(point.y + delta) }))
    const nextRoom = { ...secondRoom, vertices: nextVertices, areaM2: polygonAreaM2(nextVertices) }
    onLiveRoomChange(nextRoom)
    const nextSecond = buildDistanceEdgeSelection(secondRoom.id, nextVertices, second.edgeIndex) ?? second
    setDistancePair({ first, second: nextSecond, distanceM: safeDistance })
  }

  function handleCanvasWheel(event: ReactWheelEvent<HTMLDivElement>) {
    event.preventDefault()
    event.stopPropagation()
    const scroll = canvasScrollRef.current
    if (!scroll) return
    const rect = scroll.getBoundingClientRect()
    const mouseX = event.clientX - rect.left
    const mouseY = event.clientY - rect.top
    const beforeZoom = zoom
    const contentX = (scroll.scrollLeft + mouseX) / beforeZoom
    const contentY = (scroll.scrollTop + mouseY) / beforeZoom
    const dominantDelta = Math.abs(event.deltaY) >= Math.abs(event.deltaX) ? event.deltaY : event.deltaX
    if (dominantDelta === 0) return
    const factor = dominantDelta < 0 ? 1.12 : (1 / 1.12)
    const nextZoom = Math.min(2.5, Math.max(0.22, round2(beforeZoom * factor)))
    if (nextZoom === beforeZoom) return
    setZoom(nextZoom)
    window.requestAnimationFrame(() => {
      const nextScroll = canvasScrollRef.current
      if (!nextScroll) return
      nextScroll.scrollLeft = Math.max(0, contentX * nextZoom - mouseX)
      nextScroll.scrollTop = Math.max(0, contentY * nextZoom - mouseY)
      setScrollPosition({ left: nextScroll.scrollLeft, top: nextScroll.scrollTop })
      saveCanvasViewport(floor.id, { zoom: nextZoom, left: nextScroll.scrollLeft, top: nextScroll.scrollTop })
    })
  }

  function handleCanvasScroll() {
    const scroll = canvasScrollRef.current
    if (!scroll) return
    setScrollPosition({ left: scroll.scrollLeft, top: scroll.scrollTop })
    saveCanvasViewport(floor.id, { zoom, left: scroll.scrollLeft, top: scroll.scrollTop })
  }

  function handleCanvasMouseDown(event: ReactMouseEvent<SVGSVGElement>) {
    ;(event.currentTarget as unknown as HTMLElement).focus({ preventScroll: true })
    if (tool !== 'select' || event.button !== 0) return
    if (event.target !== event.currentTarget || !canvasScrollRef.current) return
    panDragRef.current = {
      startX: event.clientX,
      startY: event.clientY,
      scrollLeft: canvasScrollRef.current.scrollLeft,
      scrollTop: canvasScrollRef.current.scrollTop,
      moved: false,
    }
  }

  function centerAllRooms() {
    const allPoints = rooms.flatMap((room) => room.vertices)
    const bounds = boundsOf(allPoints)
    const scroll = canvasScrollRef.current
    if (!bounds || !scroll) return
    const paddedW = Math.max(0.5, bounds.maxX - bounds.minX + 1.2)
    const paddedH = Math.max(0.5, bounds.maxY - bounds.minY + 1.2)
    const fitZoom = Math.min(2.5, Math.max(0.22, Math.min(scroll.clientWidth / (paddedW * canvas.scale), scroll.clientHeight / (paddedH * canvas.scale))))
    setZoom(round2(fitZoom))
    window.requestAnimationFrame(() => {
      const nextScroll = canvasScrollRef.current
      if (!nextScroll) return
      const centerX = (bounds.minX + bounds.maxX) / 2
      const centerY = (bounds.minY + bounds.maxY) / 2
      nextScroll.scrollLeft = Math.max(0, mToX(centerX) * fitZoom - nextScroll.clientWidth / 2)
      nextScroll.scrollTop = Math.max(0, mToY(centerY) * fitZoom - nextScroll.clientHeight / 2)
      setScrollPosition({ left: nextScroll.scrollLeft, top: nextScroll.scrollTop })
      saveCanvasViewport(floor.id, { zoom: round2(fitZoom), left: nextScroll.scrollLeft, top: nextScroll.scrollTop })
    })
  }

  async function deleteActiveLayerRoomsFromCanvas() {
    const targets = activeLayerRooms
    if (targets.length === 0) return
    try {
      onError(null)
      onCaptureUndoSnapshot()
      onSelectRoom('')
      await Promise.all(targets.map((room) => deleteRoom(room.id)))
      setRoomLayerAssignments((current) => {
        const next = { ...current }
        targets.forEach((room) => { delete next[room.id] })
        return next
      })
      await onReload()
    } catch (err) {
      onError(err instanceof Error ? err.message : String(err))
    }
  }

  async function deleteAllRoomsFromCanvas() {
    if (rooms.length === 0) return
    const confirmed = window.confirm(`Wirklich alle ${rooms.length} Elemente im Blueprint loeschen?`)
    if (!confirmed) return
    try {
      onError(null)
      onCaptureUndoSnapshot()
      onSelectRoom('')
      await Promise.all(rooms.map((room) => deleteRoom(room.id)))
      setRoomLayerAssignments({})
      await onReload()
    } catch (err) {
      onError(err instanceof Error ? err.message : String(err))
    }
  }

  function scaleCanvasTo100() {
    const scroll = canvasScrollRef.current
    if (!scroll) {
      setZoom(1)
      return
    }
    const contentCenterX = (scroll.scrollLeft + scroll.clientWidth / 2) / zoom
    const contentCenterY = (scroll.scrollTop + scroll.clientHeight / 2) / zoom
    setZoom(1)
    window.requestAnimationFrame(() => {
      const nextScroll = canvasScrollRef.current
      if (!nextScroll) return
      nextScroll.scrollLeft = Math.max(0, contentCenterX - nextScroll.clientWidth / 2)
      nextScroll.scrollTop = Math.max(0, contentCenterY - nextScroll.clientHeight / 2)
      setScrollPosition({ left: nextScroll.scrollLeft, top: nextScroll.scrollTop })
      saveCanvasViewport(floor.id, { zoom: 1, left: nextScroll.scrollLeft, top: nextScroll.scrollTop })
    })
  }

  function zoomToSelectedRoom() {
    if (!selectedRoom) return
    const bounds = boundsOf(selectedRoom.vertices)
    const scroll = canvasScrollRef.current
    if (!bounds || !scroll) return

    const roomW = Math.max(0.05, bounds.maxX - bounds.minX)
    const roomH = Math.max(0.05, bounds.maxY - bounds.minY)
    const dimOffset = normalizeDimensionOffset(dimensionOffsets[selectedRoom.id])
    const maxDimOffsetM = dimensionsVisible
      ? Math.max(
          Math.abs(dimOffset.xParts),
          Math.abs(dimOffset.xTotal),
          Math.abs(dimOffset.yParts),
          Math.abs(dimOffset.yTotal),
        ) / canvas.scale
      : 0
    const paddingM = dimensionsVisible ? Math.max(0.8, maxDimOffsetM + 0.65) : 0.55
    const paddedW = Math.max(0.5, roomW + paddingM * 2)
    const paddedH = Math.max(0.5, roomH + paddingM * 2)
    const fitZoom = Math.min(
      2.5,
      Math.max(0.22, Math.min(scroll.clientWidth / (paddedW * canvas.scale), scroll.clientHeight / (paddedH * canvas.scale))),
    )
    const nextZoom = round2(fitZoom)
    setZoom(nextZoom)
    window.requestAnimationFrame(() => {
      const nextScroll = canvasScrollRef.current
      if (!nextScroll) return
      const centerX = (bounds.minX + bounds.maxX) / 2
      const centerY = (bounds.minY + bounds.maxY) / 2
      nextScroll.scrollLeft = Math.max(0, mToX(centerX) * nextZoom - nextScroll.clientWidth / 2)
      nextScroll.scrollTop = Math.max(0, mToY(centerY) * nextZoom - nextScroll.clientHeight / 2)
      if (typeof setScrollPosition === 'function') {
        setScrollPosition({ left: nextScroll.scrollLeft, top: nextScroll.scrollTop })
      }
      saveCanvasViewport(floor.id, { zoom: nextZoom, left: nextScroll.scrollLeft, top: nextScroll.scrollTop })
    })
  }

  function cycleLayerVisibilityMode() {
    const order: LayerVisibilityMode[] = ['active', 'adjacentGhostNoDims', 'adjacentGhostDims', 'allGhostNoDims']
    const index = order.indexOf(layerVisibilityMode)
    setLayerVisibilityMode(order[(index + 1) % order.length])
  }

  function createLayerFromStairEditor(name: string) {
    const cleanedName = name.trim() || `Ebene ${layers.length + 1}`
    const existingNames = new Set(layers.map((layer) => layer.name.trim().toLowerCase()))
    let finalName = cleanedName
    let suffix = 2
    while (existingNames.has(finalName.trim().toLowerCase())) {
      finalName = `${cleanedName} ${suffix}`
      suffix += 1
    }
    const layer: FloorplanLayer = { id: `layer-${Date.now()}`, name: finalName, visible: true }
    setLayers((current) => [...current, layer])
    setActiveLayerId(layer.id)
    setLayerVisibilityMode('active')
    return layer
  }

  function addLayer() {
    const layer: FloorplanLayer = { id: `layer-${Date.now()}`, name: `Ebene ${layers.length + 1}`, visible: true }
    setLayers((current) => [...current, layer])
    setActiveLayerId(layer.id)
    setLayerVisibilityMode('active')
  }

  function selectLayer(id: string) {
    setActiveLayerId(id)
    setAllSelected(false)
    onSelectRoom('')
    setDistanceFirstEdge(null)
    setDistancePair(null)
  }

  function toggleLayerVisibility(id: string) {
    setLayers((current) => current.map((layer) => layer.id === id ? { ...layer, visible: !layer.visible } : layer))
  }

  function renameLayer(id: string, name: string) {
    setLayers((current) => current.map((layer) => layer.id === id ? { ...layer, name } : layer))
  }

  function requestDeleteActiveLayer() {
    if (layers.length <= 1) return
    setLayerDeleteRequestId(activeLayer.id)
  }

  async function confirmDeleteRequestedLayer() {
    if (layers.length <= 1 || !layerDeleteRequestId) return
    const layer = layers.find((item) => item.id === layerDeleteRequestId)
    if (!layer) {
      setLayerDeleteRequestId('')
      return
    }
    const targetRooms = rooms.filter((room) => (roomLayerAssignments[room.id] ?? defaultLayerId) === layer.id)
    const remaining = layers.filter((item) => item.id !== layer.id)
    const oldIndex = layers.findIndex((item) => item.id === layer.id)
    const fallback = remaining[Math.max(0, Math.min(remaining.length - 1, oldIndex - 1))] ?? remaining[0]
    try {
      onError(null)
      onCaptureUndoSnapshot()
      setLayerDeleteRequestId('')
      setAllSelected(false)
      onSelectRoom('')
      await Promise.all(targetRooms.map((room) => deleteRoom(room.id)))
      setLayers(remaining)
      setActiveLayerId(fallback.id)
      setRoomLayerAssignments((current) => {
        const next = { ...current }
        targetRooms.forEach((room) => { delete next[room.id] })
        Object.entries(next).forEach(([roomId, layerId]) => {
          if (layerId === layer.id) delete next[roomId]
        })
        return next
      })
      setTitleOffsets((current) => {
        const next = { ...current }
        targetRooms.forEach((room) => { delete next[room.id] })
        return next
      })
      await onReload()
    } catch (err) {
      onError(err instanceof Error ? err.message : String(err))
      await onReload()
    }
  }

  function moveLayerBefore(dragId: string, targetId: string) {
    if (!dragId || dragId === targetId) return
    setLayers((current) => {
      const moving = current.find((layer) => layer.id === dragId)
      if (!moving) return current
      const without = current.filter((layer) => layer.id !== dragId)
      const targetIndex = without.findIndex((layer) => layer.id === targetId)
      if (targetIndex < 0) return current
      const next = [...without]
      next.splice(targetIndex, 0, moving)
      return next
    })
  }

  const hintText = tool === 'select'
    ? 'Auswahlmodus: Raum anklicken und ziehen. Leere Flaeche ziehen verschiebt die Ansicht. Mausrad scrollt, Shift+Mausrad zoomt. Shift haelt Bewegungen waagerecht, senkrecht oder 45 Grad.'
    : tool === 'rectangle'
      ? 'Rechteck: erster Klick setzt die Ecke, Maus aufziehen, zweiter Klick speichert und waehlt den Raum. Eigenschaften oben bearbeiten.'
      : tool === 'outerwall'
        ? 'Aussenwand: wie ein Rechteck aufziehen. Keine Raumflaeche, keine Raumbeschriftung. Beim Verschieben wandern alle Objekte mit.'
        : tool === 'polygon'
        ? 'Polygon: Punkte klicken, Doppelklick oder Startpunkt schliesst. Shift rastet den naechsten Punkt waagerecht, senkrecht oder 45 Grad ein. Ruecktaste entfernt den letzten Punkt.'
        : tool === 'recess'
          ? 'Aussparung: zeichnen oder Werte im Fenster setzen. Andere Objekte sind bis OK gesperrt.'
          : tool === 'stair'
            ? 'Treppe einzeichnen: OK bestaetigt die Umwandlung des ausgewaehlten Objekts in einen Treppenraum.'
            : 'Abstand: erste Kante waehlen, zweite parallele Kante eines anderen Objekts waehlen, Abstand in mm eingeben.'

  const editorPropertiesMode: EditorPropertiesMode = tool === 'rectangle'
    ? { kind: 'rectDraft', rectInput, rectPreview, rectDraft }
    : tool === 'outerwall'
      ? { kind: 'outerWallDraft', rectInput, rectPreview, rectDraft }
      : tool === 'polygon'
      ? { kind: 'polygonDraft', polygonName, polygonWallThicknessM, polygonDraft }
      : allSelected && activeLayerRooms.length > 0
        ? { kind: 'multi', rooms: activeLayerRooms }
        : selectedRoom
          ? { kind: 'selected', room: selectedRoom }
          : { kind: 'empty' }

  const layerDeleteRequest = layers.find((layer) => layer.id === layerDeleteRequestId) ?? null
  const layerDeleteRoomCount = layerDeleteRequest
    ? rooms.filter((room) => (roomLayerAssignments[room.id] ?? defaultLayerId) === layerDeleteRequest.id).length
    : 0

  function effectiveLayerState(layerId: string) {
    return renderStateForLayer(layerId)
  }

  return (
    <div className="floorplan-layout">
      <div className="canvas-toolbar-row">
        <div className="canvas-toolbox" aria-label="Blueprint Werkzeuge">
          <button title="Letzte Aktion rueckgaengig" data-tooltip="Rueckgaengig" aria-label="Letzte Aktion rueckgaengig" disabled={!canUndo} onMouseDown={(event) => event.preventDefault()} onClick={onUndo}>↶</button>
          {(['select', 'rectangle', 'outerwall', 'polygon'] as Tool[]).map((item) => (
            <button key={item} title={toolLabel(item)} data-tooltip={toolLabel(item)} aria-label={toolLabel(item)} className={tool === item ? 'active' : ''} onMouseDown={(event) => event.preventDefault()} onClick={() => void chooseTool(item)}>
              {toolIcon(item)}
            </button>
          ))}
          <button title="Alle Elemente der aktuellen Ebene auswaehlen" data-tooltip="Alle auswaehlen" aria-label="Alle Elemente der aktuellen Ebene auswaehlen" disabled={activeLayerRooms.length === 0} className={allSelected ? 'active' : ''} onMouseDown={(event) => event.preventDefault()} onClick={selectAllRooms}>▣</button>
          <button title="Abstand zwischen zwei Kanten einstellen" data-tooltip="Abstand einstellen" aria-label="Abstand einstellen" className={tool === 'distance' ? 'active' : ''} disabled={rooms.length < 2} onMouseDown={(event) => event.preventDefault()} onClick={() => void chooseTool('distance')}>⇔</button>
          <button title="Aussparung / Wandvorsprung subtraktiv einzeichnen" data-tooltip="Aussparung / Wandvorsprung" aria-label="Aussparung" className={tool === 'recess' ? 'active' : ''} disabled={!selectedRoom && tool !== 'recess'} onMouseDown={(event) => event.preventDefault()} onClick={() => void chooseTool('recess')}>
            ▱
          </button>
          <button title="Treppe einzeichnen" data-tooltip="Treppe einzeichnen" aria-label="Treppe einzeichnen" className={tool === 'stair' ? 'active' : ''} disabled={!selectedRoom || isOuterWallRoom(selectedRoom)} onMouseDown={(event) => event.preventDefault()} onClick={() => void chooseTool('stair')}>⇵</button>
          <button title="Ausgewaehlten Raum loeschen" data-tooltip="Loeschen" aria-label="Ausgewaehlten Raum loeschen" disabled={!selectedRoom && !allSelected} onMouseDown={(event) => event.preventDefault()} onClick={() => void deleteSelectedFromCanvas()}>
            🗑
          </button>
          <button title="Alle Elemente loeschen" data-tooltip="Alle loeschen" aria-label="Alle Elemente loeschen" disabled={rooms.length === 0} onMouseDown={(event) => event.preventDefault()} onClick={() => void deleteAllRoomsFromCanvas()}> 
            🧹
          </button>
          <span className="tool-divider" />
          <label className="snap-control" title="Objekte beim Verschieben andocken">
            <input type="checkbox" checked={snapEnabled} onChange={(event) => setSnapEnabled(event.target.checked)} />
            ↔
          </label>
          <label className="wall-control" title="Wandstaerke fuer Andocken">
            W
            <input type="number" step="0.01" min="0" value={snapWallThicknessM} onChange={(event) => setSnapWallThicknessM(toNumber(event.target.value, 0))} />
          </label>
          <span className="tool-divider" />
          <button title="Verkleinern" data-tooltip="Zoom verkleinern" aria-label="Canvas verkleinern" onMouseDown={(event) => event.preventDefault()} onClick={() => changeZoom(zoom - 0.15)}>−</button>
          <button title="Scale to 100%" data-tooltip="Scale 100%" aria-label="Scale to 100%" className={Math.abs(zoom - 1) < 0.001 ? 'active' : ''} onMouseDown={(event) => event.preventDefault()} onClick={scaleCanvasTo100}>1:1</button>
          <span className="canvas-zoom-level" aria-label="Zoomstufe">{Math.round(zoom * 100)}%</span>
          <button title="Vergroessern" data-tooltip="Zoom vergroessern" aria-label="Canvas vergroessern" onMouseDown={(event) => event.preventDefault()} onClick={() => changeZoom(zoom + 0.15)}>+</button>
          <button title="Alle Elemente zentrieren" data-tooltip="Center all" aria-label="Alle Elemente zentrieren" disabled={rooms.length === 0} onMouseDown={(event) => event.preventDefault()} onClick={centerAllRooms}>⛶</button>
          <button title="Auf ausgewaehltes Objekt zoomen" data-tooltip="Auswahl zoomen" aria-label="Auf ausgewaehltes Objekt zoomen" disabled={!selectedRoom} onMouseDown={(event) => event.preventDefault()} onClick={zoomToSelectedRoom}>⌖</button>
          <button title="Technische Bemassung an/aus" data-tooltip="Technische Bemassung" aria-label="Technische Bemassung umschalten" className={dimensionsVisible ? 'active' : ''} onMouseDown={(event) => event.preventDefault()} onClick={() => setDimensionsVisible((current) => !current)}>⌁</button>
          <button title={visibilityModeLabel(layerVisibilityMode)} data-tooltip={visibilityModeLabel(layerVisibilityMode)} aria-label="Ebenen-Sichtbarkeit umschalten" onMouseDown={(event) => event.preventDefault()} onClick={cycleLayerVisibilityMode}>{visibilityModeIcon(layerVisibilityMode)}</button>
        </div>
      </div>
      <EditorPropertiesTopBar
        mode={editorPropertiesMode}
        onRectInputChange={setRectInput}
        onRectDraftChange={setRectDraft}
        onPolygonNameChange={setPolygonName}
        onPolygonWallThicknessChange={setPolygonWallThicknessM}
        onLiveRoomChange={onLiveRoomChange}
      />

      <div className="canvas-card">
        <div className={`canvas-layer-menu ${layersOpen ? 'open' : ''}`} aria-label="Ebenen">
          <button type="button" title="Ebenen" onClick={() => setLayersOpen((current) => !current)}>☰ {activeLayer.name}</button>
          {layersOpen && (
            <div className="layer-menu-panel">
              <div className="layer-list">
                {layers.map((layer) => {
                  const active = layer.id === activeLayerId
                  const effectiveState = effectiveLayerState(layer.id)
                  const effectivelyVisible = effectiveState.visible
                  return (
                    <div
                      key={layer.id}
                      className={`layer-row ${active ? 'active' : ''} ${effectivelyVisible ? 'effectively-visible' : 'effectively-hidden'} ${effectiveState.ghost ? 'preview-visible' : ''}`}
                      draggable={false}
                      onClick={() => selectLayer(layer.id)}
                      onDragOver={(event) => event.preventDefault()}
                      onDrop={(event) => { event.preventDefault(); moveLayerBefore(draggedLayerId, layer.id); setDraggedLayerId('') }}
                    >
                      <button type="button" className={`layer-eye ${effectivelyVisible ? 'visible' : 'hidden'}`} title={effectivelyVisible ? 'Ebene aktuell sichtbar - klicken zum manuellen Ausblenden' : 'Ebene aktuell ausgeblendet - klicken zum manuellen Einblenden'} onClick={(event) => { event.stopPropagation(); toggleLayerVisibility(layer.id) }}>{effectivelyVisible ? '👁' : '◌'}</button>
                      <input
                        aria-label="Ebenenname"
                        draggable={false}
                        value={layer.name}
                        onMouseDown={(event) => event.stopPropagation()}
                        onClick={(event) => event.stopPropagation()}
                        onDragStart={(event) => event.preventDefault()}
                        onFocus={() => selectLayer(layer.id)}
                        onChange={(event) => renameLayer(layer.id, event.target.value)}
                      />
                      <button
                        type="button"
                        className="layer-grip"
                        title="Ebene verschieben"
                        draggable
                        onClick={(event) => event.stopPropagation()}
                        onDragStart={(event) => { event.dataTransfer.effectAllowed = 'move'; setDraggedLayerId(layer.id) }}
                        onDragEnd={() => setDraggedLayerId('')}
                        onMouseDown={(event) => event.stopPropagation()}
                      >⋮⋮</button>
                    </div>
                  )
                })}
              </div>
              <div className="layer-menu-actions" aria-label="Ebenenaktionen">
                <button type="button" className="layer-add round-icon" title="Neue Ebene" aria-label="Neue Ebene" onClick={addLayer}>＋</button>
                <button type="button" className="layer-delete round-icon" title="Ausgewaehlte Ebene loeschen" aria-label="Ausgewaehlte Ebene loeschen" disabled={layers.length <= 1} onClick={requestDeleteActiveLayer}>🗑</button>
              </div>
            </div>
          )}
        </div>
        {layerDeleteRequest && (
          <div className="modal-backdrop layer-delete-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) setLayerDeleteRequestId('') }}>
            <section className="confirm-modal layer-delete-modal" role="dialog" aria-modal="true" aria-label="Ebene loeschen bestaetigen">
              <h2>Ebene loeschen?</h2>
              <p>Die Ebene <strong>{layerDeleteRequest.name}</strong> wird geloescht.</p>
              {layerDeleteRoomCount > 0 && <p className="warning-text">Achtung: Dabei werden auch alle {layerDeleteRoomCount} Objekte auf dieser Ebene geloescht.</p>}
              {layerDeleteRoomCount === 0 && <p>Auf dieser Ebene befinden sich keine Objekte.</p>}
              <div className="button-row">
                <button type="button" onClick={() => setLayerDeleteRequestId('')}>Abbrechen</button>
                <button type="button" className="danger" onClick={() => void confirmDeleteRequestedLayer()}>Ja, Ebene loeschen</button>
              </div>
            </section>
          </div>
        )}

        {tool === 'distance' && distancePair && (
          <DistanceFloatingPanel
            pair={distancePair}
            onDistanceChange={changeDistanceBetweenEdges}
            onClose={() => { setDistancePair(null); setDistanceFirstEdge(null) }}
          />
        )}
        {tool === 'recess' && recessBaseRoom && (
          <div className="canvas-settings recess-help">
            <strong>Aussparung</strong>
            <span>In den ausgewaehlten Raum zeichnen. Eine Seite dockt automatisch an den naechsten Rand an.</span>
          </div>
        )}

        {tool === 'recess' && recessBaseRoom && recessDraft && (
          <RecessFloatingPanel
            preview={recessPreview}
            edge={recessDraft.edge ?? defaultRecessEdge(recessBaseRoom)}
            isRectangle={recessBaseRoom.shapeType === 'rectangle'}
            fallbackAlong={recessDraft.manualAlongM ?? 0.5}
            fallbackDepth={recessDraft.manualDepthM ?? 0.5}
            offsetM={recessPreview && recessBaseRoom ? offsetFromPreview(recessBaseRoom, recessPreview) : (recessDraft.manualOffsetM ?? 0)}
            offsetFromEnd={Boolean(recessDraft.manualOffsetFromEnd)}
            onEdgeChange={changeRecessEdge}
            onAlongChange={(value) => changeRecessSize('along', value)}
            onDepthChange={(value) => changeRecessSize('depth', value)}
            onOffsetChange={changeRecessOffset}
            onOffsetDirectionToggle={toggleRecessOffsetDirection}
            onApply={() => void finishRecess(recessPreview)}
            onCancel={cancelRecess}
          />
        )}

        <CanvasRulers zoom={zoom} scrollLeft={scrollPosition.left} scrollTop={scrollPosition.top} />
        <div className="canvas-scroll" ref={canvasScrollRef} onWheelCapture={handleCanvasWheel} onScroll={handleCanvasScroll}>
          <svg
            className={`canvas floorplan-canvas ${tool === 'select' ? 'select-mode' : ''}`}
            style={{
              width: `${canvas.width * zoom}px`,
              height: `${canvas.height * zoom}px`,
              '--floorplan-text-size': `${14.7 / zoom}px`,
              '--floorplan-small-text-size': `${12.8 / zoom}px`,
              '--floorplan-label-stroke': `${4.4 / zoom}px`,
              '--floorplan-handle-radius': `${10 / zoom}px`,
              '--floorplan-anchor-radius': `${2.4 / zoom}px`,
              '--floorplan-handle-stroke': `${2 / zoom}px`,
            } as CSSProperties}
            viewBox={`0 0 ${canvas.width} ${canvas.height}`}
            role="img"
            aria-label="Blueprint Editor"
            tabIndex={0}
            onClick={handleCanvasClick}
            onDoubleClick={handleCanvasDoubleClick}
            onMouseMove={handleMouseMove}
            onMouseUp={() => void handleMouseUp()}
            onMouseLeave={() => void handleMouseUp()}
            onMouseDown={handleCanvasMouseDown}
          >
            <Grid />
            <rect x={mToX(canvas.minM)} y={mToY(canvas.minM)} width={(canvas.maxM - canvas.minM) * canvas.scale} height={(canvas.maxM - canvas.minM) * canvas.scale} className="workspace-boundary" />

            {renderedRooms.map(({ room, vertices, renderState }) => {
              const isActiveLayerRoom = renderState.interactive
              const selected = tool !== 'recess' && isActiveLayerRoom && (allSelected || room.id === selectedRoomId)
              const showTechnicalDimensions = dimensionsVisible && !allSelected && renderState.dimensions
              return (
                <g key={room.id} className={`layer-room-wrap ${renderState.ghost ? 'ghost-layer' : ''}`} style={{ pointerEvents: isActiveLayerRoom ? 'auto' : 'none', opacity: renderState.ghost ? 0.5 : 1 } as CSSProperties}>
                  <RoomShape
                    room={room}
                    vertices={vertices}
                    selected={selected}
                    interactive={tool === 'select' && isActiveLayerRoom}
                    distanceMode={tool === 'distance' && isActiveLayerRoom}
                    distanceFirstEdge={distanceFirstEdge}
                    distancePair={distancePair}
                    onStartDrag={startRoomDrag}
                    onSelect={tool === 'recess' || !isActiveLayerRoom ? () => undefined : selectSingleRoom}
                    onStartRectHandle={startRectHandleDrag}
                    onStartVertexDrag={startVertexDrag}
                    onStartPolygonEdgeDrag={startPolygonEdgeDrag}
                    onPickDistanceEdge={handleDistanceEdgePick}
                    titleOffset={normalizeTitleOffset(titleOffsets[room.id])}
                    onStartTitleDrag={startTitleDrag}
                    ghost={renderState.ghost}
                  />
                  {tool === 'select' && showTechnicalDimensions && !isOuterWallRoom(room) && room.id !== selectedRoomId && <TechnicalDimensions vertices={vertices} zoom={zoom} offset={normalizeDimensionOffset(dimensionOffsets[room.id])} onStartDrag={isActiveLayerRoom ? (event, line) => startDimensionDrag(event, room.id, line) : undefined} />}
                  {tool === 'select' && showTechnicalDimensions && isOuterWallRoom(room) && <OuterWallDimensions vertices={vertices} />}
                </g>
              )
            })}

            <BlueprintWallObjectConnections wallObjects={blueprintWallObjects} rooms={rooms} />

            {rectPreview && (
              <g className={`draft-shape ${tool === 'outerwall' ? 'outer-wall-draft' : ''}`}>
                <rect x={mToX(rectPreview.minX)} y={mToY(rectPreview.minY)} width={rectPreview.width * canvas.scale} height={rectPreview.height * canvas.scale} />
                {tool !== 'outerwall' && <DimensionLabels vertices={rectangleVertices(rectPreview.minX, rectPreview.minY, rectPreview.width, rectPreview.height)} />}
                {tool !== 'outerwall' && <text x={mToX(rectPreview.minX + rectPreview.width / 2)} y={mToY(rectPreview.minY + rectPreview.height / 2)} textAnchor="middle">{formatM2(rectPreviewArea)}</text>}
              </g>
            )}

            {polygonDraft.length > 0 && (
              <g className="draft-shape polygon-draft">
                <polyline points={pointsToSvg(polygonDraft)} />
                {polygonDraft.map((point, index) => <circle key={index} cx={mToX(point.x)} cy={mToY(point.y)} r="6" />)}
                {cursorPoint && polygonDraft.length > 0 && <line x1={mToX(polygonDraft[polygonDraft.length - 1].x)} y1={mToY(polygonDraft[polygonDraft.length - 1].y)} x2={mToX(cursorPoint.x)} y2={mToY(cursorPoint.y)} />}
                <DimensionLabels vertices={cursorPoint ? [...polygonDraft, cursorPoint] : polygonDraft} />
                {polygonArea > 0.01 && <text x={mToX(centroid(polygonDraft).x)} y={mToY(centroid(polygonDraft).y)} textAnchor="middle">{formatM2(polygonArea)}</text>}
              </g>
            )}

            {recessPreview && (
              <g className="recess-preview">
                <rect x={mToX(recessPreview.rect.minX)} y={mToY(recessPreview.rect.minY)} width={recessPreview.rect.width * canvas.scale} height={recessPreview.rect.height * canvas.scale} />
                {recessDraft?.phase === 'ready' && <>
                  <line className="recess-resize-handle vertical" x1={mToX(recessPreview.rect.minX)} y1={mToY(recessPreview.rect.minY)} x2={mToX(recessPreview.rect.minX)} y2={mToY(recessPreview.rect.maxY)} onMouseDown={(event) => startRecessHandle(event, 'left')} />
                  <line className="recess-resize-handle vertical" x1={mToX(recessPreview.rect.maxX)} y1={mToY(recessPreview.rect.minY)} x2={mToX(recessPreview.rect.maxX)} y2={mToY(recessPreview.rect.maxY)} onMouseDown={(event) => startRecessHandle(event, 'right')} />
                  <line className="recess-resize-handle horizontal" x1={mToX(recessPreview.rect.minX)} y1={mToY(recessPreview.rect.minY)} x2={mToX(recessPreview.rect.maxX)} y2={mToY(recessPreview.rect.minY)} onMouseDown={(event) => startRecessHandle(event, 'top')} />
                  <line className="recess-resize-handle horizontal" x1={mToX(recessPreview.rect.minX)} y1={mToY(recessPreview.rect.maxY)} x2={mToX(recessPreview.rect.maxX)} y2={mToY(recessPreview.rect.maxY)} onMouseDown={(event) => startRecessHandle(event, 'bottom')} />
                </>}
                {recessBaseRoom && !isOuterWallRoom(recessBaseRoom) && <text x={mToX(recessPreview.rect.minX + recessPreview.rect.width / 2)} y={mToY(recessPreview.rect.minY + recessPreview.rect.height / 2)} textAnchor="middle">{formatM(recessPreview.rect.width)} × {formatM(recessPreview.rect.height)}</text>}
                {recessBaseRoom && !isOuterWallRoom(recessBaseRoom) && <DimensionLabels vertices={rectangleVertices(recessPreview.rect.minX, recessPreview.rect.minY, recessPreview.rect.width, recessPreview.rect.height)} />}
                {recessBaseRoom && !isOuterWallRoom(recessBaseRoom) && <RecessOffsetDimension room={recessBaseRoom} preview={recessPreview} />}
              </g>
            )}

            {distanceGuides.length > 0 && (
              <g className="distance-guides">
                {distanceGuides.map((guide, index) => (
                  <g key={index}>
                    <line x1={mToX(guide.from.x)} y1={mToY(guide.from.y)} x2={mToX(guide.to.x)} y2={mToY(guide.to.y)} />
                    <circle cx={mToX(guide.from.x)} cy={mToY(guide.from.y)} r="4" />
                    <circle cx={mToX(guide.to.x)} cy={mToY(guide.to.y)} r="4" />
                    <text x={mToX((guide.from.x + guide.to.x) / 2)} y={mToY((guide.from.y + guide.to.y) / 2) - 8} textAnchor="middle">{formatM(guide.distance)}</text>
                  </g>
                ))}
              </g>
            )}
          </svg>
        </div>
        {stairPanelOpen && selectedRoom && (
          <section
            className={`stair-floating-window ${stairPanelDrag ? 'dragging' : ''}`}
            role="dialog"
            aria-label="Treppenaufgang bearbeiten"
            style={{ left: stairPanelRect.left, top: stairPanelRect.top, width: stairPanelRect.width, height: stairPanelRect.height } as CSSProperties}
          >
            <StairLayoutPanel
              room={selectedRoom}
              rect={stairPanelRect}
              dragging={Boolean(stairPanelDrag)}
              onBeginWindowMove={beginStairPanelMove}
              onBeginWindowResize={beginStairPanelResize}
              onConfirm={() => void confirmStairRoom()}
              layers={layers}
              onCreateLayer={createLayerFromStairEditor}
            />
          </section>
        )}
      </div>
      <div className="canvas-statusbar">{hintText}</div>
    </div>
  )
}


type StairEditorElementKind = 'landing' | 'stair' | 'turn'
type StairEditorTool = 'move' | 'align'
type StairEditorEdge = 'left' | 'right' | 'top' | 'bottom' | 'topLeft' | 'topRight' | 'bottomLeft' | 'bottomRight'
type StairEdgeAssignmentKind = 'current-floor' | 'next-floor'
type StairEditorLibraryKind = StairEditorElementKind | StairEdgeAssignmentKind
type StairFloorEdgeLinkModel = {
  id: string
  kind: StairEdgeAssignmentKind
  edgeIndex: number
  layerId: string
  layerName: string
  labelXM?: number
  labelYM?: number
}

type StairEditorElement = {
  id: string
  kind: StairEditorElementKind
  xM: number
  yM: number
  widthM: number
  heightM: number
  rotationDeg: number
  steps: number
  mirrored?: boolean
}
type StairEditorDrag = {
  elementId: string
  mode: 'move' | 'edge'
  edge?: StairEditorEdge
  startPoint: PointM
  startElement: StairEditorElement
}
type StairEdgeAssignmentDrag = {
  assignmentId: string
  offsetX: number
  offsetY: number
}


type StairLayoutPanelProps = {
  room: Room
  rect: { left: number; top: number; width: number; height: number }
  dragging: boolean
  onBeginWindowMove: (event: ReactMouseEvent<HTMLElement>) => void
  onBeginWindowResize: (event: ReactMouseEvent<HTMLDivElement>) => void
  onConfirm: () => void
  layers: FloorplanLayer[]
  onCreateLayer: (name: string) => FloorplanLayer
}

const stairLibraryItems: { kind: StairEditorLibraryKind; label: string; description: string }[] = [
  { kind: 'landing', label: 'Absatz', description: 'Gerader Zwischenabsatz' },
  { kind: 'stair', label: 'Treppe', description: 'Gerader Treppenlauf mit Stufen' },
  { kind: 'turn', label: 'Biegung', description: '90 Grad Biegung mit Stufenfaecher' },
  { kind: 'current-floor', label: 'Diese Etage', description: 'Kante dieser Etage zuordnen' },
  { kind: 'next-floor', label: 'Naechste Etage', description: 'Kante der naechsten Etage zuordnen' },
]

function normalizeRightAngle(value: number) {
  return ((Math.round(value / 90) * 90) % 360 + 360) % 360
}

function stairKindLabel(kind: StairEditorElementKind) {
  if (kind === 'landing') return 'Absatz'
  if (kind === 'stair') return 'Treppe'
  return 'Biegung'
}

function stairEdgeKindLabel(kind: StairEdgeAssignmentKind) {
  return kind === 'current-floor' ? 'Diese Etage' : 'Naechste Etage'
}

function pointInPolygonForStairPanel(point: PointM, polygon: PointM[]) {
  if (polygon.length < 3) return false
  let inside = false
  for (let i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    const a = polygon[i]
    const b = polygon[j]
    if (!a || !b) continue
    const cross = (point.y - a.y) * (b.x - a.x) - (point.x - a.x) * (b.y - a.y)
    const onSegment = Math.abs(cross) < 0.000001
      && point.x >= Math.min(a.x, b.x) - 0.000001
      && point.x <= Math.max(a.x, b.x) + 0.000001
      && point.y >= Math.min(a.y, b.y) - 0.000001
      && point.y <= Math.max(a.y, b.y) + 0.000001
    if (onSegment) return true
    const intersects = ((a.y > point.y) !== (b.y > point.y)) && (point.x < ((b.x - a.x) * (point.y - a.y)) / ((b.y - a.y) || 1e-9) + a.x)
    if (intersects) inside = !inside
  }
  return inside
}

function stairLayoutStorageKey(roomId: string) {
  return `strom-stair-layout:${roomId}`
}

function readStairLayoutElements(roomId: string): StairEditorElement[] {
  if (typeof window === 'undefined') return []
  try {
    const raw = window.localStorage.getItem(stairLayoutStorageKey(roomId))
    if (!raw) return []
    const parsed = JSON.parse(raw)
    if (!Array.isArray(parsed)) return []
    return parsed
      .filter((item) => item && (item.kind === 'landing' || item.kind === 'stair' || item.kind === 'turn'))
      .map((item) => ({
        id: String(item.id || `stair-loaded-${Math.random().toString(36).slice(2, 8)}`),
        kind: item.kind as StairEditorElementKind,
        xM: Number(item.xM) || 0,
        yM: Number(item.yM) || 0,
        widthM: Math.max(0.12, Number(item.widthM) || 0.4),
        heightM: Math.max(0.12, Number(item.heightM) || 0.4),
        rotationDeg: normalizeRightAngle(Number(item.rotationDeg) || 0),
        steps: Math.max(1, Math.round(Number(item.steps) || 1)),
        mirrored: Boolean(item.mirrored),
      }))
  } catch {
    return []
  }
}

function writeStairLayoutElements(roomId: string, elements: StairEditorElement[]) {
  if (typeof window === 'undefined') return
  try {
    window.localStorage.setItem(stairLayoutStorageKey(roomId), JSON.stringify(elements))
  } catch {
    // Browser-Speicher kann voll oder deaktiviert sein; der Editor bleibt trotzdem benutzbar.
  }
}

function stairEdgeAssignmentsStorageKey(roomId: string) {
  return `strom-stair-edge-assignments:${roomId}`
}

function readStairEdgeAssignments(roomId: string): StairFloorEdgeLinkModel[] {
  if (typeof window === 'undefined') return []
  try {
    const raw = window.localStorage.getItem(stairEdgeAssignmentsStorageKey(roomId))
    if (!raw) return []
    const parsed = JSON.parse(raw)
    if (!Array.isArray(parsed)) return []
    return parsed
      .filter((item) => item && (item.kind === 'current-floor' || item.kind === 'next-floor') && Number.isFinite(Number(item.edgeIndex)))
      .map((item) => {
        const labelXM = Number(item.labelXM)
        const labelYM = Number(item.labelYM)
        return {
          id: String(item.id || `edge-${item.kind}-${Math.random().toString(36).slice(2, 8)}`),
          kind: item.kind as StairEdgeAssignmentKind,
          edgeIndex: Math.max(0, Math.round(Number(item.edgeIndex) || 0)),
          layerId: String(item.layerId || ''),
          layerName: String(item.layerName || ''),
          ...(Number.isFinite(labelXM) && Number.isFinite(labelYM) ? { labelXM, labelYM } : {}),
        }
      })
  } catch {
    return []
  }
}

function writeStairEdgeAssignments(roomId: string, assignments: StairFloorEdgeLinkModel[]) {
  if (typeof window === 'undefined') return
  try {
    window.localStorage.setItem(stairEdgeAssignmentsStorageKey(roomId), JSON.stringify(assignments))
  } catch {
    // Browser-Speicher kann voll oder deaktiviert sein; der Editor bleibt trotzdem benutzbar.
  }
}

function pointToSegmentDistance(point: PointM, a: PointM, b: PointM) {
  const dx = b.x - a.x
  const dy = b.y - a.y
  const lenSq = dx * dx + dy * dy
  if (lenSq <= 0) return Math.hypot(point.x - a.x, point.y - a.y)
  const t = clamp(((point.x - a.x) * dx + (point.y - a.y) * dy) / lenSq, 0, 1)
  const px = a.x + dx * t
  const py = a.y + dy * t
  return Math.hypot(point.x - px, point.y - py)
}


function stairDirectionVector(element: StairEditorElement) {
  const rotation = normalizeRightAngle(element.rotationDeg)
  if (element.kind === 'turn') {
    const x = element.mirrored ? -1 : 1
    if (rotation === 90) return { x: 0, y: 1 }
    if (rotation === 180) return { x: -x, y: 0 }
    if (rotation === 270) return { x: 0, y: -1 }
    return { x, y: 0 }
  }
  if (rotation === 90) return { x: 1, y: 0 }
  if (rotation === 180) return { x: 0, y: 1 }
  if (rotation === 270) return { x: -1, y: 0 }
  return { x: 0, y: -1 }
}

function stairLayoutDirection(elements: StairEditorElement[], bounds: Bounds) {
  const vector = elements.reduce((acc, element) => {
    if (element.kind === 'landing') return acc
    const direction = stairDirectionVector(element)
    const weight = Math.max(1, Math.round(element.steps || 1))
    return { x: acc.x + direction.x * weight, y: acc.y + direction.y * weight }
  }, { x: 0, y: 0 })
  if (Math.abs(vector.x) >= Math.abs(vector.y) && Math.abs(vector.x) > 0.001) return { axis: 'x' as const, sign: vector.x >= 0 ? 1 : -1 }
  if (Math.abs(vector.y) > 0.001) return { axis: 'y' as const, sign: vector.y >= 0 ? 1 : -1 }
  return (bounds.maxX - bounds.minX) >= (bounds.maxY - bounds.minY) ? { axis: 'x' as const, sign: 1 } : { axis: 'y' as const, sign: 1 }
}

function StairBlueprintLayoutOverlay({ room, elements }: { room: Room; elements: StairEditorElement[] }) {
  const bounds = boundsOf(room.vertices)
  if (!bounds || elements.length === 0) return null
  function renderElementSteps(element: StairEditorElement) {
    const count = Math.max(1, Math.round(element.steps || 1))
    if (count <= 1 || element.kind === 'landing') return null
    if (element.kind === 'turn') {
      const origin = element.mirrored
        ? { x: element.xM + element.widthM, y: element.yM + element.heightM }
        : { x: element.xM, y: element.yM + element.heightM }
      return Array.from({ length: Math.min(80, count - 1) }).map((_, index) => {
        const t = (index + 1) / count
        const target = element.mirrored
          ? { x: element.xM + element.widthM * (1 - t), y: element.yM }
          : { x: element.xM + element.widthM * t, y: element.yM }
        return <line key={`bp-turn-step-${element.id}-${index}`} className="stair-blueprint-step turn" x1={mToX(origin.x)} y1={mToY(origin.y)} x2={mToX(target.x)} y2={mToY(target.y)} />
      })
    }
    const rotation = normalizeRightAngle(element.rotationDeg)
    if (rotation === 90 || rotation === 270) {
      return Array.from({ length: Math.min(80, count - 1) }).map((_, index) => {
        const x = element.xM + (element.widthM * (index + 1)) / count
        return <line key={`bp-step-${element.id}-${index}`} className="stair-blueprint-step" x1={mToX(x)} y1={mToY(element.yM)} x2={mToX(x)} y2={mToY(element.yM + element.heightM)} />
      })
    }
    return Array.from({ length: Math.min(80, count - 1) }).map((_, index) => {
      const y = element.yM + (element.heightM * (index + 1)) / count
      return <line key={`bp-step-${element.id}-${index}`} className="stair-blueprint-step" x1={mToX(element.xM)} y1={mToY(y)} x2={mToX(element.xM + element.widthM)} y2={mToY(y)} />
    })
  }
  function renderElementDirection(element: StairEditorElement) {
    if (element.kind === 'landing') return null
    const cx = mToX(element.xM + element.widthM / 2)
    const cy = mToY(element.yM + element.heightM / 2)
    const direction = stairDirectionVector(element)
    const len = Math.max(12, Math.min(element.widthM, element.heightM) * canvas.scale * 0.33)
    const start = { x: cx - direction.x * len, y: cy - direction.y * len }
    const end = { x: cx + direction.x * len, y: cy + direction.y * len }
    const nx = -direction.y
    const ny = direction.x
    const size = len * 0.34
    const head = `M ${end.x - direction.x * size + nx * size * 0.48} ${end.y - direction.y * size + ny * size * 0.48} L ${end.x} ${end.y} L ${end.x - direction.x * size - nx * size * 0.48} ${end.y - direction.y * size - ny * size * 0.48}`
    return <g className="stair-blueprint-direction"><line x1={start.x} y1={start.y} x2={end.x} y2={end.y} /><path d={head} /></g>
  }
  return (
    <g className="stair-blueprint-layout" aria-label="Treppenlayout">
      {elements.map((element) => (
        <g key={element.id} className={`stair-blueprint-element ${element.kind}`}>
          <rect x={mToX(element.xM)} y={mToY(element.yM)} width={element.widthM * canvas.scale} height={element.heightM * canvas.scale} rx="2" />
          {renderElementSteps(element)}
          {renderElementDirection(element)}
          {element.kind !== 'landing' && <text x={mToX(element.xM + element.widthM / 2)} y={mToY(element.yM + element.heightM / 2)} textAnchor="middle" dominantBaseline="middle">{Math.max(1, Math.round(element.steps || 1))} Stufen</text>}
        </g>
      ))}
    </g>
  )
}

function StairBlueprintVisibilityOverlay({ room, elements }: { room: Room; elements: StairEditorElement[] }) {
  const bounds = boundsOf(room.vertices)
  if (!bounds || elements.length === 0) return null
  const direction = stairLayoutDirection(elements, bounds)
  const cleanId = room.id.replace(/[^a-zA-Z0-9_-]/g, '')
  const clipId = `stair-clip-${cleanId}`
  const gradientId = `stair-fade-${cleanId}`
  const minX = bounds.minX
  const maxX = bounds.maxX
  const minY = bounds.minY
  const maxY = bounds.maxY
  const width = Math.max(0.001, maxX - minX)
  const height = Math.max(0.001, maxY - minY)
  const toSvgRect = (left: number, top: number, right: number, bottom: number) => ({ x: mToX(left), y: mToY(top), width: Math.max(0, (right - left) * canvas.scale), height: Math.max(0, (bottom - top) * canvas.scale) })
  let midRect = toSvgRect(minX, minY, maxX, maxY)
  let highRect = toSvgRect(minX, minY, maxX, maxY)
  let gradientProps: { x1: string; y1: string; x2: string; y2: string } = { x1: '0%', y1: '0%', x2: '100%', y2: '0%' }
  if (direction.axis === 'x') {
    const a = direction.sign >= 0 ? minX + width * 0.25 : maxX - width * 0.5
    const b = direction.sign >= 0 ? minX + width * 0.5 : maxX - width * 0.25
    midRect = toSvgRect(Math.min(a, b), minY, Math.max(a, b), maxY)
    highRect = direction.sign >= 0 ? toSvgRect(minX + width * 0.5, minY, maxX, maxY) : toSvgRect(minX, minY, maxX - width * 0.5, maxY)
    gradientProps = direction.sign >= 0 ? { x1: '0%', y1: '0%', x2: '100%', y2: '0%' } : { x1: '100%', y1: '0%', x2: '0%', y2: '0%' }
  } else {
    const a = direction.sign >= 0 ? minY + height * 0.25 : maxY - height * 0.5
    const b = direction.sign >= 0 ? minY + height * 0.5 : maxY - height * 0.25
    midRect = toSvgRect(minX, Math.min(a, b), maxX, Math.max(a, b))
    highRect = direction.sign >= 0 ? toSvgRect(minX, minY + height * 0.5, maxX, maxY) : toSvgRect(minX, minY, maxX, maxY - height * 0.5)
    gradientProps = direction.sign >= 0 ? { x1: '0%', y1: '0%', x2: '0%', y2: '100%' } : { x1: '0%', y1: '100%', x2: '0%', y2: '0%' }
  }
  return (
    <g className="stair-blueprint-visibility" aria-hidden="true">
      <defs>
        <clipPath id={clipId}>
          <polygon points={pointsToSvg(room.vertices)} />
        </clipPath>
        <linearGradient id={gradientId} {...gradientProps}>
          <stop offset="0%" stopColor="#ffffff" stopOpacity="0" />
          <stop offset="100%" stopColor="#ffffff" stopOpacity="0.9" />
        </linearGradient>
      </defs>
      <g clipPath={`url(#${clipId})`}>
        <rect {...midRect} fill={`url(#${gradientId})`} />
        <rect {...highRect} fill="#ffffff" opacity="0.9" />
      </g>
    </g>
  )
}

function StairLayoutPanel({ room, rect, dragging, onBeginWindowMove, onBeginWindowResize, onConfirm, layers, onCreateLayer }: StairLayoutPanelProps) {
  const bounds = useMemo(() => boundsOf(room.vertices), [room.vertices])
  const safeBounds = useMemo(() => {
    const raw = bounds ?? { minX: 0, minY: 0, maxX: 1, maxY: 1 }
    return { ...raw, width: Math.max(0.01, raw.maxX - raw.minX), height: Math.max(0.01, raw.maxY - raw.minY) }
  }, [bounds])
  const [tool, setTool] = useState<StairEditorTool>('move')
  const [zoom, setZoom] = useState(1)
  const [elements, setElements] = useState<StairEditorElement[]>(() => readStairLayoutElements(room.id))
  const [loadedRoomId, setLoadedRoomId] = useState(room.id)
  const [selectedElementId, setSelectedElementId] = useState('')
  const [edgeAssignments, setEdgeAssignments] = useState<StairFloorEdgeLinkModel[]>(() => readStairEdgeAssignments(room.id))
  const [selectedEdgeAssignmentId, setSelectedEdgeAssignmentId] = useState('')
  const [edgeLayerDraftName, setEdgeLayerDraftName] = useState('')
  const [hoverFloorEdge, setHoverFloorEdge] = useState<{ kind: StairEdgeAssignmentKind; edgeIndex: number } | null>(null)
  const [draggedLibraryKind, setDraggedLibraryKind] = useState<StairEditorLibraryKind | null>(null)
  const [stairEditorUndoStack, setStairEditorUndoStack] = useState<Array<{ elements: StairEditorElement[]; edgeAssignments: StairFloorEdgeLinkModel[] }>>([])
  const [drag, setDrag] = useState<StairEditorDrag | null>(null)
  const [edgeAssignmentDrag, setEdgeAssignmentDrag] = useState<StairEdgeAssignmentDrag | null>(null)
  const [snapGuides, setSnapGuides] = useState<{ axis: 'x' | 'y'; value: number }[]>([])
  const svgRef = useRef<SVGSVGElement | null>(null)
  const selectedElement = elements.find((element) => element.id === selectedElementId) ?? null
  const selectedEdgeAssignment = edgeAssignments.find((assignment) => assignment.id === selectedEdgeAssignmentId) ?? null
  const contentBounds = useMemo(() => {
    let minX = safeBounds.minX
    let minY = safeBounds.minY
    let maxX = safeBounds.maxX
    let maxY = safeBounds.maxY
    elements.forEach((element) => {
      const ex1 = Number(element.xM)
      const ey1 = Number(element.yM)
      const ex2 = ex1 + Math.max(0.12, Number(element.widthM) || 0.12)
      const ey2 = ey1 + Math.max(0.12, Number(element.heightM) || 0.12)
      if (![ex1, ey1, ex2, ey2].every(Number.isFinite)) return
      minX = Math.min(minX, ex1)
      minY = Math.min(minY, ey1)
      maxX = Math.max(maxX, ex2)
      maxY = Math.max(maxY, ey2)
    })
    if (![minX, minY, maxX, maxY].every(Number.isFinite) || maxX <= minX || maxY <= minY) return safeBounds
    return { minX, minY, maxX, maxY, width: Math.max(0.01, maxX - minX), height: Math.max(0.01, maxY - minY) }
  }, [elements, safeBounds])
  const marginM = Math.max(0.35, Math.max(contentBounds.width, contentBounds.height) * 0.12)
  const viewWidth = Math.max(0.5, (contentBounds.width + marginM * 2) / zoom)
  const viewHeight = Math.max(0.5, (contentBounds.height + marginM * 2) / zoom)
  const center = { x: (contentBounds.minX + contentBounds.maxX) / 2, y: (contentBounds.minY + contentBounds.maxY) / 2 }
  const viewBox = { x: center.x - viewWidth / 2, y: center.y - viewHeight / 2, width: viewWidth, height: viewHeight }
  const handleSize = Math.max(0.055, Math.min(contentBounds.width || 1, contentBounds.height || 1) * 0.03 / zoom)

  useEffect(() => {
    setElements(readStairLayoutElements(room.id))
    setEdgeAssignments(readStairEdgeAssignments(room.id))
    setSelectedElementId('')
    setSelectedEdgeAssignmentId('')
    setEdgeLayerDraftName('')
    setHoverFloorEdge(null)
    setDrag(null)
    setEdgeAssignmentDrag(null)
    setSnapGuides([])
    setStairEditorUndoStack([])
    setZoom(1)
    setLoadedRoomId(room.id)
  }, [room.id])

  useEffect(() => {
    if (loadedRoomId !== room.id) return
    writeStairLayoutElements(room.id, elements)
  }, [elements, loadedRoomId, room.id])

  useEffect(() => {
    if (loadedRoomId !== room.id) return
    writeStairEdgeAssignments(room.id, edgeAssignments)
  }, [edgeAssignments, loadedRoomId, room.id])


  // 126: robust stair editor tooltips
  useEffect(() => {
    const root = document.querySelector('.stair-floating-window')
    if (!root) return
    const toolLabels: Record<string, string> = {
      move: 'Verschieben',
      rotate: 'Drehen 90 Grad',
      mirror: 'Biegung spiegeln',
      'zoom-out': 'Canvas herauszoomen',
      'zoom-in': 'Canvas hineinzoomen',
      align: 'Linien ausrichten',
      undo: 'Rueckgaengig',
      delete: 'Loeschen',
    }
    root.querySelectorAll<HTMLButtonElement>('button').forEach((button) => {
      const toolKey = button.getAttribute('data-stair-tool') || ''
      const existing = button.getAttribute('data-tooltip') || button.getAttribute('title') || button.getAttribute('aria-label') || ''
      const textLabel = (button.textContent || '').replace(/\s+/g, ' ').trim()
      const label = toolLabels[toolKey] || existing || textLabel
      if (!label) return
      button.setAttribute('title', label)
      button.setAttribute('data-tooltip', label)
      if (!button.getAttribute('aria-label')) button.setAttribute('aria-label', label)
    })
  }, [elements.length, selectedElementId, edgeAssignments.length, selectedEdgeAssignmentId])

  useEffect(() => {
    if (!drag) return
    const activeDrag = drag
    function onMove(event: MouseEvent) {
      const point = svgPointFromClient(event.clientX, event.clientY)
      if (!point) return
      updateDraggedElement(activeDrag, point.x - activeDrag.startPoint.x, point.y - activeDrag.startPoint.y)
    }
    function onUp() {
      setDrag(null)
      setSnapGuides([])
    }
    window.addEventListener('mousemove', onMove)
    window.addEventListener('mouseup', onUp)
    return () => {
      window.removeEventListener('mousemove', onMove)
      window.removeEventListener('mouseup', onUp)
    }
  }, [drag, elements])

  useEffect(() => {
    if (!edgeAssignmentDrag) return
    const activeDrag = edgeAssignmentDrag
    function onMove(event: MouseEvent) {
      const point = svgPointFromClient(event.clientX, event.clientY)
      if (!point) return
      setEdgeAssignments((current) => current.map((assignment) => assignment.id === activeDrag.assignmentId
        ? { ...assignment, labelXM: round3(point.x - activeDrag.offsetX), labelYM: round3(point.y - activeDrag.offsetY) }
        : assignment))
    }
    function onUp() {
      setEdgeAssignmentDrag(null)
    }
    window.addEventListener('mousemove', onMove)
    window.addEventListener('mouseup', onUp)
    return () => {
      window.removeEventListener('mousemove', onMove)
      window.removeEventListener('mouseup', onUp)
    }
  }, [edgeAssignmentDrag, viewBox])


  function svgPointFromClient(clientX: number, clientY: number): PointM | null {
    const svg = svgRef.current
    if (!svg) return null
    const box = svg.getBoundingClientRect()
    if (box.width <= 0 || box.height <= 0) return null
    return {
      x: viewBox.x + ((clientX - box.left) / box.width) * viewBox.width,
      y: viewBox.y + ((clientY - box.top) / box.height) * viewBox.height,
    }
  }

  function pointInsideObject(point: PointM) {
    const eps = 0.0005
    const vertices = room.vertices
    for (let index = 0; index < vertices.length; index += 1) {
      const a = vertices[index]
      const b = vertices[(index + 1) % vertices.length]
      if (!a || !b) continue
      const dx = b.x - a.x
      const dy = b.y - a.y
      const cross = (point.x - a.x) * dy - (point.y - a.y) * dx
      if (Math.abs(cross) > eps) continue
      if (point.x >= Math.min(a.x, b.x) - eps && point.x <= Math.max(a.x, b.x) + eps && point.y >= Math.min(a.y, b.y) - eps && point.y <= Math.max(a.y, b.y) + eps) return true
    }
    return pointInPolygonForStairPanel(point, room.vertices)
  }

  function cornersOf(element: StairEditorElement): PointM[] {
    return rectangleVertices(element.xM, element.yM, element.widthM, element.heightM)
  }

  function elementVisualBounds(element: StairEditorElement) {
    return {
      minX: element.xM,
      maxX: element.xM + element.widthM,
      minY: element.yM,
      maxY: element.yM + element.heightM,
      width: Math.max(0.001, element.widthM),
      height: Math.max(0.001, element.heightM),
      centerX: element.xM + element.widthM / 2,
      centerY: element.yM + element.heightM / 2,
    }
  }

  function elementInsideObject(element: StairEditorElement) {
    return cornersOf(element).every((corner) => pointInsideObject(corner)) && pointInsideObject({ x: element.xM + element.widthM / 2, y: element.yM + element.heightM / 2 })
  }

  function clampElementToBounds(element: StairEditorElement): StairEditorElement {
    const widthM = Math.min(Math.max(0.12, element.widthM), Math.max(0.12, safeBounds.width))
    const heightM = Math.min(Math.max(0.12, element.heightM), Math.max(0.12, safeBounds.height))
    const minX = safeBounds.minX
    const minY = safeBounds.minY
    const maxX = safeBounds.maxX - widthM
    const maxY = safeBounds.maxY - heightM
    const snapBoundary = (value: number, min: number, max: number) => {
      const clamped = clamp(value, min, max)
      if (Math.abs(clamped - min) <= 0.00075) return min
      if (Math.abs(clamped - max) <= 0.00075) return max
      return clamped
    }
    return { ...element, widthM, heightM, rotationDeg: normalizeRightAngle(element.rotationDeg), xM: round3(snapBoundary(element.xM, minX, maxX)), yM: round3(snapBoundary(element.yM, minY, maxY)) }
  }

  function clampElementCenterToObject(element: StairEditorElement): StairEditorElement {
    const next = clampElementToBounds(element)
    const centerPoint = { x: next.xM + next.widthM / 2, y: next.yM + next.heightM / 2 }
    if (pointInsideObject(centerPoint)) return next
    const centered = { ...next, xM: round3(clamp(center.x - next.widthM / 2, safeBounds.minX, safeBounds.maxX - next.widthM)), yM: round3(clamp(center.y - next.heightM / 2, safeBounds.minY, safeBounds.maxY - next.heightM)) }
    return elementInsideObject(centered) ? centered : next
  }

  function normalizedElement(element: StairEditorElement, previous?: StairEditorElement): StairEditorElement {
    let next = {
      ...element,
      widthM: Math.max(0.12, round3(element.widthM)),
      heightM: Math.max(0.12, round3(element.heightM)),
      xM: round3(element.xM),
      yM: round3(element.yM),
      rotationDeg: normalizeRightAngle(element.rotationDeg),
      steps: Math.max(1, Math.round(element.steps || 1)),
    }
    next = clampElementToBounds(next)
    if (elementInsideObject(next)) return next
    if (previous && elementInsideObject(previous)) return previous
    return clampElementCenterToObject(next)
  }

  function defaultElement(kind: StairEditorElementKind, point: PointM): StairEditorElement {
    const maxWidth = Math.max(0.12, safeBounds.width * 0.92)
    const maxHeight = Math.max(0.12, safeBounds.height * 0.92)
    const preferredWidth = kind === 'stair' ? Math.max(0.55, safeBounds.width * 0.32) : Math.max(0.42, safeBounds.width * 0.24)
    const preferredHeight = kind === 'stair' ? Math.max(0.55, safeBounds.height * 0.32) : Math.max(0.42, safeBounds.height * 0.24)
    const defaultWidth = Math.min(preferredWidth, maxWidth)
    const defaultHeight = Math.min(preferredHeight, maxHeight)
    return normalizedElement({
      id: `stair-${kind}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 7)}`,
      kind,
      xM: point.x - defaultWidth / 2,
      yM: point.y - defaultHeight / 2,
      widthM: defaultWidth,
      heightM: defaultHeight,
      rotationDeg: 0,
      steps: kind === 'stair' ? 12 : kind === 'turn' ? 6 : 1,
      mirrored: false,
    })
  }

  function pushStairEditorUndoSnapshot() {
    setStairEditorUndoStack((current) => [...current.slice(-24), { elements: elements.map((element) => ({ ...element })), edgeAssignments: edgeAssignments.map((assignment) => ({ ...assignment })) }])
  }

  function undoStairEditor() {
    setStairEditorUndoStack((current) => {
      const snapshot = current[current.length - 1]
      if (!snapshot) return current
      setElements(snapshot.elements.map((element) => ({ ...element })))
      setEdgeAssignments(snapshot.edgeAssignments.map((assignment) => ({ ...assignment })))
      setSelectedElementId('')
      setSelectedEdgeAssignmentId('')
      setEdgeLayerDraftName('')
      setSnapGuides([])
      setHoverFloorEdge(null)
      return current.slice(0, -1)
    })
  }

  function deleteSelectedStairElement() {
    if (!selectedElement && !selectedEdgeAssignment) return
    pushStairEditorUndoSnapshot()
    if (selectedElement) {
      setElements((current) => current.filter((element) => element.id !== selectedElement.id))
      setSelectedElementId('')
    }
    if (selectedEdgeAssignment) {
      setEdgeAssignments((current) => current.filter((assignment) => assignment.id !== selectedEdgeAssignment.id))
      setSelectedEdgeAssignmentId('')
      setEdgeLayerDraftName('')
    }
    setSnapGuides([])
    setHoverFloorEdge(null)
  }

  function nearestStairFloorEdge(point: PointM): { index: number; a: PointM; b: PointM; distance: number } | null {
    if (room.vertices.length < 2) return null
    let best: { index: number; a: PointM; b: PointM; distance: number } | null = null
    for (let index = 0; index < room.vertices.length; index += 1) {
      const a = room.vertices[index]
      const b = room.vertices[(index + 1) % room.vertices.length]
      if (!a || !b) continue
      const distance = pointToSegmentDistance(point, a, b)
      if (best === null || distance < best.distance) best = { index, a, b, distance }
    }
    return best
  }

  function edgeSnapDistance() {
    return Math.max(0.28, Math.min(viewBox.width, viewBox.height) * 0.18)
  }

  function assignEdge(kind: StairEdgeAssignmentKind, edgeIndex: number) {
    const next: StairFloorEdgeLinkModel = {
      id: `edge-${kind}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 7)}`,
      kind,
      edgeIndex,
      layerId: '',
      layerName: '',
    }
    pushStairEditorUndoSnapshot()
    setEdgeAssignments((current) => [...current.filter((item) => item.kind !== kind), next])
    setSelectedEdgeAssignmentId(next.id)
    setSelectedElementId('')
    setEdgeLayerDraftName('')
    setHoverFloorEdge(null)
  }

  function updateEdgeAssignment(id: string, layerId: string) {
    setSelectedEdgeAssignmentId(id)
    setSelectedElementId('')
    if (layerId === '__new__') {
      pushStairEditorUndoSnapshot()
      setEdgeAssignments((current) => current.map((item) => item.id === id ? { ...item, layerId: '__new__', layerName: '' } : item))
      setEdgeLayerDraftName('')
      return
    }
    const layer = layers.find((item) => item.id === layerId)
    if (!layer) return
    pushStairEditorUndoSnapshot()
    setEdgeAssignments((current) => current.map((item) => item.id === id ? { ...item, layerId: layer.id, layerName: layer.name } : item))
    setEdgeLayerDraftName('')
  }

  function commitEdgeLayerDraft() {
    if (!selectedEdgeAssignment || selectedEdgeAssignment.layerId !== '__new__') return
    const name = edgeLayerDraftName.trim()
    if (!name) return
    const layer = onCreateLayer(name)
    pushStairEditorUndoSnapshot()
    setEdgeAssignments((current) => current.map((item) => item.id === selectedEdgeAssignment.id ? { ...item, layerId: layer.id, layerName: layer.name } : item))
    setSelectedEdgeAssignmentId(selectedEdgeAssignment.id)
    setSelectedElementId('')
    setEdgeLayerDraftName('')
  }

  function renderFloorEdgeHover(edge: { kind: StairEdgeAssignmentKind; edgeIndex: number }) {
    if (room.vertices.length < 2) return null
    const index = ((edge.edgeIndex % room.vertices.length) + room.vertices.length) % room.vertices.length
    const a = room.vertices[index]
    const b = room.vertices[(index + 1) % room.vertices.length]
    if (!a || !b) return null
    return (
      <g className={`stair-editor-edge-hover ${edge.kind}`}>
        <line x1={a.x} y1={a.y} x2={b.x} y2={b.y} />
        <circle cx={a.x} cy={a.y} r={handleSize * 0.95} />
        <circle cx={b.x} cy={b.y} r={handleSize * 0.95} />
        <text className="stair-editor-edge-hover-label" x={(a.x + b.x) / 2} y={(a.y + b.y) / 2} textAnchor="middle">{stairEdgeKindLabel(edge.kind)}</text>
      </g>
    )
  }

  function startEdgeAssignmentBadgeDrag(event: ReactMouseEvent<SVGGElement>, assignment: StairFloorEdgeLinkModel, badge: PointM) {
    event.preventDefault()
    event.stopPropagation()
    const point = svgPointFromClient(event.clientX, event.clientY)
    if (!point) return
    setSelectedEdgeAssignmentId(assignment.id)
    setSelectedElementId('')
    setEdgeLayerDraftName('')
    pushStairEditorUndoSnapshot()
    setEdgeAssignmentDrag({ assignmentId: assignment.id, offsetX: point.x - badge.x, offsetY: point.y - badge.y })
  }

  function renderEdgeAssignment(assignment: StairFloorEdgeLinkModel) {
    if (room.vertices.length < 2) return null
    const index = ((assignment.edgeIndex % room.vertices.length) + room.vertices.length) % room.vertices.length
    const a = room.vertices[index]
    const b = room.vertices[(index + 1) % room.vertices.length]
    if (!a || !b) return null
    const mid = { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 }
    const dx = b.x - a.x
    const dy = b.y - a.y
    const len = Math.hypot(dx, dy) || 1
    const roomCenter = centroid(room.vertices)
    const normals = [
      { x: -dy / len, y: dx / len },
      { x: dy / len, y: -dx / len },
    ]
    const outwardNormal = normals.sort((left, right) => {
      const dl = Math.hypot(mid.x + left.x * 0.4 - roomCenter.x, mid.y + left.y * 0.4 - roomCenter.y)
      const dr = Math.hypot(mid.x + right.x * 0.4 - roomCenter.x, mid.y + right.y * 0.4 - roomCenter.y)
      return dr - dl
    })[0]
    const offset = clamp(Math.min(viewBox.width, viewBox.height) * 0.16, 0.42, 1.35)
    const label = assignment.layerName || (assignment.layerId === '__new__' ? 'Neue Ebene' : 'Ebene waehlen')
    const selected = selectedEdgeAssignmentId === assignment.id
    const badgeWidth = clamp(viewBox.width * 0.22, 1.15, 2.45)
    const badgeHeight = clamp(viewBox.height * 0.05, 0.21, 0.34)
    const defaultBadge = { x: mid.x + outwardNormal.x * offset, y: mid.y + outwardNormal.y * offset }
    const badge = {
      x: clamp(Number.isFinite(assignment.labelXM) ? Number(assignment.labelXM) : defaultBadge.x, viewBox.x + badgeWidth / 2 + 0.04, viewBox.x + viewBox.width - badgeWidth / 2 - 0.04),
      y: clamp(Number.isFinite(assignment.labelYM) ? Number(assignment.labelYM) : defaultBadge.y, viewBox.y + badgeHeight / 2 + 0.04, viewBox.y + viewBox.height - badgeHeight / 2 - 0.04),
    }
    const popupWidth = clamp(viewBox.width * 0.34, 1.8, 3.1)
    const popupHeight = clamp(viewBox.height * 0.17, 0.9, 1.32)
    const popup = {
      x: clamp(badge.x - popupWidth / 2, viewBox.x + 0.02, viewBox.x + viewBox.width - popupWidth - 0.02),
      y: clamp(badge.y + badgeHeight * 1.05, viewBox.y + 0.02, viewBox.y + viewBox.height - popupHeight - 0.02),
    }
    return (
      <g key={assignment.id} className={`stair-editor-edge-assignment ${assignment.kind} ${selected ? 'selected' : ''}`} onMouseDown={(event) => { event.stopPropagation(); setSelectedEdgeAssignmentId(assignment.id); setSelectedElementId('') }}>
        <line className="stair-editor-edge-hit" x1={a.x} y1={a.y} x2={b.x} y2={b.y} />
        <line className="stair-editor-edge-visible" x1={a.x} y1={a.y} x2={b.x} y2={b.y} />
        <circle className="stair-editor-edge-end" cx={a.x} cy={a.y} r={handleSize * 0.9} />
        <circle className="stair-editor-edge-end" cx={b.x} cy={b.y} r={handleSize * 0.9} />
        <g className="stair-editor-edge-badge" transform={`translate(${badge.x} ${badge.y})`} onMouseDown={(event) => startEdgeAssignmentBadgeDrag(event, assignment, badge)}>
          <rect x={-badgeWidth / 2} y={-badgeHeight / 2} width={badgeWidth} height={badgeHeight} rx={badgeHeight * 0.34} />
          <text className="stair-editor-edge-canvas-label" x={0} y={0} textAnchor="middle" dominantBaseline="middle">{stairEdgeKindLabel(assignment.kind)} - {label}</text>
        </g>
        {selected && (
          <foreignObject x={popup.x} y={popup.y} width={popupWidth} height={popupHeight}>
            <div className="stair-editor-edge-select" onMouseDown={(event) => { event.stopPropagation(); setSelectedEdgeAssignmentId(assignment.id); setSelectedElementId('') }} onClick={(event) => { event.stopPropagation(); setSelectedEdgeAssignmentId(assignment.id); setSelectedElementId('') }}>
              <span>{stairEdgeKindLabel(assignment.kind)}</span>
              <strong>{label}</strong>
              <select value={assignment.layerId || ''} onMouseDown={(event) => event.stopPropagation()} onClick={(event) => event.stopPropagation()} onChange={(event) => updateEdgeAssignment(assignment.id, event.target.value)}>
                <option value="" disabled>Ebene waehlen</option>
                {layers.map((layer) => <option key={layer.id} value={layer.id}>{layer.name}</option>)}
                <option value="__new__">Neue Ebene...</option>
              </select>
            </div>
          </foreignObject>
        )}
      </g>
    )
  }

  function addElement(kind: StairEditorElementKind, point: PointM) {
    if (!pointInsideObject(point)) return
    const base = defaultElement(kind, point)
    const scales = [1, 0.85, 0.72, 0.6, 0.5, 0.42, 0.34, 0.28, 0.22]
    let element: StairEditorElement | null = null
    for (const scale of scales) {
      const widthM = Math.max(0.12, base.widthM * scale)
      const heightM = Math.max(0.12, base.heightM * scale)
      const candidate = normalizedElement({
        ...base,
        widthM,
        heightM,
        xM: point.x - widthM / 2,
        yM: point.y - heightM / 2,
      })
      if (elementInsideObject(candidate)) {
        element = candidate
        break
      }
    }
    if (!element) {
      const centered = normalizedElement({
        ...base,
        widthM: Math.max(0.12, Math.min(base.widthM, safeBounds.width * 0.45)),
        heightM: Math.max(0.12, Math.min(base.heightM, safeBounds.height * 0.45)),
        xM: point.x - Math.max(0.12, Math.min(base.widthM, safeBounds.width * 0.45)) / 2,
        yM: point.y - Math.max(0.12, Math.min(base.heightM, safeBounds.height * 0.45)) / 2,
      })
      if (elementInsideObject(centered)) element = centered
    }
    if (!element) return
    pushStairEditorUndoSnapshot()
    setElements((current) => [...current, element])
    setSelectedElementId(element.id)
    setSelectedEdgeAssignmentId('')
    setEdgeLayerDraftName('')
  }

  function updateElement(id: string, update: (element: StairEditorElement) => StairEditorElement) {
    setElements((current) => current.map((element) => element.id === id ? normalizedElement(update(element), element) : element))
  }

  function rotateSelected() {
    if (!selectedElement) return
    pushStairEditorUndoSnapshot()
    updateElement(selectedElement.id, (element) => ({ ...element, rotationDeg: element.rotationDeg + 90 }))
  }

  function mirrorSelected() {
    if (!selectedElement || selectedElement.kind !== 'turn') return
    pushStairEditorUndoSnapshot()
    updateElement(selectedElement.id, (element) => ({ ...element, mirrored: !element.mirrored }))
  }

  function startElementDrag(event: ReactMouseEvent<SVGGElement>, element: StairEditorElement) {
    event.preventDefault()
    event.stopPropagation()
    const point = svgPointFromClient(event.clientX, event.clientY)
    if (!point) return
    setSelectedElementId(element.id)
    setSelectedEdgeAssignmentId('')
    setEdgeLayerDraftName('')
    pushStairEditorUndoSnapshot()
    setDrag({ elementId: element.id, mode: 'move', startPoint: point, startElement: element })
  }

  function startEdgeDrag(event: ReactMouseEvent<SVGLineElement | SVGCircleElement>, element: StairEditorElement, edge: StairEditorEdge) {
    event.preventDefault()
    event.stopPropagation()
    const point = svgPointFromClient(event.clientX, event.clientY)
    if (!point) return
    setSelectedElementId(element.id)
    setSelectedEdgeAssignmentId('')
    setEdgeLayerDraftName('')
    pushStairEditorUndoSnapshot()
    setDrag({ elementId: element.id, mode: 'edge', edge, startPoint: point, startElement: element })
  }

  function updateDraggedElement(activeDrag: StairEditorDrag, dx: number, dy: number) {
    const source = activeDrag.startElement
    let next = source
    if (activeDrag.mode === 'move') next = { ...source, xM: source.xM + dx, yM: source.yM + dy }
    else if (activeDrag.edge === 'left') next = { ...source, xM: source.xM + dx, widthM: source.widthM - dx }
    else if (activeDrag.edge === 'right') next = { ...source, widthM: source.widthM + dx }
    else if (activeDrag.edge === 'top') next = { ...source, yM: source.yM + dy, heightM: source.heightM - dy }
    else if (activeDrag.edge === 'bottom') next = { ...source, heightM: source.heightM + dy }
    else if (activeDrag.edge === 'topLeft') next = { ...source, xM: source.xM + dx, yM: source.yM + dy, widthM: source.widthM - dx, heightM: source.heightM - dy }
    else if (activeDrag.edge === 'topRight') next = { ...source, yM: source.yM + dy, widthM: source.widthM + dx, heightM: source.heightM - dy }
    else if (activeDrag.edge === 'bottomLeft') next = { ...source, xM: source.xM + dx, widthM: source.widthM - dx, heightM: source.heightM + dy }
    else if (activeDrag.edge === 'bottomRight') next = { ...source, widthM: source.widthM + dx, heightM: source.heightM + dy }
    const snapped = snapElement(next, source)
    setSnapGuides(snapped.guides)
    setElements((current) => current.map((element) => element.id === activeDrag.elementId ? normalizedElement(snapped.element, element) : element))
  }

  function snapElement(element: StairEditorElement, previous: StairEditorElement) {
    const guides: { axis: 'x' | 'y'; value: number }[] = []
    let next = clampElementToBounds(element)
    const threshold = 0.075
    const otherElements = elements.filter((item) => item.id !== previous.id)
    const otherBounds = otherElements.map((item) => elementVisualBounds(item))
    const verticalTargets = [safeBounds.minX, safeBounds.minX + safeBounds.width / 2, safeBounds.maxX, ...otherBounds.flatMap((bounds) => [bounds.minX, bounds.centerX, bounds.maxX])]
    const horizontalTargets = [safeBounds.minY, safeBounds.minY + safeBounds.height / 2, safeBounds.maxY, ...otherBounds.flatMap((bounds) => [bounds.minY, bounds.centerY, bounds.maxY])]
    const visual = elementVisualBounds(next)
    const xCandidates = [visual.minX, visual.centerX, visual.maxX]
    const yCandidates = [visual.minY, visual.centerY, visual.maxY]
    let bestX: { distance: number; shift: number; target: number } | null = null
    for (const target of verticalTargets) {
      for (const candidate of xCandidates) {
        const shift = target - candidate
        if (Math.abs(shift) <= threshold && (!bestX || Math.abs(shift) < bestX.distance)) bestX = { distance: Math.abs(shift), shift, target }
      }
    }
    if (bestX) {
      next = { ...next, xM: round3(next.xM + bestX.shift) }
      guides.push({ axis: 'x', value: bestX.target })
    }
    const visualAfterX = elementVisualBounds(next)
    const yCandidatesAfterX = [visualAfterX.minY, visualAfterX.centerY, visualAfterX.maxY]
    let bestY: { distance: number; shift: number; target: number } | null = null
    for (const target of horizontalTargets) {
      for (const candidate of yCandidatesAfterX) {
        const shift = target - candidate
        if (Math.abs(shift) <= threshold && (!bestY || Math.abs(shift) < bestY.distance)) bestY = { distance: Math.abs(shift), shift, target }
      }
    }
    if (bestY) {
      next = { ...next, yM: round3(next.yM + bestY.shift) }
      guides.push({ axis: 'y', value: bestY.target })
    }
    return { element: clampElementToBounds(next), guides }
  }

  function onCanvasDragOver(event: ReactDragEvent<Element>) {
    event.preventDefault()
    event.stopPropagation()
    event.dataTransfer.dropEffect = 'copy'
    const transferRaw = event.dataTransfer.getData('application/x-stair-editor-kind') as StairEditorLibraryKind
    const raw = (draggedLibraryKind ?? transferRaw) as StairEditorLibraryKind
    if (raw !== 'current-floor' && raw !== 'next-floor') {
      setHoverFloorEdge(null)
      return
    }
    const point = svgPointFromClient(event.clientX, event.clientY)
    if (!point) {
      setHoverFloorEdge(null)
      return
    }
    const edge = nearestStairFloorEdge(point)
    setHoverFloorEdge(edge && edge.distance <= edgeSnapDistance() ? { kind: raw, edgeIndex: edge.index } : null)
  }

  function onCanvasDrop(event: ReactDragEvent<Element>) {
    event.preventDefault()
    event.stopPropagation()
    const transferRaw = event.dataTransfer.getData('application/x-stair-editor-kind') as StairEditorLibraryKind
    const raw = (draggedLibraryKind ?? transferRaw) as StairEditorLibraryKind
    setDraggedLibraryKind(null)
    setHoverFloorEdge(null)
    if (!raw || !stairLibraryItems.some((item) => item.kind === raw)) return
    const point = svgPointFromClient(event.clientX, event.clientY)
    if (!point) return
    if (raw === 'current-floor' || raw === 'next-floor') {
      const edge = nearestStairFloorEdge(point)
      if (!edge || edge.distance > edgeSnapDistance()) return
      assignEdge(raw, edge.index)
      return
    }
    if (raw === 'landing' || raw === 'stair' || raw === 'turn') addElement(raw, point)
  }

  function onCanvasWheel(event: ReactWheelEvent<SVGSVGElement>) {
    event.preventDefault()
    event.stopPropagation()
    const factor = event.deltaY < 0 ? 1.1 : 1 / 1.1
    setZoom((current) => clamp(round3(current * factor), 0.45, 3.5))
  }

  function setSelectedPosition(axis: 'x' | 'y', valueFromOriginM: number) {
    if (!selectedElement) return
    updateElement(selectedElement.id, (element) => axis === 'x' ? { ...element, xM: safeBounds.minX + valueFromOriginM } : { ...element, yM: safeBounds.minY + valueFromOriginM })
  }

  function renderDirection(element: StairEditorElement) {
    if (element.kind === 'landing') return null
    const rotate = normalizeRightAngle(element.rotationDeg)
    const mapUnitPoint = (point: { x: number; y: number }) => {
      const dx = point.x - 0.5
      const dy = point.y - 0.5
      switch (rotate) {
        case 90:
          return { x: 0.5 + dy, y: 0.5 - dx }
        case 180:
          return { x: 0.5 - dx, y: 0.5 - dy }
        case 270:
          return { x: 0.5 - dy, y: 0.5 + dx }
        default:
          return { x: 0.5 + dx, y: 0.5 + dy }
      }
    }
    const toAbs = (point: { x: number; y: number }) => ({
      x: element.xM + point.x * element.widthM,
      y: element.yM + point.y * element.heightM,
    })
    if (element.kind === 'turn') {
      const side = element.mirrored ? -1 : 1
      const startUnit = side > 0 ? { x: 0.72, y: 0.84 } : { x: 0.28, y: 0.84 }
      const cornerUnit = side > 0 ? { x: 0.72, y: 0.56 } : { x: 0.28, y: 0.56 }
      const endUnit = side > 0 ? { x: 0.24, y: 0.56 } : { x: 0.76, y: 0.56 }
      const headAUnit = side > 0 ? { x: 0.34, y: 0.46 } : { x: 0.66, y: 0.46 }
      const headBUnit = endUnit
      const headCUnit = side > 0 ? { x: 0.34, y: 0.66 } : { x: 0.66, y: 0.66 }
      const start = toAbs(mapUnitPoint(startUnit))
      const corner = toAbs(mapUnitPoint(cornerUnit))
      const end = toAbs(mapUnitPoint(endUnit))
      const headA = toAbs(mapUnitPoint(headAUnit))
      const headB = toAbs(mapUnitPoint(headBUnit))
      const headC = toAbs(mapUnitPoint(headCUnit))
      return (
        <g className="stair-editor-direction turn">
          <path className="stair-editor-direction-bend" d={`M ${start.x} ${start.y} L ${corner.x} ${corner.y} L ${end.x} ${end.y}`} />
          <path className="stair-editor-direction-head" d={`M ${headA.x} ${headA.y} L ${headB.x} ${headB.y} L ${headC.x} ${headC.y}`} />
        </g>
      )
    }
    const start = toAbs(mapUnitPoint({ x: 0.5, y: 0.78 }))
    const end = toAbs(mapUnitPoint({ x: 0.5, y: 0.22 }))
    const headA = toAbs(mapUnitPoint({ x: 0.4, y: 0.32 }))
    const headB = end
    const headC = toAbs(mapUnitPoint({ x: 0.6, y: 0.32 }))
    return (
      <g className="stair-editor-direction">
        <line x1={start.x} y1={start.y} x2={end.x} y2={end.y} />
        <path d={`M ${headA.x} ${headA.y} L ${headB.x} ${headB.y} L ${headC.x} ${headC.y}`} />
      </g>
    )
  }

  function renderStairStepLines(element: StairEditorElement) {
    const steps = Math.max(1, Math.round(element.steps || 1))
    const rotation = normalizeRightAngle(element.rotationDeg)
    const rect = {
      left: element.xM,
      top: element.yM,
      right: element.xM + element.widthM,
      bottom: element.yM + element.heightM,
    }
    const eps = 0.000001
    const rayToRect = (origin: PointM, angleRad: number): PointM => {
      const dx = Math.cos(angleRad)
      const dy = Math.sin(angleRad)
      const hits: { t: number; point: PointM }[] = []
      if (Math.abs(dx) > eps) {
        const tLeft = (rect.left - origin.x) / dx
        const yLeft = origin.y + tLeft * dy
        if (tLeft > eps && yLeft >= rect.top - eps && yLeft <= rect.bottom + eps) hits.push({ t: tLeft, point: { x: rect.left, y: yLeft } })
        const tRight = (rect.right - origin.x) / dx
        const yRight = origin.y + tRight * dy
        if (tRight > eps && yRight >= rect.top - eps && yRight <= rect.bottom + eps) hits.push({ t: tRight, point: { x: rect.right, y: yRight } })
      }
      if (Math.abs(dy) > eps) {
        const tTop = (rect.top - origin.y) / dy
        const xTop = origin.x + tTop * dx
        if (tTop > eps && xTop >= rect.left - eps && xTop <= rect.right + eps) hits.push({ t: tTop, point: { x: xTop, y: rect.top } })
        const tBottom = (rect.bottom - origin.y) / dy
        const xBottom = origin.x + tBottom * dx
        if (tBottom > eps && xBottom >= rect.left - eps && xBottom <= rect.right + eps) hits.push({ t: tBottom, point: { x: xBottom, y: rect.bottom } })
      }
      hits.sort((a, b) => a.t - b.t)
      return hits[0]?.point || origin
    }

    if (element.kind === 'stair') {
      const lines = []
      const useVerticalTreads = rotation === 90 || rotation === 270
      for (let index = 1; index < steps; index += 1) {
        if (useVerticalTreads) {
          const x = rect.left + (element.widthM * index) / steps
          lines.push(<line key={`step-${index}`} className="stair-editor-step-line" x1={x} y1={rect.top} x2={x} y2={rect.bottom} />)
        } else {
          const y = rect.top + (element.heightM * index) / steps
          lines.push(<line key={`step-${index}`} className="stair-editor-step-line" x1={rect.left} y1={y} x2={rect.right} y2={y} />)
        }
      }
      return <g className="stair-editor-step-lines stair">{lines}</g>
    }

    if (element.kind === 'turn') {
      const centerX = element.xM + element.widthM / 2
      const centerY = element.yM + element.heightM / 2
      const candidates = elements
        .filter((candidate) => candidate.id !== element.id && candidate.kind === 'stair')
        .map((candidate) => {
          const candidateCenterX = candidate.xM + candidate.widthM / 2
          const candidateCenterY = candidate.yM + candidate.heightM / 2
          const verticalOverlap = Math.max(0, Math.min(rect.bottom, candidate.yM + candidate.heightM) - Math.max(rect.top, candidate.yM))
          const gap = candidateCenterX > centerX ? Math.max(0, candidate.xM - rect.right) : Math.max(0, rect.left - (candidate.xM + candidate.widthM))
          const score = gap + Math.abs(candidateCenterY - centerY) * 0.25 - verticalOverlap * 0.6
          return { candidateCenterX, score }
        })
        .sort((a, b) => a.score - b.score)
      const neighborSide: 'left' | 'right' = candidates[0]
        ? (candidates[0].candidateCenterX > centerX ? 'right' : 'left')
        : (element.mirrored ? 'left' : 'right')
      const origin = neighborSide === 'right'
        ? { x: rect.right, y: rect.bottom }
        : { x: rect.left, y: rect.bottom }
      const startAngle = neighborSide === 'right' ? Math.PI : -Math.PI / 2
      const endAngle = neighborSide === 'right' ? Math.PI * 1.5 : 0
      const lines = []
      for (let index = 1; index < steps; index += 1) {
        const fraction = index / steps
        const target = rayToRect(origin, startAngle + (endAngle - startAngle) * fraction)
        lines.push(<line key={`turn-step-${index}`} className="stair-editor-step-line turn" x1={origin.x} y1={origin.y} x2={target.x} y2={target.y} />)
      }
      return <g className="stair-editor-step-lines turn">{lines}</g>
    }
    return null
  }

  function renderElementDimensions(element: StairEditorElement) {
    const offset = Math.max(0.08, Math.min(viewBox.width, viewBox.height) * 0.025)
    const midX = element.xM + element.widthM / 2
    const midY = element.yM + element.heightM / 2
    const wMm = Math.round(element.widthM * 1000)
    const hMm = Math.round(element.heightM * 1000)
    return (
      <g className="stair-editor-element-dimensions" aria-hidden="true">
        <line x1={element.xM} y1={element.yM - offset} x2={element.xM + element.widthM} y2={element.yM - offset} />
        <text x={midX} y={element.yM - offset * 1.25} textAnchor="middle">{wMm} mm</text>
        <line x1={element.xM} y1={element.yM + element.heightM + offset} x2={element.xM + element.widthM} y2={element.yM + element.heightM + offset} />
        <text x={midX} y={element.yM + element.heightM + offset * 1.75} textAnchor="middle">{wMm} mm</text>
        <line x1={element.xM - offset} y1={element.yM} x2={element.xM - offset} y2={element.yM + element.heightM} />
        <text x={element.xM - offset * 1.45} y={midY} textAnchor="middle" transform={`rotate(-90 ${element.xM - offset * 1.45} ${midY})`}>{hMm} mm</text>
        <line x1={element.xM + element.widthM + offset} y1={element.yM} x2={element.xM + element.widthM + offset} y2={element.yM + element.heightM} />
        <text x={element.xM + element.widthM + offset * 1.45} y={midY} textAnchor="middle" transform={`rotate(-90 ${element.xM + element.widthM + offset * 1.45} ${midY})`}>{hMm} mm</text>
      </g>
    )
  }

  return (
    <>
      <header className="stair-editor-header" onMouseDown={onBeginWindowMove}>
        <div><span className="eyebrow">Treppe einzeichnen</span><strong>{cleanRoomName(room)}</strong></div>
        <button type="button" className="stair-editor-ok" onMouseDown={(event) => event.stopPropagation()} onClick={onConfirm}>OK</button>
      </header>
      <div className="canvas-toolbox stair-editor-toolbar" aria-label="Treppenwerkzeuge" onMouseDown={(event) => event.stopPropagation()}>
        <button type="button" className={tool === 'move' ? 'active' : ''} title="Verschieben" data-tooltip="Verschieben" aria-label="Verschieben" data-stair-tool="move" onClick={() => setTool('move')}>↖</button>
        <button type="button" title="Drehen 90 Grad" data-tooltip="Drehen 90 Grad" aria-label="Drehen 90 Grad" data-stair-tool="rotate" onClick={rotateSelected} disabled={!selectedElement}>⟳</button>
        <button type="button" title="Biegung spiegeln" data-tooltip="Biegung spiegeln" aria-label="Biegung spiegeln" data-stair-tool="mirror" onClick={mirrorSelected} disabled={!selectedElement || selectedElement.kind !== 'turn'}>⇄</button>
        <button type="button" title="Canvas herauszoomen" data-tooltip="Canvas herauszoomen" aria-label="Canvas herauszoomen" data-stair-tool="zoom-out" onClick={() => setZoom((current) => clamp(round3(current / 1.1), 0.45, 3.5))}>−</button>
        <button type="button" title="Canvas hineinzoomen" data-tooltip="Canvas hineinzoomen" aria-label="Canvas hineinzoomen" data-stair-tool="zoom-in" onClick={() => setZoom((current) => clamp(round3(current * 1.1), 0.45, 3.5))}>+</button>
        <button type="button" className={tool === 'align' ? 'active' : ''} title="Linien ausrichten" data-tooltip="Linien ausrichten" aria-label="Linien ausrichten" data-stair-tool="align" onClick={() => setTool((current) => current === 'align' ? 'move' : 'align')}>⇔</button>
        <button type="button" title="Rueckgaengig" data-tooltip="Rueckgaengig" aria-label="Letzte Aktion rueckgaengig" data-stair-tool="undo" onMouseDown={(event) => event.preventDefault()} onClick={undoStairEditor} disabled={!stairEditorUndoStack.length}>↶</button>
        <button type="button" title="Loeschen" data-tooltip="Loeschen" aria-label="Ausgewaehltes Element loeschen" data-stair-tool="delete" onMouseDown={(event) => event.preventDefault()} onClick={deleteSelectedStairElement} disabled={!(selectedElement || selectedEdgeAssignment)}>⌫</button>
      </div>
      <div className="stair-editor-properties" onMouseDown={(event) => event.stopPropagation()}>
        {selectedEdgeAssignment && (
          <div className="stair-editor-property-group stair-editor-edge-property-panel">
            <span>{stairEdgeKindLabel(selectedEdgeAssignment.kind)}</span>
            <label>Ebene
              <select value={selectedEdgeAssignment.layerId || ''} onChange={(event) => updateEdgeAssignment(selectedEdgeAssignment.id, event.target.value)}>
                <option value="" disabled>Ebene waehlen</option>
                {layers.map((layer) => <option key={layer.id} value={layer.id}>{layer.name}</option>)}
                <option value="__new__">Neue Ebene...</option>
              </select>
            </label>
            <label>Ebenenname
              <input
                value={selectedEdgeAssignment.layerId === '__new__' ? edgeLayerDraftName : (selectedEdgeAssignment.layerName || '')}
                onChange={(event) => {
                  setEdgeLayerDraftName(event.target.value)
                  if (selectedEdgeAssignment.layerId !== '__new__') setEdgeAssignments((current) => current.map((item) => item.id === selectedEdgeAssignment.id ? { ...item, layerId: '__new__', layerName: '' } : item))
                }}
                onKeyDown={(event) => { if (event.key === 'Enter') commitEdgeLayerDraft() }}
                placeholder="Ebenenname"
              />
            </label>
            {selectedEdgeAssignment.layerId === '__new__' && <button type="button" onClick={commitEdgeLayerDraft} disabled={!edgeLayerDraftName.trim()}>Ebene erstellen</button>}
          </div>
        )}
        {selectedElement ? (
          <>
            <label>Typ <span>{stairKindLabel(selectedElement.kind)}</span></label>
            <label>X <MmNumberInput valueM={selectedElement.xM - safeBounds.minX} minM={0} onChangeM={(value) => setSelectedPosition('x', value)} /></label>
            <label>Y <MmNumberInput valueM={selectedElement.yM - safeBounds.minY} minM={0} onChangeM={(value) => setSelectedPosition('y', value)} /></label>
            <label>Breite <MmNumberInput valueM={selectedElement.widthM} minM={0.12} onChangeM={(value) => updateElement(selectedElement.id, (element) => ({ ...element, widthM: value }))} /></label>
            <label>Hoehe <MmNumberInput valueM={selectedElement.heightM} minM={0.12} onChangeM={(value) => updateElement(selectedElement.id, (element) => ({ ...element, heightM: value }))} /></label>
            {selectedElement.kind !== 'landing' && <label>Richtung <span>{normalizeRightAngle(selectedElement.rotationDeg)} Grad</span></label>}
            {selectedElement.kind !== 'landing' && <label>Stufen <input type="number" min="1" step="1" value={selectedElement.steps} onChange={(event) => updateElement(selectedElement.id, (element) => ({ ...element, steps: Math.max(1, Number(event.target.value) || 1) }))} /></label>}
          </>
        ) : !selectedEdgeAssignment ? <span className="stair-editor-empty">Element aus der Bibliothek in die Grundflaeche ziehen oder Etagenwerkzeug auf eine Kante ziehen.</span> : null}
      </div>
      <div className="stair-editor-body" onMouseDown={(event) => event.stopPropagation()}>
        <div className="stair-editor-canvas-wrap" onDragOver={onCanvasDragOver} onDragEnter={onCanvasDragOver} onDrop={onCanvasDrop} onDragLeave={() => setHoverFloorEdge(null)}>
          <svg
            ref={svgRef}
            className="stair-editor-canvas"
            viewBox={`${viewBox.x} ${viewBox.y} ${viewBox.width} ${viewBox.height}`}
            onWheel={onCanvasWheel}
            onMouseDown={() => { setSelectedElementId(''); setSelectedEdgeAssignmentId(''); setEdgeLayerDraftName('') }}
          >
            <polygon className="stair-editor-room-base" points={room.vertices.map((point) => `${point.x},${point.y}`).join(' ')} />
            {room.vertices.map((point, index) => {
              const next = room.vertices[(index + 1) % room.vertices.length]
              if (!next) return null
              return <line key={`stair-room-edge-${index}`} className="stair-editor-room-edge" x1={point.x} y1={point.y} x2={next.x} y2={next.y} />
            })}
            {snapGuides.map((guide, index) => guide.axis === 'x'
              ? <line key={`x-${index}`} className="stair-editor-snap-guide" x1={guide.value} y1={viewBox.y} x2={guide.value} y2={viewBox.y + viewBox.height} />
              : <line key={`y-${index}`} className="stair-editor-snap-guide" x1={viewBox.x} y1={guide.value} x2={viewBox.x + viewBox.width} y2={guide.value} />)}
            {elements.map((element) => {
              const selected = element.id === selectedElementId
              const cx = element.xM + element.widthM / 2
              const cy = element.yM + element.heightM / 2
              return (
                <g key={element.id} className={`stair-editor-element ${selected ? 'selected' : ''} ${element.kind}`} onMouseDown={(event) => startElementDrag(event, element)}>
                  <rect className="stair-editor-element-hit" x={element.xM} y={element.yM} width={element.widthM} height={element.heightM} rx={Math.min(element.widthM, element.heightM) * 0.04} />
                  <rect className="stair-editor-element-shape" x={element.xM} y={element.yM} width={element.widthM} height={element.heightM} rx={Math.min(element.widthM, element.heightM) * 0.04} />
                  {(element.kind === 'stair' || element.kind === 'turn') && renderStairStepLines(element)}
                  {renderDirection(element)}
                  <text className="stair-editor-kind-label" x={cx} y={cy - element.heightM * 0.18} textAnchor="middle">{stairKindLabel(element.kind)}</text>
                  {selected && renderElementDimensions(element)}
                  {element.kind !== 'landing' && <text className="stair-editor-step-count" x={cx} y={cy + element.heightM * 0.23} textAnchor="middle">{element.steps} Stufen</text>}
                  {selected && (
                    <g className="stair-editor-edge-handles">
                      <line x1={element.xM} y1={element.yM} x2={element.xM} y2={element.yM + element.heightM} onMouseDown={(event) => startEdgeDrag(event, element, 'left')} />
                      <line x1={element.xM + element.widthM} y1={element.yM} x2={element.xM + element.widthM} y2={element.yM + element.heightM} onMouseDown={(event) => startEdgeDrag(event, element, 'right')} />
                      <line x1={element.xM} y1={element.yM} x2={element.xM + element.widthM} y2={element.yM} onMouseDown={(event) => startEdgeDrag(event, element, 'top')} />
                      <line x1={element.xM} y1={element.yM + element.heightM} x2={element.xM + element.widthM} y2={element.yM + element.heightM} onMouseDown={(event) => startEdgeDrag(event, element, 'bottom')} />
                      <circle className="corner top-left" cx={element.xM} cy={element.yM} r={handleSize} onMouseDown={(event) => startEdgeDrag(event, element, 'topLeft')} />
                      <circle className="corner top-right" cx={element.xM + element.widthM} cy={element.yM} r={handleSize} onMouseDown={(event) => startEdgeDrag(event, element, 'topRight')} />
                      <circle className="corner bottom-left" cx={element.xM} cy={element.yM + element.heightM} r={handleSize} onMouseDown={(event) => startEdgeDrag(event, element, 'bottomLeft')} />
                      <circle className="corner bottom-right" cx={element.xM + element.widthM} cy={element.yM + element.heightM} r={handleSize} onMouseDown={(event) => startEdgeDrag(event, element, 'bottomRight')} />
                    </g>
                  )}
                </g>
              )
            })}
            {edgeAssignments.map((assignment) => renderEdgeAssignment(assignment))}
            {hoverFloorEdge && renderFloorEdgeHover(hoverFloorEdge)}
          </svg>
        </div>
        <aside className="stair-editor-library">
          <span className="eyebrow">Bibliothek</span>
          {stairLibraryItems.map((item) => (
            <button
              key={item.kind}
              type="button"
              title={item.label}
              data-tooltip={item.label}
              aria-label={item.label}
              draggable
              onDragStart={(event) => { setDraggedLibraryKind(item.kind); event.dataTransfer.setData('application/x-stair-editor-kind', item.kind); event.dataTransfer.effectAllowed = 'copy' }}
              onDragEnd={() => { setDraggedLibraryKind(null); setHoverFloorEdge(null) }}
            >
              <span className={`stair-library-graphic ${item.kind}`} aria-hidden="true" />
              <strong>{item.label}</strong>
            </button>
          ))}
        </aside>
      </div>
      <div className="stair-panel-resize-handle" onMouseDown={onBeginWindowResize} aria-hidden="true" />
    </>
  )
}

type EditorPropertiesMode =
  | { kind: 'empty' }
  | { kind: 'selected'; room: Room }
  | { kind: 'multi'; rooms: Room[] }
  | { kind: 'rectDraft'; rectInput: RectInput; rectPreview: RectM | null; rectDraft: RectDraft | null }
  | { kind: 'outerWallDraft'; rectInput: RectInput; rectPreview: RectM | null; rectDraft: RectDraft | null }
  | { kind: 'polygonDraft'; polygonName: string; polygonWallThicknessM: number; polygonDraft: PointM[] }


function round3(value: number) {
  return Math.round((Number.isFinite(value) ? value : 0) * 1000) / 1000
}
function formatSelectedDimensionM(value: number) { return `${round3(value).toFixed(3)} m` }
function formatMm(value: number) { return `${Math.round(value * 1000)} mm` }
function formatMmInput(value: number) { return `${Math.round(value * 1000)}` }

function MmNumberInput({
  valueM,
  minM,
  disabled = false,
  onChangeM,
}: {
  valueM: number
  minM?: number
  disabled?: boolean
  onChangeM: (valueM: number) => void
}) {
  const [draft, setDraft] = useState(formatMmInput(valueM))
  const [focused, setFocused] = useState(false)

  useEffect(() => {
    if (!focused) setDraft(formatMmInput(valueM))
  }, [valueM, focused])

  return (
    <input
      type="number"
      step="1"
      min={minM !== undefined ? Math.round(minM * 1000) : undefined}
      value={draft}
      disabled={disabled}
      onMouseDown={(event) => event.stopPropagation()}
      onClick={(event) => event.stopPropagation()}
      onFocus={() => setFocused(true)}
      onBlur={() => {
        setFocused(false)
        setDraft(formatMmInput(valueM))
      }}
      onChange={(event) => {
        const raw = event.target.value
        setDraft(raw)
        if (raw.trim() === '' || raw === '-' || raw === '.' || raw === '-.') return
        const parsed = Number(raw.replace(',', '.'))
        if (!Number.isFinite(parsed)) return
        const nextM = round3(parsed / 1000)
        onChangeM(minM === undefined ? nextM : Math.max(minM, nextM))
      }}
    />
  )
}

function EditorPropertiesTopBar({
  mode,
  onRectInputChange,
  onRectDraftChange,
  onPolygonNameChange,
  onPolygonWallThicknessChange,
  onLiveRoomChange,
}: {
  mode: EditorPropertiesMode
  onRectInputChange: (value: RectInput) => void
  onRectDraftChange: (value: RectDraft | null) => void
  onPolygonNameChange: (value: string) => void
  onPolygonWallThicknessChange: (value: number) => void
  onLiveRoomChange: (room: Room) => void
}) {
  if (mode.kind === 'empty') {
    return (
      <section className="properties-topbar empty">
        <div><span className="eyebrow">Eigenschaften</span><strong>Keine Auswahl</strong></div>
        <p>Waehle einen Raum oder ein Werkzeug. Werte werden hier live angezeigt.</p>
      </section>
    )
  }
  if (mode.kind === 'rectDraft') {
    const rect = mode.rectPreview
    const rectDraft = mode.rectDraft
    const x = rect?.minX ?? 0
    const y = rect?.minY ?? 0
    const width = rect?.width ?? 0
    const height = rect?.height ?? 0
    function updateDraftSize(axis: 'width' | 'height', value: number) {
      if (!rectDraft) return
      const current = normalizeRect(rectDraft.start, rectDraft.end)
      const nextWidth = axis === 'width' ? clamp(round3(value), 0.05, canvas.maxM - current.minX) : current.width
      const nextHeight = axis === 'height' ? clamp(round3(value), 0.05, canvas.maxM - current.minY) : current.height
      onRectDraftChange({ start: { x: current.minX, y: current.minY }, end: { x: round3(current.minX + nextWidth), y: round3(current.minY + nextHeight) } })
    }
    function updateDraftPos(axis: 'x' | 'y', value: number) {
      if (!rectDraft) return
      const current = normalizeRect(rectDraft.start, rectDraft.end)
      const nextX = axis === 'x' ? clamp(round3(value), 0, canvas.maxM - current.width) : current.minX
      const nextY = axis === 'y' ? clamp(round3(value), 0, canvas.maxM - current.height) : current.minY
      onRectDraftChange({ start: { x: nextX, y: nextY }, end: { x: round3(nextX + current.width), y: round3(nextY + current.height) } })
    }
    return (
      <section className="properties-topbar">
        <div className="properties-title"><span className="eyebrow">Eigenschaften</span><strong>Neues Rechteck</strong></div>
        <label>Name<input value={mode.rectInput.name} onChange={(event) => onRectInputChange({ ...mode.rectInput, name: event.target.value })} /></label>
        <label>X mm<MmNumberInput valueM={x} disabled={!rect} onChangeM={(valueM) => updateDraftPos('x', valueM)} /></label>
        <label>Y mm<MmNumberInput valueM={y} disabled={!rect} onChangeM={(valueM) => updateDraftPos('y', valueM)} /></label>
        <label>Breite mm<MmNumberInput valueM={width} minM={0.05} disabled={!rect} onChangeM={(valueM) => updateDraftSize('width', valueM)} /></label>
        <label>Tiefe mm<MmNumberInput valueM={height} minM={0.05} disabled={!rect} onChangeM={(valueM) => updateDraftSize('height', valueM)} /></label>
        <label>Wand mm<MmNumberInput valueM={mode.rectInput.wallThicknessM} minM={0} onChangeM={(valueM) => onRectInputChange({ ...mode.rectInput, wallThicknessM: Math.max(0, valueM) })} /></label>
        <div className="property-readout"><span>Anker: {formatMm(x)} / {formatMm(y)}</span><span>Flaeche: {formatM2(width * height)}</span></div>
      </section>
    )
  }
  if (mode.kind === 'outerWallDraft') {
    const rect = mode.rectPreview
    const rectDraft = mode.rectDraft
    const x = rect?.minX ?? 0
    const y = rect?.minY ?? 0
    const width = rect?.width ?? 0
    const height = rect?.height ?? 0
    function updateDraftSize(axis: 'width' | 'height', value: number) {
      if (!rectDraft) return
      const current = normalizeRect(rectDraft.start, rectDraft.end)
      const nextWidth = axis === 'width' ? clamp(round3(value), 0.05, canvas.maxM - current.minX) : current.width
      const nextHeight = axis === 'height' ? clamp(round3(value), 0.05, canvas.maxM - current.minY) : current.height
      onRectDraftChange({ start: { x: current.minX, y: current.minY }, end: { x: round3(current.minX + nextWidth), y: round3(current.minY + nextHeight) } })
    }
    function updateDraftPos(axis: 'x' | 'y', value: number) {
      if (!rectDraft) return
      const current = normalizeRect(rectDraft.start, rectDraft.end)
      const nextX = axis === 'x' ? clamp(round3(value), 0, canvas.maxM - current.width) : current.minX
      const nextY = axis === 'y' ? clamp(round3(value), 0, canvas.maxM - current.height) : current.minY
      onRectDraftChange({ start: { x: nextX, y: nextY }, end: { x: round3(nextX + current.width), y: round3(nextY + current.height) } })
    }
    return (
      <section className="properties-topbar">
        <div className="properties-title"><span className="eyebrow">Eigenschaften</span><strong>Neue Aussenwand</strong></div>
        <label>X mm<MmNumberInput valueM={x} disabled={!rect} onChangeM={(valueM) => updateDraftPos('x', valueM)} /></label>
        <label>Y mm<MmNumberInput valueM={y} disabled={!rect} onChangeM={(valueM) => updateDraftPos('y', valueM)} /></label>
        <label>Breite mm<MmNumberInput valueM={width} minM={0.05} disabled={!rect} onChangeM={(valueM) => updateDraftSize('width', valueM)} /></label>
        <label>Tiefe mm<MmNumberInput valueM={height} minM={0.05} disabled={!rect} onChangeM={(valueM) => updateDraftSize('height', valueM)} /></label>
        <label>Wand mm<MmNumberInput valueM={mode.rectInput.wallThicknessM} minM={0} onChangeM={(valueM) => onRectInputChange({ ...mode.rectInput, wallThicknessM: Math.max(0, valueM) })} /></label>
        <div className="property-readout"><span>Anker: {formatMm(x)} / {formatMm(y)}</span><span>Aussenwand ohne Raumflaeche</span></div>
      </section>
    )
  }

  if (mode.kind === 'polygonDraft') {
    const bounds = boundsOf(mode.polygonDraft)
    const area = polygonAreaM2(mode.polygonDraft)
    return (
      <section className="properties-topbar">
        <div className="properties-title"><span className="eyebrow">Eigenschaften</span><strong>Neues Polygon</strong></div>
        <label>Name<input value={mode.polygonName} onChange={(event) => onPolygonNameChange(event.target.value)} /></label>
        <label>Wand mm<MmNumberInput valueM={mode.polygonWallThicknessM} minM={0} onChangeM={(valueM) => onPolygonWallThicknessChange(Math.max(0, valueM))} /></label>
        <div className="property-readout"><span>Anker: {formatMm(bounds?.minX ?? 0)} / {formatMm(bounds?.minY ?? 0)}</span><span>Flaeche: {formatM2(area)}</span></div>
      </section>
    )
  }
  if (mode.kind === 'multi') {
    const multiMode = mode as Extract<EditorPropertiesMode, { kind: 'multi' }>
    const allPoints = multiMode.rooms.flatMap((room: Room) => room.vertices)
    const bounds = boundsOf(allPoints)
    const area = multiMode.rooms.reduce((sum: number, room: Room) => sum + polygonAreaM2(room.vertices), 0)
    function changeGroupPosition(axis: 'x' | 'y', value: number) {
      if (!bounds) return
      const nextX = axis === 'x' ? clamp(round3(value), 0, canvas.maxM) : bounds.minX
      const nextY = axis === 'y' ? clamp(round3(value), 0, canvas.maxM) : bounds.minY
      const dx = round3(nextX - bounds.minX)
      const dy = round3(nextY - bounds.minY)
      multiMode.rooms.forEach((room: Room) => {
        const nextVertices = room.vertices.map((point: PointM) => clampPoint({ x: round3(point.x + dx), y: round3(point.y + dy) }))
        onLiveRoomChange({ ...room, vertices: nextVertices, areaM2: polygonAreaM2(nextVertices) })
      })
    }
    return (
      <section className="properties-topbar">
        <div className="properties-title"><span className="eyebrow">Eigenschaften</span><strong>Alle Elemente</strong></div>
        <label>X mm<MmNumberInput valueM={bounds?.minX ?? 0} onChangeM={(valueM) => changeGroupPosition('x', valueM)} /></label>
        <label>Y mm<MmNumberInput valueM={bounds?.minY ?? 0} onChangeM={(valueM) => changeGroupPosition('y', valueM)} /></label>
        <div className="property-readout"><span>{multiMode.rooms.length} Elemente</span><span>Anker: {formatMm(bounds?.minX ?? 0)} / {formatMm(bounds?.minY ?? 0)}</span><span>Flaeche: {formatM2(area)}</span></div>
      </section>
    )
  }
  const room = mode.room
  const outerWall = isOuterWallRoom(room)
  const bounds = boundsOf(room.vertices)
  const width = bounds ? bounds.maxX - bounds.minX : 0
  const height = bounds ? bounds.maxY - bounds.minY : 0
  const area = polygonAreaM2(room.vertices)
  function changeName(name: string) { onLiveRoomChange({ ...room, name: name || 'Raum' }) }
  function changePosition(axis: 'x' | 'y', value: number) {
    if (!bounds) return
    const nextX = axis === 'x' ? clamp(round3(value), 0, canvas.maxM) : bounds.minX
    const nextY = axis === 'y' ? clamp(round3(value), 0, canvas.maxM) : bounds.minY
    const dx = nextX - bounds.minX
    const dy = nextY - bounds.minY
    const nextVertices = room.vertices.map((point) => clampPoint({ x: round3(point.x + dx), y: round3(point.y + dy) }))
    onLiveRoomChange({ ...room, vertices: nextVertices, areaM2: polygonAreaM2(nextVertices) })
  }
  function changeRectSize(axis: 'width' | 'height', value: number) {
    if (!bounds) return
    const nextWidth = axis === 'width' ? clamp(round3(value), 0.1, canvas.maxM - bounds.minX) : width
    const nextHeight = axis === 'height' ? clamp(round3(value), 0.1, canvas.maxM - bounds.minY) : height
    const nextVertices = rectangleVertices(bounds.minX, bounds.minY, nextWidth, nextHeight)
    onLiveRoomChange({ ...room, vertices: nextVertices, areaM2: polygonAreaM2(nextVertices) })
  }
  function changeWall(value: number) { onLiveRoomChange({ ...room, wallThicknessM: Math.max(0, round3(value)) }) }
  return (
    <section className="properties-topbar">
      <div className="properties-title"><span className="eyebrow">Eigenschaften</span><strong>{outerWall ? 'Aussenwand' : isStairRoom(room) ? 'Treppenraum' : room.shapeType === 'rectangle' ? 'Rechteck' : 'Polygon'}</strong></div>
      {!outerWall && <label>Name<input value={room.name} onChange={(event) => changeName(event.target.value)} /></label>}
      <label>X mm<MmNumberInput valueM={bounds?.minX ?? 0} onChangeM={(valueM) => changePosition('x', valueM)} /></label>
      <label>Y mm<MmNumberInput valueM={bounds?.minY ?? 0} onChangeM={(valueM) => changePosition('y', valueM)} /></label>
      {room.shapeType === 'rectangle' && <><label>Breite mm<MmNumberInput valueM={width} minM={0.1} onChangeM={(valueM) => changeRectSize('width', valueM)} /></label><label>Tiefe mm<MmNumberInput valueM={height} minM={0.1} onChangeM={(valueM) => changeRectSize('height', valueM)} /></label></>}
      <label>Wand mm<MmNumberInput valueM={room.wallThicknessM} minM={0} onChangeM={(valueM) => changeWall(valueM)} /></label>
      <div className="property-readout"><span>Anker: {formatMm(bounds?.minX ?? 0)} / {formatMm(bounds?.minY ?? 0)}</span><span>{outerWall ? 'Aussenwand ohne Raumflaeche' : `Flaeche: ${formatM2(area)}`}</span></div>
    </section>
  )
}

function ToolSettingsPanel({
  tool,
  rectInput,
  rectPreview,
  rectPreviewArea,
  polygonName,
  polygonWallThicknessM,
  polygonDraft,
  polygonArea,
  onRectInputChange,
  onPolygonNameChange,
  onPolygonWallThicknessChange,
  onDiscardRect,
  onFinishPolygon,
  onUndoPolygon,
  onClearPolygon,
}: {
  tool: Tool
  rectInput: RectInput
  rectPreview: RectM | null
  rectPreviewArea: number
  polygonName: string
  polygonWallThicknessM: number
  polygonDraft: PointM[]
  polygonArea: number
  onRectInputChange: (input: RectInput) => void
  onPolygonNameChange: (value: string) => void
  onPolygonWallThicknessChange: (value: number) => void
  onDiscardRect: () => void
  onFinishPolygon: () => void
  onUndoPolygon: () => void
  onClearPolygon: () => void
}) {
  if (tool === 'rectangle') {
    return (
      <div className="canvas-settings">
        <label>Name<input value={rectInput.name} onChange={(event) => onRectInputChange({ ...rectInput, name: event.target.value })} /></label>
        <label>Wandstaerke m<input type="number" step="0.01" min="0" value={rectInput.wallThicknessM} onChange={(event) => onRectInputChange({ ...rectInput, wallThicknessM: toNumber(event.target.value, 0.12) })} /></label>
        {rectPreview && <div className="metric-card compact"><strong>{formatM(rectPreview.width)} × {formatM(rectPreview.height)}</strong><span>{formatM2(rectPreviewArea)}</span></div>}
        <button onClick={onDiscardRect} disabled={!rectPreview}>Verwerfen</button>
      </div>
    )
  }

  if (tool === 'polygon') {
    return (
      <div className="canvas-settings">
        <label>Name<input value={polygonName} onChange={(event) => onPolygonNameChange(event.target.value)} /></label>
        <label>Wandstaerke m<input type="number" step="0.01" min="0" value={polygonWallThicknessM} onChange={(event) => onPolygonWallThicknessChange(toNumber(event.target.value, 0.12))} /></label>
        <div className="metric-card compact"><strong>{polygonDraft.length} Punkte</strong><span>{polygonArea > 0 ? formatM2(polygonArea) : 'noch offen'}</span></div>
        <button onClick={onUndoPolygon} disabled={polygonDraft.length === 0}>Rueckpunkt</button>
        <button onClick={onClearPolygon} disabled={polygonDraft.length === 0}>Leeren</button>
        <button onClick={onFinishPolygon} disabled={polygonDraft.length < 3}>Polygon schliessen</button>
      </div>
    )
  }

  return null
}

function RecessFloatingPanel({
  preview,
  edge,
  isRectangle,
  fallbackAlong,
  fallbackDepth,
  offsetM,
  offsetFromEnd,
  onEdgeChange,
  onAlongChange,
  onDepthChange,
  onOffsetChange,
  onOffsetDirectionToggle,
  onApply,
  onCancel,
}: {
  preview: RecessPreview | null
  edge: RecessEdge
  isRectangle: boolean
  fallbackAlong: number
  fallbackDepth: number
  offsetM: number
  offsetFromEnd: boolean
  onEdgeChange: (edge: RecessEdge) => void
  onAlongChange: (value: number) => void
  onDepthChange: (value: number) => void
  onOffsetChange: (value: number) => void
  onOffsetDirectionToggle: () => void
  onApply: () => void
  onCancel: () => void
}) {
  const along = preview ? (preview.edge === 'top' || preview.edge === 'bottom' ? preview.rect.width : preview.rect.height) : fallbackAlong
  const depth = preview ? (preview.edge === 'top' || preview.edge === 'bottom' ? preview.rect.height : preview.rect.width) : fallbackDepth
  const offsetStartLabel = edge === 'top' || edge === 'bottom' ? 'von links' : 'von oben'
  const offsetEndLabel = edge === 'top' || edge === 'bottom' ? 'von rechts' : 'von unten'
  return (
    <div className="recess-floating">
      <div>
        <span className="eyebrow">Aussparung</span>
        <strong>Subtraktive Form</strong>
      </div>
      <label>
        Position
        <select value={edge} onMouseDown={(event) => event.stopPropagation()} onClick={(event) => event.stopPropagation()} onChange={(event) => onEdgeChange(event.target.value as RecessEdge)}>
          <option value="top">oben</option>
          <option value="bottom">unten</option>
          <option value="right">rechts</option>
          <option value="left">links</option>
        </select>
      </label>
      <label>
        Laenge mm
        <MmNumberInput valueM={along} minM={0.05} onChangeM={onAlongChange} />
      </label>
      <label>
        Tiefe mm
        <MmNumberInput valueM={depth} minM={0.05} onChangeM={onDepthChange} />
      </label>
      <label>
        Abstand zur Wand mm
        <MmNumberInput valueM={offsetM} minM={0} onChangeM={onOffsetChange} />
      </label>
      <label>
        Abstand Richtung
        <button type="button" className="recess-direction-toggle" onMouseDown={(event) => { event.preventDefault(); event.stopPropagation() }} onClick={(event) => { event.stopPropagation(); onOffsetDirectionToggle() }}>
          {offsetFromEnd ? offsetEndLabel : offsetStartLabel}
        </button>
      </label>
      <p className="mini-hint">{isRectangle ? 'Rechteck-Aussparung' : 'Polygon-Aussparung'}: Zeichnen, Handles ziehen oder Werte eingeben. Erst OK verbindet die Formen.</p>
      <div className="button-row">
        <button type="button" onClick={onCancel}>Abbrechen</button>
        <button type="button" disabled={!preview} onClick={onApply}>OK</button>
      </div>
    </div>
  )
}



function DistanceFloatingPanel({
  pair,
  onDistanceChange,
  onClose,
}: {
  pair: DistancePair
  onDistanceChange: (valueM: number) => void
  onClose: () => void
}) {
  return (
    <div className="distance-floating-panel">
      <div className="floating-header">
        <strong>Abstand einstellen</strong>
        <button type="button" onClick={onClose} aria-label="Abstand schliessen">×</button>
      </div>
      <p>{pair.first.axis === 'vertical' ? 'Senkrechte Kanten: horizontaler Abstand' : 'Waagerechte Kanten: vertikaler Abstand'}</p>
      <label>Abstand mm<MmNumberInput valueM={pair.distanceM} minM={0} onChangeM={onDistanceChange} /></label>
    </div>
  )
}

function OuterWallDimensions({ vertices }: { vertices: PointM[] }) {
  const bounds = boundsOf(vertices)
  if (!bounds) return null
  const offset = 28
  const y = mToY(bounds.minY) - offset
  const x = mToX(bounds.maxX) + offset
  return (
    <g className="technical-dimensions outer-wall-dimensions">
      <line x1={mToX(bounds.minX)} y1={y} x2={mToX(bounds.maxX)} y2={y} />
      <DimensionTick x={mToX(bounds.minX)} y={y} />
      <DimensionTick x={mToX(bounds.maxX)} y={y} />
      <line className="extension" x1={mToX(bounds.minX)} y1={mToY(bounds.minY)} x2={mToX(bounds.minX)} y2={y} />
      <line className="extension" x1={mToX(bounds.maxX)} y1={mToY(bounds.minY)} x2={mToX(bounds.maxX)} y2={y} />
      <text x={(mToX(bounds.minX) + mToX(bounds.maxX)) / 2} y={y - 3} textAnchor="middle">{formatDimValue(bounds.maxX - bounds.minX)}</text>
      <line x1={x} y1={mToY(bounds.minY)} x2={x} y2={mToY(bounds.maxY)} />
      <DimensionTick x={x} y={mToY(bounds.minY)} />
      <DimensionTick x={x} y={mToY(bounds.maxY)} />
      <line className="extension" x1={mToX(bounds.maxX)} y1={mToY(bounds.minY)} x2={x} y2={mToY(bounds.minY)} />
      <line className="extension" x1={mToX(bounds.maxX)} y1={mToY(bounds.maxY)} x2={x} y2={mToY(bounds.maxY)} />
      <text x={x + 3} y={(mToY(bounds.minY) + mToY(bounds.maxY)) / 2} textAnchor="middle" transform={`rotate(-90 ${x + 3} ${(mToY(bounds.minY) + mToY(bounds.maxY)) / 2})`}>{formatDimValue(bounds.maxY - bounds.minY)}</text>
    </g>
  )
}

function TechnicalDimensions({ vertices, zoom = 1, offset, onStartDrag }: { vertices: PointM[]; zoom?: number; offset?: Partial<DimensionOffset>; onStartDrag?: (event: ReactMouseEvent<SVGGElement>, line: DimensionLineKey) => void }) {
  const bounds = boundsOf(vertices)
  if (!bounds) return null
  const dimOffset = normalizeDimensionOffset(offset)
  const xBreaks = dimensionBreaks(vertices.map((point) => point.x), bounds.minX, bounds.maxX)
  const yBreaks = dimensionBreaks(vertices.map((point) => point.y), bounds.minY, bounds.maxY)
  const hasXParts = xBreaks.length > 2
  const hasYParts = yBreaks.length > 2
  const roomScreenWidth = Math.abs(mToX(bounds.maxX) - mToX(bounds.minX))
  const roomScreenHeight = Math.abs(mToY(bounds.maxY) - mToY(bounds.minY))
  const compact = roomScreenWidth < 220 || roomScreenHeight < 180
  const inset = compact ? 13 : 17
  const gap = compact ? 19 : 23

  const bottomY = mToY(bounds.maxY)
  const topY = mToY(bounds.minY)
  const leftX = mToX(bounds.minX)
  const rightX = mToX(bounds.maxX)

  // Technical dimensions stay preferably inside the room. The offsets are still
  // the same per-line offsets from the previous working version.
  const yParts = bottomY - (hasXParts ? inset + gap : inset) + dimOffset.xParts
  const yTotal = bottomY - inset + dimOffset.xTotal
  const xParts = leftX + (hasYParts ? inset + gap : inset) + dimOffset.yParts
  const xTotal = leftX + inset + dimOffset.yTotal

  function horizontalLabelY(lineY: number) {
    return lineY <= bottomY ? lineY - 3 : lineY + 10
  }

  function verticalLabelX(lineX: number) {
    return lineX >= leftX ? lineX + 6 : lineX - 6
  }

  function showSegmentText(lengthM: number, availableSvgPx: number) {
    const label = formatDimValue(lengthM)
    const availableScreenPx = Math.abs(availableSvgPx) * zoom
    const requiredScreenPx = Math.max(30, label.length * 6.6)
    return availableScreenPx >= requiredScreenPx
  }

  return (
    <g className={`technical-dimensions ${compact ? 'compact' : ''}`}>
      {hasXParts && (
        <g className="dimension-drag-zone dimension-line-x-parts" onMouseDown={(event) => onStartDrag?.(event, 'xParts')}>
          <line className="hit" x1={leftX} y1={yParts} x2={rightX} y2={yParts} />
          <line className="measure-line" x1={leftX} y1={yParts} x2={rightX} y2={yParts} />
          {xBreaks.map((value, index) => {
            const next = xBreaks[index + 1]
            if (next === undefined) return null
            const length = next - value
            if (length <= 0.01) return null
            return (
              <g key={`xp-${value}-${next}`}>
                <DimensionTick x={mToX(value)} y={yParts} />
                <DimensionTick x={mToX(next)} y={yParts} />
                <line className="extension indicator-line" x1={mToX(value)} y1={topY} x2={mToX(value)} y2={bottomY} />
                {index === xBreaks.length - 2 && <line className="extension indicator-line" x1={mToX(next)} y1={topY} x2={mToX(next)} y2={bottomY} />}
                {showSegmentText(length, Math.abs(mToX(next) - mToX(value))) && <text x={(mToX(value) + mToX(next)) / 2} y={horizontalLabelY(yParts)} textAnchor="middle">{formatDimValue(length)}</text>}
              </g>
            )
          })}
        </g>
      )}

      <g className="dimension-drag-zone dimension-line-x-total" onMouseDown={(event) => onStartDrag?.(event, 'xTotal')}>
        <line className="hit" x1={leftX} y1={yTotal} x2={rightX} y2={yTotal} />
        <line className="measure-line" x1={leftX} y1={yTotal} x2={rightX} y2={yTotal} />
        <DimensionTick x={leftX} y={yTotal} />
        <DimensionTick x={rightX} y={yTotal} />
        {!hasXParts && <line className="extension indicator-line" x1={leftX} y1={topY} x2={leftX} y2={bottomY} />}
        {!hasXParts && <line className="extension indicator-line" x1={rightX} y1={topY} x2={rightX} y2={bottomY} />}
        <text x={(leftX + rightX) / 2} y={horizontalLabelY(yTotal)} textAnchor="middle">{formatDimValue(bounds.maxX - bounds.minX)}</text>
      </g>

      {hasYParts && (
        <g className="dimension-drag-zone dimension-line-y-parts" onMouseDown={(event) => onStartDrag?.(event, 'yParts')}>
          <line className="hit" x1={xParts} y1={topY} x2={xParts} y2={bottomY} />
          <line className="measure-line" x1={xParts} y1={topY} x2={xParts} y2={bottomY} />
          {yBreaks.map((value, index) => {
            const next = yBreaks[index + 1]
            if (next === undefined) return null
            const length = next - value
            if (length <= 0.01) return null
            const labelX = verticalLabelX(xParts)
            const labelY = (mToY(value) + mToY(next)) / 2
            return (
              <g key={`yp-${value}-${next}`}>
                <DimensionTick x={xParts} y={mToY(value)} />
                <DimensionTick x={xParts} y={mToY(next)} />
                <line className="extension indicator-line" x1={leftX} y1={mToY(value)} x2={rightX} y2={mToY(value)} />
                {index === yBreaks.length - 2 && <line className="extension indicator-line" x1={leftX} y1={mToY(next)} x2={rightX} y2={mToY(next)} />}
                {showSegmentText(length, Math.abs(mToY(next) - mToY(value))) && <text x={labelX} y={labelY} textAnchor="middle" transform={`rotate(-90 ${labelX} ${labelY})`}>{formatDimValue(length)}</text>}
              </g>
            )
          })}
        </g>
      )}

      <g className="dimension-drag-zone dimension-line-y-total" onMouseDown={(event) => onStartDrag?.(event, 'yTotal')}>
        <line className="hit" x1={xTotal} y1={topY} x2={xTotal} y2={bottomY} />
        <line className="measure-line" x1={xTotal} y1={topY} x2={xTotal} y2={bottomY} />
        <DimensionTick x={xTotal} y={topY} />
        <DimensionTick x={xTotal} y={bottomY} />
        {!hasYParts && <line className="extension indicator-line" x1={leftX} y1={topY} x2={rightX} y2={topY} />}
        {!hasYParts && <line className="extension indicator-line" x1={leftX} y1={bottomY} x2={rightX} y2={bottomY} />}
        {(() => {
          const labelX = verticalLabelX(xTotal)
          const labelY = (topY + bottomY) / 2
          return <text x={labelX} y={labelY} textAnchor="middle" transform={`rotate(-90 ${labelX} ${labelY})`}>{formatDimValue(bounds.maxY - bounds.minY)}</text>
        })()}
      </g>
    </g>
  )
}

function RecessOffsetDimension({ room, preview }: { room: Room; preview: RecessPreview }) {
  const bounds = boundsOf(room.vertices)
  if (!bounds) return null
  const edge = preview.edge
  const rect = preview.rect
  const offset = offsetFromPreview(room, preview)
  if (offset <= 0.001) return null
  if (edge === 'top' || edge === 'bottom') {
    const y = mToY((rect.minY + rect.maxY) / 2)
    const x1 = preview.offsetFromEnd ? mToX(bounds.maxX) : mToX(bounds.minX)
    const x2 = preview.offsetFromEnd ? mToX(rect.maxX) : mToX(rect.minX)
    const midX = (x1 + x2) / 2
    return (
      <g className="recess-offset-dim">
        <line x1={x1} y1={y} x2={x2} y2={y} />
        <DimensionTick x={x1} y={y} />
        <DimensionTick x={x2} y={y} />
        <text x={midX} y={y - 6} textAnchor="middle">{formatM(offset)}</text>
      </g>
    )
  }
  const x = mToX((rect.minX + rect.maxX) / 2)
  const y1 = preview.offsetFromEnd ? mToY(bounds.maxY) : mToY(bounds.minY)
  const y2 = preview.offsetFromEnd ? mToY(rect.maxY) : mToY(rect.minY)
  const midY = (y1 + y2) / 2
  return (
    <g className="recess-offset-dim">
      <line x1={x} y1={y1} x2={x} y2={y2} />
      <DimensionTick x={x} y={y1} />
      <DimensionTick x={x} y={y2} />
      <text x={x + 6} y={midY} textAnchor="middle" transform={`rotate(-90 ${x + 6} ${midY})`}>{formatM(offset)}</text>
    </g>
  )
}

function DimensionTick({ x, y }: { x: number; y: number }) {
  return <line className="tick" x1={x - 7} y1={y + 7} x2={x + 7} y2={y - 7} />
}

function RoomShape({
  room,
  vertices,
  selected,
  interactive,
  distanceMode = false,
  distanceFirstEdge,
  distancePair,
  onStartDrag,
  onSelect,
  onStartRectHandle,
  onStartVertexDrag,
  onStartPolygonEdgeDrag,
  onPickDistanceEdge,
  titleOffset = { x: 0, y: 0 },
  onStartTitleDrag,
  ghost = false,
}: {
  room: Room
  vertices: PointM[]
  selected: boolean
  interactive: boolean
  distanceMode?: boolean
  distanceFirstEdge?: DistanceEdgeSelection | null
  distancePair?: DistancePair | null
  onStartDrag: (event: ReactMouseEvent<SVGGElement>, room: Room) => void
  onSelect: (id: string) => void
  onStartRectHandle: (event: ReactMouseEvent<SVGLineElement>, room: Room, handle: RectHandle) => void
  onStartVertexDrag: (event: ReactMouseEvent<SVGCircleElement>, room: Room, index: number) => void
  onStartPolygonEdgeDrag: (event: ReactMouseEvent<SVGLineElement>, room: Room, index: number) => void
  onPickDistanceEdge?: (event: ReactMouseEvent<SVGLineElement>, room: Room, vertices: PointM[], index: number) => void
  titleOffset?: TitleOffset
  onStartTitleDrag?: (event: ReactMouseEvent<SVGGElement>, room: Room) => void
  ghost?: boolean
}) {
  const verticesText = pointsToSvg(vertices)
  const center = centroid(vertices)
  const area = polygonAreaM2(vertices)
  const bounds = boundsOf(vertices)
  const topLeft = bounds ? { x: bounds.minX, y: bounds.minY } : center
  const outerWall = isOuterWallRoom(room)
  const stairRoom = isStairRoom(room)
  const stairLayoutElements = stairRoom ? readStairLayoutElements(room.id) : []

  return (
    <g className={`room-group ${selected ? 'selected' : ''} ${outerWall ? 'outer-wall-room' : ''} ${stairRoom ? 'stair-room-group' : ''} ${ghost ? 'ghost-room-group' : ''}`} onMouseDown={(event) => { if (interactive) onStartDrag(event, room) }} onClick={(event) => { if (!interactive) return; event.stopPropagation(); onSelect(room.id) }}>
      <polygon points={verticesText} className="room" />
      <polyline points={`${verticesText} ${mToX(vertices[0]?.x ?? 0)},${mToY(vertices[0]?.y ?? 0)}`} className="wall-outline" />
      {selected && room.shapeType === 'polygon' && (
        <g className="polygon-edge-handles">
          {vertices.map((point, index) => {
            const next = vertices[(index + 1) % vertices.length]
            return (
              <line
                key={`edge-${index}`}
                className="polygon-edge-handle"
                x1={mToX(point.x)}
                y1={mToY(point.y)}
                x2={mToX(next.x)}
                y2={mToY(next.y)}
                onMouseDown={(event) => onStartPolygonEdgeDrag(event, room, index)}
              />
            )
          })}
        </g>
      )}
      {distanceMode && (
        <g className="distance-edge-pickers">
          {vertices.map((point, index) => {
            const next = vertices[(index + 1) % vertices.length]
            const isFirst = isDistanceEdgeMatch(distanceFirstEdge, room.id, index)
            const isPair = Boolean(distancePair && (isDistanceEdgeMatch(distancePair.first, room.id, index) || isDistanceEdgeMatch(distancePair.second, room.id, index)))
            return (
              <line
                key={`distance-edge-${index}`}
                className={`distance-edge-picker ${isFirst ? 'first' : ''} ${isPair ? 'paired' : ''}`}
                x1={mToX(point.x)}
                y1={mToY(point.y)}
                x2={mToX(next.x)}
                y2={mToY(next.y)}
                onMouseDown={(event) => onPickDistanceEdge?.(event, room, vertices, index)}
                onClick={(event) => { event.preventDefault(); event.stopPropagation() }}
              />
            )
          })}
        </g>
      )}
      {bounds && (
        <g className="room-anchor" aria-label={`Position ${formatM(bounds.minX)} / ${formatM(bounds.minY)}`}>
          <line x1={mToX(topLeft.x) - 7} y1={mToY(topLeft.y)} x2={mToX(topLeft.x) + 7} y2={mToY(topLeft.y)} />
          <line x1={mToX(topLeft.x)} y1={mToY(topLeft.y) - 7} x2={mToX(topLeft.x)} y2={mToY(topLeft.y) + 7} />
          <circle cx={mToX(topLeft.x)} cy={mToY(topLeft.y)} r="2.2" />
        </g>
      )}
      {stairRoom && bounds && (
        <g className="room-stair-indicator" transform={`translate(${mToX(topLeft.x) + 12}, ${mToY(topLeft.y) + 8})`} aria-label="Treppenindikator">
          <path d="M0 14 H4 V10 H8 V6 H12 V2 H16" />
          <path d="M0 18 H17" />
        </g>
      )}
      {stairRoom && bounds && stairLayoutElements.length > 0 && <StairBlueprintLayoutOverlay room={room} elements={stairLayoutElements} />}
      {!outerWall && (
        <g className="room-title" transform={`translate(${titleOffset.x}, ${titleOffset.y})`} onMouseDown={(event) => { event.stopPropagation(); onStartTitleDrag?.(event, room) }}>
          <text x={mToX(center.x)} y={mToY(center.y)} dy="-0.24em" textAnchor="middle" className="room-label">{room.name}</text>
          <text x={mToX(center.x)} y={mToY(center.y)} dy="0.95em" textAnchor="middle" className="room-measure">{formatM2(area)}</text>
          {stairRoom && <text x={mToX(center.x)} y={mToY(center.y)} dy="2.05em" textAnchor="middle" className="room-stair-label">Treppenraum</text>}
        </g>
      )}
      {selected && !outerWall && <DimensionLabels vertices={vertices} />}
      {stairRoom && bounds && stairLayoutElements.length > 0 && <StairBlueprintVisibilityOverlay room={room} elements={stairLayoutElements} />}
      {selected && room.shapeType === 'rectangle' && bounds && (
        <g className="rect-selection">
          <polyline points={`${verticesText} ${mToX(vertices[0]?.x ?? 0)},${mToY(vertices[0]?.y ?? 0)}`} className="selected-edit-line" />
          {vertices.map((point, index) => (
            <circle key={`rect-corner-${index}`} className="rect-corner-marker" cx={mToX(point.x)} cy={mToY(point.y)} r="7" />
          ))}
          <g className="rect-handles">

          <line className="rect-resize-handle vertical" x1={mToX(bounds.minX)} y1={mToY(bounds.minY)} x2={mToX(bounds.minX)} y2={mToY(bounds.maxY)} onMouseDown={(event) => onStartRectHandle(event, room, 'left')} />
          <line className="rect-resize-handle vertical" x1={mToX(bounds.maxX)} y1={mToY(bounds.minY)} x2={mToX(bounds.maxX)} y2={mToY(bounds.maxY)} onMouseDown={(event) => onStartRectHandle(event, room, 'right')} />
          <line className="rect-resize-handle horizontal" x1={mToX(bounds.minX)} y1={mToY(bounds.minY)} x2={mToX(bounds.maxX)} y2={mToY(bounds.minY)} onMouseDown={(event) => onStartRectHandle(event, room, 'top')} />
          <line className="rect-resize-handle horizontal" x1={mToX(bounds.minX)} y1={mToY(bounds.maxY)} x2={mToX(bounds.maxX)} y2={mToY(bounds.maxY)} onMouseDown={(event) => onStartRectHandle(event, room, 'bottom')} />
          </g>
        </g>
      )}
      {selected && room.shapeType === 'polygon' && vertices.map((point, index) => (
        <circle key={index} className="vertex-handle" cx={mToX(point.x)} cy={mToY(point.y)} r="7" onMouseDown={(event) => onStartVertexDrag(event, room, index)} />
      ))}
    </g>
  )
}

function DimensionLabels({ vertices, muted = false }: { vertices: PointM[]; muted?: boolean }) {
  if (vertices.length < 2) return null
  const items = vertices.map((point, index) => {
    const next = vertices[(index + 1) % vertices.length]
    const mid = { x: (point.x + next.x) / 2, y: (point.y + next.y) / 2 }
    const len = distance(point, next)
    if (len < 0.08) return null
    return <text key={index} x={mToX(mid.x)} y={mToY(mid.y) - 5} textAnchor="middle" className={`edge-label ${muted ? 'muted' : ''}`}>{formatSelectedDimensionM(len)}</text>
  })
  return <>{items}</>
}


function CanvasRulers({ zoom, scrollLeft, scrollTop }: { zoom: number; scrollLeft: number; scrollTop: number }) {
  const ticks = Array.from({ length: canvas.maxM - canvas.minM + 1 }, (_, index) => canvas.minM + index)
  return (
    <div className="canvas-rulers" aria-hidden="true">
      <div className="canvas-ruler-corner" />
      <div className="canvas-ruler-top">
        {ticks.map((meter) => {
          const major = meter % 5 === 0
          return (
            <span key={`rt-${meter}`} className={`canvas-ruler-tick ${major ? 'major' : ''}`} style={{ left: mToX(meter) * zoom - scrollLeft }}>
              {major && <em>{meter}</em>}
            </span>
          )
        })}
      </div>
      <div className="canvas-ruler-left">
        {ticks.map((meter) => {
          const major = meter % 5 === 0
          return (
            <span key={`rl-${meter}`} className={`canvas-ruler-tick ${major ? 'major' : ''}`} style={{ top: mToY(meter) * zoom - scrollTop }}>
              {major && <em>{meter}</em>}
            </span>
          )
        })}
      </div>
    </div>
  )
}

function Grid() {
  const lines = []
  for (let meter = canvas.minM; meter <= canvas.maxM; meter += 1) {
    const major = meter % 5 === 0
    lines.push(<line key={`x-${meter}`} x1={mToX(meter)} y1={mToY(canvas.minM)} x2={mToX(meter)} y2={mToY(canvas.maxM)} className={major ? 'major' : ''} />)
    lines.push(<line key={`y-${meter}`} x1={mToX(canvas.minM)} y1={mToY(meter)} x2={mToX(canvas.maxM)} y2={mToY(meter)} className={major ? 'major' : ''} />)
    if (major) {
      lines.push(<text key={`tx-${meter}`} x={mToX(meter)} y={mToY(canvas.minM) - 10} textAnchor="middle">{meter} m</text>)
      lines.push(<text key={`ty-${meter}`} x={mToX(canvas.minM) - 12} y={mToY(meter) + 4} textAnchor="end">{meter} m</text>)
    }
  }
  return <g className="grid">{lines}</g>
}


function BlueprintWallObjectConnections({ wallObjects, rooms }: { wallObjects: ApiWallObject[]; rooms: Room[] }) {
  const byGroup = wallObjects
    .filter((item) => item.objectType === 'door' && item.groupId && !isFullWallOpenGroupId(item.groupId))
    .reduce<Record<string, ApiWallObject[]>>((acc, item) => {
      const key = item.groupId || item.id
      acc[key] = [...(acc[key] ?? []), item]
      return acc
    }, {})

  const connectors = Object.entries(byGroup).flatMap(([groupId, groupItems]) => {
    const segments = groupItems
      .map((item) => blueprintWallObjectSegment(item, rooms))
      .filter((segment): segment is BlueprintWallSegment => Boolean(segment))
    if (segments.length < 2) return []
    const pair = bestBlueprintConnectionPair(segments)
    const normalized = normalizeBlueprintConnectionPair(pair.a, pair.b)
    return [{ groupId, points: [normalized.a.left, normalized.a.right, normalized.b.right, normalized.b.left] }]
  })

  if (connectors.length === 0) return null
  return (
    <g className="blueprint-wall-object-connections" aria-label="Wanddetail-Durchgaenge">
      {connectors.map((connector) => (
        <polygon
          key={connector.groupId}
          points={connector.points.map((point) => `${mToX(point.x)},${mToY(point.y)}`).join(' ')}
          className="blueprint-wall-connection-door"
        />
      ))}
    </g>
  )
}

type BlueprintWallSegment = {
  left: PointM
  right: PointM
  edge: { a: PointM; b: PointM }
}

function blueprintWallObjectSegment(item: ApiWallObject, rooms: Room[]): BlueprintWallSegment | null {
  const room = rooms.find((candidate) => candidate.id === item.roomId)
  if (!room || room.vertices.length < 2) return null
  const edge = edgePoints(room.vertices, item.edgeIndex)
  if (!edge) return null
  const len = distance(edge.a, edge.b)
  if (len < 0.0001) return null
  const t = clamp(item.x, 0, 1)
  const half = clamp(item.w / 2, 0.005, 0.495)
  const leftT = clamp(t - half, 0, 1)
  const rightT = clamp(t + half, 0, 1)
  const pointAt = (value: number): PointM => ({
    x: round3(edge.a.x + (edge.b.x - edge.a.x) * value),
    y: round3(edge.a.y + (edge.b.y - edge.a.y) * value),
  })
  return { left: pointAt(leftT), right: pointAt(rightT), edge }
}

function bestBlueprintConnectionPair(segments: BlueprintWallSegment[]) {
  let best = { a: segments[0], b: segments[1], score: Number.POSITIVE_INFINITY }
  for (let i = 0; i < segments.length; i += 1) {
    for (let j = i + 1; j < segments.length; j += 1) {
      const a = segments[i]
      const b = segments[j]
      const centerA = { x: (a.left.x + a.right.x) / 2, y: (a.left.y + a.right.y) / 2 }
      const centerB = { x: (b.left.x + b.right.x) / 2, y: (b.left.y + b.right.y) / 2 }
      const score = distance(centerA, centerB)
      if (score < best.score) best = { a, b, score }
    }
  }
  return { a: best.a, b: best.b }
}

function normalizeBlueprintConnectionPair(a: BlueprintWallSegment, b: BlueprintWallSegment) {
  const axisDx = a.edge.b.x - a.edge.a.x
  const axisDy = a.edge.b.y - a.edge.a.y
  const axisLen = Math.hypot(axisDx, axisDy) || 1
  const ux = axisDx / axisLen
  const uy = axisDy / axisLen
  const origin = a.edge.a
  const scalar = (point: PointM) => (point.x - origin.x) * ux + (point.y - origin.y) * uy
  const sorted = (left: PointM, right: PointM) => {
    const values = [scalar(left), scalar(right)].sort((x, y) => x - y)
    return { min: values[0], max: values[1] }
  }
  const intervalA = sorted(a.left, a.right)
  const intervalB = sorted(b.left, b.right)
  const edgeA = sorted(a.edge.a, a.edge.b)
  const edgeB = sorted(b.edge.a, b.edge.b)
  const overlapMin = Math.max(edgeA.min, edgeB.min)
  const overlapMax = Math.min(edgeA.max, edgeB.max)
  if (overlapMax - overlapMin < 0.001) return alignBlueprintSegmentPair(a, b)

  let commonMin = clamp((intervalA.min + intervalB.min) / 2, overlapMin, overlapMax)
  let commonMax = clamp((intervalA.max + intervalB.max) / 2, overlapMin, overlapMax)
  if (commonMax < commonMin) [commonMin, commonMax] = [commonMax, commonMin]
  if (commonMax - commonMin < 0.01) {
    const center = clamp((commonMin + commonMax) / 2, overlapMin, overlapMax)
    commonMin = clamp(center - 0.005, overlapMin, overlapMax)
    commonMax = clamp(center + 0.005, overlapMin, overlapMax)
  }

  const pointOnEdge = (edge: { a: PointM; b: PointM }, targetScalar: number): PointM => {
    const aScalar = scalar(edge.a)
    const bScalar = scalar(edge.b)
    const denom = bScalar - aScalar
    const t = Math.abs(denom) < 0.000001 ? 0 : clamp((targetScalar - aScalar) / denom, 0, 1)
    return {
      x: round3(edge.a.x + (edge.b.x - edge.a.x) * t),
      y: round3(edge.a.y + (edge.b.y - edge.a.y) * t),
    }
  }

  return {
    a: { ...a, left: pointOnEdge(a.edge, commonMin), right: pointOnEdge(a.edge, commonMax) },
    b: { ...b, left: pointOnEdge(b.edge, commonMin), right: pointOnEdge(b.edge, commonMax) },
  }
}

function alignBlueprintSegmentPair(a: BlueprintWallSegment, b: BlueprintWallSegment) {
  const same = distance(a.left, b.left) + distance(a.right, b.right)
  const swapped = distance(a.left, b.right) + distance(a.right, b.left)
  if (swapped < same) return { a, b: { ...b, left: b.right, right: b.left } }
  return { a, b }
}

type WallSelection = { roomId: string; edgeIndex: number }
type WallRotationDrag = { startX: number; startY: number; startYawDeg: number; startPitchDeg: number }
type SvgPoint = { x: number; y: number }
type WallOverlayMotion = { startDx: number; startDy: number; startRotate: number; startScale: number; initialX: number; initialY: number }
type RenderedProjectedRoom = { room: Room; outerWall: boolean; selectedRoom: boolean; avgDepth: number; projected: ProjectedRoom3D }
type RenderedWallFace = { room: Room; outerWall: boolean; edgeIndex: number; selected: boolean; points: SvgPoint[]; avgDepth: number; axis: { x: number; y: number; originX: number; originY: number }; modelFaceId?: string; pairGroupKey?: string; pairedFaceIds?: string[] }
type WallLibraryItemType = 'door' | 'window' | 'socket'
type WallPlacedObject = { id: string; type: WallLibraryItemType; x: number; y: number; w: number; h: number; groupId?: string }
type WallFaceLocation = { key: string; roomId: string; edgeIndex: number; reversed: boolean }
type WallObjectResizeMode = 'resize' | 'resize-left' | 'resize-right' | 'resize-top' | 'resize-bottom'
type WallObjectDragState = { mode: 'move' | WallObjectResizeMode; id: string; startX: number; startY: number; original: WallPlacedObject; drawW: number; drawH: number; scaleX: number; scaleY: number }
type WallModelRoom3D = { id: string; room: Room; outerWall: boolean; floorLoop: Vec3[]; ceilingLoop: Vec3[]; labelPoint: Vec3 }
type WallModelFace3D = { id: string; key: string; room: Room; roomId: string; edgeIndex: number; outerWall: boolean; a: Vec3; b: Vec3; topB: Vec3; topA: Vec3; lengthM: number; pairGroupKey: string; pairedFaceIds: string[] }
type WallModel3D = { floorId: string; heightM: number; rooms: WallModelRoom3D[]; faces: WallModelFace3D[]; bounds: Bounds | null; originM: PointM; outerRoomId?: string }

const defaultWallViewYawDeg = 67
const defaultWallViewPitchDeg = 71
const introWallViewYawDeg = 90
const introWallViewPitchDeg = 90
const wallIntroDurationMs = 600
const wallIntroRevealDurationMs = 300

function defaultWallObjectSize(type: WallLibraryItemType) {
  if (type === 'door') return { w: 0.16, h: 0.68 }
  if (type === 'window') return { w: 0.24, h: 0.24 }
  return { w: 0.06, h: 0.06 }
}

function WallDetailEditor({
  floor,
  rooms,
  selectedRoomId,
  onSelectRoom,
  canUndo,
  onUndo,
}: {
  floor: Floor
  rooms: Room[]
  selectedRoomId: string
  onSelectRoom: (id: string) => void
  canUndo: boolean
  onUndo: () => void
}) {
  const [zoom, setZoom] = useState(() => loadCanvasViewport(floor.id).zoom)
  const [scrollPosition, setScrollPosition] = useState(() => {
    const viewport = loadCanvasViewport(floor.id)
    return { left: viewport.left, top: viewport.top }
  })
  const [layers, setLayers] = useState<FloorplanLayer[]>(() => loadFloorplanLayers(floor.id))
  const [activeLayerId, setActiveLayerId] = useState<string>(() => loadActiveLayerId(floor.id, loadFloorplanLayers(floor.id)))
  const [roomLayerAssignments, setRoomLayerAssignments] = useState<Record<string, string>>(() => loadLayerAssignments(floor.id))
  const [layersOpen, setLayersOpen] = useState(false)
  const [selectedWall, setSelectedWall] = useState<WallSelection | null>(null)
  const [hoveredWall, setHoveredWall] = useState<WallSelection | null>(null)
  const [wallObjectsByKey, setWallObjectsByKey] = useState<Record<string, WallPlacedObject[]>>({})
  const [viewTool, setViewTool] = useState<WallViewTool>('rotate')
  const [rotationDeg, setRotationDeg] = useState(defaultWallViewYawDeg)
  const [rotationInput, setRotationInput] = useState(String(defaultWallViewYawDeg))
  const [tiltDeg, setTiltDeg] = useState(defaultWallViewPitchDeg)
  const [tiltInput, setTiltInput] = useState(String(defaultWallViewPitchDeg))
  const [wallHeightM, setWallHeightMState] = useState(() => loadWallHeightM(floor.id, floor.heightM))
  const [wallHeightInput, setWallHeightInput] = useState(() => String(loadWallHeightM(floor.id, floor.heightM)))
  const [introReady, setIntroReady] = useState(false)
  const [introPhase, setIntroPhase] = useState<'animating' | 'revealing' | 'ready'>('animating')
  const [introProgress, setIntroProgress] = useState(0)
  const [introRevealProgress, setIntroRevealProgress] = useState(0)
  const canvasScrollRef = useRef<HTMLDivElement | null>(null)
  const panDragRef = useRef<{ startX: number; startY: number; scrollLeft: number; scrollTop: number; moved: boolean } | null>(null)
  const rotationDragRef = useRef<WallRotationDrag | null>(null)
  const initializedCanvasScrollRef = useRef<string>('')

  useEffect(() => {
    const nextLayers = loadFloorplanLayers(floor.id)
    setLayers(nextLayers)
    setActiveLayerId(loadActiveLayerId(floor.id, nextLayers))
    setRoomLayerAssignments(loadLayerAssignments(floor.id))
    setLayersOpen(false)
    setSelectedWall(null)
    setHoveredWall(null)
    setViewTool('rotate')
    setRotationDeg(introWallViewYawDeg)
    setRotationInput(String(introWallViewYawDeg))
    setTiltDeg(introWallViewPitchDeg)
    setTiltInput(String(introWallViewPitchDeg))
    saveWallCanvasRotation(floor.id, defaultWallViewYawDeg)
    const storedHeight = loadWallHeightM(floor.id, floor.heightM)
    setWallHeightMState(storedHeight)
    setWallHeightInput(String(storedHeight))
    saveWallHeightM(floor.id, storedHeight)
    const entryViewport = loadCanvasViewport(floor.id)
    const targetZoom = clamp(round2(entryViewport.zoom * 0.9), 0.22, 2.5)
    setIntroReady(false)
    setIntroPhase('animating')
    setIntroProgress(0)
    setIntroRevealProgress(0)
    let frameId = 0
    let revealFrameId = 0
    const start = performance.now()
    const animate = (now: number) => {
      const t = clamp((now - start) / wallIntroDurationMs, 0, 1)
      const eased = easeInOutCubic(t)
      const yaw = introWallViewYawDeg + (defaultWallViewYawDeg - introWallViewYawDeg) * eased
      const pitch = introWallViewPitchDeg + (defaultWallViewPitchDeg - introWallViewPitchDeg) * eased
      setRotationDeg(round2(yaw))
      setRotationInput(formatRotationInput(round2(yaw)))
      setTiltDeg(round2(pitch))
      setTiltInput(formatTiltInput(round2(pitch)))
      setIntroProgress(eased)
      if (t < 1) {
        frameId = window.requestAnimationFrame(animate)
        return
      }
      setWallRotation(defaultWallViewYawDeg)
      setWallTilt(defaultWallViewPitchDeg)
      setZoom(targetZoom)
      saveCanvasViewport(floor.id, { zoom: targetZoom, left: entryViewport.left, top: entryViewport.top })
      setIntroPhase('revealing')
      const revealStart = performance.now()
      const reveal = (revealNow: number) => {
        const revealT = clamp((revealNow - revealStart) / wallIntroRevealDurationMs, 0, 1)
        setIntroRevealProgress(easeOutCubic(revealT))
        if (revealT < 1) {
          revealFrameId = window.requestAnimationFrame(reveal)
          return
        }
        setIntroPhase('ready')
        setIntroReady(true)
      }
      revealFrameId = window.requestAnimationFrame(reveal)
    }
    frameId = window.requestAnimationFrame(animate)
    return () => {
      if (frameId) window.cancelAnimationFrame(frameId)
      if (revealFrameId) window.cancelAnimationFrame(revealFrameId)
    }
  }, [floor.id])

  useEffect(() => {
    const viewport = loadCanvasViewport(floor.id)
    setZoom(viewport.zoom)
    setScrollPosition({ left: viewport.left, top: viewport.top })
    window.requestAnimationFrame(() => {
      const scroll = canvasScrollRef.current
      if (!scroll || initializedCanvasScrollRef.current === floor.id) return
      initializedCanvasScrollRef.current = floor.id
      const fallbackLeft = Math.max(0, mToX(0) - canvas.margin)
      const fallbackTop = Math.max(0, mToY(0) - canvas.margin)
      scroll.scrollLeft = viewport.left > 0 ? viewport.left : fallbackLeft
      scroll.scrollTop = viewport.top > 0 ? viewport.top : fallbackTop
      setScrollPosition({ left: scroll.scrollLeft, top: scroll.scrollTop })
      saveCanvasViewport(floor.id, { zoom: viewport.zoom, left: scroll.scrollLeft, top: scroll.scrollTop })
    })
  }, [floor.id])

  useEffect(() => {
    const layerIds = new Set(layers.map((layer) => layer.id))
    if (!layerIds.has(activeLayerId)) setActiveLayerId(layers[0]?.id ?? defaultLayerId)
  }, [layers, activeLayerId])

  useEffect(() => {
    function handleKeyDown(event: KeyboardEvent) {
      if (event.key === 'Escape') setSelectedWall(null)
    }
    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [])

  useEffect(() => {
    void reloadWallObjects()
  }, [floor.id])

  function formatRotationInput(value: number) {
    return Number.isInteger(value) ? String(Math.round(value)) : String(round2(value))
  }

  function setWallRotation(next: number) {
    const normalized = normalizeDegrees(next)
    setRotationDeg(normalized)
    setRotationInput(formatRotationInput(normalized))
    saveWallCanvasRotation(floor.id, normalized)
  }

  function updateWallRotationWithoutInputRewrite(next: number) {
    const normalized = normalizeDegrees(next)
    setRotationDeg(normalized)
    saveWallCanvasRotation(floor.id, normalized)
  }

  function handleRotationInputChange(event: ReactChangeEvent<HTMLInputElement>) {
    const raw = event.target.value
    setRotationInput(raw)
    const normalizedRaw = raw.replace(',', '.')
    if (normalizedRaw.trim() === '' || normalizedRaw === '-' || normalizedRaw === '+' || normalizedRaw === '.' || normalizedRaw === ',') return
    const next = Number(normalizedRaw)
    if (Number.isFinite(next)) updateWallRotationWithoutInputRewrite(next)
  }

  function handleRotationInputBlur() {
    setWallRotation(rotationDeg)
  }

  function formatTiltInput(value: number) {
    return Number.isInteger(value) ? String(Math.round(value)) : String(round2(value))
  }

  function setWallTilt(next: number) {
    const normalized = clamp(round2(next), 15, 85)
    setTiltDeg(normalized)
    setTiltInput(formatTiltInput(normalized))
  }

  function updateWallTiltWithoutInputRewrite(next: number) {
    const normalized = clamp(round2(next), 15, 85)
    setTiltDeg(normalized)
  }

  function handleTiltInputChange(event: ReactChangeEvent<HTMLInputElement>) {
    const raw = event.target.value
    setTiltInput(raw)
    const normalizedRaw = raw.replace(',', '.')
    if (normalizedRaw.trim() === '' || normalizedRaw === '-' || normalizedRaw === '+' || normalizedRaw === '.' || normalizedRaw === ',') return
    const next = Number(normalizedRaw)
    if (Number.isFinite(next)) updateWallTiltWithoutInputRewrite(next)
  }

  function handleTiltInputBlur() {
    setWallTilt(tiltDeg)
  }

  function formatHeightInputValue(value: number) {
    return Number.isInteger(value) ? String(Math.round(value)) : String(round2(value))
  }

  function setWallHeight(next: number) {
    const normalized = clamp(round2(next), 0.1, 10)
    setWallHeightMState(normalized)
    setWallHeightInput(formatHeightInputValue(normalized))
    saveWallHeightM(floor.id, normalized)
  }

  function updateWallHeightWithoutInputRewrite(next: number) {
    const normalized = clamp(round2(next), 0.1, 10)
    setWallHeightMState(normalized)
    saveWallHeightM(floor.id, normalized)
  }

  function handleWallHeightInputChange(event: ReactChangeEvent<HTMLInputElement>) {
    const raw = event.target.value
    setWallHeightInput(raw)
    const normalizedRaw = raw.replace(',', '.')
    if (normalizedRaw.trim() === '' || normalizedRaw === '-' || normalizedRaw === '+' || normalizedRaw === '.' || normalizedRaw === ',') return
    const next = Number(normalizedRaw)
    if (Number.isFinite(next)) updateWallHeightWithoutInputRewrite(next)
  }

  function handleWallHeightInputBlur() {
    setWallHeight(wallHeightM)
  }

  function resetWallViewportRotation() {
    setWallRotation(defaultWallViewYawDeg)
    setWallTilt(defaultWallViewPitchDeg)
    setViewTool('rotate')
  }

  const activeLayer = layers.find((layer) => layer.id === activeLayerId) ?? layers[0] ?? defaultFloorplanLayers()[0]
  const wallDetailRooms = useMemo(() => rooms, [rooms])
  const visibleRooms = useMemo(
    () => wallDetailRooms.filter((room) => (roomLayerAssignments[room.id] ?? defaultLayerId) === activeLayerId),
    [wallDetailRooms, roomLayerAssignments, activeLayerId],
  )
  const selectedWallRoom = selectedWall ? wallDetailRooms.find((room) => room.id === selectedWall.roomId) ?? null : null
  const selectedWallLength = selectedWallRoom && selectedWall ? edgeLength(selectedWallRoom.vertices, selectedWall.edgeIndex) : 0
  const selectedWallEdge = selectedWallRoom && selectedWall ? edgePoints(selectedWallRoom.vertices, selectedWall.edgeIndex) : null
  const selectedWallTitle = selectedWallRoom && selectedWall
    ? `${cleanRoomName(selectedWallRoom)} · Wand ${selectedWall.edgeIndex + 1}`
    : ''
  const selectedWallObjects = useMemo(() => {
    if (!selectedWall || !selectedWallRoom) return []
    return wallObjectsForSelectedWall(floor.id, selectedWallRoom, selectedWall.edgeIndex, wallDetailRooms, wallObjectsByKey)
  }, [floor.id, selectedWall, selectedWallRoom, wallDetailRooms, wallObjectsByKey])

  async function reloadWallObjects() {
    try {
      const objects = await getWallObjects(floor.id)
      setWallObjectsByKey(groupApiWallObjects(objects))
    } catch (err) {
      console.warn('Wandobjekte konnten nicht geladen werden', err)
    }
  }

  async function addWallObject(type: WallLibraryItemType, x: number, y: number) {
    if (!selectedWall || !selectedWallRoom) return
    const size = defaultWallObjectSize(type)
    const groupId = `wall-group-${Date.now()}-${Math.round(Math.random() * 10000)}`
    const sourceItem = normalizeWallPlacedObject({
      id: `temp-source-${groupId}`,
      type,
      groupId,
      x,
      y,
      w: size.w,
      h: size.h,
    })
    const targets = pairedWallLocations(floor.id, selectedWallRoom, selectedWall.edgeIndex, wallDetailRooms)
    const optimisticByKey = targets.map((target) => {
      const targetRoom = wallDetailRooms.find((room) => room.id === target.roomId) ?? selectedWallRoom
      const placed = projectWallPlacedObjectBetweenRooms(sourceItem, selectedWallRoom, selectedWall.edgeIndex, targetRoom, target.edgeIndex)
      return {
        target,
        item: { ...placed, id: `temp-${target.key}-${groupId}` },
      }
    })
    setWallObjectsByKey((current) => {
      const next = { ...current }
      optimisticByKey.forEach(({ target, item }) => {
        next[target.key] = [...(next[target.key] ?? []), item]
      })
      return next
    })
    try {
      await Promise.all(optimisticByKey.map(({ target, item }) => createWallObject({
        floorId: floor.id,
        roomId: target.roomId,
        edgeIndex: target.edgeIndex,
        objectType: item.type,
        x: item.x,
        y: item.y,
        w: item.w,
        h: item.h,
        groupId,
      })))
      await reloadWallObjects()
    } catch (err) {
      console.warn('Wandobjekt konnte nicht gespeichert werden', err)
      await reloadWallObjects()
    }
  }

  async function toggleFullWallOpen() {
    if (!selectedWall || !selectedWallRoom) return
    const existing = selectedWallObjects.find((item) => isFullWallOpenObject(item))
    if (existing) {
      deleteWallObject(existing.id)
      return
    }
    const groupId = `${FULL_WALL_OPEN_GROUP_PREFIX}${Date.now()}-${Math.round(Math.random() * 10000)}`
    const sourceItem = normalizeWallPlacedObject({
      id: `temp-source-${groupId}`,
      type: 'door',
      groupId,
      x: 0.5,
      y: 0.5,
      w: 1,
      h: 1,
    })
    const targets = pairedWallLocations(floor.id, selectedWallRoom, selectedWall.edgeIndex, wallDetailRooms)
    const optimisticByKey = targets.map((target) => {
      const targetRoom = wallDetailRooms.find((room) => room.id === target.roomId) ?? selectedWallRoom
      const placed = projectWallPlacedObjectBetweenRooms(sourceItem, selectedWallRoom, selectedWall.edgeIndex, targetRoom, target.edgeIndex)
      return {
        target,
        item: { ...placed, id: `temp-${target.key}-${groupId}`, groupId, type: 'door' as WallLibraryItemType },
      }
    })
    setWallObjectsByKey((current) => {
      const next = { ...current }
      optimisticByKey.forEach(({ target, item }) => {
        next[target.key] = [...(next[target.key] ?? []), item]
      })
      return next
    })
    try {
      await Promise.all(optimisticByKey.map(({ target, item }) => createWallObject({
        floorId: floor.id,
        roomId: target.roomId,
        edgeIndex: target.edgeIndex,
        objectType: item.type,
        x: item.x,
        y: item.y,
        w: item.w,
        h: item.h,
        groupId,
      })))
      await reloadWallObjects()
    } catch (err) {
      console.warn('Komplette Wandoeffnung konnte nicht gespeichert werden', err)
      await reloadWallObjects()
    }
  }

  function updateWallObject(id: string, patch: Partial<WallPlacedObject>) {
    if (!selectedWall || !selectedWallRoom) return
    const currentState = wallObjectsByKey
    const source = findWallObjectEntry(currentState, id)
    if (!source) return
    const sourceBase = normalizeWallPlacedObject({ ...source.item, ...patch })
    const affected = source.item.groupId
      ? findWallObjectsByGroup(currentState, source.item.groupId)
      : [source]

    setWallObjectsByKey((current) => {
      const next = { ...current }
      affected.forEach((entry) => {
        const targetRoom = rooms.find((room) => room.id === entry.roomId)
        const mapped = targetRoom
          ? projectWallPlacedObjectBetweenRooms(sourceBase, selectedWallRoom, selectedWall.edgeIndex, targetRoom, entry.edgeIndex)
          : sourceBase
        next[entry.key] = (next[entry.key] ?? []).map((item) => item.id === entry.item.id ? { ...mapped, id: item.id } : item)
      })
      return next
    })

    affected.forEach((entry) => {
      const targetRoom = rooms.find((room) => room.id === entry.roomId)
      const mapped = targetRoom
        ? projectWallPlacedObjectBetweenRooms(sourceBase, selectedWallRoom, selectedWall.edgeIndex, targetRoom, entry.edgeIndex)
        : sourceBase
      void updateWallObjectApi(entry.item.id, {
        objectType: mapped.type,
        x: mapped.x,
        y: mapped.y,
        w: mapped.w,
        h: mapped.h,
        groupId: mapped.groupId,
      }).catch((err) => console.warn('Wandobjekt konnte nicht aktualisiert werden', err))
    })
  }

  function deleteWallObject(id: string) {
    const source = findWallObjectEntry(wallObjectsByKey, id)
    if (!source) return
    const affected = source.item.groupId ? findWallObjectsByGroup(wallObjectsByKey, source.item.groupId) : [source]
    setWallObjectsByKey((current) => {
      const next = { ...current }
      affected.forEach((entry) => {
        next[entry.key] = (next[entry.key] ?? []).filter((item) => item.id !== entry.item.id)
      })
      return next
    })
    affected.forEach((entry) => {
      void deleteWallObjectFromApi(entry.item.id).catch((err) => console.warn('Wandobjekt konnte nicht geloescht werden', err))
    })
  }

  const introModelHeightM = introPhase === 'animating' ? round3(wallHeightM * introProgress) : wallHeightM
  const showWallSubmodels = introPhase !== 'animating'
  const wallSubmodelStyle = { opacity: introPhase === 'revealing' ? introRevealProgress : 1 } as CSSProperties
  const wallModel = useMemo(() => buildWallModel3D(floor.id, visibleRooms, introModelHeightM, wallObjectsByKey), [floor.id, visibleRooms, introModelHeightM, wallObjectsByKey])
  const viewOriginM = wallModel.originM
  const viewOriginSvg = useMemo(() => ({ x: mToX(viewOriginM.x), y: mToY(viewOriginM.y) }), [viewOriginM])
  const wallCamera = useMemo(() => wallCameraBasis(viewOriginM, viewOriginSvg, visibleRooms, introModelHeightM, rotationDeg, tiltDeg), [viewOriginM, viewOriginSvg, visibleRooms, introModelHeightM, rotationDeg, tiltDeg])

  useEffect(() => {
    const scrollEl = canvasScrollRef.current
    if (!scrollEl) return
    const wheelTarget = scrollEl
    function handleNativeWheel(event: WheelEvent) {
      event.preventDefault()
      event.stopPropagation()
      const dominantDelta = Math.abs(event.deltaY) >= Math.abs(event.deltaX) ? event.deltaY : event.deltaX
      if (dominantDelta === 0) return
      const factor = dominantDelta < 0 ? 1.12 : (1 / 1.12)
      const beforeZoom = zoom
      const nextZoom = Math.min(2.5, Math.max(0.22, round2(beforeZoom * factor)))
      if (nextZoom === beforeZoom) return
      const anchorX = viewOriginSvg.x
      const anchorY = viewOriginSvg.y
      const viewportX = anchorX * beforeZoom - wheelTarget.scrollLeft
      const viewportY = anchorY * beforeZoom - wheelTarget.scrollTop
      setZoom(nextZoom)
      window.requestAnimationFrame(() => {
        const nextScroll = canvasScrollRef.current
        if (!nextScroll) return
        nextScroll.scrollLeft = Math.max(0, anchorX * nextZoom - viewportX)
        nextScroll.scrollTop = Math.max(0, anchorY * nextZoom - viewportY)
        setScrollPosition({ left: nextScroll.scrollLeft, top: nextScroll.scrollTop })
        saveCanvasViewport(floor.id, { zoom: nextZoom, left: nextScroll.scrollLeft, top: nextScroll.scrollTop })
      })
    }
    wheelTarget.addEventListener('wheel', handleNativeWheel, { passive: false })
    return () => wheelTarget.removeEventListener('wheel', handleNativeWheel)
  }, [floor.id, zoom, viewOriginSvg])

  const overlayBasePosition = useMemo(() => {
    const scroll = canvasScrollRef.current
    const availableWidth = scroll?.clientWidth ?? 980
    return { x: Math.max(24, availableWidth - 610), y: 78 }
  }, [selectedWall, scrollPosition.left, scrollPosition.top])

  const selectedWallMotion = useMemo<WallOverlayMotion | null>(() => {
    if (!selectedWallEdge || !selectedWallRoom) return null
    return wallOverlayMotion(selectedWallEdge, selectedWallLength, rotationDeg, viewOriginSvg, zoom, scrollPosition, overlayBasePosition)
  }, [selectedWallEdge, selectedWallRoom, selectedWallLength, rotationDeg, viewOriginSvg, zoom, scrollPosition, overlayBasePosition])

  const projectedRooms = useMemo<RenderedProjectedRoom[]>(() => projectWallModelRooms(wallModel, wallCamera, selectedRoomId), [wallModel, wallCamera, selectedRoomId])

  const ceilingGapPath = useMemo(() => wallModelCeilingGapPath(wallModel, wallCamera), [wallModel, wallCamera])

  const projectedWallFaces = useMemo<RenderedWallFace[]>(() => projectWallModelFaces(wallModel, wallCamera, selectedWall), [wallModel, wallCamera, selectedWall])

  const projectedStairObjects = useMemo(() => projectWallModelStairPolygons(wallModel, wallCamera), [wallModel, wallCamera])



  const visibleWallFacePieces = useMemo(() => projectedWallFaces.flatMap((face) => {
    const placements = wallObjectsForFace(face, floor.id, rooms, wallObjectsByKey)
    const fullOpen = placements.some((item) => isFullWallOpenObject(item))
    if (introPhase === 'animating') return [{ face, polygon: face.points, pieceIndex: 0, opened: false, fullOpen }]
    if (fullOpen) return [{ face, polygon: face.points, pieceIndex: 0, opened: false, fullOpen: true }]
    const openings = placements.filter((item) => isRegularWallOpeningObject(item))
    return wallFaceVisiblePolygons(face.points, openings).map((polygon, pieceIndex) => ({ face, polygon, pieceIndex, opened: openings.length > 0, fullOpen: false }))
  }), [projectedWallFaces, wallObjectsByKey, floor.id, rooms, introPhase])

  const wallDepthScene = useMemo(() => [
    ...visibleWallFacePieces.map((entry) => ({ kind: 'wall' as const, depth: entry.face.avgDepth, entry })),
    ...projectedStairObjects.map((entry) => ({ kind: 'stair' as const, depth: entry.avgDepth, entry })),
  ].sort((a, b) => b.depth - a.depth), [visibleWallFacePieces, projectedStairObjects])

  const wallPassageRevealsIn3D = useMemo(() => projectedWallFaces.flatMap((face) => {
    const openings = wallObjectsForFace(face, floor.id, rooms, wallObjectsByKey).filter((item) => isRegularWallOpeningObject(item))
    return openings.flatMap((item) => wallOpeningRevealPolygonsBetween(face, item, projectedWallFaces, floor.id, rooms, wallObjectsByKey).map(({ polygon, kind }, index) => ({ face, item, polygon, kind, index })))
  }), [projectedWallFaces, wallObjectsByKey, floor.id, rooms])

  const wallObjectsIn3D = useMemo(() => projectedWallFaces.flatMap((face) => {
    const key = `${floor.id}:${face.room.id}:${face.edgeIndex}`
    return (wallObjectsByKey[key] ?? [])
      .filter((item) => item.type === 'socket')
      .map((item) => ({ face, item, polygon: wallObjectProjectedPolygon(face.points, item) }))
  }), [projectedWallFaces, wallObjectsByKey, floor.id])

  const wallHitFaces = useMemo(() => [...projectedWallFaces].sort((a, b) => {
    return b.avgDepth - a.avgDepth
  }), [projectedWallFaces])

  function selectLayer(id: string) {
    setActiveLayerId(id)
    localStorage.setItem(layerStorageKey(floor.id, 'active'), JSON.stringify(id))
    onSelectRoom('')
    setSelectedWall(null)
    setLayersOpen(false)
  }

  function handleCanvasWheel(event: ReactWheelEvent<HTMLDivElement>) {
    event.preventDefault()
    event.stopPropagation()
    const scroll = canvasScrollRef.current
    if (!scroll) return
    const rect = scroll.getBoundingClientRect()
    const mouseX = event.clientX - rect.left
    const mouseY = event.clientY - rect.top
    const beforeZoom = zoom
    const contentX = (scroll.scrollLeft + mouseX) / beforeZoom
    const contentY = (scroll.scrollTop + mouseY) / beforeZoom
    const dominantDelta = Math.abs(event.deltaY) >= Math.abs(event.deltaX) ? event.deltaY : event.deltaX
    if (dominantDelta === 0) return
    const factor = dominantDelta < 0 ? 1.12 : (1 / 1.12)
    const nextZoom = Math.min(2.5, Math.max(0.22, round2(beforeZoom * factor)))
    if (nextZoom === beforeZoom) return
    setZoom(nextZoom)
    window.requestAnimationFrame(() => {
      const nextScroll = canvasScrollRef.current
      if (!nextScroll) return
      nextScroll.scrollLeft = Math.max(0, contentX * nextZoom - mouseX)
      nextScroll.scrollTop = Math.max(0, contentY * nextZoom - mouseY)
      setScrollPosition({ left: nextScroll.scrollLeft, top: nextScroll.scrollTop })
      saveCanvasViewport(floor.id, { zoom: nextZoom, left: nextScroll.scrollLeft, top: nextScroll.scrollTop })
    })
  }

  function handleCanvasScroll() {
    const scroll = canvasScrollRef.current
    if (!scroll) return
    setScrollPosition({ left: scroll.scrollLeft, top: scroll.scrollTop })
    saveCanvasViewport(floor.id, { zoom, left: scroll.scrollLeft, top: scroll.scrollTop })
  }

  function changeZoom(next: number) {
    const nextZoom = Math.min(2.5, Math.max(0.22, round2(next)))
    setZoom(nextZoom)
    const scroll = canvasScrollRef.current
    if (scroll) saveCanvasViewport(floor.id, { zoom: nextZoom, left: scroll.scrollLeft, top: scroll.scrollTop })
  }

  function scaleCanvasTo100() {
    const scroll = canvasScrollRef.current
    if (!scroll) {
      setZoom(1)
      return
    }
    const anchorX = viewOriginSvg.x
    const anchorY = viewOriginSvg.y
    const viewportX = anchorX * zoom - scroll.scrollLeft
    const viewportY = anchorY * zoom - scroll.scrollTop
    setZoom(1)
    window.requestAnimationFrame(() => {
      const nextScroll = canvasScrollRef.current
      if (!nextScroll) return
      nextScroll.scrollLeft = Math.max(0, anchorX - viewportX)
      nextScroll.scrollTop = Math.max(0, anchorY - viewportY)
      setScrollPosition({ left: nextScroll.scrollLeft, top: nextScroll.scrollTop })
      saveCanvasViewport(floor.id, { zoom: 1, left: nextScroll.scrollLeft, top: nextScroll.scrollTop })
    })
  }

  function centerAllRooms() {
    const allPoints = visibleRooms.flatMap((room) => room.vertices)
    const bounds = boundsOf(allPoints)
    const scroll = canvasScrollRef.current
    if (!bounds || !scroll) return
    const paddedW = Math.max(0.5, bounds.maxX - bounds.minX + 1.2)
    const paddedH = Math.max(0.5, bounds.maxY - bounds.minY + 1.2)
    const fitZoom = Math.min(2.5, Math.max(0.22, Math.min(scroll.clientWidth / (paddedW * canvas.scale), scroll.clientHeight / (paddedH * canvas.scale))))
    const nextZoom = round2(fitZoom)
    setZoom(nextZoom)
    window.requestAnimationFrame(() => {
      const nextScroll = canvasScrollRef.current
      if (!nextScroll) return
      const centerX = (bounds.minX + bounds.maxX) / 2
      const centerY = (bounds.minY + bounds.maxY) / 2
      nextScroll.scrollLeft = Math.max(0, mToX(centerX) * nextZoom - nextScroll.clientWidth / 2)
      nextScroll.scrollTop = Math.max(0, mToY(centerY) * nextZoom - nextScroll.clientHeight / 2)
      setScrollPosition({ left: nextScroll.scrollLeft, top: nextScroll.scrollTop })
      saveCanvasViewport(floor.id, { zoom: nextZoom, left: nextScroll.scrollLeft, top: nextScroll.scrollTop })
    })
  }

  function zoomToSelectedWall() {
    const room = selectedWallRoom ?? (selectedRoomId ? rooms.find((item) => item.id === selectedRoomId) ?? null : null)
    const bounds = room ? boundsOf(room.vertices) : null
    const scroll = canvasScrollRef.current
    if (!bounds || !scroll) return
    const paddedW = Math.max(0.5, bounds.maxX - bounds.minX + 1.1)
    const paddedH = Math.max(0.5, bounds.maxY - bounds.minY + 1.1)
    const nextZoom = round2(Math.min(2.5, Math.max(0.22, Math.min(scroll.clientWidth / (paddedW * canvas.scale), scroll.clientHeight / (paddedH * canvas.scale)))))
    setZoom(nextZoom)
    window.requestAnimationFrame(() => {
      const nextScroll = canvasScrollRef.current
      if (!nextScroll) return
      const centerX = (bounds.minX + bounds.maxX) / 2
      const centerY = (bounds.minY + bounds.maxY) / 2
      nextScroll.scrollLeft = Math.max(0, mToX(centerX) * nextZoom - nextScroll.clientWidth / 2)
      nextScroll.scrollTop = Math.max(0, mToY(centerY) * nextZoom - nextScroll.clientHeight / 2)
      setScrollPosition({ left: nextScroll.scrollLeft, top: nextScroll.scrollTop })
      saveCanvasViewport(floor.id, { zoom: nextZoom, left: nextScroll.scrollLeft, top: nextScroll.scrollTop })
    })
  }

  function isInteractiveWallTarget(target: EventTarget | null) {
    const element = target as Element | null
    if (!element) return false
    return Boolean(element.closest('.wall-detail-face, .wall-detail-floor, .wall-detail-room-label'))
  }

  function pointerSvgPoint(event: ReactMouseEvent<SVGSVGElement>): SvgPoint {
    const rect = event.currentTarget.getBoundingClientRect()
    if (rect.width <= 0 || rect.height <= 0) return { x: canvas.width / 2, y: canvas.height / 2 }
    return {
      x: ((event.clientX - rect.left) / rect.width) * canvas.width,
      y: ((event.clientY - rect.top) / rect.height) * canvas.height,
    }
  }

  function handleCanvasMouseDown(event: ReactMouseEvent<SVGSVGElement>) {
    ;(event.currentTarget as unknown as HTMLElement).focus({ preventScroll: true })
    if (!canvasScrollRef.current) return
    if (event.button === 1) {
      event.preventDefault()
      panDragRef.current = {
        startX: event.clientX,
        startY: event.clientY,
        scrollLeft: canvasScrollRef.current.scrollLeft,
        scrollTop: canvasScrollRef.current.scrollTop,
        moved: false,
      }
      return
    }
    if (event.button !== 0) return
    if (viewTool === 'rotate') {
      rotationDragRef.current = {
        startX: event.clientX,
        startY: event.clientY,
        startYawDeg: rotationDeg,
        startPitchDeg: tiltDeg,
      }
      return
    }
    if (isInteractiveWallTarget(event.target)) return
    panDragRef.current = {
      startX: event.clientX,
      startY: event.clientY,
      scrollLeft: canvasScrollRef.current.scrollLeft,
      scrollTop: canvasScrollRef.current.scrollTop,
      moved: false,
    }
  }

  function handleMouseMove(event: ReactMouseEvent<SVGSVGElement>) {
    if (rotationDragRef.current) {
      const drag = rotationDragRef.current
      const dx = event.clientX - drag.startX
      const dy = event.clientY - drag.startY
      setWallRotation(drag.startYawDeg + dx * 0.32)
      setWallTilt(drag.startPitchDeg - dy * 0.18)
      return
    }
    if (!panDragRef.current || !canvasScrollRef.current) return
    const drag = panDragRef.current
    const dx = event.clientX - drag.startX
    const dy = event.clientY - drag.startY
    if (Math.abs(dx) > 2 || Math.abs(dy) > 2) drag.moved = true
    canvasScrollRef.current.scrollLeft = drag.scrollLeft - dx
    canvasScrollRef.current.scrollTop = drag.scrollTop - dy
  }

  function handleMouseUp() {
    panDragRef.current = null
    rotationDragRef.current = null
  }

  function pickWall(event: ReactMouseEvent<SVGPolygonElement>, room: Room, edgeIndex: number) {
    event.preventDefault()
    event.stopPropagation()
    onSelectRoom(room.id)
    setSelectedWall({ roomId: room.id, edgeIndex })
  }

  function pickRoomFloor(event: ReactMouseEvent<SVGPolygonElement>, room: Room) {
    event.preventDefault()
    event.stopPropagation()
    if (viewTool === 'rotate') return
    onSelectRoom(room.id)
    setSelectedWall(null)
  }

  const hintText = selectedWall
    ? 'Wanddetail: ausgewaehlte Wand ist aktiv. Klicke Waende zum Auswaehlen, ziehe im Canvas fuer die 3D-Drehung.'
    : 'Wanddetail: Dreh- und Auswahlmodus aktiv. Klicke Waende zum Auswaehlen, ziehe im Canvas fuer die 3D-Drehung. Mittlere Maustaste verschiebt.'

  return (
    <div className={`floorplan-layout wall-detail-layout ${introReady ? 'wall-ready' : 'wall-start'}`}>
      <div className="canvas-toolbar-row">
        <div className="canvas-toolbox" aria-label="Wanddetail Werkzeuge">
          <button title="Letzte Aktion rueckgaengig" data-tooltip="Rueckgaengig" aria-label="Letzte Aktion rueckgaengig" disabled={!canUndo} onMouseDown={(event) => event.preventDefault()} onClick={onUndo}>↶</button>
          <span className="tool-divider" />
          <button title="Drehen und Waende auswaehlen" data-tooltip="Drehen/Auswahl" aria-label="Drehen und Waende auswaehlen" className="active" onMouseDown={(event) => event.preventDefault()} onClick={() => setViewTool('rotate')}>↻</button>
          <button title="Ansicht zuruecksetzen" data-tooltip="Ansicht zuruecksetzen" aria-label="3D-Ansicht zuruecksetzen" disabled={Math.abs(rotationDeg - defaultWallViewYawDeg) < 0.05 && Math.abs(tiltDeg - defaultWallViewPitchDeg) < 0.05} onMouseDown={(event) => event.preventDefault()} onClick={resetWallViewportRotation}>⟲</button>
          <label className="wall-rotation-pill" title="Azimut in Grad eingeben">
            <input
              aria-label="Azimut in Grad"
              type="number"
              step="1"
              value={rotationInput}
              onMouseDown={(event) => event.stopPropagation()}
              onChange={handleRotationInputChange}
              onBlur={handleRotationInputBlur}
              onKeyDown={(event) => { if (event.key === 'Enter') (event.currentTarget as HTMLInputElement).blur() }}
            />
            <span>°</span>
          </label>
          <label className="wall-tilt-pill" title="Neigung in Grad eingeben">
            <span>N</span>
            <input
              aria-label="Neigung in Grad"
              type="number"
              step="1"
              value={tiltInput}
              onMouseDown={(event) => event.stopPropagation()}
              onChange={handleTiltInputChange}
              onBlur={handleTiltInputBlur}
              onKeyDown={(event) => { if (event.key === 'Enter') (event.currentTarget as HTMLInputElement).blur() }}
            />
            <span>°</span>
          </label>
          <label className="wall-height-pill" title="Raumhoehe in Metern">
            <span>H</span>
            <input
              aria-label="Raumhoehe in Metern"
              type="number"
              step="0.1"
              min="0.1"
              value={wallHeightInput}
              onMouseDown={(event) => event.stopPropagation()}
              onChange={handleWallHeightInputChange}
              onBlur={handleWallHeightInputBlur}
              onKeyDown={(event) => { if (event.key === 'Enter') (event.currentTarget as HTMLInputElement).blur() }}
            />
            <span>m</span>
          </label>
          <span className="tool-divider" />
          <button title="Verkleinern" data-tooltip="Zoom verkleinern" aria-label="Canvas verkleinern" onMouseDown={(event) => event.preventDefault()} onClick={() => changeZoom(zoom - 0.15)}>−</button>
          <button title="Scale to 100%" data-tooltip="Scale 100%" aria-label="Scale to 100%" className={Math.abs(zoom - 1) < 0.001 ? 'active' : ''} onMouseDown={(event) => event.preventDefault()} onClick={scaleCanvasTo100}>1:1</button>
          <span className="canvas-zoom-level" aria-label="Zoomstufe">{Math.round(zoom * 100)}%</span>
          <button title="Vergroessern" data-tooltip="Zoom vergroessern" aria-label="Canvas vergroessern" onMouseDown={(event) => event.preventDefault()} onClick={() => changeZoom(zoom + 0.15)}>+</button>
          <button title="Alle Elemente zentrieren" data-tooltip="Center all" aria-label="Alle Elemente zentrieren" disabled={visibleRooms.length === 0} onMouseDown={(event) => event.preventDefault()} onClick={centerAllRooms}>⛶</button>
          <button title="Auswahl zoomen" data-tooltip="Auswahl zoomen" aria-label="Auf ausgewaehlte Wand zoomen" disabled={!selectedWall && !selectedRoomId} onMouseDown={(event) => event.preventDefault()} onClick={zoomToSelectedWall}>⌖</button>
        </div>
      </div>

      <WallDetailPropertiesTopBar
        selectedWallTitle={selectedWallTitle}
        selectedWallLength={selectedWallLength}
        selectedWallHeight={wallHeightM}
        selectedWallEdge={selectedWallEdge}
        activeLayerName={activeLayer.name}
        visibleRoomCount={visibleRooms.filter((room) => !isOuterWallRoom(room)).length}
        viewTool={viewTool}
        rotationDeg={rotationDeg}
        tiltDeg={tiltDeg}
        wallHeightM={wallHeightM}
      />

      <div className="canvas-card wall-detail-card">
        <div className={`canvas-layer-menu wall-layer-menu ${layersOpen ? 'open' : ''}`} aria-label="Ebenen">
          <button type="button" title="Ebenen" onClick={() => setLayersOpen((current) => !current)}>☰ {activeLayer.name}</button>
          {layersOpen && (
            <div className="layer-menu-panel">
              <div className="layer-list">
                {layers.map((layer) => {
                  const active = layer.id === activeLayerId
                  return (
                    <div
                      key={layer.id}
                      className={`layer-row ${active ? 'active effectively-visible' : 'effectively-hidden'}`}
                      onClick={() => selectLayer(layer.id)}
                    >
                      <button type="button" className={`layer-eye ${active ? 'visible' : 'hidden'}`} title={active ? 'Aktive Ebene sichtbar' : 'In Wanddetail automatisch ausgeblendet'} onClick={(event) => { event.stopPropagation(); selectLayer(layer.id) }}>{active ? '👁' : '◌'}</button>
                      <input aria-label="Ebenenname" value={layer.name} readOnly onFocus={() => selectLayer(layer.id)} />
                    </div>
                  )
                })}
              </div>
              <p className="layer-mode-note">Wanddetail zeigt immer genau eine Ebene. Beim Auswaehlen werden alle anderen Ebenen automatisch ausgeblendet.</p>
            </div>
          )}
        </div>

        {selectedWall && selectedWallRoom && (
          <>
            <WallFrontOverlay
              title={selectedWallTitle}
              lengthM={selectedWallLength}
              heightM={wallHeightM}
              motion={selectedWallMotion}
              placements={selectedWallObjects}
              onAddPlacement={addWallObject}
              onToggleFullWallOpen={toggleFullWallOpen}
              onUpdatePlacement={updateWallObject}
              onDeletePlacement={deleteWallObject}
              onClose={() => setSelectedWall(null)}
            />
            <WallObjectLibraryFloating baseX={selectedWallMotion?.initialX ?? 420} baseY={(selectedWallMotion?.initialY ?? 78) + 378} />
          </>
        )}

        <div className="canvas-scroll" ref={canvasScrollRef} onWheelCapture={handleCanvasWheel} onScroll={handleCanvasScroll}>
          <svg
            className={`canvas floorplan-canvas wall-detail-canvas select-mode ${viewTool === 'rotate' ? 'rotate-mode' : ''}`}
            style={{
              width: `${canvas.width * (introPhase === 'animating' ? zoom * (1 - 0.1 * introProgress) : zoom)}px`,
              height: `${canvas.height * (introPhase === 'animating' ? zoom * (1 - 0.1 * introProgress) : zoom)}px`,
              '--floorplan-text-size': `${14.7 / zoom}px`,
              '--floorplan-small-text-size': `${12.8 / zoom}px`,
              '--floorplan-label-stroke': `${4.4 / zoom}px`,
            } as CSSProperties}
            viewBox={`0 0 ${canvas.width} ${canvas.height}`}
            role="img"
            aria-label="Wanddetail Editor"
            tabIndex={0}
            onMouseMove={handleMouseMove}
            onMouseUp={handleMouseUp}
            onMouseLeave={handleMouseUp}
            onMouseDown={handleCanvasMouseDown}
            onWheelCapture={(event) => handleCanvasWheel(event as unknown as ReactWheelEvent<HTMLDivElement>)}
            onAuxClick={(event) => event.preventDefault()}
            onClick={() => { if (viewTool !== 'rotate') { onSelectRoom(''); setSelectedWall(null) } }}
          >
            <g className="wall-detail-stage">
              <Grid />
              <rect x={mToX(canvas.minM)} y={mToY(canvas.minM)} width={(canvas.maxM - canvas.minM) * canvas.scale} height={(canvas.maxM - canvas.minM) * canvas.scale} className="workspace-boundary" />

              {projectedRooms.map(({ room, outerWall, selectedRoom, projected }) => (
                <g key={room.id} className={`wall-detail-room ${selectedRoom ? 'selected' : ''} ${outerWall ? 'outer-wall-room' : ''}`}>
                  <polygon
                    points={svgPointsToString(projected.floor)}
                    className="wall-detail-floor"
                    onClick={(event) => pickRoomFloor(event, room)}
                  />
                  {showWallSubmodels && <polyline points={`${svgPointsToString(projected.floor)} ${projected.floor[0]?.x ?? 0},${projected.floor[0]?.y ?? 0}`} className="wall-detail-outline" style={wallSubmodelStyle} />}
                </g>
              ))}
              {showWallSubmodels && ceilingGapPath && <path d={ceilingGapPath} className="wall-ceiling-gap" fillRule="evenodd" style={wallSubmodelStyle} />}
              {wallDepthScene.map((scene) => {
                if (scene.kind === 'stair') {
                  if (!showWallSubmodels) return null
                  const item = scene.entry
                  return (
                    <polygon
                      key={item.key}
                      points={svgPointsToString(item.points)}
                      className={`wall-detail-stair wall-detail-stair-${item.role}`}
                      data-room-id={item.roomId}
                      data-depth={round2(item.avgDepth)}
                      style={wallSubmodelStyle}
                    />
                  )
                }
                const { face, polygon, pieceIndex, opened, fullOpen } = scene.entry
                const pairedHover = wallFaceIsInPair(face, hoveredWall, wallDetailRooms)
                return (
                  <polygon
                    key={`${face.room.id}-wall-face-${face.edgeIndex}-${pieceIndex}`}
                    points={svgPointsToString(polygon)}
                    className={`wall-detail-face wall-detail-face-3d ${face.outerWall ? 'outer-wall-face-3d' : ''} ${face.selected ? 'selected' : ''} ${pairedHover ? 'pair-hover' : ''} ${opened ? 'opened' : ''} ${fullOpen ? 'full-open' : ''}`}
                    data-depth={round2(face.avgDepth)}
                    style={{
                      '--wall-axis-x': String(face.axis.x),
                      '--wall-axis-y': String(face.axis.y),
                      '--wall-origin-x': `${face.axis.originX}px`,
                      '--wall-origin-y': `${face.axis.originY}px`,
                    } as CSSProperties}
                    onMouseEnter={() => setHoveredWall({ roomId: face.room.id, edgeIndex: face.edgeIndex })}
                    onMouseLeave={() => setHoveredWall(null)}
                    onClick={(event) => pickWall(event, face.room, face.edgeIndex)}
                  />
                )
              })}

              {showWallSubmodels && wallPassageRevealsIn3D.map(({ face, item, polygon, index, kind }) => (
                <polygon
                  key={`${face.room.id}-${face.edgeIndex}-${item.id}-reveal-${index}`}
                  points={svgPointsToString(polygon)}
                  className={`wall-detail-opening-reveal wall-detail-opening-${kind} wall-detail-opening-${item.type}`}
                  style={wallSubmodelStyle}
                  onClick={(event) => { event.preventDefault(); event.stopPropagation(); pickWall(event as unknown as ReactMouseEvent<SVGPolygonElement>, face.room, face.edgeIndex) }}
                />
              ))}
              {showWallSubmodels && wallObjectsIn3D.map(({ face, item, polygon }) => (
                <polygon
                  key={`${face.room.id}-${face.edgeIndex}-${item.id}`}
                  points={svgPointsToString(polygon)}
                  className={`wall-detail-placed-object wall-detail-placed-${item.type}`}
                  style={wallSubmodelStyle}
                  onClick={(event) => { event.preventDefault(); event.stopPropagation(); pickWall(event as unknown as ReactMouseEvent<SVGPolygonElement>, face.room, face.edgeIndex) }}
                />
              ))}

              {showWallSubmodels && projectedRooms.map(({ room, outerWall, projected }) => (!outerWall ? (
                <text
                  key={`${room.id}-label`}
                  x={projected.center.x}
                  y={projected.center.y}
                  dy="0.35em"
                  textAnchor="middle"
                  className="wall-detail-room-label wall-detail-floor-label"
                  style={wallSubmodelStyle}
                >{cleanRoomName(room)}</text>
              ) : null))}
              {showWallSubmodels && wallHitFaces.map((face) => (
                <polygon
                  key={`${face.room.id}-wall-hit-${face.edgeIndex}`}
                  points={svgPointsToString(face.points)}
                  className={`wall-detail-hit-face ${wallFaceIsInPair(face, hoveredWall, wallDetailRooms) ? 'pair-hover' : ''}`}
                  onMouseEnter={() => setHoveredWall({ roomId: face.room.id, edgeIndex: face.edgeIndex })}
                  onMouseLeave={() => setHoveredWall(null)}
                  onClick={(event) => pickWall(event, face.room, face.edgeIndex)}
                />
              ))}
            </g>
            {viewTool === 'rotate' && (
              <g className="wall-rotation-pivot" aria-hidden="true">
                <circle cx={viewOriginSvg.x} cy={viewOriginSvg.y} r={7 / zoom} />
                <line x1={viewOriginSvg.x - 14 / zoom} y1={viewOriginSvg.y} x2={viewOriginSvg.x + 14 / zoom} y2={viewOriginSvg.y} />
                <line x1={viewOriginSvg.x} y1={viewOriginSvg.y - 14 / zoom} x2={viewOriginSvg.x} y2={viewOriginSvg.y + 14 / zoom} />
              </g>
            )}
          </svg>
        </div>
      </div>
      <div className="canvas-statusbar">{hintText}</div>
    </div>
  )
}

function WallDetailPropertiesTopBar({
  selectedWallTitle,
  selectedWallLength,
  selectedWallHeight,
  selectedWallEdge,
  activeLayerName,
  visibleRoomCount,
  viewTool,
  rotationDeg,
  tiltDeg,
  wallHeightM,
}: {
  selectedWallTitle: string
  selectedWallLength: number
  selectedWallHeight: number
  selectedWallEdge: { a: PointM; b: PointM } | null
  activeLayerName: string
  visibleRoomCount: number
  viewTool: WallViewTool
  rotationDeg: number
  tiltDeg: number
  wallHeightM: number
}) {
  return (
    <div className="properties-topbar wall-properties-topbar">
      <div className="properties-inline-group strong">
        <span>Wanddetail</span>
        <strong>{selectedWallTitle || 'Wand auswaehlen'}</strong>
      </div>
      <div className="properties-inline-group">
        <span>Ebene</span>
        <strong>{activeLayerName}</strong>
      </div>
      <div className="properties-inline-group">
        <span>Raeume</span>
        <strong>{visibleRoomCount}</strong>
      </div>
      <div className="properties-inline-group">
        <span>Werkzeug</span>
        <strong>Drehen/Auswahl</strong>
      </div>
      <div className="properties-inline-group">
        <span>Azimut</span>
        <strong>{rotationDeg > 0 ? '+' : ''}{Math.round(rotationDeg)}°</strong>
      </div>
      <div className="properties-inline-group">
        <span>Neigung</span>
        <strong>{Math.round(tiltDeg)}°</strong>
      </div>
      <div className="properties-inline-group">
        <span>Raumhoehe</span>
        <strong>{formatM(wallHeightM)}</strong>
      </div>
      {selectedWallTitle ? (
        <>
          <div className="properties-inline-group">
            <span>Laenge</span>
            <strong>{formatMm(selectedWallLength)}</strong>
          </div>
          <div className="properties-inline-group">
            <span>Hoehe</span>
            <strong>{formatMm(selectedWallHeight)}</strong>
          </div>
          {selectedWallEdge && (
            <div className="properties-inline-group wide">
              <span>Kante</span>
              <strong>{formatM(selectedWallEdge.a.x)} / {formatM(selectedWallEdge.a.y)} → {formatM(selectedWallEdge.b.x)} / {formatM(selectedWallEdge.b.y)}</strong>
            </div>
          )}
        </>
      ) : (
        <div className="properties-inline-group wide muted">
          <span>Status</span>
          <strong>3D-Modell aktiv, Bemassung ausgeblendet</strong>
        </div>
      )}
    </div>
  )
}

function WallFrontOverlay({
  title,
  lengthM,
  heightM,
  motion,
  placements,
  onAddPlacement,
  onToggleFullWallOpen,
  onUpdatePlacement,
  onDeletePlacement,
  onClose,
}: {
  title: string
  lengthM: number
  heightM: number
  motion: WallOverlayMotion | null
  placements: WallPlacedObject[]
  onAddPlacement: (type: WallLibraryItemType, x: number, y: number) => void
  onToggleFullWallOpen: () => void
  onUpdatePlacement: (id: string, patch: Partial<WallPlacedObject>) => void
  onDeletePlacement: (id: string) => void
  onClose: () => void
}) {
  const baseW = 520
  const baseH = 245
  const safeLength = Math.max(0.1, lengthM)
  const safeHeight = Math.max(0.1, heightM)
  const ratio = safeLength / safeHeight
  const [position, setPosition] = useState(() => ({ x: motion?.initialX ?? 420, y: motion?.initialY ?? 78 }))
  const [size, setSize] = useState(() => ({ w: 560, h: 370 }))
  const dragRef = useRef<{ startX: number; startY: number; originX: number; originY: number } | null>(null)
  const resizeRef = useRef<{ startX: number; startY: number; originW: number; originH: number } | null>(null)
  const objectDragRef = useRef<WallObjectDragState | null>(null)
  const [selectedObjectId, setSelectedObjectId] = useState<string>('')
  const svgScaleXRef = useRef(1)
  const svgScaleYRef = useRef(1)

  const regularPlacements = placements.filter((item) => !isFullWallOpenObject(item))
  const fullWallOpenPlacement = placements.find((item) => isFullWallOpenObject(item)) ?? null

  useEffect(() => {
    setPosition({ x: motion?.initialX ?? 420, y: motion?.initialY ?? 78 })
  }, [title, motion?.initialX, motion?.initialY])

  useEffect(() => {
    function handleMove(event: MouseEvent) {
      if (dragRef.current) {
        const nextX = Math.max(12, dragRef.current.originX + event.clientX - dragRef.current.startX)
        const nextY = Math.max(12, dragRef.current.originY + event.clientY - dragRef.current.startY)
        setPosition({ x: nextX, y: nextY })
      }
      if (resizeRef.current) {
        const nextW = clamp(Math.round(resizeRef.current.originW + event.clientX - resizeRef.current.startX), 360, 980)
        const nextH = clamp(Math.round(resizeRef.current.originH + event.clientY - resizeRef.current.startY), 280, 760)
        setSize({ w: nextW, h: nextH })
      }
      if (objectDragRef.current) {
        const drag = objectDragRef.current
        const dxNorm = drag.drawW > 0 ? (event.clientX - drag.startX) / Math.max(1, drag.scaleX) / drag.drawW : 0
        const dyNorm = drag.drawH > 0 ? (event.clientY - drag.startY) / Math.max(1, drag.scaleY) / drag.drawH : 0
        if (drag.mode === 'move') {
          onUpdatePlacement(drag.id, {
            x: clamp(round3(drag.original.x + dxNorm), drag.original.w / 2, 1 - drag.original.w / 2),
            y: clamp(round3(drag.original.y + dyNorm), drag.original.h / 2, 1 - drag.original.h / 2),
          })
        } else {
          const originalRect = wallObjectRect(drag.original)
          let left = originalRect.left
          let right = originalRect.right
          let top = originalRect.top
          let bottom = originalRect.bottom
          if (drag.mode === 'resize') {
            right = clamp(right + dxNorm, left + 0.02, 1)
            bottom = clamp(bottom + dyNorm, top + 0.02, 1)
          } else if (drag.mode === 'resize-left') {
            left = clamp(left + dxNorm, 0, right - 0.02)
          } else if (drag.mode === 'resize-right') {
            right = clamp(right + dxNorm, left + 0.02, 1)
          } else if (drag.mode === 'resize-top') {
            top = clamp(top + dyNorm, 0, bottom - 0.02)
          } else if (drag.mode === 'resize-bottom') {
            bottom = clamp(bottom + dyNorm, top + 0.02, 1)
          }
          onUpdatePlacement(drag.id, {
            x: round3((left + right) / 2),
            y: round3((top + bottom) / 2),
            w: round3(right - left),
            h: round3(bottom - top),
          })
        }
      }
    }
    function handleUp() {
      dragRef.current = null
      resizeRef.current = null
      objectDragRef.current = null
    }
    window.addEventListener('mousemove', handleMove)
    window.addEventListener('mouseup', handleUp)
    return () => {
      window.removeEventListener('mousemove', handleMove)
      window.removeEventListener('mouseup', handleUp)
    }
  }, [onUpdatePlacement])

  function beginDrag(event: ReactMouseEvent<HTMLDivElement>) {
    if ((event.target as Element | null)?.closest('button')) return
    event.preventDefault()
    dragRef.current = { startX: event.clientX, startY: event.clientY, originX: position.x, originY: position.y }
  }

  function beginResize(event: ReactMouseEvent<HTMLDivElement>) {
    event.preventDefault()
    event.stopPropagation()
    resizeRef.current = { startX: event.clientX, startY: event.clientY, originW: size.w, originH: size.h }
  }

  const svgH = Math.max(170, size.h - 110)
  const svgW = baseW
  const drawW = ratio >= svgW / baseH ? svgW : baseH * ratio
  const drawH = ratio >= svgW / baseH ? svgW / ratio : baseH
  const x = (svgW - drawW) / 2
  const y = (baseH - drawH) / 2

  useEffect(() => {
    if (selectedObjectId && !regularPlacements.some((item) => item.id === selectedObjectId)) {
      setSelectedObjectId('')
    }
  }, [selectedObjectId, regularPlacements])

  useEffect(() => {
    function handleKeyDown(event: KeyboardEvent) {
      if ((event.key === 'Delete' || event.key === 'Backspace') && selectedObjectId) {
        event.preventDefault()
        onDeletePlacement(selectedObjectId)
        setSelectedObjectId('')
      }
    }
    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [selectedObjectId, onDeletePlacement])

  function handleDrop(event: ReactDragEvent<SVGSVGElement>) {
    event.preventDefault()
    const rawType = event.dataTransfer.getData('application/x-strom-wall-object') || event.dataTransfer.getData('text/plain')
    if (!isWallLibraryItemType(rawType)) return
    const svg = event.currentTarget
    const rect = svg.getBoundingClientRect()
    svgScaleXRef.current = rect.width / svgW
    svgScaleYRef.current = rect.height / baseH
    const px = ((event.clientX - rect.left) / rect.width) * svgW
    const py = ((event.clientY - rect.top) / rect.height) * baseH
    const nx = drawW > 0 ? clamp((px - x) / drawW, 0, 1) : 0.5
    const ny = drawH > 0 ? clamp((py - y) / drawH, 0, 1) : 0.5
    onAddPlacement(rawType, nx, ny)
  }

  function beginObjectDrag(event: ReactMouseEvent<SVGGElement>, item: WallPlacedObject, mode: 'move' | WallObjectResizeMode) {
    event.preventDefault()
    event.stopPropagation()
    const svg = event.currentTarget.ownerSVGElement
    let scaleX = svgScaleXRef.current || 1
    let scaleY = svgScaleYRef.current || 1
    if (svg) {
      const rect = svg.getBoundingClientRect()
      scaleX = rect.width / svgW
      scaleY = rect.height / baseH
      svgScaleXRef.current = scaleX
      svgScaleYRef.current = scaleY
    }
    setSelectedObjectId(item.id)
    objectDragRef.current = { mode, id: item.id, startX: event.clientX, startY: event.clientY, original: item, drawW, drawH, scaleX, scaleY }
  }

  function deleteSelectedObject() {
    if (!selectedObjectId) return
    onDeletePlacement(selectedObjectId)
    setSelectedObjectId('')
  }

  return (
    <div
      className="wall-front-overlay"
      role="dialog"
      aria-label="Wand frontal"
      style={{
        left: `${position.x}px`,
        top: `${position.y}px`,
        width: `${size.w}px`,
        minHeight: `${size.h}px`,
        '--wall-start-dx': `${motion?.startDx ?? 0}px`,
        '--wall-start-dy': `${motion?.startDy ?? 0}px`,
        '--wall-start-rotate': `${motion?.startRotate ?? 0}deg`,
        '--wall-start-scale': String(motion?.startScale ?? 0.18),
      } as CSSProperties}
    >
      <div className="wall-front-header" onMouseDown={beginDrag} title="Fenster verschieben">
        <div>
          <span className="eyebrow">Frontalansicht</span>
          <strong>{title}</strong>
        </div>
        <button type="button" aria-label="Frontalansicht schliessen" onClick={onClose}>×</button>
      </div>
      <svg
        viewBox={`0 0 ${svgW} ${baseH}`}
        className="wall-front-svg"
        style={{ height: `${svgH}px` }}
        role="img"
        aria-label="Ausgewaehlte Wand frontal"
        onDragOver={(event) => event.preventDefault()}
        onDrop={handleDrop}
      >
        <defs>
          <pattern id="wall-front-fullopen-hatch" width="12" height="12" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">
            <rect width="12" height="12" fill="rgba(245, 158, 11, 0.12)" />
            <line x1="0" y1="0" x2="0" y2="12" stroke="rgba(180, 83, 9, 0.42)" strokeWidth="3" />
          </pattern>
        </defs>
        <rect x={x} y={y} width={drawW} height={drawH} rx="1" className="wall-front-main" />
        {fullWallOpenPlacement && (
          <rect
            x={x}
            y={y}
            width={drawW}
            height={drawH}
            rx="1"
            className="wall-front-full-open-overlay"
            fill="url(#wall-front-fullopen-hatch)"
          />
        )}
        <line x1={x} y1={y + drawH} x2={x + drawW} y2={y + drawH} />
        <line x1={x} y1={y} x2={x} y2={y + drawH} />
        {regularPlacements.map((item) => <WallFrontPlacedObject key={item.id} item={item} placements={regularPlacements} lengthM={lengthM} heightM={heightM} wallX={x} wallY={y} wallW={drawW} wallH={drawH} selected={item.id === selectedObjectId} onBeginDrag={beginObjectDrag} />)}
      </svg>
      <div className="wall-front-meta">
        <span>Breite {formatMm(lengthM)}</span>
        <span>Hoehe {formatMm(heightM)}</span>
        <span>{regularPlacements.length} Objekt(e)</span>
        {fullWallOpenPlacement && <span className="wall-front-open-note">Wand geoeffnet</span>}
        <button type="button" className={`wall-front-full-open-toggle ${fullWallOpenPlacement ? 'active' : ''}`} onClick={onToggleFullWallOpen}>
          {fullWallOpenPlacement ? 'Komplette Oeffnung entfernen' : 'Wand komplett oeffnen'}
        </button>
        {selectedObjectId && <button type="button" className="wall-front-delete-object" onClick={deleteSelectedObject}>Objekt löschen</button>}
      </div>
      <div className="wall-front-resize-handle" onMouseDown={beginResize} title="Fenster skalieren" />
    </div>
  )
}

function WallFrontPlacedObject({
  item,
  placements,
  lengthM,
  heightM,
  wallX,
  wallY,
  wallW,
  wallH,
  selected,
  onBeginDrag,
}: {
  item: WallPlacedObject
  placements: WallPlacedObject[]
  lengthM: number
  heightM: number
  wallX: number
  wallY: number
  wallW: number
  wallH: number
  selected: boolean
  onBeginDrag: (event: ReactMouseEvent<SVGGElement>, item: WallPlacedObject, mode: 'move' | WallObjectResizeMode) => void
}) {
  const cx = wallX + item.x * wallW
  const cy = wallY + item.y * wallH
  const w = Math.max(10, item.w * wallW)
  const h = Math.max(10, item.h * wallH)
  const className = `wall-front-object ${item.type} ${selected ? 'selected' : ''}`
  const resizeHandle = selected ? (
    <g className="wall-front-object-handles">
      <rect className="wall-front-object-resize corner" x={cx + w / 2 - 6} y={cy + h / 2 - 6} width="12" height="12" onMouseDown={(event) => onBeginDrag(event, item, 'resize')} />
      <rect className="wall-front-object-edge-handle left" x={cx - w / 2 - 4} y={cy - h / 2} width="8" height={h} onMouseDown={(event) => onBeginDrag(event, item, 'resize-left')} />
      <rect className="wall-front-object-edge-handle right" x={cx + w / 2 - 4} y={cy - h / 2} width="8" height={h} onMouseDown={(event) => onBeginDrag(event, item, 'resize-right')} />
      <rect className="wall-front-object-edge-handle top" x={cx - w / 2} y={cy - h / 2 - 4} width={w} height="8" onMouseDown={(event) => onBeginDrag(event, item, 'resize-top')} />
      <rect className="wall-front-object-edge-handle bottom" x={cx - w / 2} y={cy + h / 2 - 4} width={w} height="8" onMouseDown={(event) => onBeginDrag(event, item, 'resize-bottom')} />
    </g>
  ) : null
  const leftMm = Math.max(0, Math.round((item.x - item.w / 2) * lengthM * 1000))
  const rightMm = Math.max(0, Math.round((1 - item.x - item.w / 2) * lengthM * 1000))
  const topMm = Math.max(0, Math.round((item.y - item.h / 2) * heightM * 1000))
  const bottomMm = Math.max(0, Math.round((1 - item.y - item.h / 2) * heightM * 1000))
  const nearestMm = Math.round(nearestWallObjectGapM(item, placements) * Math.max(lengthM, heightM) * 1000)
  const widthMm = Math.round(item.w * lengthM * 1000)
  const heightMm = Math.round(item.h * heightM * 1000)
  const dimTextY = clamp(cy - 7, wallY + 12, wallY + wallH - 10)
  const topTextX = clamp(cx + 7, wallX + 10, wallX + wallW - 10)
  const bottomTextX = clamp(cx + 7, wallX + 10, wallX + wallW - 10)
  const widthLineY = clamp(cy + h / 2 + 15, wallY + 10, wallY + wallH - 18)
  const widthTextY = clamp(widthLineY + 14, wallY + 13, wallY + wallH - 4)
  const heightLineX = clamp(cx + w / 2 + 15, wallX + 12, wallX + wallW - 18)
  const heightTextX = clamp(heightLineX + 12, wallX + 14, wallX + wallW - 6)
  const nearestTextY = clamp(cy - h / 2 - 13, wallY + 12, wallY + wallH - 8)
  const dimensions = selected ? (
    <g className="wall-front-object-dimensions">
      <line x1={wallX} y1={cy} x2={cx - w / 2} y2={cy} />
      <line x1={cx + w / 2} y1={cy} x2={wallX + wallW} y2={cy} />
      <text x={clamp((wallX + cx - w / 2) / 2, wallX + 18, wallX + wallW - 18)} y={dimTextY} textAnchor="middle">{leftMm} mm</text>
      <text x={clamp((cx + w / 2 + wallX + wallW) / 2, wallX + 18, wallX + wallW - 18)} y={dimTextY} textAnchor="middle">{rightMm} mm</text>
      <line x1={cx} y1={wallY} x2={cx} y2={cy - h / 2} />
      <line x1={cx} y1={cy + h / 2} x2={cx} y2={wallY + wallH} />
      <text x={topTextX} y={clamp((wallY + cy - h / 2) / 2, wallY + 16, wallY + wallH - 16)} transform={`rotate(-90 ${topTextX} ${clamp((wallY + cy - h / 2) / 2, wallY + 16, wallY + wallH - 16)})`} textAnchor="middle">{topMm} mm</text>
      <text x={bottomTextX} y={clamp((cy + h / 2 + wallY + wallH) / 2, wallY + 16, wallY + wallH - 16)} transform={`rotate(-90 ${bottomTextX} ${clamp((cy + h / 2 + wallY + wallH) / 2, wallY + 16, wallY + wallH - 16)})`} textAnchor="middle">{bottomMm} mm</text>
      <line x1={cx - w / 2} y1={widthLineY} x2={cx + w / 2} y2={widthLineY} />
      <text x={clamp(cx, wallX + 20, wallX + wallW - 20)} y={widthTextY} textAnchor="middle">{widthMm} mm</text>
      <line x1={heightLineX} y1={cy - h / 2} x2={heightLineX} y2={cy + h / 2} />
      <text x={heightTextX} y={clamp(cy, wallY + 16, wallY + wallH - 16)} transform={`rotate(-90 ${heightTextX} ${clamp(cy, wallY + 16, wallY + wallH - 16)})`} textAnchor="middle">{heightMm} mm</text>
      {nearestMm > 0 && <text x={clamp(cx, wallX + 24, wallX + wallW - 24)} y={nearestTextY} textAnchor="middle">nächster {nearestMm} mm</text>}
    </g>
  ) : null
  if (item.type === 'door') {
    return <g className={className} onMouseDown={(event) => onBeginDrag(event, item, 'move')}><rect x={cx - w / 2} y={cy - h / 2} width={w} height={h} rx="1" /><path d={`M ${round2(cx - w / 2)} ${round2(cy + h / 2)} Q ${round2(cx + w * 0.22)} ${round2(cy + h * 0.06)} ${round2(cx + w / 2)} ${round2(cy + h / 2)}`} />{resizeHandle}{dimensions}</g>
  }
  if (item.type === 'window') {
    return <g className={className} onMouseDown={(event) => onBeginDrag(event, item, 'move')}><rect x={cx - w / 2} y={cy - h / 2} width={w} height={h} rx="1" /><line x1={cx} y1={cy - h / 2} x2={cx} y2={cy + h / 2} /><line x1={cx - w / 2} y1={cy} x2={cx + w / 2} y2={cy} />{resizeHandle}{dimensions}</g>
  }
  return <g className={className} onMouseDown={(event) => onBeginDrag(event, item, 'move')}><circle cx={cx} cy={cy} r={Math.max(6, Math.min(w, h) / 2)} /><circle cx={cx - 3} cy={cy} r="1.4" /><circle cx={cx + 3} cy={cy} r="1.4" />{resizeHandle}{dimensions}</g>
}

function WallObjectLibraryFloating({ baseX, baseY }: { baseX: number; baseY: number }) {
  function clampLibraryPosition(x: number, y: number) {
    const width = 210
    const height = 205
    const maxX = typeof window === 'undefined' ? x : Math.max(12, window.innerWidth - width - 12)
    const maxY = typeof window === 'undefined' ? y : Math.max(12, window.innerHeight - height - 12)
    return { x: clamp(Math.round(x), 12, maxX), y: clamp(Math.round(y), 12, maxY) }
  }

  const [position, setPosition] = useState(() => clampLibraryPosition(baseX, baseY))
  const dragRef = useRef<{ startX: number; startY: number; originX: number; originY: number } | null>(null)

  useEffect(() => {
    setPosition(clampLibraryPosition(baseX, baseY))
  }, [baseX, baseY])

  useEffect(() => {
    function handleMove(event: MouseEvent) {
      if (!dragRef.current) return
      setPosition(clampLibraryPosition(
        dragRef.current.originX + event.clientX - dragRef.current.startX,
        dragRef.current.originY + event.clientY - dragRef.current.startY,
      ))
    }
    function handleUp() { dragRef.current = null }
    window.addEventListener('mousemove', handleMove)
    window.addEventListener('mouseup', handleUp)
    return () => {
      window.removeEventListener('mousemove', handleMove)
      window.removeEventListener('mouseup', handleUp)
    }
  }, [])

  function beginDrag(event: ReactMouseEvent<HTMLDivElement>) {
    event.preventDefault()
    dragRef.current = { startX: event.clientX, startY: event.clientY, originX: position.x, originY: position.y }
  }

  function startLibraryDrag(event: ReactDragEvent<HTMLButtonElement>, type: WallLibraryItemType) {
    event.dataTransfer.setData('application/x-strom-wall-object', type)
    event.dataTransfer.setData('text/plain', type)
    event.dataTransfer.effectAllowed = 'copy'
  }

  return (
    <div className="wall-object-library" style={{ left: `${position.x}px`, top: `${position.y}px` }}>
      <div className="wall-object-library-header" onMouseDown={beginDrag}>Objektbibliothek</div>
      <div className="wall-object-library-items">
        <button type="button" draggable onDragStart={(event) => startLibraryDrag(event, 'door')}><span>▯</span>Tür</button>
        <button type="button" draggable onDragStart={(event) => startLibraryDrag(event, 'window')}><span>▭</span>Fenster</button>
        <button type="button" draggable onDragStart={(event) => startLibraryDrag(event, 'socket')}><span>◉</span>Steckdose</button>
      </div>
      <p>Element auf die Frontalansicht ziehen.</p>
    </div>
  )
}

function isWallLibraryItemType(value: string): value is WallLibraryItemType {
  return value === 'door' || value === 'window' || value === 'socket'
}


// 131: wall geometry helpers
const FULL_WALL_OPEN_GROUP_PREFIX = 'wall-open:'

function isFullWallOpenGroupId(groupId?: string) {
  return Boolean(groupId && groupId.startsWith(FULL_WALL_OPEN_GROUP_PREFIX))
}

function isFullWallOpenObject(item: WallPlacedObject) {
  return item.type === 'door' && isFullWallOpenGroupId(item.groupId)
}

function isRegularWallOpeningObject(item: WallPlacedObject) {
  return (item.type === 'door' || item.type === 'window') && !isFullWallOpenObject(item)
}

function normalizeWallPlacedObject(item: WallPlacedObject): WallPlacedObject {
  const minWH = item.type === 'socket' ? 0.02 : 0.04
  const w = clamp(round3(item.w), 0.02, 1)
  const h = clamp(round3(item.h), minWH, 1)
  return {
    ...item,
    x: clamp(round3(item.x), w / 2, 1 - w / 2),
    y: clamp(round3(item.y), h / 2, 1 - h / 2),
    w,
    h,
  }
}

function projectWallPlacedObjectBetweenRooms(item: WallPlacedObject, sourceRoom: Room, sourceEdgeIndex: number, targetRoom: Room, targetEdgeIndex: number): WallPlacedObject {
  const normalized = normalizeWallPlacedObject(item)
  if (sourceRoom.id === targetRoom.id && sourceEdgeIndex === targetEdgeIndex) return normalized
  const sourceEdge = edgePoints(sourceRoom.vertices, sourceEdgeIndex)
  const targetEdge = edgePoints(targetRoom.vertices, targetEdgeIndex)
  if (!sourceEdge || !targetEdge) return normalized
  const pair = wallEdgePairInfo(sourceEdge, targetEdge)
  if (!pair?.paired) return normalized

  const sourceDx = sourceEdge.b.x - sourceEdge.a.x
  const sourceDy = sourceEdge.b.y - sourceEdge.a.y
  const targetDx = targetEdge.b.x - targetEdge.a.x
  const targetDy = targetEdge.b.y - targetEdge.a.y
  const sourceLen = Math.hypot(sourceDx, sourceDy)
  const targetLen = Math.hypot(targetDx, targetDy)
  if (sourceLen < 0.0001 || targetLen < 0.0001) return normalized

  const sourceUx = sourceDx / sourceLen
  const sourceUy = sourceDy / sourceLen
  const targetUx = targetDx / targetLen
  const targetUy = targetDy / targetLen
  const rect = wallObjectRect(normalized)
  const sourceLeftM = rect.left * sourceLen
  const sourceRightM = rect.right * sourceLen

  const pointAtSource = (meters: number): PointM => ({
    x: sourceEdge.a.x + sourceUx * meters,
    y: sourceEdge.a.y + sourceUy * meters,
  })
  const projectToTargetM = (point: PointM) => clamp(
    (point.x - targetEdge.a.x) * targetUx + (point.y - targetEdge.a.y) * targetUy,
    0,
    targetLen,
  )

  const leftOnTargetM = projectToTargetM(pointAtSource(sourceLeftM))
  const rightOnTargetM = projectToTargetM(pointAtSource(sourceRightM))
  const minM = Math.min(leftOnTargetM, rightOnTargetM)
  const maxM = Math.max(leftOnTargetM, rightOnTargetM)
  const left = clamp(round3(minM / targetLen), 0, 1)
  const right = clamp(round3(maxM / targetLen), 0, 1)

  return normalizeWallPlacedObject({
    ...normalized,
    x: round3((left + right) / 2),
    y: normalized.y,
    w: round3(Math.max(0.02, right - left)),
    h: normalized.h,
  })
}


function wallObjectKey(floorId: string, roomId: string, edgeIndex: number) {
  return `${floorId}:${roomId}:${edgeIndex}`
}

function parseWallObjectKey(key: string) {
  const [floorId, roomId, rawEdgeIndex] = key.split(':')
  return { floorId, roomId, edgeIndex: Number(rawEdgeIndex) }
}

function groupApiWallObjects(objects: ApiWallObject[]): Record<string, WallPlacedObject[]> {
  return objects.reduce<Record<string, WallPlacedObject[]>>((acc, item) => {
    const key = wallObjectKey(item.floorId, item.roomId, item.edgeIndex)
    const placed: WallPlacedObject = {
      id: item.id,
      type: item.objectType,
      x: item.x,
      y: item.y,
      w: item.w,
      h: item.h,
      groupId: item.groupId || undefined,
    }
    acc[key] = [...(acc[key] ?? []), placed]
    return acc
  }, {})
}

function wallObjectsForSelectedWall(
  floorId: string,
  targetRoom: Room,
  targetEdgeIndex: number,
  rooms: Room[],
  wallObjectsByKey: Record<string, WallPlacedObject[]>,
) {
  const ownKey = wallObjectKey(floorId, targetRoom.id, targetEdgeIndex)
  const ownObjects = (wallObjectsByKey[ownKey] ?? []).map(normalizeWallPlacedObject)
  const result: WallPlacedObject[] = [...ownObjects]
  const seenIds = new Set(result.map((item) => item.id))
  const seenGroups = new Set(result.map((item) => item.groupId).filter((value): value is string => Boolean(value)))
  const targetEdge = edgePoints(targetRoom.vertices, targetEdgeIndex)
  if (!targetEdge) return result

  rooms.forEach((room) => {
    room.vertices.forEach((_, edgeIndex) => {
      if (room.id === targetRoom.id && edgeIndex === targetEdgeIndex) return
      const sourceEdge = edgePoints(room.vertices, edgeIndex)
      if (!sourceEdge || !wallEdgePairInfo(targetEdge, sourceEdge)?.paired) return
      const key = wallObjectKey(floorId, room.id, edgeIndex)
      ;(wallObjectsByKey[key] ?? []).forEach((item) => {
        if (seenIds.has(item.id)) return
        if (item.groupId && seenGroups.has(item.groupId)) return
        const mapped = projectWallPlacedObjectBetweenRooms(item, room, edgeIndex, targetRoom, targetEdgeIndex)
        result.push({ ...mapped, id: item.id })
        seenIds.add(item.id)
        if (item.groupId) seenGroups.add(item.groupId)
      })
    })
  })
  return result
}

type WallObjectEntry = { key: string; roomId: string; edgeIndex: number; item: WallPlacedObject }

function findWallObjectEntry(state: Record<string, WallPlacedObject[]>, id: string): WallObjectEntry | null {
  for (const [key, items] of Object.entries(state)) {
    const item = items.find((candidate) => candidate.id === id)
    if (item) {
      const parsed = parseWallObjectKey(key)
      return { key, roomId: parsed.roomId, edgeIndex: parsed.edgeIndex, item }
    }
  }
  return null
}

function findWallObjectsByGroup(state: Record<string, WallPlacedObject[]>, groupId: string): WallObjectEntry[] {
  return Object.entries(state).flatMap(([key, items]) => {
    const parsed = parseWallObjectKey(key)
    return items
      .filter((item) => item.groupId === groupId)
      .map((item) => ({ key, roomId: parsed.roomId, edgeIndex: parsed.edgeIndex, item }))
  })
}

function pairedWallLocations(floorId: string, sourceRoom: Room, sourceEdgeIndex: number, rooms: Room[]): WallFaceLocation[] {
  const sourceEdge = edgePoints(sourceRoom.vertices, sourceEdgeIndex)
  const own = { key: wallObjectKey(floorId, sourceRoom.id, sourceEdgeIndex), roomId: sourceRoom.id, edgeIndex: sourceEdgeIndex, reversed: false }
  if (!sourceEdge) return [own]
  const pairs: (WallFaceLocation & { score: number })[] = []
  rooms.forEach((room) => {
    room.vertices.forEach((_, edgeIndex) => {
      if (room.id === sourceRoom.id && edgeIndex === sourceEdgeIndex) return
      const otherEdge = edgePoints(room.vertices, edgeIndex)
      if (!otherEdge) return
      const pair = wallEdgePairInfo(sourceEdge, otherEdge)
      if (!pair?.paired) return
      pairs.push({ key: wallObjectKey(floorId, room.id, edgeIndex), roomId: room.id, edgeIndex, reversed: pair.reversed, score: wallPairPlacementScore(sourceEdge, otherEdge) })
    })
  })
  pairs.sort((a, b) => b.score - a.score)
  const best = pairs[0]
  return best ? [own, { key: best.key, roomId: best.roomId, edgeIndex: best.edgeIndex, reversed: best.reversed }] : [own]
}

function wallPairPlacementScore(source: { a: PointM; b: PointM }, other: { a: PointM; b: PointM }) {
  const sx = source.b.x - source.a.x
  const sy = source.b.y - source.a.y
  const len = Math.hypot(sx, sy) || 1
  const ux = sx / len
  const uy = sy / len
  const s0 = 0
  const s1 = len
  const t0 = (other.a.x - source.a.x) * ux + (other.a.y - source.a.y) * uy
  const t1 = (other.b.x - source.a.x) * ux + (other.b.y - source.a.y) * uy
  const overlap = Math.max(0, Math.min(s1, Math.max(t0, t1)) - Math.max(s0, Math.min(t0, t1)))
  const normalA = Math.abs((other.a.x - source.a.x) * uy - (other.a.y - source.a.y) * ux)
  const normalB = Math.abs((other.b.x - source.a.x) * uy - (other.b.y - source.a.y) * ux)
  const normal = (normalA + normalB) / 2
  return overlap * 100 - normal * 8 - Math.abs(len - Math.hypot(other.b.x - other.a.x, other.b.y - other.a.y))
}

function wallFaceIsInPair(face: { room: Room; edgeIndex: number }, hovered: WallSelection | null, rooms: Room[]) {
  if (!hovered) return false
  if (face.room.id === hovered.roomId && face.edgeIndex === hovered.edgeIndex) return true
  const hoveredRoom = rooms.find((room) => room.id === hovered.roomId)
  const hoveredEdge = hoveredRoom ? edgePoints(hoveredRoom.vertices, hovered.edgeIndex) : null
  const faceEdge = edgePoints(face.room.vertices, face.edgeIndex)
  return Boolean(hoveredEdge && faceEdge && wallEdgePairInfo(hoveredEdge, faceEdge)?.paired)
}

function cleanRoomName(room: Room) {
  return isOuterWallRoom(room) ? 'Aussenwand' : room.name
}

function edgePoints(vertices: PointM[], edgeIndex: number): { a: PointM; b: PointM } | null {
  if (vertices.length < 2) return null
  const a = vertices[edgeIndex]
  const b = vertices[(edgeIndex + 1) % vertices.length]
  if (!a || !b) return null
  return { a, b }
}

function edgeLength(vertices: PointM[], edgeIndex: number) {
  const edge = edgePoints(vertices, edgeIndex)
  return edge ? distance(edge.a, edge.b) : 0
}


// 130: wall detail stair 3d helpers
type ProjectedWallStairPolygon = {
  roomId: string
  key: string
  role: 'landing' | 'tread' | 'riser'
  points: CameraProjectedPoint[]
  avgDepth: number
}

function stairRectPolygon3D(left: number, top: number, right: number, bottom: number, z: number): Vec3[] {
  return [
    { x: left, y: top, z },
    { x: right, y: top, z },
    { x: right, y: bottom, z },
    { x: left, y: bottom, z },
  ]
}

function stairRayToRectBoundary(origin: PointM, rect: { left: number; top: number; right: number; bottom: number }, angleRad: number): PointM {
  const dx = Math.cos(angleRad)
  const dy = Math.sin(angleRad)
  const eps = 0.000001
  const hits: { t: number; point: PointM }[] = []
  if (Math.abs(dx) > eps) {
    const tLeft = (rect.left - origin.x) / dx
    const yLeft = origin.y + tLeft * dy
    if (tLeft > eps && yLeft >= rect.top - eps && yLeft <= rect.bottom + eps) hits.push({ t: tLeft, point: { x: rect.left, y: yLeft } })
    const tRight = (rect.right - origin.x) / dx
    const yRight = origin.y + tRight * dy
    if (tRight > eps && yRight >= rect.top - eps && yRight <= rect.bottom + eps) hits.push({ t: tRight, point: { x: rect.right, y: yRight } })
  }
  if (Math.abs(dy) > eps) {
    const tTop = (rect.top - origin.y) / dy
    const xTop = origin.x + tTop * dx
    if (tTop > eps && xTop >= rect.left - eps && xTop <= rect.right + eps) hits.push({ t: tTop, point: { x: xTop, y: rect.top } })
    const tBottom = (rect.bottom - origin.y) / dy
    const xBottom = origin.x + tBottom * dx
    if (tBottom > eps && xBottom >= rect.left - eps && xBottom <= rect.right + eps) hits.push({ t: tBottom, point: { x: xBottom, y: rect.bottom } })
  }
  hits.sort((a, b) => a.t - b.t)
  return hits[0]?.point ?? origin
}

function stairMapUnitPointForWallDetail(element: StairEditorElement, point: PointM): PointM {
  const rotation = normalizeRightAngle(element.rotationDeg)
  const dx = point.x - 0.5
  const dy = point.y - 0.5
  const rotated = rotation === 90
    ? { x: 0.5 + dy, y: 0.5 - dx }
    : rotation === 180
      ? { x: 0.5 - dx, y: 0.5 - dy }
      : rotation === 270
        ? { x: 0.5 - dy, y: 0.5 + dx }
        : { x: 0.5 + dx, y: 0.5 + dy }
  return {
    x: element.xM + rotated.x * element.widthM,
    y: element.yM + rotated.y * element.heightM,
  }
}

function stairDirectionForWallDetail(element: StairEditorElement): { start: PointM; end: PointM } {
  if (element.kind === 'turn') {
    const side = element.mirrored ? -1 : 1
    const startUnit = side > 0 ? { x: 0.72, y: 0.84 } : { x: 0.28, y: 0.84 }
    const endUnit = side > 0 ? { x: 0.24, y: 0.56 } : { x: 0.76, y: 0.56 }
    return { start: stairMapUnitPointForWallDetail(element, startUnit), end: stairMapUnitPointForWallDetail(element, endUnit) }
  }
  return {
    start: stairMapUnitPointForWallDetail(element, { x: 0.5, y: 0.78 }),
    end: stairMapUnitPointForWallDetail(element, { x: 0.5, y: 0.22 }),
  }
}

function stairElementCenterForWallDetail(element: StairEditorElement): PointM {
  return { x: element.xM + element.widthM / 2, y: element.yM + element.heightM / 2 }
}

function stairCurrentFloorOriginForWallDetail(room: Room): PointM {
  const assignments = readStairEdgeAssignments(room.id).filter((assignment) => assignment.kind === 'current-floor')
  if (!assignments.length || room.vertices.length < 2) return centroid(room.vertices)
  const assignment = assignments[0]
  const index = ((assignment.edgeIndex % room.vertices.length) + room.vertices.length) % room.vertices.length
  const a = room.vertices[index]
  const b = room.vertices[(index + 1) % room.vertices.length]
  return { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 }
}

function stairDistancePointToSegment(point: PointM, a: PointM, b: PointM) {
  const dx = b.x - a.x
  const dy = b.y - a.y
  const lenSq = dx * dx + dy * dy
  if (lenSq <= 0.000001) return distance(point, a)
  const t = clamp(((point.x - a.x) * dx + (point.y - a.y) * dy) / lenSq, 0, 1)
  const proj = { x: a.x + dx * t, y: a.y + dy * t }
  return distance(point, proj)
}

function stairDirectionUnitForWallDetail(element: StairEditorElement): PointM {
  const direction = stairDirectionForWallDetail(element)
  const dx = direction.end.x - direction.start.x
  const dy = direction.end.y - direction.start.y
  const length = Math.hypot(dx, dy) || 1
  return { x: dx / length, y: dy / length }
}

function stairOrderedElementsForWallDetail(room: Room, elements: StairEditorElement[]): StairEditorElement[] {
  const relevant = elements.filter((element) => element.kind === 'landing' || element.kind === 'stair' || element.kind === 'turn')
  if (relevant.length <= 1) return relevant

  const startPoint = stairCurrentFloorOriginForWallDetail(room)
  const ordered: StairEditorElement[] = []
  const remaining = [...relevant]

  const entryScore = (candidate: StairEditorElement) => {
    const direction = stairDirectionForWallDetail(candidate)
    const center = stairElementCenterForWallDetail(candidate)
    const startGap = distance(startPoint, direction.start)
    const endGap = distance(startPoint, direction.end)
    const segmentGap = stairDistancePointToSegment(startPoint, direction.start, direction.end)
    const centerGap = distance(startPoint, center)
    const wrongSidePenalty = endGap + 0.18 < startGap ? 0.75 : 0
    const landingBonus = candidate.kind === 'landing' ? -0.06 : 0
    return startGap * 1.9 + segmentGap * 0.35 + centerGap * 0.25 + wrongSidePenalty + landingBonus
  }

  remaining.sort((left, right) => entryScore(left) - entryScore(right))
  ordered.push(remaining.shift()!)

  while (remaining.length) {
    const current = ordered[ordered.length - 1]
    const currentDirection = stairDirectionForWallDetail(current)
    const unit = stairDirectionUnitForWallDetail(current)
    const pivot = currentDirection.end

    remaining.sort((left, right) => {
      const evalCandidate = (candidate: StairEditorElement) => {
        const candidateDirection = stairDirectionForWallDetail(candidate)
        const candidateCenter = stairElementCenterForWallDetail(candidate)
        const vecX = candidateCenter.x - pivot.x
        const vecY = candidateCenter.y - pivot.y
        const along = vecX * unit.x + vecY * unit.y
        const lateral = Math.abs(vecX * unit.y - vecY * unit.x)
        const startGap = distance(pivot, candidateDirection.start)
        const endGap = distance(pivot, candidateDirection.end)
        const segmentGap = stairDistancePointToSegment(pivot, candidateDirection.start, candidateDirection.end)
        const backwardsPenalty = along < -0.02 ? Math.abs(along) * 5 : 0
        const wrongStartPenalty = endGap + 0.12 < startGap ? 0.4 : 0
        const kindBonus = candidate.kind === 'landing' ? 0.08 : 0
        return startGap * 1.9 + segmentGap * 0.65 + lateral * 0.42 + backwardsPenalty + wrongStartPenalty + kindBonus
      }
      return evalCandidate(left) - evalCandidate(right)
    })
    ordered.push(remaining.shift()!)
  }

  return ordered
}

function stairTotalStepsForWallDetail(room: Room, elements: StairEditorElement[]) {
  return Math.max(1, stairOrderedElementsForWallDetail(room, elements).reduce((sum, element) => {
    if (element.kind !== 'stair' && element.kind !== 'turn') return sum
    return sum + Math.max(1, Math.round(element.steps || 1))
  }, 0))
}

function stairElementStartStepForWallDetail(room: Room, elements: StairEditorElement[], target: StairEditorElement) {
  let stepIndex = 0
  for (const element of stairOrderedElementsForWallDetail(room, elements)) {
    if (element.id === target.id) return stepIndex
    if (element.kind === 'stair' || element.kind === 'turn') stepIndex += Math.max(1, Math.round(element.steps || 1))
  }
  return stepIndex
}

function stairNeighborSideForWallDetail(room: Room, target: StairEditorElement, elements: StairEditorElement[]): 'left' | 'right' {
  void room
  const rect = {
    left: target.xM,
    top: target.yM,
    right: target.xM + target.widthM,
    bottom: target.yM + target.heightM,
  }
  const centerX = target.xM + target.widthM / 2
  const centerY = target.yM + target.heightM / 2
  const candidates = elements
    .filter((candidate) => candidate.id !== target.id && candidate.kind === 'stair')
    .map((candidate) => {
      const candidateCenterX = candidate.xM + candidate.widthM / 2
      const candidateCenterY = candidate.yM + candidate.heightM / 2
      const verticalOverlap = Math.max(0, Math.min(rect.bottom, candidate.yM + candidate.heightM) - Math.max(rect.top, candidate.yM))
      const gap = candidateCenterX > centerX
        ? Math.max(0, candidate.xM - rect.right)
        : Math.max(0, rect.left - (candidate.xM + candidate.widthM))
      const score = gap + Math.abs(candidateCenterY - centerY) * 0.25 - verticalOverlap * 0.6
      return { candidateCenterX, score }
    })
    .sort((a, b) => a.score - b.score)
  return candidates[0]
    ? (candidates[0].candidateCenterX > centerX ? 'right' : 'left')
    : (target.mirrored ? 'left' : 'right')
}

function stairElementPolygons3D(room: Room, element: StairEditorElement, roomHeightM: number, elements: StairEditorElement[]): { role: 'landing' | 'tread' | 'riser'; points: Vec3[] }[] {
  const rect = {
    left: element.xM,
    top: element.yM,
    right: element.xM + element.widthM,
    bottom: element.yM + element.heightM,
  }
  const steps = Math.max(1, Math.round(element.steps || 1))
  const totalSteps = stairTotalStepsForWallDetail(room, elements)
  const stepHeightM = Math.max(0.001, roomHeightM / totalSteps)
  const startStep = stairElementStartStepForWallDetail(room, elements, element)
  const baseZ = stepHeightM * startStep
  const rotation = normalizeRightAngle(element.rotationDeg)

  if (element.kind === 'landing') {
    return [{ role: 'landing', points: stairRectPolygon3D(rect.left, rect.top, rect.right, rect.bottom, baseZ) }]
  }

  const polygons: { role: 'landing' | 'tread' | 'riser'; points: Vec3[] }[] = []

  if (element.kind === 'stair') {
    for (let index = 0; index < steps; index += 1) {
      const zPrev = round3(baseZ + stepHeightM * index)
      const zNext = round3(baseZ + stepHeightM * (index + 1))
      if (rotation === 90) {
        const x1 = rect.right - (element.widthM * index) / steps
        const x0 = rect.right - (element.widthM * (index + 1)) / steps
        polygons.push({ role: 'tread', points: stairRectPolygon3D(x0, rect.top, x1, rect.bottom, zNext) })
        polygons.push({ role: 'riser', points: [
          { x: x1, y: rect.top, z: zPrev }, { x: x1, y: rect.bottom, z: zPrev },
          { x: x1, y: rect.bottom, z: zNext }, { x: x1, y: rect.top, z: zNext },
        ] })
      } else if (rotation === 270) {
        const x0 = rect.left + (element.widthM * index) / steps
        const x1 = rect.left + (element.widthM * (index + 1)) / steps
        polygons.push({ role: 'tread', points: stairRectPolygon3D(x0, rect.top, x1, rect.bottom, zNext) })
        polygons.push({ role: 'riser', points: [
          { x: x0, y: rect.top, z: zPrev }, { x: x0, y: rect.bottom, z: zPrev },
          { x: x0, y: rect.bottom, z: zNext }, { x: x0, y: rect.top, z: zNext },
        ] })
      } else if (rotation === 180) {
        const y0 = rect.top + (element.heightM * index) / steps
        const y1 = rect.top + (element.heightM * (index + 1)) / steps
        polygons.push({ role: 'tread', points: stairRectPolygon3D(rect.left, y0, rect.right, y1, zNext) })
        polygons.push({ role: 'riser', points: [
          { x: rect.left, y: y1, z: zPrev }, { x: rect.right, y: y1, z: zPrev },
          { x: rect.right, y: y1, z: zNext }, { x: rect.left, y: y1, z: zNext },
        ] })
      } else {
        const y1 = rect.bottom - (element.heightM * index) / steps
        const y0 = rect.bottom - (element.heightM * (index + 1)) / steps
        polygons.push({ role: 'tread', points: stairRectPolygon3D(rect.left, y0, rect.right, y1, zNext) })
        polygons.push({ role: 'riser', points: [
          { x: rect.left, y: y0, z: zPrev }, { x: rect.right, y: y0, z: zPrev },
          { x: rect.right, y: y0, z: zNext }, { x: rect.left, y: y0, z: zNext },
        ] })
      }
    }
    return polygons
  }

  if (element.kind === 'turn') {
    const neighborSide = stairNeighborSideForWallDetail(room, element, elements)
    const origin = neighborSide === 'right'
      ? { x: rect.right, y: rect.bottom }
      : { x: rect.left, y: rect.bottom }
    const nominalStartAngle = neighborSide === 'right' ? Math.PI : -Math.PI / 2
    const nominalEndAngle = neighborSide === 'right' ? Math.PI * 1.5 : 0
    const nominalStartPoint = stairRayToRectBoundary(origin, rect, nominalStartAngle + 0.0001)
    const nominalEndPoint = stairRayToRectBoundary(origin, rect, nominalEndAngle - 0.0001)
    const direction = stairDirectionForWallDetail(element)
    const startDistanceNormal = distance(direction.start, nominalStartPoint) + distance(direction.end, nominalEndPoint)
    const startDistanceReversed = distance(direction.start, nominalEndPoint) + distance(direction.end, nominalStartPoint)
    const angleA = startDistanceNormal <= startDistanceReversed ? nominalStartAngle : nominalEndAngle
    const angleB = startDistanceNormal <= startDistanceReversed ? nominalEndAngle : nominalStartAngle

    for (let index = 0; index < steps; index += 1) {
      const fromAngle = angleA + ((angleB - angleA) * index) / steps
      const toAngle = angleA + ((angleB - angleA) * (index + 1)) / steps
      const startPoint = stairRayToRectBoundary(origin, rect, fromAngle)
      const endPoint = stairRayToRectBoundary(origin, rect, toAngle)
      const zPrev = round3(baseZ + stepHeightM * index)
      const zNext = round3(baseZ + stepHeightM * (index + 1))
      polygons.push({
        role: 'tread',
        points: [
          { x: origin.x, y: origin.y, z: zNext },
          { x: startPoint.x, y: startPoint.y, z: zNext },
          { x: endPoint.x, y: endPoint.y, z: zNext },
        ],
      })
      polygons.push({
        role: 'riser',
        points: [
          { x: startPoint.x, y: startPoint.y, z: zPrev },
          { x: endPoint.x, y: endPoint.y, z: zPrev },
          { x: endPoint.x, y: endPoint.y, z: zNext },
          { x: startPoint.x, y: startPoint.y, z: zNext },
        ],
      })
    }
  }

  return polygons
}

function projectWallModelStairPolygons(model: WallModel3D, basis: CameraBasis): ProjectedWallStairPolygon[] {
  const projected: ProjectedWallStairPolygon[] = []
  model.rooms
    .filter((modelRoom) => isStairRoom(modelRoom.room))
    .forEach((modelRoom) => {
      const elements = readStairLayoutElements(modelRoom.room.id)
      stairOrderedElementsForWallDetail(modelRoom.room, elements).forEach((element) => {
        stairElementPolygons3D(modelRoom.room, element, model.heightM, elements).forEach((entry, index) => {
          const points = entry.points.map((point) => projectVec3ToSvg(point, basis))
          const avgDepth = round3(points.reduce((sum, point) => sum + point.depth, 0) / Math.max(1, points.length))
          projected.push({
            roomId: modelRoom.room.id,
            key: `${modelRoom.room.id}-${element.id}-${entry.role}-${index}`,
            role: entry.role,
            points,
            avgDepth,
          })
        })
      })
    })
  return projected.sort((a, b) => b.avgDepth - a.avgDepth)
}

function buildWallModel3D(floorId: string, rooms: Room[], heightM: number, wallObjectsByKey: Record<string, WallPlacedObject[]>): WallModel3D {
  const safeHeight = Math.max(0.05, heightM)
  const modelSourceRooms = rooms
  const bounds = boundsOf(modelSourceRooms.flatMap((room) => room.vertices))
  const originM = bounds
    ? { x: round3((bounds.minX + bounds.maxX) / 2), y: round3((bounds.minY + bounds.maxY) / 2) }
    : { x: 0, y: 0 }
  const modelRooms: WallModelRoom3D[] = modelSourceRooms.map((room) => ({
    id: room.id,
    room,
    outerWall: isOuterWallRoom(room),
    floorLoop: room.vertices.map((point) => ({ x: point.x, y: point.y, z: 0 })),
    ceilingLoop: room.vertices.map((point) => ({ x: point.x, y: point.y, z: safeHeight })),
    labelPoint: { x: centroid(room.vertices).x, y: centroid(room.vertices).y, z: 0.018 },
  }))
  const faces: WallModelFace3D[] = []
  modelRooms.forEach((modelRoom) => {
    modelRoom.floorLoop.forEach((point, edgeIndex) => {
      const nextIndex = (edgeIndex + 1) % modelRoom.floorLoop.length
      const a = point
      const b = modelRoom.floorLoop[nextIndex]
      const topB = modelRoom.ceilingLoop[nextIndex]
      const topA = modelRoom.ceilingLoop[edgeIndex]
      const key = wallObjectKey(floorId, modelRoom.room.id, edgeIndex)
      faces.push({
        id: `${modelRoom.room.id}:${edgeIndex}`,
        key,
        room: modelRoom.room,
        roomId: modelRoom.room.id,
        edgeIndex,
        outerWall: modelRoom.outerWall,
        a,
        b,
        topB,
        topA,
        lengthM: distance({ x: a.x, y: a.y }, { x: b.x, y: b.y }),
        pairGroupKey: `${modelRoom.room.id}:${edgeIndex}`,
        pairedFaceIds: [],
      })
    })
  })
  for (let i = 0; i < faces.length; i += 1) {
    for (let j = i + 1; j < faces.length; j += 1) {
      const aFace = faces[i]
      const bFace = faces[j]
      const pair = wallEdgePairInfo({ a: { x: aFace.a.x, y: aFace.a.y }, b: { x: aFace.b.x, y: aFace.b.y } }, { a: { x: bFace.a.x, y: bFace.a.y }, b: { x: bFace.b.x, y: bFace.b.y } })
      if (!pair?.paired) continue
      const groupKey = [aFace.id, bFace.id].sort().join('|')
      aFace.pairGroupKey = groupKey
      bFace.pairGroupKey = groupKey
      if (!aFace.pairedFaceIds.includes(bFace.id)) aFace.pairedFaceIds.push(bFace.id)
      if (!bFace.pairedFaceIds.includes(aFace.id)) bFace.pairedFaceIds.push(aFace.id)
    }
  }
  faces.forEach((face) => {
    const objects = wallObjectsByKey[face.key] ?? []
    if (objects.length === 0) return
    faces.forEach((candidate) => {
      if (candidate.id === face.id || candidate.pairGroupKey !== face.pairGroupKey) return
      if (!candidate.pairedFaceIds.includes(face.id)) candidate.pairedFaceIds.push(face.id)
    })
  })
  return {
    floorId,
    heightM: safeHeight,
    rooms: modelRooms,
    faces,
    bounds,
    originM,
    outerRoomId: modelRooms.find((room) => room.outerWall)?.room.id,
  }
}

function projectWallModelRooms(model: WallModel3D, basis: CameraBasis, selectedRoomId: string): RenderedProjectedRoom[] {
  return model.rooms
    .map((modelRoom) => {
      const floor = modelRoom.floorLoop.map((point) => projectVec3ToSvg(point, basis))
      const ceiling = modelRoom.ceilingLoop.map((point) => projectVec3ToSvg(point, basis))
      const label = projectVec3ToSvg(modelRoom.labelPoint, basis)
      return {
        room: modelRoom.room,
        outerWall: modelRoom.outerWall,
        selectedRoom: modelRoom.room.id === selectedRoomId,
        avgDepth: round3(floor.reduce((sum, point) => sum + point.depth, 0) / Math.max(1, floor.length)),
        projected: { floor, ceiling, center: svgCentroid(floor), label },
      }
    })
    .sort((a, b) => b.avgDepth - a.avgDepth)
}

function projectWallModelFaces(model: WallModel3D, basis: CameraBasis, selectedWall: WallSelection | null): RenderedWallFace[] {
  return model.faces
    .map((face) => {
      const points = [face.a, face.b, face.topB, face.topA].map((point) => projectVec3ToSvg(point, basis))
      const axis = wallFaceAnimationAxisFromSvg(points[0], points[1])
      return {
        room: face.room,
        outerWall: face.outerWall,
        edgeIndex: face.edgeIndex,
        selected: selectedWall?.roomId === face.roomId && selectedWall.edgeIndex === face.edgeIndex,
        points,
        avgDepth: round3(points.reduce((sum, point) => sum + point.depth, 0) / Math.max(1, points.length)),
        axis,
        modelFaceId: face.id,
        pairGroupKey: face.pairGroupKey,
        pairedFaceIds: face.pairedFaceIds,
      }
    })
    .sort((a, b) => {
      if (a.outerWall !== b.outerWall) return a.outerWall ? -1 : 1
      return b.avgDepth - a.avgDepth
    })
}

function wallModelCeilingGapPath(model: WallModel3D, basis: CameraBasis) {
  const outer = model.rooms.find((room) => room.outerWall)
  if (!outer) return ''
  const outerCeiling = outer.ceilingLoop.map((point) => projectVec3ToSvg(point, basis))
  if (outerCeiling.length < 3) return ''
  const holes = model.rooms
    .filter((room) => !room.outerWall)
    .map((room) => room.ceilingLoop.map((point) => projectVec3ToSvg(point, basis)))
    .filter((points) => points.length >= 3)
  return [svgClosedPath(outerCeiling), ...holes.map(svgClosedPath)].join(' ')
}

function projectVec3ToSvg(point: Vec3, basis: CameraBasis): CameraProjectedPoint {
  return cameraProject(point, basis)
}

type CameraProjectedPoint = SvgPoint & { depth: number }
type ProjectedRoom3D = { floor: CameraProjectedPoint[]; ceiling: CameraProjectedPoint[]; center: SvgPoint; label: CameraProjectedPoint }
type Vec3 = { x: number; y: number; z: number }
type CameraBasis = { camera: Vec3; right: Vec3; up: Vec3; forward: Vec3; focal: number; originSvg: SvgPoint }

type WallFace3D = { points: SvgPoint[]; avgDepth: number }

function projectRoom3D(vertices: PointM[], heightM: number, basis: CameraBasis): ProjectedRoom3D {
  const floor = vertices.map((point) => wall3DProjectToSvg(point, 0, basis))
  const ceiling = vertices.map((point) => wall3DProjectToSvg(point, Math.max(0.1, heightM), basis))
  const center = svgCentroid(floor)
  const label = wall3DProjectToSvg(centroid(vertices), 0.015, basis)
  return { floor, ceiling, center, label }
}

function wall3DFaceData(projectedRoom: ProjectedRoom3D, edgeIndex: number): WallFace3D | null {
  if (projectedRoom.floor.length < 2 || projectedRoom.ceiling.length < projectedRoom.floor.length) return null
  const a = projectedRoom.floor[edgeIndex]
  const b = projectedRoom.floor[(edgeIndex + 1) % projectedRoom.floor.length]
  const topB = projectedRoom.ceiling[(edgeIndex + 1) % projectedRoom.floor.length]
  const topA = projectedRoom.ceiling[edgeIndex]
  if (!a || !b || !topA || !topB) return null
  return {
    points: [a, b, topB, topA],
    avgDepth: round3((a.depth + b.depth + topA.depth + topB.depth) / 4),
  }
}

function wallCeilingGapPath(rooms: Room[], heightM: number, basis: CameraBasis) {
  const outer = rooms.find((room) => isOuterWallRoom(room))
  if (!outer) return ''
  const outerProjected = projectRoom3D(outer.vertices, heightM, basis)
  if (outerProjected.ceiling.length < 3) return ''
  const holes = rooms
    .filter((room) => !isOuterWallRoom(room))
    .map((room) => projectRoom3D(room.vertices, heightM, basis).ceiling)
    .filter((points) => points.length >= 3)
  return [svgClosedPath(outerProjected.ceiling), ...holes.map(svgClosedPath)].join(' ')
}

function svgClosedPath(points: SvgPoint[]) {
  if (points.length === 0) return ''
  const [first, ...rest] = points
  return `M ${round2(first.x)} ${round2(first.y)} ${rest.map((point) => `L ${round2(point.x)} ${round2(point.y)}`).join(' ')} Z`
}

function wall3DProjectToSvg(point: PointM, zM: number, basis: CameraBasis): CameraProjectedPoint {
  const projected = cameraProject({ x: point.x, y: point.y, z: zM }, basis)
  return { x: projected.x, y: projected.y, depth: projected.depth }
}

function cameraProject(point: Vec3, basis: CameraBasis): CameraProjectedPoint {
  const rel = { x: point.x - basis.camera.x, y: point.y - basis.camera.y, z: point.z - basis.camera.z }
  const cx = dot3(rel, basis.right)
  const cy = dot3(rel, basis.up)
  const depth = Math.max(0.6, dot3(rel, basis.forward))
  const factor = basis.focal / depth
  return {
    x: round2(basis.originSvg.x + cx * canvas.scale * factor),
    y: round2(basis.originSvg.y - cy * canvas.scale * factor),
    depth,
  }
}

function wallCameraBasis(originM: PointM, originSvg: SvgPoint, rooms: Room[], heightM: number, yawDeg: number, pitchDeg: number): CameraBasis {
  const bounds = boundsOf(rooms.flatMap((room) => room.vertices))
  const widthM = bounds ? Math.max(1, bounds.maxX - bounds.minX) : 8
  const heightPlanM = bounds ? Math.max(1, bounds.maxY - bounds.minY) : 8
  const sceneRadius = Math.max(widthM, heightPlanM, heightM * 2)
  const distance = sceneRadius * 2.8
  const yaw = yawDeg * Math.PI / 180
  const pitch = clamp(pitchDeg, 15, 90) * Math.PI / 180
  const horizontalRadius = distance * Math.cos(pitch)
  const vertical = distance * Math.sin(pitch)
  const cameraPoint = {
    x: originM.x + horizontalRadius * Math.cos(yaw),
    y: originM.y + horizontalRadius * Math.sin(yaw),
    z: vertical,
  }
  const target = { x: originM.x, y: originM.y, z: 0 }
  const forward = normalize3({ x: target.x - cameraPoint.x, y: target.y - cameraPoint.y, z: target.z - cameraPoint.z })
  const worldUp = { x: 0, y: 0, z: 1 }
  const baseRight = normalize3(cross3(forward, worldUp))
  let right = { x: -baseRight.x, y: -baseRight.y, z: -baseRight.z }
  if (Math.hypot(right.x, right.y, right.z) < 0.0001) right = { x: 1, y: 0, z: 0 }
  const up = normalize3(cross3(baseRight, forward))
  const focal = distance * 1.02
  return { camera: cameraPoint, right, up, forward, focal, originSvg }
}

function floorLabelTransformFromProjected(projectedRoom: ProjectedRoom3D) {
  const label = projectedRoom.label ?? projectedRoom.center
  const points = projectedRoom.floor
  if (points.length < 2) return `translate(${round2(label.x)} ${round2(label.y)})`
  const longestEdge = points
    .map((point, index) => {
      const next = points[(index + 1) % points.length]
      return { a: point, b: next, len: Math.hypot(next.x - point.x, next.y - point.y) }
    })
    .sort((a, b) => b.len - a.len)[0]
  let angle = Math.atan2(longestEdge.b.y - longestEdge.a.y, longestEdge.b.x - longestEdge.a.x) * 180 / Math.PI
  if (angle > 90 || angle < -90) angle += 180
  return `translate(${round2(label.x)} ${round2(label.y)}) rotate(${round2(angle)}) scale(1 0.58)`
}


function wallObjectsForFace(face: RenderedWallFace, floorId: string, rooms: Room[], wallObjectsByKey: Record<string, WallPlacedObject[]>) {
  const ownKey = wallObjectKey(floorId, face.room.id, face.edgeIndex)
  const ownObjects = wallObjectsByKey[ownKey] ?? []
  const ownGroupIds = new Set(ownObjects.map((item) => item.groupId).filter((value): value is string => Boolean(value)))
  const faceEdge = edgePoints(face.room.vertices, face.edgeIndex)
  if (!faceEdge) return ownObjects
  const mirrored: WallPlacedObject[] = []
  rooms.forEach((room) => {
    room.vertices.forEach((_, edgeIndex) => {
      if (room.id === face.room.id && edgeIndex === face.edgeIndex) return
      const key = wallObjectKey(floorId, room.id, edgeIndex)
      const objects = wallObjectsByKey[key] ?? []
      if (objects.length === 0) return
      const otherEdge = edgePoints(room.vertices, edgeIndex)
      if (!otherEdge || !samePhysicalWallEdge(faceEdge, otherEdge)) return
      objects.forEach((item) => {
        if (item.groupId && ownGroupIds.has(item.groupId)) return
        const projected = projectWallPlacedObjectBetweenRooms(item, room, edgeIndex, face.room, face.edgeIndex)
        mirrored.push({ ...projected, id: `${item.id}-mirror-${room.id}-${edgeIndex}` })
      })
    })
  })
  return [...ownObjects, ...mirrored]
}

function samePhysicalWallEdge(a: { a: PointM; b: PointM }, b: { a: PointM; b: PointM }) {
  return Boolean(wallEdgePairInfo(a, b)?.paired)
}

type WallEdgePairInfo = { paired: boolean; reversed: boolean }

function wallEdgePairInfo(a: { a: PointM; b: PointM }, b: { a: PointM; b: PointM }): WallEdgePairInfo | null {
  const direct = distance(a.a, b.a) + distance(a.b, b.b)
  const reversedExact = distance(a.a, b.b) + distance(a.b, b.a)
  if (Math.min(direct, reversedExact) < 0.08) return { paired: true, reversed: reversedExact < direct }
  const ax = a.b.x - a.a.x
  const ay = a.b.y - a.a.y
  const bx = b.b.x - b.a.x
  const by = b.b.y - b.a.y
  const lenA = Math.hypot(ax, ay)
  const lenB = Math.hypot(bx, by)
  if (lenA < 0.2 || lenB < 0.2) return null
  const dot = (ax * bx + ay * by) / (lenA * lenB)
  if (Math.abs(dot) < 0.965) return null
  const ux = ax / lenA
  const uy = ay / lenA
  const normalDistanceA = Math.abs((b.a.x - a.a.x) * uy - (b.a.y - a.a.y) * ux)
  const normalDistanceB = Math.abs((b.b.x - a.a.x) * uy - (b.b.y - a.a.y) * ux)
  const maxNormalDistance = Math.max(normalDistanceA, normalDistanceB)
  if (maxNormalDistance > 0.32) return null
  const t1 = (b.a.x - a.a.x) * ux + (b.a.y - a.a.y) * uy
  const t2 = (b.b.x - a.a.x) * ux + (b.b.y - a.a.y) * uy
  const overlap = Math.min(lenA, Math.max(t1, t2)) - Math.max(0, Math.min(t1, t2))
  if (overlap < Math.min(0.35, Math.min(lenA, lenB) * 0.35)) return null
  return { paired: true, reversed: dot < 0 }
}

function wallOpeningRevealPolygonsBetween(
  face: RenderedWallFace,
  item: WallPlacedObject,
  faces: RenderedWallFace[],
  floorId: string,
  rooms: Room[],
  wallObjectsByKey: Record<string, WallPlacedObject[]>,
) {
  if (face.points.length < 4 || (item.type !== 'door' && item.type !== 'window') || !item.groupId || !face.modelFaceId) return []
  const partner = findOpeningPartnerFace(face, item, faces, floorId, rooms, wallObjectsByKey)
  if (!partner?.face.modelFaceId) return []
  const canonicalFaceId = [face.modelFaceId, partner.face.modelFaceId].sort()[0]
  if (face.modelFaceId !== canonicalFaceId) return []
  const front = wallObjectProjectedPolygon(face.points, item)
  const backRaw = wallObjectProjectedPolygon(partner.face.points, partner.item)
  if (front.length < 4 || backRaw.length < 4) return []
  const back = alignOpeningBackPolygon(front, backRaw)
  const [frontTopLeft, frontTopRight, frontBottomRight, frontBottomLeft] = front
  const [backTopLeft, backTopRight, backBottomRight, backBottomLeft] = back
  return [
    { kind: 'side', polygon: [frontTopLeft, backTopLeft, backBottomLeft, frontBottomLeft] },
    { kind: 'side', polygon: [frontTopRight, backTopRight, backBottomRight, frontBottomRight] },
    { kind: 'top', polygon: [frontTopLeft, frontTopRight, backTopRight, backTopLeft] },
    { kind: 'floor', polygon: [frontBottomLeft, frontBottomRight, backBottomRight, backBottomLeft] },
  ]
}

function findOpeningPartnerFace(
  face: RenderedWallFace,
  item: WallPlacedObject,
  faces: RenderedWallFace[],
  floorId: string,
  rooms: Room[],
  wallObjectsByKey: Record<string, WallPlacedObject[]>,
): { face: RenderedWallFace; item: WallPlacedObject } | null {
  const sourceRoom = rooms.find((room) => room.id === face.room.id) ?? face.room
  const faceEdge = edgePoints(sourceRoom.vertices, face.edgeIndex)
  if (!faceEdge) return null
  const candidates = faces.flatMap((candidate) => {
    if (candidate.modelFaceId === face.modelFaceId) return []
    const candidateRoom = rooms.find((room) => room.id === candidate.room.id) ?? candidate.room
    const candidateEdge = edgePoints(candidateRoom.vertices, candidate.edgeIndex)
    if (!candidateEdge) return []
    const pair = wallEdgePairInfo(faceEdge, candidateEdge)
    if (!pair?.paired) return []
    const projectedItem = projectWallPlacedObjectBetweenRooms(item, sourceRoom, face.edgeIndex, candidateRoom, candidate.edgeIndex)
    const centerDistance = openingCenterDistance(face.points, item, candidate.points, projectedItem)
    return [{ face: candidate, item: projectedItem, score: centerDistance }]
  })
  if (candidates.length === 0) return null
  candidates.sort((a, b) => a.score - b.score)
  return { face: candidates[0].face, item: candidates[0].item }
}

function openingCenterDistance(aFace: SvgPoint[], aItem: WallPlacedObject, bFace: SvgPoint[], bItem: WallPlacedObject) {
  const a = svgCentroid(wallObjectProjectedPolygon(aFace, aItem))
  const b = svgCentroid(wallObjectProjectedPolygon(bFace, bItem))
  return Math.hypot(a.x - b.x, a.y - b.y)
}

function alignOpeningBackPolygon(front: SvgPoint[], back: SvgPoint[]) {
  const sameCost = Math.hypot(front[0].x - back[0].x, front[0].y - back[0].y)
    + Math.hypot(front[1].x - back[1].x, front[1].y - back[1].y)
    + Math.hypot(front[2].x - back[2].x, front[2].y - back[2].y)
    + Math.hypot(front[3].x - back[3].x, front[3].y - back[3].y)
  const swapCost = Math.hypot(front[0].x - back[1].x, front[0].y - back[1].y)
    + Math.hypot(front[1].x - back[0].x, front[1].y - back[0].y)
    + Math.hypot(front[2].x - back[3].x, front[2].y - back[3].y)
    + Math.hypot(front[3].x - back[2].x, front[3].y - back[2].y)
  return swapCost < sameCost ? [back[1], back[0], back[3], back[2]] : back
}

function nearestWallObjectGapM(item: WallPlacedObject, placements: WallPlacedObject[]) {
  const self = wallObjectRect(item)
  let nearest = Number.POSITIVE_INFINITY
  placements.forEach((other) => {
    if (other.id === item.id) return
    const rect = wallObjectRect(other)
    const gapX = rect.left > self.right ? rect.left - self.right : self.left > rect.right ? self.left - rect.right : 0
    const gapY = rect.top > self.bottom ? rect.top - self.bottom : self.top > rect.bottom ? self.top - rect.bottom : 0
    const gap = Math.hypot(gapX, gapY)
    nearest = Math.min(nearest, gap)
  })
  return Number.isFinite(nearest) ? nearest : 0
}

function wallObjectRect(item: WallPlacedObject) {
  return {
    left: clamp(item.x - item.w / 2, 0, 1),
    right: clamp(item.x + item.w / 2, 0, 1),
    top: clamp(item.y - item.h / 2, 0, 1),
    bottom: clamp(item.y + item.h / 2, 0, 1),
  }
}

function wallFaceVisiblePolygons(facePoints: SvgPoint[], openings: WallPlacedObject[]) {
  if (facePoints.length < 4) return [facePoints]
  const openingRects = openings.map(wallObjectRect).filter((rect) => rect.right > rect.left && rect.bottom > rect.top)
  if (openingRects.length === 0) return [facePoints]
  const xs = uniqueSorted([0, 1, ...openingRects.flatMap((rect) => [rect.left, rect.right])])
  const ys = uniqueSorted([0, 1, ...openingRects.flatMap((rect) => [rect.top, rect.bottom])])
  const polygons: SvgPoint[][] = []
  for (let xi = 0; xi < xs.length - 1; xi += 1) {
    for (let yi = 0; yi < ys.length - 1; yi += 1) {
      const left = xs[xi]
      const right = xs[xi + 1]
      const top = ys[yi]
      const bottom = ys[yi + 1]
      if (right - left < 0.0005 || bottom - top < 0.0005) continue
      const cx = (left + right) / 2
      const cy = (top + bottom) / 2
      if (openingRects.some((rect) => cx >= rect.left && cx <= rect.right && cy >= rect.top && cy <= rect.bottom)) continue
      polygons.push([
        wallFacePointAt(facePoints, left, top),
        wallFacePointAt(facePoints, right, top),
        wallFacePointAt(facePoints, right, bottom),
        wallFacePointAt(facePoints, left, bottom),
      ])
    }
  }
  return polygons.length > 0 ? polygons : [facePoints]
}

function uniqueSorted(values: number[]) {
  return Array.from(new Set(values.map((value) => clamp(round3(value), 0, 1)))).sort((a, b) => a - b)
}

function wallObjectProjectedPolygon(facePoints: SvgPoint[], item: WallPlacedObject) {
  if (facePoints.length < 4) return []
  const left = clamp(item.x - item.w / 2, 0, 1)
  const right = clamp(item.x + item.w / 2, 0, 1)
  const top = clamp(item.y - item.h / 2, 0, 1)
  const bottom = clamp(item.y + item.h / 2, 0, 1)
  return [
    wallFacePointAt(facePoints, left, top),
    wallFacePointAt(facePoints, right, top),
    wallFacePointAt(facePoints, right, bottom),
    wallFacePointAt(facePoints, left, bottom),
  ]
}

function wallFacePointAt(facePoints: SvgPoint[], xNorm: number, yNorm: number): SvgPoint {
  const floorA = facePoints[0]
  const floorB = facePoints[1]
  const topB = facePoints[2]
  const topA = facePoints[3]
  const top = { x: topA.x + (topB.x - topA.x) * xNorm, y: topA.y + (topB.y - topA.y) * xNorm }
  const bottom = { x: floorA.x + (floorB.x - floorA.x) * xNorm, y: floorA.y + (floorB.y - floorA.y) * xNorm }
  return { x: round2(top.x + (bottom.x - top.x) * yNorm), y: round2(top.y + (bottom.y - top.y) * yNorm) }
}

function normalize2(vector: SvgPoint): SvgPoint {
  const length = Math.hypot(vector.x, vector.y)
  if (length < 0.0001) return { x: 1, y: 0 }
  return { x: vector.x / length, y: vector.y / length }
}

function round4(value: number) {
  return Math.round(value * 10000) / 10000
}

function easeInOutCubic(t: number) {
  const clamped = clamp(t, 0, 1)
  return clamped < 0.5 ? 4 * clamped * clamped * clamped : 1 - Math.pow(-2 * clamped + 2, 3) / 2
}

function easeOutCubic(t: number) {
  const clamped = clamp(t, 0, 1)
  return 1 - Math.pow(1 - clamped, 3)
}

function rotatePointM(point: PointM, pivot: PointM, rotationDeg: number): PointM {
  const rad = rotationDeg * Math.PI / 180
  const cos = Math.cos(rad)
  const sin = Math.sin(rad)
  const dx = point.x - pivot.x
  const dy = point.y - pivot.y
  return {
    x: round3(pivot.x + dx * cos - dy * sin),
    y: round3(pivot.y + dx * sin + dy * cos),
  }
}

function svgPointsToString(points: SvgPoint[]) {
  return points.map((point) => `${round2(point.x)},${round2(point.y)}`).join(' ')
}

function svgCentroid(points: SvgPoint[]): SvgPoint {
  if (points.length === 0) return { x: canvas.width / 2, y: canvas.height / 2 }
  const sum = points.reduce((acc, point) => ({ x: acc.x + point.x, y: acc.y + point.y }), { x: 0, y: 0 })
  return { x: round2(sum.x / points.length), y: round2(sum.y / points.length) }
}

function wallFaceAnimationAxisFromSvg(a: SvgPoint | undefined, b: SvgPoint | undefined) {
  if (!a || !b) return { x: 1, y: 0, originX: canvas.width / 2, originY: canvas.height / 2 }
  const len = Math.hypot(b.x - a.x, b.y - a.y) || 1
  return {
    x: round3((b.x - a.x) / len),
    y: round3((b.y - a.y) / len),
    originX: round2((a.x + b.x) / 2),
    originY: round2((a.y + b.y) / 2),
  }
}

function dot3(a: Vec3, b: Vec3) {
  return a.x * b.x + a.y * b.y + a.z * b.z
}

function cross3(a: Vec3, b: Vec3): Vec3 {
  return {
    x: a.y * b.z - a.z * b.y,
    y: a.z * b.x - a.x * b.z,
    z: a.x * b.y - a.y * b.x,
  }
}

function normalize3(value: Vec3): Vec3 {
  const len = Math.hypot(value.x, value.y, value.z) || 1
  return { x: value.x / len, y: value.y / len, z: value.z / len }
}

function wallOverlayMotion(edge: { a: PointM; b: PointM }, lengthM: number, rotationDeg: number, pivot: SvgPoint, zoom: number, scrollPosition: { left: number; top: number }, initialPosition: { x: number; y: number }): WallOverlayMotion {
  const ax = mToX(edge.a.x)
  const ay = mToY(edge.a.y)
  const bx = mToX(edge.b.x)
  const by = mToY(edge.b.y)
  const mid = rotateSvgPoint({ x: (ax + bx) / 2, y: (ay + by) / 2 }, pivot, rotationDeg)
  const overlayCenter = { x: initialPosition.x + 280, y: initialPosition.y + 154 }
  const source = { x: mid.x * zoom - scrollPosition.left, y: mid.y * zoom - scrollPosition.top }
  const wallPx = Math.max(1, lengthM * canvas.scale * zoom)
  const startScale = clamp(wallPx / 520, 0.045, 0.72)
  const startRotate = normalizeDegrees((Math.atan2(by - ay, bx - ax) * 180 / Math.PI) + rotationDeg)
  return {
    startDx: round2(source.x - overlayCenter.x),
    startDy: round2(source.y - overlayCenter.y),
    startRotate,
    startScale: round3(startScale),
    initialX: initialPosition.x,
    initialY: initialPosition.y,
  }
}

function rotateSvgPoint(point: SvgPoint, pivot: SvgPoint, rotationDeg: number): SvgPoint {
  const rad = rotationDeg * Math.PI / 180
  const cos = Math.cos(rad)
  const sin = Math.sin(rad)
  const dx = point.x - pivot.x
  const dy = point.y - pivot.y
  return {
    x: pivot.x + dx * cos - dy * sin,
    y: pivot.y + dx * sin + dy * cos,
  }
}

function lerpPoint(a: PointM, b: PointM, t: number): PointM {
  return { x: round3(a.x + (b.x - a.x) * t), y: round3(a.y + (b.y - a.y) * t) }
}

function BoardMock() {
  return <div className="placeholder3d"><p>Verteileransicht: folgt nach dem Blueprint.</p></div>
}

function ThreeDMock() {
  return <div className="placeholder3d"><div className="cube" /><p>3D-Ansicht: spaeter Three.js / React Three Fiber</p></div>
}

function roomToPayload(room: Room) {
  return {
    name: room.name.trim() || 'Raum',
    shapeType: room.shapeType,
    roomType: room.roomType ?? 'room',
    wallThicknessM: room.wallThicknessM > 0 ? room.wallThicknessM : 0.12,
    vertices: room.vertices,
  }
}

function viewModeIcon(mode: ViewMode) {
  if (mode === 'floorplan') return '▦'
  if (mode === 'wall') return '▤'
  if (mode === 'board') return '⚡'
  return '⌂'
}

function toolLabel(tool: Tool) {
  if (tool === 'select') return 'Auswaehlen'
  if (tool === 'rectangle') return 'Rechteckraum zeichnen'
  if (tool === 'outerwall') return 'Aussenwand zeichnen'
  if (tool === 'polygon') return 'Polygonraum zeichnen'
  if (tool === 'recess') return 'Aussparung / Wandvorsprung'
  return 'Abstand zwischen Kanten'
}

function toolIcon(tool: Tool) {
  if (tool === 'select') return '↖'
  if (tool === 'rectangle') return '▭'
  if (tool === 'outerwall') return '▤'
  if (tool === 'polygon') return '⬠'
  if (tool === 'recess') return '▱'
  if (tool === 'stair') return '⇵'
  return '⇔'
}

function mToX(meter: number) { return canvas.margin + (meter - canvas.minM) * canvas.scale }
function mToY(meter: number) { return canvas.margin + (meter - canvas.minM) * canvas.scale }
function xToM(x: number) { return (x - canvas.margin) / canvas.scale + canvas.minM }
function yToM(y: number) { return (y - canvas.margin) / canvas.scale + canvas.minM }

function buildDistanceEdgeSelection(roomId: string, vertices: PointM[], edgeIndex: number): DistanceEdgeSelection | null {
  if (vertices.length < 2) return null
  const a = vertices[edgeIndex]
  const b = vertices[(edgeIndex + 1) % vertices.length]
  if (!a || !b) return null
  const dx = Math.abs(b.x - a.x)
  const dy = Math.abs(b.y - a.y)
  if (dx < 0.001 && dy < 0.001) return null
  if (dy >= dx) {
    return { roomId, edgeIndex, axis: 'vertical', coord: round3((a.x + b.x) / 2), min: Math.min(a.y, b.y), max: Math.max(a.y, b.y) }
  }
  return { roomId, edgeIndex, axis: 'horizontal', coord: round3((a.y + b.y) / 2), min: Math.min(a.x, b.x), max: Math.max(a.x, b.x) }
}

function isDistanceEdgeMatch(edge: DistanceEdgeSelection | null | undefined, roomId: string, edgeIndex: number) {
  return Boolean(edge && edge.roomId === roomId && edge.edgeIndex === edgeIndex)
}

function eventToMeters(event: ReactMouseEvent<Element>): PointM | null {
  const svg = (event.currentTarget instanceof SVGSVGElement ? event.currentTarget : event.currentTarget.closest('svg')) as SVGSVGElement | null
  if (!svg) return null
  const rect = svg.getBoundingClientRect()
  const svgX = ((event.clientX - rect.left) / rect.width) * canvas.width
  const svgY = ((event.clientY - rect.top) / rect.height) * canvas.height
  return clampPoint({ x: round2(xToM(svgX)), y: round2(yToM(svgY)) })
}

function pointsToSvg(points: PointM[]) {
  return points.map((point) => `${mToX(point.x)},${mToY(point.y)}`).join(' ')
}

function rectangleVertices(x: number, y: number, width: number, height: number): PointM[] {
  const minX = clamp(round2(x), 0, canvas.maxM)
  const minY = clamp(round2(y), 0, canvas.maxM)
  const maxX = clamp(round2(minX + Math.max(0.1, width)), 0, canvas.maxM)
  const maxY = clamp(round2(minY + Math.max(0.1, height)), 0, canvas.maxM)
  return [
    { x: minX, y: minY },
    { x: maxX, y: minY },
    { x: maxX, y: maxY },
    { x: minX, y: maxY },
  ]
}

function normalizeRect(a: PointM, b: PointM): RectM {
  const minX = Math.min(a.x, b.x)
  const minY = Math.min(a.y, b.y)
  const maxX = Math.max(a.x, b.x)
  const maxY = Math.max(a.y, b.y)
  return { minX, minY, maxX, maxY, width: round2(maxX - minX), height: round2(maxY - minY) }
}

function boundsOf(points: PointM[]): Bounds | null {
  if (points.length === 0) return null
  return points.reduce<Bounds>((bounds, point) => ({
    minX: Math.min(bounds.minX, point.x),
    maxX: Math.max(bounds.maxX, point.x),
    minY: Math.min(bounds.minY, point.y),
    maxY: Math.max(bounds.maxY, point.y),
  }), { minX: points[0].x, maxX: points[0].x, minY: points[0].y, maxY: points[0].y })
}

function centroid(points: PointM[]): PointM {
  if (points.length === 0) return { x: 0, y: 0 }
  const sum = points.reduce((acc, point) => ({ x: acc.x + point.x, y: acc.y + point.y }), { x: 0, y: 0 })
  return { x: sum.x / points.length, y: sum.y / points.length }
}

function polygonAreaM2(points: PointM[]) {
  if (points.length < 3) return 0
  let sum = 0
  for (let index = 0; index < points.length; index += 1) {
    const current = points[index]
    const next = points[(index + 1) % points.length]
    sum += current.x * next.y - next.x * current.y
  }
  return Math.abs(sum / 2)
}

function distance(a: PointM, b: PointM) {
  return Math.hypot(a.x - b.x, a.y - b.y)
}

function isNearStartPoint(point: PointM, start: PointM) {
  return distance(point, start) <= 0.18
}

function round2(value: number) {
  return Math.round((Number.isFinite(value) ? value : 0) * 1000) / 1000
}

function clamp(value: number, min: number, max: number) {
  return Math.min(max, Math.max(min, value))
}

function clampPoint(point: PointM): PointM {
  return {
    x: clamp(round2(point.x), 0, canvas.maxM),
    y: clamp(round2(point.y), 0, canvas.maxM),
  }
}

function clampPointToBounds(point: PointM, bounds: Bounds): PointM {
  return {
    x: clamp(round2(point.x), bounds.minX, bounds.maxX),
    y: clamp(round2(point.y), bounds.minY, bounds.maxY),
  }
}

function constrainTo45(origin: PointM, raw: PointM): PointM {
  const dx = raw.x - origin.x
  const dy = raw.y - origin.y
  const length = Math.hypot(dx, dy)
  if (length < 0.01) return raw
  const step = Math.PI / 4
  const angle = Math.atan2(dy, dx)
  const snapped = Math.round(angle / step) * step
  return clampPoint({ x: origin.x + Math.cos(snapped) * length, y: origin.y + Math.sin(snapped) * length })
}

function constrainDragToAxis(dx: number, dy: number): { dx: number; dy: number; axis: DragAxis } {
  if (Math.abs(dx) >= Math.abs(dy)) return { dx, dy: 0, axis: 'x' }
  return { dx: 0, dy, axis: 'y' }
}

function constrainDeltaTo45(dx: number, dy: number): { dx: number; dy: number } {
  const length = Math.hypot(dx, dy)
  if (length < 0.001) return { dx: 0, dy: 0 }
  const step = Math.PI / 4
  const angle = Math.atan2(dy, dx)
  const snapped = Math.round(angle / step) * step
  return { dx: round2(Math.cos(snapped) * length), dy: round2(Math.sin(snapped) * length) }
}

function keyboardStepForZoom(zoom: number) {
  if (zoom >= 1.6) return 0.02
  if (zoom >= 0.9) return 0.05
  return 0.10
}

function isEditableTarget(target: EventTarget | null) {
  const element = target as HTMLElement | null
  if (!element) return false
  const tag = element.tagName.toLowerCase()
  return tag === 'input' || tag === 'textarea' || tag === 'select' || element.isContentEditable
}

function resizeRectangleByHandle(vertices: PointM[], handle: RectHandle, point: PointM): PointM[] {
  const bounds = boundsOf(vertices)
  if (!bounds) return vertices
  let minX = bounds.minX
  let maxX = bounds.maxX
  let minY = bounds.minY
  let maxY = bounds.maxY
  if (handle === 'left') minX = clamp(point.x, 0, maxX - 0.1)
  if (handle === 'right') maxX = clamp(point.x, minX + 0.1, canvas.maxM)
  if (handle === 'top') minY = clamp(point.y, 0, maxY - 0.1)
  if (handle === 'bottom') maxY = clamp(point.y, minY + 0.1, canvas.maxM)
  return rectangleVertices(minX, minY, maxX - minX, maxY - minY)
}

function snapVerticesToRooms(vertices: PointM[], targets: Array<{ room: Room; vertices: PointM[] }>, wallThicknessM: number, axisLock: DragAxis): PointM[] {
  const source = boundsOf(vertices)
  if (!source || targets.length === 0) return vertices
  const threshold = 0.18
  const wall = Math.max(0, wallThicknessM)
  let bestDx = 0
  let bestDy = 0
  let bestXScore = threshold
  let bestYScore = threshold

  for (const targetItem of targets) {
    const target = boundsOf(targetItem.vertices)
    if (!target) continue
    const verticalOverlap = source.minY <= target.maxY + wall && source.maxY >= target.minY - wall
    const horizontalOverlap = source.minX <= target.maxX + wall && source.maxX >= target.minX - wall

    const sideBySideCandidate = Math.min(
      Math.abs(target.maxX + wall - source.minX),
      Math.abs(target.minX - wall - source.maxX),
      Math.abs(target.maxX - source.minX),
      Math.abs(target.minX - source.maxX),
    ) < threshold
    const aboveBelowCandidate = Math.min(
      Math.abs(target.maxY + wall - source.minY),
      Math.abs(target.minY - wall - source.maxY),
      Math.abs(target.maxY - source.minY),
      Math.abs(target.minY - source.maxY),
    ) < threshold

    if (axisLock !== 'y' && (verticalOverlap || sideBySideCandidate)) {
      const candidatesX = [
        target.maxX - source.minX,
        target.minX - source.maxX,
        target.maxX + wall - source.minX,
        target.minX - wall - source.maxX,
        target.minX - source.minX,
        target.maxX - source.maxX,
      ]
      for (const dx of candidatesX) {
        const score = Math.abs(dx)
        if (score < bestXScore) { bestXScore = score; bestDx = dx }
      }
    }

    if (axisLock !== 'x' && (horizontalOverlap || aboveBelowCandidate || sideBySideCandidate)) {
      const candidatesY = [
        target.maxY - source.minY,
        target.minY - source.maxY,
        target.maxY + wall - source.minY,
        target.minY - wall - source.maxY,
        target.minY - source.minY,
        target.maxY - source.maxY,
      ]
      for (const dy of candidatesY) {
        const score = Math.abs(dy)
        if (score < bestYScore) { bestYScore = score; bestDy = dy }
      }
    }
  }
  if (bestDx === 0 && bestDy === 0) return vertices
  return vertices.map((vertex) => clampPoint({ x: vertex.x + bestDx, y: vertex.y + bestDy }))
}

function buildDistanceGuides(vertices: PointM[], targets: Array<{ room: Room; vertices: PointM[] }>) {
  const source = boundsOf(vertices)
  if (!source) return []
  const guides: Array<{ from: PointM; to: PointM; distance: number }> = []
  for (const targetItem of targets) {
    const target = boundsOf(targetItem.vertices)
    if (!target) continue
    const y = Math.max(Math.min((Math.max(source.minY, target.minY) + Math.min(source.maxY, target.maxY)) / 2, source.maxY), source.minY)
    if (source.maxX <= target.minX) guides.push({ from: { x: source.maxX, y }, to: { x: target.minX, y }, distance: target.minX - source.maxX })
    if (target.maxX <= source.minX) guides.push({ from: { x: source.minX, y }, to: { x: target.maxX, y }, distance: source.minX - target.maxX })
    const x = Math.max(Math.min((Math.max(source.minX, target.minX) + Math.min(source.maxX, target.maxX)) / 2, source.maxX), source.minX)
    if (source.maxY <= target.minY) guides.push({ from: { x, y: source.maxY }, to: { x, y: target.minY }, distance: target.minY - source.maxY })
    if (target.maxY <= source.minY) guides.push({ from: { x, y: source.minY }, to: { x, y: target.maxY }, distance: source.minY - target.maxY })
  }
  return guides.filter((guide) => guide.distance >= 0 && guide.distance <= 3).sort((a, b) => a.distance - b.distance).slice(0, 4)
}



function offsetFromPointForEdge(bounds: Bounds, edge: RecessEdge, point: PointM): number {
  return edge === 'top' || edge === 'bottom'
    ? Math.max(0, round2(point.x - bounds.minX))
    : Math.max(0, round2(point.y - bounds.minY))
}

function offsetFromPreview(room: Room, preview: RecessPreview): number {
  const bounds = boundsOf(room.vertices)
  if (!bounds) return 0
  if (preview.edge === 'top' || preview.edge === 'bottom') {
    return Math.max(0, round2(preview.offsetFromEnd ? bounds.maxX - preview.rect.maxX : preview.rect.minX - bounds.minX))
  }
  return Math.max(0, round2(preview.offsetFromEnd ? bounds.maxY - preview.rect.maxY : preview.rect.minY - bounds.minY))
}

function dimensionBreaks(values: number[], min: number, max: number): number[] {
  const eps = 0.03
  const sorted = [min, ...values, max].map(round2).sort((a, b) => a - b)
  const result: number[] = []
  for (const value of sorted) {
    if (value < min - eps || value > max + eps) continue
    const clamped = clamp(value, min, max)
    if (result.length === 0 || Math.abs(clamped - result[result.length - 1]) > eps) result.push(round2(clamped))
  }
  return result.length >= 2 ? result : [round2(min), round2(max)]
}

function formatDimValue(value: number) {
  return `${Math.round(value * 1000)} mm`
}

function defaultRecessEdge(room: Room): RecessEdge {
  return room.shapeType === 'rectangle' ? 'top' : 'top'
}

function defaultRecessDraftForRoom(room: Room, edge: RecessEdge): RecessDraft {
  const bounds = boundsOf(room.vertices) ?? { minX: 0, minY: 0, maxX: 1, maxY: 1 }
  const alongLimit = edge === 'top' || edge === 'bottom' ? bounds.maxX - bounds.minX : bounds.maxY - bounds.minY
  const depthLimit = edge === 'top' || edge === 'bottom' ? bounds.maxY - bounds.minY : bounds.maxX - bounds.minX
  const along = clamp(0.8, 0.05, Math.max(0.05, alongLimit))
  const depth = clamp(0.3, 0.05, Math.max(0.05, depthLimit))
  const offset = clamp(round2((alongLimit - along) / 2), 0, Math.max(0, alongLimit - along))
  const common = { edge, manualAlongM: along, manualDepthM: depth, manualOffsetM: offset, manualOffsetFromEnd: false, phase: 'idle' as const }
  if (edge === 'top') return { start: { x: round2(bounds.minX + offset), y: bounds.minY }, end: { x: round2(bounds.minX + offset + along), y: round2(bounds.minY + depth) }, ...common }
  if (edge === 'bottom') return { start: { x: round2(bounds.minX + offset), y: round2(bounds.maxY - depth) }, end: { x: round2(bounds.minX + offset + along), y: bounds.maxY }, ...common }
  if (edge === 'left') return { start: { x: bounds.minX, y: round2(bounds.minY + offset) }, end: { x: round2(bounds.minX + depth), y: round2(bounds.minY + offset + along) }, ...common }
  return { start: { x: round2(bounds.maxX - depth), y: round2(bounds.minY + offset) }, end: { x: bounds.maxX, y: round2(bounds.minY + offset + along) }, ...common }
}

function resizeRecessDraftByHandle(room: Room, draft: RecessDraft, handle: RecessHandle, point: PointM): RecessDraft | null {
  const preview = buildRecessPreview(room, draft)
  const roomBounds = boundsOf(room.vertices)
  if (!preview || !roomBounds) return null
  const p = clampPointToBounds(point, roomBounds)
  const r = { ...preview.rect }
  if (handle === 'left') r.minX = clamp(round2(p.x), roomBounds.minX, r.maxX - 0.05)
  if (handle === 'right') r.maxX = clamp(round2(p.x), r.minX + 0.05, roomBounds.maxX)
  if (handle === 'top') r.minY = clamp(round2(p.y), roomBounds.minY, r.maxY - 0.05)
  if (handle === 'bottom') r.maxY = clamp(round2(p.y), r.minY + 0.05, roomBounds.maxY)
  r.width = round2(r.maxX - r.minX)
  r.height = round2(r.maxY - r.minY)
  const edge = draft.edge ?? preview.edge
  const along = edge === 'top' || edge === 'bottom' ? r.width : r.height
  const depth = edge === 'top' || edge === 'bottom' ? r.height : r.width
  const fromEnd = Boolean(draft.manualOffsetFromEnd)
  const offset = edge === 'top' || edge === 'bottom'
    ? (fromEnd ? roomBounds.maxX - r.maxX : r.minX - roomBounds.minX)
    : (fromEnd ? roomBounds.maxY - r.maxY : r.minY - roomBounds.minY)
  return {
    ...draft,
    start: { x: r.minX, y: r.minY },
    end: { x: r.maxX, y: r.maxY },
    manualAlongM: along,
    manualDepthM: depth,
    manualOffsetM: Math.max(0, round2(offset)),
    manualOffsetFromEnd: fromEnd,
    edge,
    phase: 'ready',
  }
}

function normalizeResultPolygon(points: PointM[]): PointM[] {
  const cleaned = cleanPolygon(points)
  const bounds = boundsOf(cleaned)
  if (!bounds) return cleaned
  const eps = 0.01
  const hasTopLeft = cleaned.some((p) => Math.abs(p.x - bounds.minX) <= eps && Math.abs(p.y - bounds.minY) <= eps)
  const hasTopRight = cleaned.some((p) => Math.abs(p.x - bounds.maxX) <= eps && Math.abs(p.y - bounds.minY) <= eps)
  const hasBottomRight = cleaned.some((p) => Math.abs(p.x - bounds.maxX) <= eps && Math.abs(p.y - bounds.maxY) <= eps)
  const hasBottomLeft = cleaned.some((p) => Math.abs(p.x - bounds.minX) <= eps && Math.abs(p.y - bounds.maxY) <= eps)
  if (cleaned.length <= 4 && hasTopLeft && hasTopRight && hasBottomRight && hasBottomLeft) {
    return rectangleVertices(bounds.minX, bounds.minY, bounds.maxX - bounds.minX, bounds.maxY - bounds.minY)
  }
  return cleaned
}

function isAxisAlignedRectangle(points: PointM[]): boolean {
  const normalized = normalizeResultPolygon(points)
  const bounds = boundsOf(normalized)
  if (!bounds || normalized.length !== 4) return false
  const eps = 0.01
  const corners = rectangleVertices(bounds.minX, bounds.minY, bounds.maxX - bounds.minX, bounds.maxY - bounds.minY)
  return corners.every((corner) => normalized.some((point) => Math.abs(point.x - corner.x) <= eps && Math.abs(point.y - corner.y) <= eps))
}

function cleanPolygon(points: PointM[]): PointM[] {
  const eps = 0.01
  let work = points
    .map((point) => clampPoint({ x: round2(point.x), y: round2(point.y) }))
    .filter((point, index, array) => index === 0 || distance(point, array[index - 1]) > eps)
  if (work.length > 1 && distance(work[0], work[work.length - 1]) <= eps) work = work.slice(0, -1)

  let changed = true
  let guard = 0
  while (changed && work.length > 3 && guard < 12) {
    changed = false
    guard += 1
    const next: PointM[] = []
    for (let index = 0; index < work.length; index += 1) {
      const prev = work[(index - 1 + work.length) % work.length]
      const current = work[index]
      const following = work[(index + 1) % work.length]
      const prevLen = distance(prev, current)
      const nextLen = distance(current, following)
      const cross = (current.x - prev.x) * (following.y - current.y) - (current.y - prev.y) * (following.x - current.x)
      const collinear = Math.abs(cross) <= 0.0005
      if (prevLen <= eps || nextLen <= eps || collinear) {
        changed = true
        continue
      }
      next.push(current)
    }
    if (next.length >= 3) work = next
  }
  return work.length >= 3 ? work : points.map((point) => clampPoint(point))
}

function buildRecessPreview(room: Room, draft: RecessDraft): RecessPreview | null {
  const bounds = boundsOf(room.vertices)
  if (!bounds) return null
  const raw = normalizeRect(clampPointToBounds(draft.start, bounds), clampPointToBounds(draft.end, bounds))
  const center = { x: raw.minX + raw.width / 2, y: raw.minY + raw.height / 2 }
  const distances: Array<{ edge: RecessEdge; distance: number }> = [
    { edge: 'top', distance: Math.abs(center.y - bounds.minY) },
    { edge: 'right', distance: Math.abs(bounds.maxX - center.x) },
    { edge: 'bottom', distance: Math.abs(bounds.maxY - center.y) },
    { edge: 'left', distance: Math.abs(center.x - bounds.minX) },
  ]
  const edge = draft.edge ?? distances.sort((a, b) => a.distance - b.distance)[0].edge
  const alongLimit = edge === 'top' || edge === 'bottom' ? bounds.maxX - bounds.minX : bounds.maxY - bounds.minY
  const depthLimit = edge === 'top' || edge === 'bottom' ? bounds.maxY - bounds.minY : bounds.maxX - bounds.minX
  const rawAlong = edge === 'top' || edge === 'bottom' ? raw.width : raw.height
  const rawDepth = edge === 'top' || edge === 'bottom' ? raw.height : raw.width
  const along = clamp(round2(draft.manualAlongM ?? rawAlong), 0.05, Math.max(0.05, alongLimit))
  const depth = clamp(round2(draft.manualDepthM ?? rawDepth), 0.05, Math.max(0.05, depthLimit))
  const offsetFromEnd = Boolean(draft.manualOffsetFromEnd)
  const rawOffset = edge === 'top' || edge === 'bottom'
    ? (offsetFromEnd ? bounds.maxX - raw.maxX : raw.minX - bounds.minX)
    : (offsetFromEnd ? bounds.maxY - raw.maxY : raw.minY - bounds.minY)
  const offset = clamp(round2(draft.manualOffsetM ?? rawOffset), 0, Math.max(0, alongLimit - along))
  let rect: RectM
  if (edge === 'top') {
    const minX = offsetFromEnd ? round2(bounds.maxX - offset - along) : round2(bounds.minX + offset)
    rect = { minX, maxX: round2(minX + along), minY: bounds.minY, maxY: round2(bounds.minY + depth), width: along, height: depth }
  } else if (edge === 'bottom') {
    const minX = offsetFromEnd ? round2(bounds.maxX - offset - along) : round2(bounds.minX + offset)
    rect = { minX, maxX: round2(minX + along), minY: round2(bounds.maxY - depth), maxY: bounds.maxY, width: along, height: depth }
  } else if (edge === 'left') {
    const minY = offsetFromEnd ? round2(bounds.maxY - offset - along) : round2(bounds.minY + offset)
    rect = { minX: bounds.minX, maxX: round2(bounds.minX + depth), minY, maxY: round2(minY + along), width: depth, height: along }
  } else {
    const minY = offsetFromEnd ? round2(bounds.maxY - offset - along) : round2(bounds.minY + offset)
    rect = { minX: round2(bounds.maxX - depth), maxX: bounds.maxX, minY, maxY: round2(minY + along), width: depth, height: along }
  }
  return { rect, edge, offsetFromEnd, vertices: subtractRecessRectFromRoom(room, rect, edge) }
}

function subtractRecessRectFromRoom(room: Room, rect: RectM, edge: RecessEdge): PointM[] {
  const source = normalizeResultPolygon(room.vertices)
  const bounds = boundsOf(source)
  if (!bounds) return source
  const eps = 0.0005
  const xs = recessUniqueCoordinates([...source.map((point) => point.x), rect.minX, rect.maxX])
  const ys = recessUniqueCoordinates([...source.map((point) => point.y), rect.minY, rect.maxY])
  if (xs.length < 2 || ys.length < 2) return source

  const occupied = new Set<string>()
  for (let xi = 0; xi < xs.length - 1; xi += 1) {
    for (let yi = 0; yi < ys.length - 1; yi += 1) {
      const x0 = xs[xi]
      const x1 = xs[xi + 1]
      const y0 = ys[yi]
      const y1 = ys[yi + 1]
      if (x1 - x0 <= eps || y1 - y0 <= eps) continue
      const center = { x: (x0 + x1) / 2, y: (y0 + y1) / 2 }
      const insideRoom = recessPointInPolygon(center, source)
      const insideCut = center.x > rect.minX + eps && center.x < rect.maxX - eps && center.y > rect.minY + eps && center.y < rect.maxY - eps
      if (insideRoom && !insideCut) occupied.add(`${xi},${yi}`)
    }
  }

  if (occupied.size === 0) return source
  const hasCell = (xi: number, yi: number) => occupied.has(`${xi},${yi}`)
  const segments: Array<{ start: PointM; end: PointM }> = []
  const addSegment = (start: PointM, end: PointM) => {
    if (distance(start, end) > eps) segments.push({ start: clampPoint(start), end: clampPoint(end) })
  }

  for (let xi = 0; xi < xs.length - 1; xi += 1) {
    for (let yi = 0; yi < ys.length - 1; yi += 1) {
      if (!hasCell(xi, yi)) continue
      const x0 = xs[xi]
      const x1 = xs[xi + 1]
      const y0 = ys[yi]
      const y1 = ys[yi + 1]
      if (!hasCell(xi, yi - 1)) addSegment({ x: x0, y: y0 }, { x: x1, y: y0 })
      if (!hasCell(xi + 1, yi)) addSegment({ x: x1, y: y0 }, { x: x1, y: y1 })
      if (!hasCell(xi, yi + 1)) addSegment({ x: x1, y: y1 }, { x: x0, y: y1 })
      if (!hasCell(xi - 1, yi)) addSegment({ x: x0, y: y1 }, { x: x0, y: y0 })
    }
  }

  const loops = recessTraceBoundaryLoops(segments)
    .map((loop) => normalizeResultPolygon(loop))
    .filter((loop) => loop.length >= 3)

  if (loops.length === 0) return subtractRectFromBounds(bounds, rect, edge)
  const largest = loops.reduce((best, loop) => Math.abs(polygonAreaM2(loop)) > Math.abs(polygonAreaM2(best)) ? loop : best, loops[0])
  return normalizeResultPolygon(largest)
}

function recessUniqueCoordinates(values: number[]): number[] {
  const sorted = values
    .filter((value) => Number.isFinite(value))
    .map((value) => round2(value))
    .sort((a, b) => a - b)
  const result: number[] = []
  for (const value of sorted) {
    if (result.length === 0 || Math.abs(value - result[result.length - 1]) > 0.0005) result.push(value)
  }
  return result
}

function recessPointInPolygon(point: PointM, polygon: PointM[]): boolean {
  let inside = false
  for (let index = 0, previous = polygon.length - 1; index < polygon.length; previous = index, index += 1) {
    const a = polygon[index]
    const b = polygon[previous]
    const crosses = ((a.y > point.y) !== (b.y > point.y)) && (point.x < ((b.x - a.x) * (point.y - a.y)) / ((b.y - a.y) || 0.0000001) + a.x)
    if (crosses) inside = !inside
  }
  return inside
}

function recessPointKey(point: PointM): string {
  return `${round2(point.x)},${round2(point.y)}`
}

function recessSegmentKey(segment: { start: PointM; end: PointM }): string {
  return `${recessPointKey(segment.start)}>${recessPointKey(segment.end)}`
}

function recessTraceBoundaryLoops(segments: Array<{ start: PointM; end: PointM }>): PointM[][] {
  const byStart = new Map<string, Array<{ start: PointM; end: PointM }>>()
  const unused = new Set<string>()
  for (const segment of segments) {
    const key = recessPointKey(segment.start)
    const list = byStart.get(key) ?? []
    list.push(segment)
    byStart.set(key, list)
    unused.add(recessSegmentKey(segment))
  }

  const loops: PointM[][] = []
  let guardAll = 0
  while (unused.size > 0 && guardAll < segments.length * 4) {
    guardAll += 1
    const firstKey = unused.values().next().value as string | undefined
    if (!firstKey) break
    const first = segments.find((segment) => recessSegmentKey(segment) === firstKey)
    if (!first) {
      unused.delete(firstKey)
      continue
    }
    const loop: PointM[] = []
    let current = first
    const startKey = recessPointKey(first.start)
    let guard = 0
    while (guard < segments.length + 8) {
      guard += 1
      const currentKey = recessSegmentKey(current)
      if (!unused.has(currentKey)) break
      unused.delete(currentKey)
      loop.push(current.start)
      const endKey = recessPointKey(current.end)
      if (endKey === startKey) break
      const next = (byStart.get(endKey) ?? []).find((segment) => unused.has(recessSegmentKey(segment)))
      if (!next) break
      current = next
    }
    if (loop.length >= 3) loops.push(loop)
  }
  return loops
}


function subtractRectFromBounds(bounds: Bounds, rect: RectM, edge: RecessEdge): PointM[] {
  const b = bounds
  const r = rect
  const eps = 0.01
  const touchesLeft = Math.abs(r.minX - b.minX) <= eps
  const touchesRight = Math.abs(r.maxX - b.maxX) <= eps
  const touchesTop = Math.abs(r.minY - b.minY) <= eps
  const touchesBottom = Math.abs(r.maxY - b.maxY) <= eps
  let points: PointM[]

  if (edge === 'top') {
    if (touchesLeft && touchesRight) points = rectangleVertices(b.minX, r.maxY, b.maxX - b.minX, b.maxY - r.maxY)
    else if (touchesLeft) points = [{ x: r.maxX, y: b.minY }, { x: b.maxX, y: b.minY }, { x: b.maxX, y: b.maxY }, { x: b.minX, y: b.maxY }, { x: b.minX, y: r.maxY }, { x: r.maxX, y: r.maxY }]
    else if (touchesRight) points = [{ x: b.minX, y: b.minY }, { x: r.minX, y: b.minY }, { x: r.minX, y: r.maxY }, { x: b.maxX, y: r.maxY }, { x: b.maxX, y: b.maxY }, { x: b.minX, y: b.maxY }]
    else points = [{ x: b.minX, y: b.minY }, { x: r.minX, y: b.minY }, { x: r.minX, y: r.maxY }, { x: r.maxX, y: r.maxY }, { x: r.maxX, y: b.minY }, { x: b.maxX, y: b.minY }, { x: b.maxX, y: b.maxY }, { x: b.minX, y: b.maxY }]
  } else if (edge === 'bottom') {
    if (touchesLeft && touchesRight) points = rectangleVertices(b.minX, b.minY, b.maxX - b.minX, r.minY - b.minY)
    else if (touchesLeft) points = [{ x: b.minX, y: b.minY }, { x: b.maxX, y: b.minY }, { x: b.maxX, y: b.maxY }, { x: r.maxX, y: b.maxY }, { x: r.maxX, y: r.minY }, { x: b.minX, y: r.minY }]
    else if (touchesRight) points = [{ x: b.minX, y: b.minY }, { x: b.maxX, y: b.minY }, { x: b.maxX, y: r.minY }, { x: r.minX, y: r.minY }, { x: r.minX, y: b.maxY }, { x: b.minX, y: b.maxY }]
    else points = [{ x: b.minX, y: b.minY }, { x: b.maxX, y: b.minY }, { x: b.maxX, y: b.maxY }, { x: r.maxX, y: b.maxY }, { x: r.maxX, y: r.minY }, { x: r.minX, y: r.minY }, { x: r.minX, y: b.maxY }, { x: b.minX, y: b.maxY }]
  } else if (edge === 'left') {
    if (touchesTop && touchesBottom) points = rectangleVertices(r.maxX, b.minY, b.maxX - r.maxX, b.maxY - b.minY)
    else if (touchesTop) points = [{ x: r.maxX, y: b.minY }, { x: b.maxX, y: b.minY }, { x: b.maxX, y: b.maxY }, { x: b.minX, y: b.maxY }, { x: b.minX, y: r.maxY }, { x: r.maxX, y: r.maxY }]
    else if (touchesBottom) points = [{ x: b.minX, y: b.minY }, { x: b.maxX, y: b.minY }, { x: b.maxX, y: b.maxY }, { x: r.maxX, y: b.maxY }, { x: r.maxX, y: r.minY }, { x: b.minX, y: r.minY }]
    else points = [{ x: b.minX, y: b.minY }, { x: b.maxX, y: b.minY }, { x: b.maxX, y: b.maxY }, { x: b.minX, y: b.maxY }, { x: b.minX, y: r.maxY }, { x: r.maxX, y: r.maxY }, { x: r.maxX, y: r.minY }, { x: b.minX, y: r.minY }]
  } else {
    if (touchesTop && touchesBottom) points = rectangleVertices(b.minX, b.minY, r.minX - b.minX, b.maxY - b.minY)
    else if (touchesTop) points = [{ x: b.minX, y: b.minY }, { x: r.minX, y: b.minY }, { x: r.minX, y: r.maxY }, { x: b.maxX, y: r.maxY }, { x: b.maxX, y: b.maxY }, { x: b.minX, y: b.maxY }]
    else if (touchesBottom) points = [{ x: b.minX, y: b.minY }, { x: b.maxX, y: b.minY }, { x: b.maxX, y: r.minY }, { x: r.minX, y: r.minY }, { x: r.minX, y: b.maxY }, { x: b.minX, y: b.maxY }]
    else points = [{ x: b.minX, y: b.minY }, { x: b.maxX, y: b.minY }, { x: b.maxX, y: r.minY }, { x: r.minX, y: r.minY }, { x: r.minX, y: r.maxY }, { x: b.maxX, y: r.maxY }, { x: b.maxX, y: b.maxY }, { x: b.minX, y: b.maxY }]
  }
  return normalizeResultPolygon(points.map(clampPoint))
}


function normalizeDimensionOffset(offset?: Partial<DimensionOffset> | null): DimensionOffset {
  const anyOffset = offset as Partial<DimensionOffset> & { x?: number; y?: number } | null | undefined
  return {
    xParts: typeof anyOffset?.xParts === 'number' ? anyOffset.xParts : 0,
    xTotal: typeof anyOffset?.xTotal === 'number' ? anyOffset.xTotal : (typeof anyOffset?.y === 'number' ? anyOffset.y : 0),
    yParts: typeof anyOffset?.yParts === 'number' ? anyOffset.yParts : 0,
    yTotal: typeof anyOffset?.yTotal === 'number' ? anyOffset.yTotal : (typeof anyOffset?.x === 'number' ? anyOffset.x : 0),
  }
}

function maxPointDelta(a: PointM[], b: PointM[]) {
  const count = Math.min(a.length, b.length)
  let max = 0
  for (let index = 0; index < count; index += 1) max = Math.max(max, distance(a[index], b[index]))
  return max
}

function edgeLabel(edge: RecessEdge) {
  if (edge === 'top') return 'an oberer Kante'
  if (edge === 'right') return 'an rechter Kante'
  if (edge === 'bottom') return 'an unterer Kante'
  return 'an linker Kante'
}

function toNumber(value: string, fallback: number) {
  const parsed = Number(value)
  return Number.isFinite(parsed) ? parsed : fallback
}

function formatM(value: number) { return `${round2(value).toFixed(2)} m` }
function formatM2(value: number) { return `${round2(value).toFixed(2)} m²` }
function formatInput(value: number) { return round2(value).toFixed(2) }




