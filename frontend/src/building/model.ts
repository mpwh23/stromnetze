import type { Floor, PointM, Room, WallObject } from '../types'

/**
 * 137: Common building geometry consumed by Blueprint and the WebGL scene.
 * Coordinates are metres; Blueprint X/Y maps to WebGL X/Z, and WebGL Y is elevation.
 * These are derived view objects; Rooms and WallObjects in the Go API remain the
 * authoritative records. No independent 3D geometry is persisted.
 */
export type BuildingOpening = {
  id: string
  groupId: string
  type: 'door' | 'window'
  roomId: string
  edgeIndex: number
  centerM: number
  widthM: number
  sillM: number
  heightM: number
}

export type BuildingWall = {
  id: string
  roomId: string
  edgeIndex: number
  start: PointM
  end: PointM
  lengthM: number
  thicknessM: number
  heightM: number
  outerWall: boolean
  roomIds?: string[]
  openings: BuildingOpening[]
}

export type BuildingRoom = {
  id: string
  name: string
  vertices: PointM[]
  kind: 'room' | 'stair' | 'outer'
}

export type BuildingModel = {
  floorId: string
  floorName: string
  floorHeightM: number
  floorElevationM: number
  rooms: BuildingRoom[]
  walls: BuildingWall[]
  doors: BuildingOpening[]
  center: PointM
  spanM: number
}

export type WallSolidPiece = {
  fromM: number
  toM: number
  bottomM: number
  topM: number
}

const minSizeM = 0.005
const roundMm = (value: number) => Math.round(value * 1000) / 1000
const clamp = (value: number, min: number, max: number) => Math.max(min, Math.min(max, value))
const distance = (a: PointM, b: PointM) => Math.hypot(b.x - a.x, b.y - a.y)

function wallOpeningFromApi(item: WallObject, lengthM: number, heightM: number): BuildingOpening {
  const widthM = clamp(item.w * lengthM, minSizeM, lengthM)
  const topOriginY = Number(item.y)
  const height = clamp(Number(item.h) * heightM, minSizeM, heightM)
  const sill = item.objectType === 'door' ? 0 : clamp((1 - topOriginY - item.h / 2) * heightM, 0, heightM - height)
  return {
    id: item.id,
    groupId: item.groupId || item.id,
    type: item.objectType as 'door' | 'window',
    roomId: item.roomId,
    edgeIndex: item.edgeIndex,
    centerM: clamp(item.x * lengthM, 0, lengthM),
    widthM,
    sillM: sill,
    heightM: height,
  }
}

/**
 * 138: A physical wall may be described by two opposite Blueprint room edges.
 * The edges are wall references, not independent blocks. Normalized parallel
 * edge bands are assembled into ONE solid wall prism per longitudinal slice.
 *
 * The canonical records remain Room and WallObject in the API. No database
 * changes and no independent 3D geometry are persisted.
 */
type WallFaceCandidate = {
  wall: BuildingWall
  tangent: PointM
  normal: PointM
  normalOffsetM: number
  minT: number
  maxT: number
  interiorSide: number
}

const dot = (a: PointM, b: PointM) => a.x * b.x + a.y * b.y
const signedArea2 = (points: PointM[]) => points.reduce((sum, point, index) => {
  const next = points[(index + 1) % points.length]
  return sum + point.x * next.y - next.x * point.y
}, 0)

function faceCandidate(wall: BuildingWall, room: Room): WallFaceCandidate {
  const vx = wall.end.x - wall.start.x
  const vy = wall.end.y - wall.start.y
  // A canonical direction makes anti-parallel room edges comparable.
  const sign = vx > 0.000001 || (Math.abs(vx) <= 0.000001 && vy >= 0) ? 1 : -1
  const tangent = { x: sign * vx / wall.lengthM, y: sign * vy / wall.lengthM }
  const normal = { x: -tangent.y, y: tangent.x }
  const t0 = dot(tangent, wall.start)
  const t1 = dot(tangent, wall.end)
  const polygonSide = signedArea2(room.vertices) >= 0 ? 1 : -1
  return {
    wall,
    tangent,
    normal,
    normalOffsetM: dot(normal, wall.start),
    minT: Math.min(t0, t1),
    maxT: Math.max(t0, t1),
    interiorSide: polygonSide * sign,
  }
}

function physicalWallFacesCompatible(a: WallFaceCandidate, b: WallFaceCandidate): boolean {
  if (dot(a.tangent, b.tangent) < 0.9995) return false
  const normalGap = Math.abs(dot(a.normal, b.wall.start) - a.normalOffsetM)
  const maxGap = Math.max(0.22, Math.min(0.52, 0.15 + 0.8 * (a.wall.thicknessM + b.wall.thicknessM)))
  if (normalGap > maxGap) return false
  const b0 = dot(a.tangent, b.wall.start)
  const b1 = dot(a.tangent, b.wall.end)
  const overlap = Math.min(a.maxT, Math.max(b0, b1)) - Math.max(a.minT, Math.min(b0, b1))
  if (overlap < Math.min(0.06, Math.min(a.wall.lengthM, b.wall.lengthM) * 0.2)) return false
  if (normalGap < 0.012) return true
  // Never consume both sides of a narrow room as one wall.
  if (a.wall.roomId === b.wall.roomId) return false
  // Interior sides of neighboring rooms must face away from the partition.
  // An explicitly drawn outer wall is the outside boundary, not a room.
  return a.wall.outerWall || b.wall.outerWall || a.interiorSide !== b.interiorSide
}

function groupPhysicalWallFaces(candidates: WallFaceCandidate[]): WallFaceCandidate[][] {
  const groups: WallFaceCandidate[][] = []
  const sorted = [...candidates].sort((a, b) => b.wall.lengthM - a.wall.lengthM)
  for (const candidate of sorted) {
    let destination: WallFaceCandidate[] | undefined
    let bestGap = Number.POSITIVE_INFINITY
    for (const group of groups) {
      const anchor = group[0]
      const offsets = [...group, candidate].map((face) => dot(anchor.normal, face.wall.start))
      if (Math.max(...offsets) - Math.min(...offsets) > 0.52) continue
      const compatible = group.filter((face) => physicalWallFacesCompatible(face, candidate))
      if (!compatible.length) continue
      const gap = Math.min(...compatible.map((face) => Math.abs(dot(face.normal, candidate.wall.start) - face.normalOffsetM)))
      if (gap < bestGap) { destination = group; bestGap = gap }
    }
    if (destination) destination.push(candidate)
    else groups.push([candidate])
  }
  return groups
}

function projectOpeningT(candidate: WallFaceCandidate, opening: BuildingOpening, tangent: PointM): number {
  const fraction = opening.centerM / Math.max(minSizeM, candidate.wall.lengthM)
  const point = {
    x: candidate.wall.start.x + (candidate.wall.end.x - candidate.wall.start.x) * fraction,
    y: candidate.wall.start.y + (candidate.wall.end.y - candidate.wall.start.y) * fraction,
  }
  return dot(point, tangent)
}

function pickWallFace(candidates: WallFaceCandidate[]): WallFaceCandidate {
  // The room side is preferable for selecting a wall from within the 3D model.
  return [...candidates].sort((a, b) => Number(a.wall.outerWall) - Number(b.wall.outerWall) || b.wall.lengthM - a.wall.lengthM)[0]
}

function wallsFromPhysicalFaceGroup(
  faces: WallFaceCandidate[],
  groupIndex: number,
  canonicalDoorMap: Map<string, BuildingOpening>,
): BuildingWall[] {
  const tangent = faces[0].tangent
  const normal = faces[0].normal
  const boundaries = faces.flatMap((candidate) => [
    dot(tangent, candidate.wall.start),
    dot(tangent, candidate.wall.end),
  ])
  const xs = [...new Set(boundaries.map(roundMm))].sort((a, b) => a - b)
  const slices: BuildingWall[] = []
  for (let i = 0; i < xs.length - 1; i += 1) {
    const t0 = xs[i]
    const t1 = xs[i + 1]
    if (t1 - t0 < 0.002) continue
    const mid = (t0 + t1) / 2
    const active = faces.filter((face) => {
      const a = dot(tangent, face.wall.start)
      const b = dot(tangent, face.wall.end)
      return mid >= Math.min(a, b) - 0.002 && mid <= Math.max(a, b) + 0.002
    })
    if (!active.length) continue

    const low = Math.min(...active.map((candidate) => dot(normal, candidate.wall.start) - candidate.wall.thicknessM / 2))
    const high = Math.max(...active.map((candidate) => dot(normal, candidate.wall.start) + candidate.wall.thicknessM / 2))
    const center = (low + high) / 2
    const chosen = pickWallFace(active)
    const openings = new Map<string, BuildingOpening>()
    for (const face of active) {
      for (const item of face.wall.openings) {
        const centerT = projectOpeningT(face, item, tangent)
        if (centerT + item.widthM / 2 < t0 + 0.0001 || centerT - item.widthM / 2 > t1 - 0.0001) continue
        const selected = canonicalDoorMap.get(item.groupId) ?? item
        // A shared door has two API records. Use one canonical opening on all
        // slices, including the slice where the opening center is located.
        const matching = active.find((entry) => entry.wall.openings.some((opening) => opening.id === selected.id))
        const reference = matching ?? face
        const source = matching ? selected : item
        const projectedCenter = projectOpeningT(reference, source, tangent)
        const local = { ...source, centerM: projectedCenter - t0 }
        const key = item.groupId || item.id
        const prior = openings.get(key)
        if (!prior || source.id === selected.id) openings.set(key, local)
      }
    }
    // Active rooms are retained so selection/highlighting works from either side.
    slices.push({
      id: `wall138:${groupIndex}:${i}`,
      roomId: chosen.wall.roomId,
      edgeIndex: chosen.wall.edgeIndex,
      roomIds: [...new Set(active.map((face) => face.wall.roomId))],
      start: { x: roundMm(tangent.x * t0 + normal.x * center), y: roundMm(tangent.y * t0 + normal.y * center) },
      end: { x: roundMm(tangent.x * t1 + normal.x * center), y: roundMm(tangent.y * t1 + normal.y * center) },
      lengthM: roundMm(t1 - t0),
      thicknessM: roundMm(high - low),
      heightM: chosen.wall.heightM,
      outerWall: active.some((candidate) => candidate.wall.outerWall),
      openings: [...openings.values()],
    })
  }
  return slices
}

export function buildBuildingModel(floor: Floor, rooms: Room[], objects: WallObject[]): BuildingModel {
  const safeHeight = Math.max(0.1, floor.heightM)
  const validRooms = rooms.filter((room) => Array.isArray(room.vertices) && room.vertices.length >= 3)
  const modelRooms: BuildingRoom[] = validRooms.map((room) => ({
    id: room.id,
    name: room.name.startsWith('__strom_outer_wall__') ? 'Außenwand' : room.name,
    vertices: room.vertices.map((point) => ({ x: point.x, y: point.y })),
    kind: room.name.startsWith('__strom_outer_wall__') ? 'outer' : room.roomType === 'stair' ? 'stair' : 'room',
  }))
  const candidates: BuildingWall[] = []
  for (const room of validRooms) {
    const count = room.vertices.length
    for (let edgeIndex = 0; edgeIndex < count; edgeIndex += 1) {
      const start = room.vertices[edgeIndex]
      const end = room.vertices[(edgeIndex + 1) % count]
      const lengthM = distance(start, end)
      if (lengthM < 0.05) continue
      candidates.push({
        id: `${room.id}:${edgeIndex}`,
        roomId: room.id,
        edgeIndex,
        start: { ...start }, end: { ...end },
        lengthM,
        thicknessM: clamp(room.wallThicknessM || 0.12, 0.04, 0.45),
        heightM: safeHeight,
        outerWall: room.name.startsWith('__strom_outer_wall__'),
        openings: objects
          .filter((item) => item.roomId === room.id && item.edgeIndex === edgeIndex && (item.objectType === 'door' || item.objectType === 'window'))
          .map((item) => wallOpeningFromApi(item, lengthM, safeHeight)),
      })
    }
  }

  const candidatesById = new Map(validRooms.map((room) => [room.id, room]))
  const faceCandidates = candidates.map((wall) => faceCandidate(wall, candidatesById.get(wall.roomId)!))

  // Canonical door IDs and editor coordinates remain on the original API edge.
  // New 3D wall slices use local rendering offsets without changing the DB.
  const doorMap = new Map<string, BuildingOpening>()
  for (const wall of [...candidates].sort((a, b) => Number(a.outerWall) - Number(b.outerWall))) {
    for (const opening of wall.openings) {
      if (opening.type === 'door' && !opening.groupId.startsWith('wall-open:') && !doorMap.has(opening.groupId)) {
        doorMap.set(opening.groupId, opening)
      }
    }
  }

  const walls = groupPhysicalWallFaces(faceCandidates)
    .flatMap((group, groupIndex) => wallsFromPhysicalFaceGroup(group, groupIndex, doorMap))

  const vertices = modelRooms.filter((room) => room.kind !== 'outer').flatMap((room) => room.vertices)
  const allPoints = vertices.length > 0 ? vertices : modelRooms.flatMap((room) => room.vertices)
  const minX = allPoints.length ? Math.min(...allPoints.map((p) => p.x)) : 0
  const maxX = allPoints.length ? Math.max(...allPoints.map((p) => p.x)) : 0
  const minY = allPoints.length ? Math.min(...allPoints.map((p) => p.y)) : 0
  const maxY = allPoints.length ? Math.max(...allPoints.map((p) => p.y)) : 0
  return {
    floorId: floor.id,
    floorName: floor.name,
    floorHeightM: safeHeight,
    floorElevationM: floor.elevationM || 0,
    rooms: modelRooms,
    walls,
    doors: [...doorMap.values()],
    center: { x: (minX + maxX) / 2, y: (minY + maxY) / 2 },
    spanM: Math.max(5, maxX - minX, maxY - minY),
  }
}

/** Generate an actual hole in the wall by subdividing it into solid boxes. */
export function wallSolidPieces(wall: BuildingWall): WallSolidPiece[] {
  const eps = 0.0001
  const breakpoints = [0, wall.lengthM]
  for (const opening of wall.openings) {
    breakpoints.push(clamp(opening.centerM - opening.widthM / 2, 0, wall.lengthM))
    breakpoints.push(clamp(opening.centerM + opening.widthM / 2, 0, wall.lengthM))
  }
  const xs = [...new Set(breakpoints.map(roundMm))].sort((a, b) => a - b)
  const pieces: WallSolidPiece[] = []
  for (let i = 0; i < xs.length - 1; i += 1) {
    const fromM = xs[i]
    const toM = xs[i + 1]
    if (toM - fromM < eps) continue
    const mid = (fromM + toM) / 2
    const cutouts = wall.openings
      .filter((opening) => mid >= opening.centerM - opening.widthM / 2 - eps && mid <= opening.centerM + opening.widthM / 2 + eps)
      .map((opening) => ({
        bottom: clamp(opening.sillM, 0, wall.heightM),
        top: clamp(opening.sillM + opening.heightM, 0, wall.heightM),
      }))
      .sort((a, b) => a.bottom - b.bottom)
    let cursor = 0
    for (const hole of cutouts) {
      if (hole.bottom > cursor + eps) pieces.push({ fromM, toM, bottomM: cursor, topM: hole.bottom })
      cursor = Math.max(cursor, hole.top)
    }
    if (cursor < wall.heightM - eps) pieces.push({ fromM, toM, bottomM: cursor, topM: wall.heightM })
  }
  return pieces
}
