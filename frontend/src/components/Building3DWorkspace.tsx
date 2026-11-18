import { useEffect, useMemo, useState } from 'react'
import { Canvas, ThreeEvent, useFrame, useThree } from '@react-three/fiber'
import * as THREE from 'three'
import { OrbitControls } from 'three/addons/controls/OrbitControls.js'
import { getWallObjects, updateWallObject as updateWallObjectApi } from '../api'
import type { Floor, Room, WallObject, PointM } from '../types'
import { buildSolidSurface, nearestRoomForWallHit } from '../building/solidGeometry'
import { selectWallEdgeFrom3DHit, type WallHitSelection3D } from '../building/wallHitSelection'
import { pickWallHoverPlane, buildWallHoverTriangles, type WallHoverPlane } from '../building/wallHoverGeometry'
import type { ReactNode } from 'react'
import { buildBuildingModel, type BuildingModel, type BuildingRoom, type BuildingWall, type BuildingOpening } from '../building/model'
import { active3DFloor, readActiveBlueprintLevel } from '../building/blueprintLevels'
// STROM143_STAIRS_FIX: share the exact saved room layouts across 3D views.
import { build3DStairsAcrossLevels143, type PlacedStairSurface143 } from '../building/stairVisibility143'

const roundMm = (value: number) => Math.round(value * 1000) / 1000
const fmtMm = (value: number) => Math.round(value * 1000).toLocaleString('de-DE')
const clamp = (value: number, min: number, max: number) => Math.max(min, Math.min(max, value))

function FloorMesh({ room, selected, onSelect }: { room: BuildingRoom; selected: boolean; onSelect: () => void }) {
  const [hovered, setHovered] = useState(false)
  const shape = useMemo(() => {
    const s = new THREE.Shape()
    room.vertices.forEach((point, index) => {
      if (index === 0) s.moveTo(point.x, -point.y)
      else s.lineTo(point.x, -point.y)
    })
    s.closePath()
    return s
  }, [room.vertices])
  if (room.kind === 'outer') return null
  return (
    <mesh rotation={[-Math.PI / 2, 0, 0]} position={[0, 0.015, 0]} onPointerOver={() => setHovered(true)} onPointerOut={() => setHovered(false)} onClick={(event: ThreeEvent<MouseEvent>) => { event.stopPropagation(); onSelect() }}>
      <shapeGeometry args={[shape]} />
      <meshStandardMaterial color={selected ? '#5797ec' : hovered ? '#a9cdfa' : room.kind === 'stair' ? '#e2ebf9' : '#e9edf2'} emissive={selected ? '#2563eb' : '#000000'} emissiveIntensity={selected ? 0.16 : 0} side={THREE.DoubleSide} roughness={0.87} />
    </mesh>
  )
}

// STROM141_WALL_HOVER: same Blueprint wall edge for hover and click.
// Hover rendering uses a selective COPY of the exact watertight 139 wall face.
// No second set of wall solids, no overlays across real door/window openings.
type HoveredSolidWall = WallHitSelection3D & { plane: WallHoverPlane }

function SolidWallMeshes({ model, onSelectRoom, onSelectWall, transparent }: {
  model: BuildingModel
  onSelectRoom: (id: string) => void
  onSelectWall?: (wall: WallHitSelection3D | null) => void
  transparent: boolean
}) {
  const [hovered, setHovered] = useState<HoveredSolidWall | null>(null)
  const gl = useThree((state) => state.gl)

  // Preserve the 139 model and geometry byte-for-byte: only its material
  // surface triangles are copied into the optional hover visualization.
  const geometry = useMemo(() => {
    const surface = buildSolidSurface(model)
    const mesh = new THREE.BufferGeometry()
    mesh.setAttribute('position', new THREE.Float32BufferAttribute(surface.positions, 3))
    mesh.computeVertexNormals()
    mesh.computeBoundingSphere()
    return mesh
  }, [model])
  useEffect(() => () => geometry.dispose(), [geometry])

  const hoverGeometry = useMemo(() => {
    if (!onSelectWall || !hovered) return null
    const room = model.rooms.find((item) => item.id === hovered.roomId)
    if (!room?.vertices || room.vertices.length < 2) return null
    const a = room.vertices[hovered.edgeIndex]
    const b = room.vertices[(hovered.edgeIndex + 1) % room.vertices.length]
    if (!a || !b) return null
    const positions = buildWallHoverTriangles(
      (geometry.getAttribute('position') as THREE.BufferAttribute).array, a, b, hovered.plane,
    )
    if (!positions.length) return null
    const patch = new THREE.BufferGeometry()
    patch.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3))
    patch.computeVertexNormals()
    patch.computeBoundingSphere()
    return patch
  }, [geometry, model, hovered, onSelectWall])
  useEffect(() => () => { hoverGeometry?.dispose() }, [hoverGeometry])

  // Only Wanddetail provides onSelectWall. 3D Haus is left untouched.
  useEffect(() => {
    if (!onSelectWall) return
    gl.domElement.style.cursor = hovered ? 'pointer' : ''
    return () => { gl.domElement.style.cursor = '' }
  }, [gl, hovered, onSelectWall])

  function hoverAt(event: ThreeEvent<PointerEvent>) {
    if (!onSelectWall) return
    const point = { x: event.point.x, y: event.point.z }
    const hitWall = selectWallEdgeFrom3DHit(model, point)
    if (!hitWall) {
      setHovered((previous) => previous === null ? previous : null)
      return
    }
    const room = model.rooms.find((item) => item.id === hitWall.roomId)
    if (!room?.vertices || room.vertices.length < 2) {
      setHovered(null)
      return
    }
    const a = room.vertices[hitWall.edgeIndex]
    const b = room.vertices[(hitWall.edgeIndex + 1) % room.vertices.length]
    if (!a || !b) { setHovered(null); return }
    const plane = pickWallHoverPlane(
      (geometry.getAttribute('position') as THREE.BufferAttribute).array, a, b, point, event.faceIndex ?? undefined,
    )
    if (!plane) { setHovered(null); return }
    // No React rerender while moving within the same physical wall surface.
    setHovered((previous) => {
      if (previous && previous.roomId === hitWall.roomId && previous.edgeIndex === hitWall.edgeIndex
        && Math.abs(previous.plane.offsetM - plane.offsetM) < 0.006
        && previous.plane.normalX * plane.normalX + previous.plane.normalZ * plane.normalZ > 0.99) {
        return previous
      }
      return { ...hitWall, plane }
    })
  }

  return (
    <group>
      <mesh
        geometry={geometry}
        onPointerMove={hoverAt}
        onPointerOut={() => setHovered(null)}
        onClick={(event: ThreeEvent<MouseEvent>) => {
          event.stopPropagation()
          if (onSelectWall && event.delta > 5) return // 3D camera orbit, not a wall click
          const point = { x: event.point.x, y: event.point.z }
          const hitWall = onSelectWall ? selectWallEdgeFrom3DHit(model, point) : null
          if (hitWall) {
            onSelectWall?.(hitWall)
            onSelectRoom(hitWall.roomId)
          } else {
            const roomId = nearestRoomForWallHit(model, point)
            if (roomId) onSelectRoom(roomId)
          }
        }}
        castShadow={!transparent}
        receiveShadow
      >
        <meshStandardMaterial
          color="#c1ccda"
          roughness={0.84}
          transparent={transparent}
          opacity={transparent ? 0.34 : 1}
          depthWrite={!transparent}
          side={THREE.DoubleSide}
        />
      </mesh>
      {hovered && hoverGeometry && onSelectWall && (
        <mesh
          geometry={hoverGeometry}
          position={[hovered.plane.normalX * 0.006, 0, hovered.plane.normalZ * 0.006]}
          raycast={() => {}}
          renderOrder={9}
        >
          <meshBasicMaterial
            color="#2563eb"
            transparent
            opacity={transparent ? 0.56 : 0.42}
            depthWrite={false}
            depthTest
            side={THREE.DoubleSide}
            polygonOffset
            polygonOffsetFactor={-2}
            polygonOffsetUnits={-2}
          />
        </mesh>
      )}
    </group>
  )
}

// STROM142_STAIRS3D: extruded tread footprints derived from the existing
// Treppe-einzeichnen layout. This is true 3D geometry, not stacked SVG.
function StairSolid({ surface, selected, onSelect }: {
  surface: PlacedStairSurface143
  selected: boolean
  onSelect: () => void
}) {
  const geometry = useMemo(() => {
    const shape = new THREE.Shape()
    surface.points.forEach((point, index) => {
      if (index === 0) shape.moveTo(point.x, -point.y)
      else shape.lineTo(point.x, -point.y)
    })
    shape.closePath()
    const solid = new THREE.ExtrudeGeometry(shape, {
      depth: Math.max(0.014, surface.elevationM), bevelEnabled: false, steps: 1, curveSegments: 1,
    })
    solid.rotateX(-Math.PI / 2)
    solid.computeVertexNormals()
    return solid
  }, [surface])
  useEffect(() => () => geometry.dispose(), [geometry])
  return (
    <mesh
      geometry={geometry}
      position={[0, surface.levelOffsetM, 0]}
      onClick={(event: ThreeEvent<MouseEvent>) => { event.stopPropagation(); if (Math.abs(surface.levelOffsetM) < 0.001) onSelect() }}
      castShadow
      receiveShadow
    >
      <meshStandardMaterial
        color={selected ? '#598fe4' : surface.kind === 'landing' ? '#c4d7ef' : '#9fbade'}
        transparent={Math.abs(surface.levelOffsetM) > 0.001}
        opacity={Math.abs(surface.levelOffsetM) > 0.001 ? 0.48 : 1}
        depthWrite={Math.abs(surface.levelOffsetM) <= 0.001}
        side={THREE.DoubleSide}
        roughness={0.78}
        metalness={0.03}
      />
    </mesh>
  )
}

function DoorHandle({ door, wall, selected, onSelect }: { door: BuildingOpening; wall: BuildingWall; selected: boolean; onSelect: () => void }) {
  const t = door.centerM / wall.lengthM
  const x = wall.start.x + (wall.end.x - wall.start.x) * t
  const z = wall.start.y + (wall.end.y - wall.start.y) * t
  return (
    <mesh
      position={[x, door.sillM + door.heightM / 2, z]}
      rotation={[0, -Math.atan2(wall.end.y - wall.start.y, wall.end.x - wall.start.x), 0]}
      onClick={(event: ThreeEvent<MouseEvent>) => { event.stopPropagation(); onSelect() }}
    >
      <boxGeometry args={[door.widthM, door.heightM, Math.max(0.045, wall.thicknessM + 0.018)]} />
      <meshBasicMaterial color={selected ? '#2563eb' : '#79a4d5'} transparent opacity={selected ? 0.3 : 0.085} depthWrite={false} />
    </mesh>
  )
}

function SceneControls({ model }: { model: BuildingModel }) {
  const { camera, gl } = useThree()
  const controls = useMemo(() => new OrbitControls(camera, gl.domElement), [camera, gl.domElement])
  useEffect(() => {
    controls.target.set(model.center.x, model.floorElevationM + model.floorHeightM / 2, model.center.y)
    controls.enableDamping = true
    controls.dampingFactor = 0.11
    controls.minDistance = 1
    controls.maxDistance = Math.max(35, model.spanM * 7)
    controls.maxPolarAngle = Math.PI * 0.49
    controls.update()
    return () => controls.dispose()
  }, [controls, model.floorId, model.center.x, model.center.y, model.floorElevationM, model.floorHeightM, model.spanM])
  useFrame(() => controls.update())
  return null
}

function RealBuildingScene({ model, stairs, selectedRoomId, selectedDoorId, onSelectRoom, onSelectDoor, onSelectWall, transparent }: {
  model: BuildingModel
  stairs: PlacedStairSurface143[]
  selectedRoomId: string
  selectedDoorId: string
  onSelectRoom: (id: string) => void
  onSelectDoor: (id: string) => void
  onSelectWall?: (wall: WallHitSelection3D | null) => void
  transparent: boolean
}) {
  const distance = Math.max(8, model.spanM * 1.2)
  return (
    <Canvas
      shadows={!transparent}
      dpr={[1, 1.75]}
      camera={{ position: [model.center.x + distance, model.floorElevationM + distance * 0.8 + model.floorHeightM, model.center.y + distance], fov: 48, near: 0.05, far: Math.max(100, model.spanM * 20) }}
      onPointerMissed={() => { onSelectDoor(''); onSelectRoom(''); onSelectWall?.(null) }}
      gl={{ antialias: true, alpha: false }}
      aria-label="Echte dreidimensionale Gebaeudeansicht"
    >
      <color attach="background" args={['#f5f8fc']} />
      <ambientLight intensity={1.15} />
      <directionalLight position={[14, 20, 16]} intensity={2.1} castShadow={!transparent} shadow-mapSize={[1024, 1024]} />
      <hemisphereLight args={['#e8f1ff', '#9698a6', 0.85]} />
      <group position={[0, model.floorElevationM, 0]}>
        {model.rooms.map((room) => (
          <FloorMesh key={room.id} room={room} selected={selectedRoomId === room.id} onSelect={() => { onSelectRoom(room.id); onSelectDoor(''); onSelectWall?.(null) }} />
        ))}
        {stairs.map((surface) => (
          <StairSolid
            key={surface.key}
            surface={surface}
            selected={surface.roomId === selectedRoomId}
            onSelect={() => { onSelectRoom(surface.roomId); onSelectDoor(''); onSelectWall?.(null) }}
          />
        ))}
        <SolidWallMeshes
          model={model}
          onSelectRoom={(id) => { onSelectRoom(id); onSelectDoor('') }}
          onSelectWall={onSelectWall}
          transparent={transparent}
        />
        {model.walls.flatMap((wall) => wall.openings
          .filter((opening) => opening.type === 'door' && opening.centerM >= -0.0001 && opening.centerM <= wall.lengthM + 0.0001 && model.doors.some((door) => door.id === opening.id))
          .map((door) => (
            <DoorHandle
              key={`${wall.id}/${door.id}`}
              door={door}
              wall={wall}
              selected={selectedDoorId === door.groupId}
              onSelect={() => {
                onSelectDoor(door.groupId)
                onSelectRoom(door.roomId)
                onSelectWall?.({ roomId: door.roomId, edgeIndex: door.edgeIndex })
              }}
            />
          )))}
      </group>
      <gridHelper args={[Math.max(40, model.spanM * 4), 40, '#bbc7d5', '#dce5ef']} position={[model.center.x, model.floorElevationM - 0.035, model.center.y]} />
      <SceneControls model={model} />
    </Canvas>
  )
}

function DoorForm({ model, door, rooms, rawObjects, onSaved }: {
  model: BuildingModel
  door: BuildingOpening
  rooms: Room[]
  rawObjects: WallObject[]
  onSaved: () => Promise<void>
}) {
  const [positionMm, setPositionMm] = useState(Math.round(door.centerM * 1000))
  const [widthMm, setWidthMm] = useState(Math.round(door.widthM * 1000))
  const [heightMm, setHeightMm] = useState(Math.round(door.heightM * 1000))
  const [saving, setSaving] = useState(false)
  const [notice, setNotice] = useState('')
  useEffect(() => {
    setPositionMm(Math.round(door.centerM * 1000))
    setWidthMm(Math.round(door.widthM * 1000))
    setHeightMm(Math.round(door.heightM * 1000))
    setNotice('')
  }, [door.id, door.centerM, door.widthM, door.heightM])

  async function save() {
    const originalWall = model.walls.find((wall) => wall.roomId === door.roomId && wall.edgeIndex === door.edgeIndex)
    const sourceRoom = rooms.find((room) => room.id === door.roomId)
    if (!originalWall && !sourceRoom) { setNotice('Quellwand nicht gefunden.'); return }
    const edge = sourceRoom && sourceRoom.vertices.length > door.edgeIndex
      ? { start: sourceRoom.vertices[door.edgeIndex], end: sourceRoom.vertices[(door.edgeIndex + 1) % sourceRoom.vertices.length] }
      : { start: originalWall!.start, end: originalWall!.end }
    const sourceLength = Math.hypot(edge.end.x - edge.start.x, edge.end.y - edge.start.y)
    const widthM = widthMm / 1000
    const heightM = heightMm / 1000
    const centerM = positionMm / 1000
    if (widthM < 0.3 || widthM > sourceLength - 0.01 || heightM < 0.5 || heightM > model.floorHeightM || centerM < widthM / 2 || centerM > sourceLength - widthM / 2) {
      setNotice('Bitte gueltige Masse innerhalb der Wand waehlen.')
      return
    }
    const point: PointM = {
      x: edge.start.x + ((edge.end.x - edge.start.x) * centerM) / sourceLength,
      y: edge.start.y + ((edge.end.y - edge.start.y) * centerM) / sourceLength,
    }
    const group = rawObjects.filter((item) => item.objectType === 'door' && (door.groupId === item.id || item.groupId === door.groupId))
    if (!group.length) { setNotice('Tuerobjekt nicht gefunden.'); return }
    const patches: { id: string; x: number; y: number; w: number; h: number }[] = []
    for (const item of group) {
      const room = rooms.find((candidate) => candidate.id === item.roomId)
      if (!room) { setNotice('Zugehoeriger Raum nicht gefunden.'); return }
      const a = room.vertices[item.edgeIndex]
      const b = room.vertices[(item.edgeIndex + 1) % room.vertices.length]
      if (!a || !b) { setNotice('Zugehoerige Wand nicht gefunden.'); return }
      const vx = b.x - a.x
      const vy = b.y - a.y
      const lengthM = Math.hypot(vx, vy)
      if (widthM > lengthM - 0.01) { setNotice('Tuer ist breiter als ihre Gegenwand.'); return }
      const projected = ((point.x - a.x) * vx + (point.y - a.y) * vy) / (lengthM * lengthM)
      const fraction = clamp(projected, widthM / lengthM / 2, 1 - widthM / lengthM / 2)
      const h = roundMm(heightM / model.floorHeightM)
      patches.push({ id: item.id, x: roundMm(fraction), y: roundMm(1 - h / 2), w: roundMm(widthM / lengthM), h })
    }
    setSaving(true)
    setNotice('')
    try {
      // Update each physical face; on a failed update attempt to restore any
      // already-written faces. This does not require a database schema change.
      const updated: string[] = []
      try {
        for (const entry of patches) {
          await updateWallObjectApi(entry.id, { x: entry.x, y: entry.y, w: entry.w, h: entry.h })
          updated.push(entry.id)
        }
      } catch (error) {
        await Promise.allSettled(updated.map((id) => {
          const previous = group.find((item) => item.id === id)!
          return updateWallObjectApi(id, { x: previous.x, y: previous.y, w: previous.w, h: previous.h })
        }))
        throw error
      }
      await onSaved()
      setNotice('Gespeichert – Blueprint und 3D verwenden dieselbe Tuer.')
    } catch (error) {
      await onSaved()
      setNotice(`Speichern fehlgeschlagen: ${error instanceof Error ? error.message : String(error)}`)
    } finally {
      setSaving(false)
    }
  }

  return (
    <div className="building3d-inspector-section">
      <h3>Tuer bearbeiten (3D → Blueprint)</h3>
      <p>Unterkante: 0 mm (Boden). Position ab Wandanfang.</p>
      <label>Position (mm)<input type="number" min={0} step={10} value={positionMm} onChange={(event) => setPositionMm(Number(event.target.value))} /></label>
      <label>Breite (mm)<input type="number" min={300} step={10} value={widthMm} onChange={(event) => setWidthMm(Number(event.target.value))} /></label>
      <label>Hoehe (mm)<input type="number" min={500} step={10} value={heightMm} onChange={(event) => setHeightMm(Number(event.target.value))} /></label>
      <button type="button" disabled={saving} onClick={() => void save()} title="Tuer in den gemeinsamen Gebaeudedaten speichern">{saving ? 'Speichere ...' : 'Tuer speichern'}</button>
      {notice && <p className="building3d-notice" role="status">{notice}</p>}
    </div>
  )
}

export default function Building3DWorkspace({ floor, rooms, selectedRoomId, onSelectRoom, onPersistRoom, onCaptureUndo, onBackToBlueprint, variant = 'house', onOpenLegacyWallDetail, onSelectWall, wallEditor, objectsRevision }: {
  floor: Floor
  rooms: Room[]
  selectedRoomId: string
  onSelectRoom: (id: string) => void
  onPersistRoom: (room: Room) => Promise<void>
  onCaptureUndo: () => void
  onBackToBlueprint: () => void
  variant?: 'house' | 'wall'
  onOpenLegacyWallDetail?: () => void
  onSelectWall?: (wall: WallHitSelection3D | null) => void
  wallEditor?: ReactNode
  objectsRevision?: number
}) {
  const [objects, setObjects] = useState<WallObject[]>([])
  const [selectedDoorId, setSelectedDoorId] = useState('')
  const [transparent, setTransparent] = useState(false)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')
  const [xMm, setXmm] = useState(0)
  const [yMm, setYmm] = useState(0)
  const [levelRevision, setLevelRevision] = useState(0)
  useEffect(() => {
    const refresh = () => setLevelRevision((value) => value + 1)
    window.addEventListener('storage', refresh)
    window.addEventListener('strom:blueprint-levels-changed', refresh)
    return () => {
      window.removeEventListener('storage', refresh)
      window.removeEventListener('strom:blueprint-levels-changed', refresh)
    }
  }, [floor.id])
  // Same Blueprint layer IDs, room assignments, and heights are read by 3D.
  // No duplicate per-view geometry state; the local-storage adapter will be
  // replaced by an API-backed canonical level record in a later migration.
  const activeLevel = useMemo(() => readActiveBlueprintLevel(floor, rooms, window.localStorage), [floor, rooms, levelRevision])
  const levelFloor = useMemo(() => active3DFloor(floor, activeLevel), [floor, activeLevel])
  const model = useMemo(() => buildBuildingModel(levelFloor, activeLevel.rooms, objects), [levelFloor, activeLevel, objects])
  const stairData143 = useMemo(() => build3DStairsAcrossLevels143(floor, rooms, activeLevel, window.localStorage), [floor, rooms, activeLevel, levelRevision])
  const stairs = stairData143.surfaces
  const selectedRoom = activeLevel.rooms.find((room) => room.id === selectedRoomId) ?? null
  const selectedDoor = model.doors.find((door) => door.groupId === selectedDoorId) ?? null
  const movable = Boolean(selectedRoom && !selectedRoom.name.startsWith('__strom_outer_wall__') && selectedRoom.roomType !== 'stair')
  const centroid = useMemo(() => {
    if (!selectedRoom?.vertices.length) return { x: 0, y: 0 }
    return selectedRoom.vertices.reduce((acc, point) => ({ x: acc.x + point.x / selectedRoom.vertices.length, y: acc.y + point.y / selectedRoom.vertices.length }), { x: 0, y: 0 })
  }, [selectedRoom])

  async function reloadDoors() {
    try {
      setObjects(await getWallObjects(floor.id))
    } catch (error) {
      setMessage(`Tueren konnten nicht geladen werden: ${error instanceof Error ? error.message : String(error)}`)
    }
  }
  useEffect(() => { void reloadDoors() }, [floor.id, objectsRevision])
  useEffect(() => { setXmm(Math.round(centroid.x * 1000)); setYmm(Math.round(centroid.y * 1000)) }, [selectedRoomId, centroid.x, centroid.y])

  async function shiftSelectedRoom(dxM: number, dyM: number) {
    if (!selectedRoom || !movable || busy) return
    const next: Room = {
      ...selectedRoom,
      vertices: selectedRoom.vertices.map((point) => ({ x: roundMm(point.x + dxM), y: roundMm(point.y + dyM) })),
    }
    setBusy(true)
    setMessage('')
    try {
      onCaptureUndo()
      await onPersistRoom(next)
      setMessage('Raum gespeichert. Blueprint verwendet dieselben Koordinaten.')
    } catch (error) {
      setMessage(`Speichern fehlgeschlagen: ${error instanceof Error ? error.message : String(error)}`)
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="building3d-layout" aria-label="Echtes 3D Gebaeudemodell">
      <div className="building3d-toolbar">
        <strong>{variant === 'wall' ? 'Wanddetail · Echtes 3D' : 'Echtes 3D · Aufbauphase 1'}</strong>
        <span>Etage: {activeLevel.name} · {Math.round(activeLevel.heightM * 1000)} mm</span>
        <button type="button" title="Transparente Waende umschalten" onClick={() => setTransparent((value) => !value)}>{transparent ? 'Waende deckend' : 'Waende transparent'}</button>
        <button type="button" title="Zum 2D-Blueprint wechseln" onClick={onBackToBlueprint}>Zurueck zum Blueprint (2D)</button>
        {variant === 'wall' && onOpenLegacyWallDetail && (
          <button type="button" title="Bisherige Wandobjekte, Durchbrueche und Wand-Popup bearbeiten" onClick={onOpenLegacyWallDetail}>
            Klassische Wandbearbeitung
          </button>
        )}
      </div>
      <div className="building3d-content">
        <div className="building3d-view">
          <RealBuildingScene model={model} stairs={stairs} selectedRoomId={selectedRoomId} selectedDoorId={selectedDoorId} onSelectRoom={onSelectRoom} onSelectDoor={setSelectedDoorId} onSelectWall={variant === 'wall' ? onSelectWall : undefined} transparent={transparent} />
          <div className="building3d-help">{variant === 'wall' ? 'Linke Maustaste: drehen · Mausrad: zoomen · rechte Maustaste: verschieben · Klick: Wand zum Bearbeiten auswaehlen' : 'Linke Maustaste: drehen · Mausrad: zoomen · rechte Maustaste: verschieben · Klick: Raum oder Tuer waehlen'}</div>
        </div>
        <aside className="building3d-inspector">
          <h2>{variant === 'wall' ? 'Wanddetail · Eigenschaften' : '3D-Eigenschaften'}</h2>
          <p>Die Daten stammen direkt aus demselben Gebaeudemodell wie im Blueprint.</p>
          <div className="building3d-inspector-section">
            <strong>{selectedRoom ? `Raum: ${selectedRoom.name}` : 'Raum anklicken'}</strong>
            <p>{selectedRoom ? `${selectedRoom.vertices.length} Eckpunkte · ${fmtMm(floor.heightM)} mm Hoehe` : 'Ein Raum kann in 3D ausgewaehlt und verschoben werden.'}</p>
            {movable && (
              <>
                <label>Mittelpunkt X (mm)<input type="number" value={xMm} step={100} onChange={(event) => setXmm(Number(event.target.value))} /></label>
                <label>Mittelpunkt Y (mm)<input type="number" value={yMm} step={100} onChange={(event) => setYmm(Number(event.target.value))} /></label>
                <button type="button" disabled={busy} onClick={() => void shiftSelectedRoom((xMm / 1000) - centroid.x, (yMm / 1000) - centroid.y)} title="Raumposition speichern">Raumposition speichern</button>
                <p>Feinverschiebung um 100 mm:</p>
                <div className="building3d-directional">
                  <button type="button" disabled={busy} title="Raum um 100 mm nach links verschieben" onClick={() => void shiftSelectedRoom(-0.1, 0)}>X −100</button>
                  <button type="button" disabled={busy} title="Raum um 100 mm nach oben verschieben" onClick={() => void shiftSelectedRoom(0, -0.1)}>Y −100</button>
                  <button type="button" disabled={busy} title="Raum um 100 mm nach unten verschieben" onClick={() => void shiftSelectedRoom(0, 0.1)}>Y +100</button>
                  <button type="button" disabled={busy} title="Raum um 100 mm nach rechts verschieben" onClick={() => void shiftSelectedRoom(0.1, 0)}>X +100</button>
                </div>
              </>
            )}
            {selectedRoom && !movable && <p>Dieses Spezialobjekt bleibt in Phase 1 im Blueprint bearbeitbar.</p>}
          </div>
          {selectedDoor && <DoorForm model={model} door={selectedDoor} rooms={rooms} rawObjects={objects} onSaved={reloadDoors} />}
          {!selectedDoor && <p>Eine blau angedeutete Tuer anklicken, um Position, Breite oder Hoehe auch in 3D zu bearbeiten.</p>}
          {message && <p className="building3d-notice" role="status">{message}</p>}
        </aside>
      </div>
      {variant === 'wall' && wallEditor}
      <div className="building3d-status">Modell: {model.rooms.length} Raumkonturen, {model.walls.length} Wandkanten, {model.doors.length} Tuergruppen, {stairs.length} Stufen-/Absatzvolumen aus {stairData143.savedLayouts} gespeicherten Treppenlayouts ({stairData143.activeLayouts} auf aktiver Ebene) · Blueprint-Ebene: {activeLevel.name} von {activeLevel.layerCount}. Weitere Etagen werden spaeter gleichzeitig gestapelt.</div>
    </div>
  )
}
