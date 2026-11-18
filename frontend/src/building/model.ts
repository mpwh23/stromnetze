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

function identicalPhysicalEdge(first: BuildingWall, second: BuildingWall) {
  return (distance(first.start, second.start) < 0.008 && distance(first.end, second.end) < 0.008)
    || (distance(first.start, second.end) < 0.008 && distance(first.end, second.start) < 0.008)
}

function remapOpening(opening: BuildingOpening, from: BuildingWall, to: BuildingWall): BuildingOpening {
  const ratio = opening.centerM / Math.max(minSizeM, from.lengthM)
  const point = {
    x: from.start.x + (from.end.x - from.start.x) * ratio,
    y: from.start.y + (from.end.y - from.start.y) * ratio,
  }
  const vx = (to.end.x - to.start.x) / to.lengthM
  const vy = (to.end.y - to.start.y) / to.lengthM
  return {
    ...opening,
    centerM: clamp((point.x - to.start.x) * vx + (point.y - to.start.y) * vy, 0, to.lengthM),
  }
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

  // Coincident reverse room edges describe the same physical wall. Render it once;
  // project openings from both source edges onto that one wall.
  const walls: BuildingWall[] = []
  for (const candidate of candidates) {
    const existing = walls.find((wall) => identicalPhysicalEdge(wall, candidate))
    if (!existing) {
      walls.push(candidate)
      continue
    }
    existing.thicknessM = Math.max(existing.thicknessM, candidate.thicknessM)
    for (const opening of candidate.openings) {
      if (existing.openings.some((item) => item.groupId === opening.groupId)) continue
      existing.openings.push(remapOpening(opening, candidate, existing))
    }
  }

  const doorMap = new Map<string, BuildingOpening>()
  // Prefer a room wall as the reference when a door is present on both faces.
  for (const wall of [...walls].sort((a, b) => Number(a.outerWall) - Number(b.outerWall))) {
    for (const opening of wall.openings) {
      if (opening.type === 'door' && !opening.groupId.startsWith('wall-open:') && !doorMap.has(opening.groupId)) doorMap.set(opening.groupId, opening)
    }
  }

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
