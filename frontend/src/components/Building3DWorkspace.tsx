import CanonicalGrid152 from './CanonicalGrid152' // STROM152_BLUEPRINT_GRID
import {levelElevationsDatum151} from '../building/coordinateReference151' // STROM151_COORDINATE_DATUM
import { useEffect, useMemo, useRef, useState } from 'react'
import { Canvas, ThreeEvent, useFrame, useThree } from '@react-three/fiber'
import * as THREE from 'three'
import RoofMeshes148 from './RoofMeshes148'
import CameraFlight150 from './CameraFlight150'
import FloorSlab149 from './FloorSlab149'
import { clipSolidWalls149 } from '../building/roofCut149'
import { readRoofSlopes148 } from '../building/roofSlopes148'
import { stairRise149, readSlabThickness149 } from '../building/levelGeometry149'
import { createContext, useContext } from 'react'
import RoofEditor148 from './RoofEditor148'
import { ROOF_EVENT148 } from '../building/roofSlopes148' 
import { OrbitControls } from 'three/addons/controls/OrbitControls.js'
import { getWallObjects, updateWallObject as updateWallObjectApi } from '../api'
import type { Floor, Room, WallObject, PointM } from '../types'
import { buildSolidSurface, nearestRoomForWallHit } from '../building/solidGeometry'
import { repairWallSurface145 } from '../building/wallSurface145'
import StromIcon from './StromIcon'
import { selectWallEdgeFrom3DHit, type WallHitSelection3D } from '../building/wallHitSelection'
import { pickWallHoverPlane, buildWallHoverTriangles, type WallHoverPlane } from '../building/wallHoverGeometry'
import type { ReactNode } from 'react'
import { useLayoutEffect } from 'react'
import { registerGrowth166, type GrowthKind166 } from './wallGrowth166'
import { buildBuildingModel, type BuildingModel, type BuildingRoom, type BuildingWall, type BuildingOpening } from '../building/model'
import { active3DFloor, readActiveBlueprintLevel, listBlueprintLevelOptions144, selectBlueprintLevel144 } from '../building/blueprintLevels'
// STROM143B_STAIR_AUDIT: StairSolid is rendered and storage availability is displayed.
// STROM143_STAIRS_FIX: share the exact saved room layouts across 3D views.
import { build3DStairsAcrossLevels143, type PlacedStairSurface143 } from '../building/stairVisibility143'
import { buildStair3DSurfaces } from '../building/stair3d'
import { readStairDirections147 } from '../building/stairOverlay147'

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

/** STROM166_WALL_GROWTH: Hoehengruppe. Der Kameraflug setzt scale.y (0 = flach im Blueprint).
 * 'level' = ganze weitere Etage (Hoehe UND Lage relativ zu Z=0, beim Absenken ausgeblendet). */
function Growth166({ kind = 'height', children }: { kind?: GrowthKind166; children: ReactNode }) {
  const ref = useRef<THREE.Group>(null)
  useLayoutEffect(() => (ref.current ? registerGrowth166(ref.current, kind) : undefined), [kind])
  return <group ref={ref} name={kind === 'level' ? 'strom166-level-growth' : 'strom166-growth'}>{children}</group>
}

// STROM141_WALL_HOVER: same Blueprint wall edge for hover and click.
// Hover rendering uses a selective COPY of the exact watertight 139 wall face.
// No second set of wall solids, no overlays across real door/window openings.
type HoveredSolidWall = WallHitSelection3D & { plane: WallHoverPlane }

// STROM149_CUT_WALL: the current floor and ghost floor resolve roofs independently.
const RoofScope149 = createContext({levelId:'',revision:0})
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
  const roofScope149 = useContext(RoofScope149)
  const geometry = useMemo(() => {
    const surface = buildSolidSurface(model)
    const slopes149 = readRoofSlopes148(model.floorId,window.localStorage).filter(item=>item.levelId===roofScope149.levelId)
    const clipped149 = slopes149.length ? clipSolidWalls149(model,surface.positions,slopes149) : surface.positions
    const repaired145 = repairWallSurface145(clipped149)
    if (repaired145.repairedPlanes || repaired145.skippedPlanes) {
      console.info('[STROM145 Wandgeometrie]', {
        vorher: repaired145.inputTriangles, nachher: repaired145.outputTriangles,
        reparierteFlaechen: repaired145.repairedPlanes, uebersprungeneFlaechen: repaired145.skippedPlanes,
      })
    }
    const mesh = new THREE.BufferGeometry()
    mesh.setAttribute('position', new THREE.Float32BufferAttribute(repaired145.positions, 3))
    mesh.computeVertexNormals()
    mesh.computeBoundingSphere()
    return mesh
  }, [model,roofScope149.levelId,roofScope149.revision])
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
          depthWrite={true}
          side={THREE.DoubleSide}
          forceSinglePass={false}
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
    <group scale={[1, surface.direction147 === 'down' ? -1 : 1, 1]}>
      {/* STROM147_DOWN_SCENE: wraps all existing stair meshes; no geometry changes. */}
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
    </group>
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
  // STROM165_ONE_CAMERA_OWNER: Controls im R3F-Store anmelden. Erst dadurch kann der
  // Kameraflug (CameraFlight150) sie waehrend Blende und Flug wirklich sperren.
  const setRootState165 = useThree((state) => state.set)
  useEffect(() => {
    setRootState165({ controls })
    return () => setRootState165({ controls: null })
  }, [controls, setRootState165])
  const fittedSpan146 = useRef<number | null>(null)
  useEffect(() => {
    const nextTarget146 = new THREE.Vector3(model.center.x, model.floorElevationM + model.floorHeightM / 2, model.center.y)
    const nextSpan146 = Math.max(model.spanM, model.floorHeightM * 1.6)
    if (fittedSpan146.current !== null) {
      // Preserve orbit orientation. If the total building gets taller, zoom out to frame it.
      const eye146 = camera.position.clone().sub(controls.target)
      if (eye146.lengthSq() < 0.001) eye146.set(1, .7, 1)
      if (nextSpan146 > fittedSpan146.current + 0.15) eye146.setLength(Math.max(eye146.length(), nextSpan146 * 2.0))
      camera.position.copy(nextTarget146).add(eye146)
    }
    controls.target.copy(nextTarget146)
    fittedSpan146.current = nextSpan146
    controls.enableDamping = true
    controls.dampingFactor = 0.11
    controls.minDistance = 1
    controls.maxDistance = Math.max(35, model.spanM * 7)
    controls.maxPolarAngle = Math.PI * 0.49
    controls.update()
  }, [controls, model.floorId, model.center.x, model.center.y, model.floorElevationM, model.floorHeightM, model.spanM])
  useEffect(() => () => controls.dispose(), [controls])
  useFrame(() => controls.update())
  return null
}

// STROM146_ALL_LEVELS: one Blueprint storage schema, multiple read-only 3D floor meshes.
type SceneLevel146 = { id: string; model: BuildingModel; stairs: PlacedStairSurface143[]; offsetM: number }

function RealBuildingScene({ model, stairs, extraLevels146, activeOffsetM146, showAllLevels146, activeLevelId148, roofRevision148, selectedRoof148, onSelectRoof148, selectedRoomId, selectedDoorId, onSelectRoom, onSelectDoor, onSelectWall, transparent }: {
  model: BuildingModel
  stairs: PlacedStairSurface143[]
  extraLevels146: SceneLevel146[]
  activeOffsetM146: number
  showAllLevels146: boolean
  activeLevelId148: string
  roofRevision148: number
  selectedRoof148: string
  onSelectRoof148: (id:string)=>void
  selectedRoomId: string
  selectedDoorId: string
  onSelectRoom: (id: string) => void
  onSelectDoor: (id: string) => void
  onSelectWall?: (wall: WallHitSelection3D | null) => void
  transparent: boolean
}) {
  const cameraModel146 = useMemo(() => {
    if (!showAllLevels146 || extraLevels146.length === 0) return model
    const levels = [{ model, offsetM: activeOffsetM146 }, ...extraLevels146]
    const base = Math.min(...levels.map((entry) => entry.model.floorElevationM + entry.offsetM))
    const top = Math.max(...levels.map((entry) => entry.model.floorElevationM + entry.offsetM + entry.model.floorHeightM))
    const maxSpan = Math.max(...levels.map((entry) => entry.model.spanM))
    return { ...model, floorElevationM: base, floorHeightM: top - base, spanM: maxSpan }
  }, [model, extraLevels146, showAllLevels146, activeOffsetM146])
  const activeSlab149 = readSlabThickness149(model.floorId,activeLevelId148,window.localStorage)
  const distance = Math.max(8, cameraModel146.spanM * 1.2, cameraModel146.floorHeightM * 1.35)
  return (
    <Canvas
      shadows={!transparent}
      dpr={[1, 1.75]}
      camera={{ position: [cameraModel146.center.x + distance, cameraModel146.floorElevationM + distance * 0.8 + cameraModel146.floorHeightM, cameraModel146.center.y + distance], fov: 48, near: 0.05, far: Math.max(100, cameraModel146.spanM * 20, cameraModel146.floorHeightM * 12) }}
      onPointerMissed={() => { onSelectDoor(''); onSelectRoom(''); onSelectWall?.(null) }}
      gl={{ antialias: true, alpha: false }}
      aria-label="Echte dreidimensionale Gebaeudeansicht"
    >
      <color attach="background" args={['#f5f8fc']} />
      <ambientLight intensity={1.15} />
      <directionalLight position={[14, 20, 16]} intensity={2.1} castShadow={!transparent} shadow-mapSize={[1024, 1024]} />
      <hemisphereLight args={['#e8f1ff', '#9698a6', 0.85]} />
      <group position={[0, model.floorElevationM + activeOffsetM146, 0]}>
        {model.rooms.map((room) => (
          <FloorMesh key={room.id} room={room} selected={selectedRoomId === room.id} onSelect={() => { onSelectRoom(room.id); onSelectDoor(''); onSelectWall?.(null) }} />
        ))}
        <Growth166>{stairs.map((surface) => (
          <StairSolid
            key={surface.key}
            surface={surface}
            selected={surface.roomId === selectedRoomId}
            onSelect={() => { onSelectRoom(surface.roomId); onSelectDoor(''); onSelectWall?.(null) }}
          />
        ))}</Growth166>
        <RoofScope149.Provider value={{levelId:activeLevelId148,revision:roofRevision148}}>
            {/* STROM152_BLUEPRINT_GRID: portal into absolute Three scene; it is not centered on the building. */}
            <CanonicalGrid152 points={model.rooms.flatMap(room152=>room152.vertices)} />
            {/* STROM150_CAMERA: model XY = Blueprint XY, floor plane = 3D XZ */}
            <CameraFlight150 points={model.rooms.flatMap(room150 => room150.vertices)} /><Growth166><SolidWallMeshes
          model={model}
          onSelectRoom={(id) => { onSelectRoom(id); onSelectDoor('') }}
          onSelectWall={onSelectWall}
          transparent={transparent}
        /></Growth166></RoofScope149.Provider>
        {/* STROM149_FLOOR_SLAB: physical thickness below each finished room floor. */}
        {model.rooms.map(room149=><FloorSlab149 key={`slab149-${room149.id}`} room={room149} thicknessM={activeSlab149} />)}
        <Growth166>{model.walls.flatMap((wall) => wall.openings
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
          )))}</Growth166>
        {/* STROM148_ROOF_3D: roof faces are built from saved Blueprint slope records. */}
        <Growth166><RoofMeshes148 floorId={model.floorId} levelId={activeLevelId148} rooms={model.rooms}
          revision={roofRevision148} selectedId={selectedRoof148} onSelect={onSelectRoof148} /></Growth166>
      </group>
      {showAllLevels146 && extraLevels146.map((entry146) => (
        <Growth166 kind="level" key={`floor-146-${entry146.id}`}><group position={[0, entry146.model.floorElevationM + entry146.offsetM, 0]}>
          {entry146.model.rooms.map((room146) => (
            <FloorMesh key={room146.id} room={room146} selected={false} onSelect={() => undefined} />
          ))}
          <RoofScope149.Provider value={{levelId:entry146.id,revision:roofRevision148}}><SolidWallMeshes model={entry146.model} onSelectRoom={() => undefined} transparent={transparent} /></RoofScope149.Provider>
          <RoofMeshes148 floorId={entry146.model.floorId} levelId={entry146.id} rooms={entry146.model.rooms}
            revision={roofRevision148} selectedId={selectedRoof148} onSelect={onSelectRoof148} />
          {entry146.model.rooms.map(room149=><FloorSlab149 key={`slab149-${room149.id}`} room={room149}
            thicknessM={readSlabThickness149(entry146.model.floorId,entry146.id,window.localStorage)} ghost150r />)}
          {entry146.stairs.map((surface146) => (
            <StairSolid key={surface146.key} surface={surface146} selected={false} onSelect={() => undefined} />
          ))}
          {entry146.model.walls.flatMap((wall146) => wall146.openings
            .filter((opening146) => opening146.type === 'door' && entry146.model.doors.some((door146) => door146.id === opening146.id))
            .map((door146) => (
              <DoorHandle key={`${wall146.id}/${door146.id}`} door={door146} wall={wall146} selected={false} onSelect={() => undefined} />
            )))}
        </group></Growth166>
      ))}
      <gridHelper args={[Math.max(40, model.spanM * 4), 40, '#bbc7d5', '#dce5ef']} position={[model.center.x, model.floorElevationM - 0.035, model.center.y]}  visible={false}/>
      <SceneControls model={cameraModel146} />
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
  const [levelsOpen145, setLevelsOpen145] = useState(false)
  const [showAllLevels146, setShowAllLevels146] = useState(false)
  const [separateLevels146, setSeparateLevels146] = useState(false)
  const [selectedRoof148, setSelectedRoof148] = useState('')
  const [roofRevision148,setRoofRevision148] = useState(0)
  useEffect(()=>{
    const sync=()=>setRoofRevision148(value=>value+1)
    window.addEventListener(ROOF_EVENT148,sync)
    return ()=>window.removeEventListener(ROOF_EVENT148,sync)
  },[])
  useEffect(()=>setSelectedRoof148(''),[floor.id])
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
  // STROM144_LEVEL_PICKER: identical layer list, names, heights and active ID as Blueprint.
  const levelOptions144 = useMemo(() => listBlueprintLevelOptions144(floor, window.localStorage), [floor, levelRevision])
  function chooseWallDetailLevel144(id: string) {
    if (!selectBlueprintLevel144(floor, id, window.localStorage)) {
      setMessage('Ebene konnte nicht ausgewaehlt werden.')
      return
    }
    onSelectRoom('')
    onSelectWall?.(null)
    setSelectedDoorId('')
    window.dispatchEvent(new Event('strom:blueprint-levels-changed'))
  }

  const levelFloor = useMemo(() => active3DFloor(floor, activeLevel), [floor, activeLevel])
  const model = useMemo(() => buildBuildingModel(levelFloor, activeLevel.rooms, objects), [levelFloor, activeLevel, objects])
  const stairData143 = useMemo(() => build3DStairsAcrossLevels143(floor, rooms, activeLevel, window.localStorage), [floor, rooms, activeLevel, levelRevision])
  const stairs = stairData143.surfaces
  // STROM146: always derive floor/room assignments from the live Blueprint keys.
  const sceneLevels146 = useMemo((): SceneLevel146[] => {
    let assignments146: Record<string, string> = {}
    try {
      const saved146: unknown = JSON.parse(window.localStorage.getItem(`strom.floorplan.layers.${floor.id}.roomAssignments`) || '{}')
      if (saved146 && typeof saved146 === 'object' && !Array.isArray(saved146)) assignments146 = saved146 as Record<string, string>
    } catch { /* unreadable legacy storage is treated as main layer */ }
    const directions147 = readStairDirections147(floor.id, window.localStorage)
    const elevation149 = levelElevationsDatum151(levelOptions144,floor.id,window.localStorage)
    return levelOptions144.map((item146, idx146) => {
      const floorRooms146 = rooms.filter((room146) => (assignments146[room146.id] || 'layer-main') === item146.id)
      const allowedIds146 = new Set(floorRooms146.map((room146) => room146.id))
      const floorObjects146 = objects.filter((object146) => allowedIds146.has(object146.roomId))
      const layerFloor146: Floor = { ...floor, name: `${floor.name} / ${item146.name}`,
        elevationM: elevation149[item146.id], heightM: item146.heightM }
      return { id: item146.id,
        model: buildBuildingModel(layerFloor146, floorRooms146, floorObjects146),
        stairs: buildStair3DSurfaces(floorRooms146, stairRise149(levelOptions144,item146.id), window.localStorage).map((surface146) => ({
          ...surface146, levelId: item146.id, levelOffsetM: 0, direction147: directions147[surface146.roomId] === 'down' ? 'down' : 'up',
        })),
        offsetM: showAllLevels146 && separateLevels146 ? (levelOptions144.length-1-idx146) * 1.15 : 0 }
    })
  }, [floor, rooms, objects, levelOptions144, levelRevision, showAllLevels146, separateLevels146])
  const activeOffsetM146 = showAllLevels146 && separateLevels146
    ? sceneLevels146.find((entry146) => entry146.id === activeLevel.id)?.offsetM ?? 0 : 0
  const extraLevels146 = showAllLevels146 && variant === 'house'
    ? sceneLevels146.filter((entry146) => entry146.id !== activeLevel.id) : []
  // 143b already supplies ghost stairs from every level. Suppress those
  // copies when dedicated floor groups render the same staircases in 146.
  const activeStairs146 = showAllLevels146 && variant === 'house'
    ? stairs.filter((surface146) => surface146.levelId === activeLevel.id) : stairs
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
        {/* STROM145_FLOATING_LEVELS: layer selection lives in the canvas overlay. */}
        {variant === 'house' && (
          <div className="building3d-stacked-options146" role="group" aria-label="3D Haus Geschossdarstellung">
            <button type="button" className={showAllLevels146 ? 'active' : ''} aria-pressed={showAllLevels146}
              title="Alle Blueprint-Etagen gemeinsam als echtes 3D anzeigen" data-tooltip="Alle Etagen anzeigen"
              onClick={() => setShowAllLevels146((value) => !value)}>
              <StromIcon name="layers-all" size={19} title="Alle Etagen anzeigen" /> Alle Etagen {showAllLevels146 ? 'AN' : 'AUS'}
            </button>
            <button type="button" className={separateLevels146 && showAllLevels146 ? 'active' : ''}
              aria-pressed={separateLevels146 && showAllLevels146} disabled={!showAllLevels146}
              title="Etagen nur in der 3D-Ansicht mit zusätzlichem vertikalen Abstand darstellen; Blueprint-Höhen unverändert"
              data-tooltip="Etagen mit Abstand auseinanderziehen"
              onClick={() => setSeparateLevels146((value) => !value)}>
              <StromIcon name="layers-explode" size={19} title="Etagen auseinanderziehen" /> Offset {separateLevels146 ? 'AN' : 'AUS'}
            </button>
          </div>
        )}
        <button type="button" title="Transparente Waende umschalten" onClick={() => setTransparent((value) => !value)} aria-pressed={transparent}><StromIcon name="walls-transparent" size={19} />{transparent ? 'Waende deckend' : 'Waende transparent'}</button>
        <button type="button" title="Zum 2D-Blueprint wechseln" onClick={onBackToBlueprint}><StromIcon name="blueprint" size={19} />Zurueck zum Blueprint (2D)</button>
        {variant === 'wall' && onOpenLegacyWallDetail && (
          <button type="button" title="Bisherige Wandobjekte, Durchbrueche und Wand-Popup bearbeiten" onClick={onOpenLegacyWallDetail}>
            <StromIcon name="wall-edit" size={19} />Klassische Wandbearbeitung
          </button>
        )}
      </div>
      <div className="building3d-content">
        <div className="building3d-view">
          <RealBuildingScene model={model} stairs={activeStairs146} activeLevelId148={activeLevel.id} roofRevision148={roofRevision148}
            selectedRoof148={selectedRoof148} onSelectRoof148={setSelectedRoof148} extraLevels146={extraLevels146} activeOffsetM146={variant === 'house' ? activeOffsetM146 : 0} showAllLevels146={variant === 'house' && showAllLevels146} selectedRoomId={selectedRoomId} selectedDoorId={selectedDoorId} onSelectRoom={onSelectRoom} onSelectDoor={setSelectedDoorId} onSelectWall={variant === 'wall' ? onSelectWall : undefined} transparent={transparent} />
          {/* STROM145_FLOATING_LEVELS: reuse the Blueprint floating layer-menu classes. */}
          <div className={`canvas-layer-menu building3d-floating-levels145 ${levelsOpen145 ? 'open' : ''}`} aria-label="Ebenen">
            <button type="button" title="Ebenenauswahl wie im Blueprint" aria-label="Ebenenauswahl öffnen oder schließen"
              aria-expanded={levelsOpen145} onClick={() => setLevelsOpen145((value) => !value)}>
              <StromIcon name="chevron-down" size={19} title="Ebenen" />
              <span>{activeLevel.name}</span>
            </button>
            {levelsOpen145 && (
              <div className="layer-menu-panel" role="group" aria-label="Blueprint-Ebenen">
                <div className="layer-list">
                  {levelOptions144.map((level) => {
                    const selected = level.id === activeLevel.id
                    return (
                      <button type="button" key={level.id}
                        className={`layer-row building3d-floating-level-row145 ${selected ? 'active effectively-visible' : 'effectively-hidden'}`}
                        title={`${level.name} wählen – ${Math.round(level.heightM * 1000)} mm Geschosshöhe`}
                        aria-current={selected ? 'true' : undefined}
                        onClick={() => { chooseWallDetailLevel144(level.id); setLevelsOpen145(false) }}>
                        <StromIcon name={selected ? 'layers-current' : 'layers-neighbor'} size={19} title={selected ? 'Aktive Ebene' : 'Andere Ebene'} />
                        <span className="building3d-level-name145">{level.name}</span>
                        <small>{Math.round(level.heightM * 1000)} mm</small>
                      </button>
                    )
                  })}
                </div>
                <p className="building3d-level-note145">Die aktive Ebene ist dieselbe wie im Blueprint. Ebenenverwaltung und Höhenänderung erfolgen im Blueprint.</p>
              </div>
            )}
          </div>

          <div className="building3d-help">{variant === 'wall' ? 'Linke Maustaste: drehen · Mausrad: zoomen · rechte Maustaste: verschieben · Klick: Wand zum Bearbeiten auswaehlen' : 'Linke Maustaste: drehen · Mausrad: zoomen · rechte Maustaste: verschieben · Klick: Raum oder Tuer waehlen'}</div>
        </div>
        <aside className="building3d-inspector">
          {selectedRoof148 && <RoofEditor148 floorId={floor.id} roofId={selectedRoof148}
            onClose={()=>setSelectedRoof148('')} onChanged={()=>setRoofRevision148(value=>value+1)}/>}
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
      <div className="building3d-status">Modell: {model.rooms.length} Raumkonturen, {model.walls.length} Wandkanten, {model.doors.length} Tuergruppen, {stairs.length} Stufen-/Absatzvolumen aus {stairData143.savedLayouts} gespeicherten Treppenlayouts ({stairData143.activeLayouts} auf aktiver Ebene){stairData143.savedLayouts === 0 ? ' · Hinweis: keine Treppenlayouts im Browser-Speicher gefunden' : ''} · Blueprint-Ebene: {activeLevel.name} von {activeLevel.layerCount}. Weitere Etagen koennen ueber den Schalter Alle Etagen eingeblendet werden.</div>
    </div>
  )
}
