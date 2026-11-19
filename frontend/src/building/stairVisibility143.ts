import {levelElevationsDatum151} from './coordinateReference151' // STROM151_COORDINATE_DATUM
import type { Floor, Room } from '../types'
import type { BlueprintLevelView, KeyValueReader } from './blueprintLevels'
import { buildStair3DSurfaces, type Stair3DSurface } from './stair3d'
import { stairRise149, cleanSlab149 } from './levelGeometry149'

export type PlacedStairSurface143 = Stair3DSurface & {
  /** Offset relative to the currently rendered level, applied by the 3D group. */
  levelOffsetM: number
  levelId: string
  direction147?: 'up' | 'down'
}
export type StairSceneData143 = { surfaces: PlacedStairSurface143[]; savedLayouts: number; activeLayouts: number }

function readJson(storage: KeyValueReader, key: string): unknown {
  try { const raw = storage.getItem(key); return raw ? JSON.parse(raw) as unknown : null } catch { return null }
}
const numeric = (value: unknown, fallback: number) => typeof value === 'number' && Number.isFinite(value) ? value : fallback
const heightM = (value: unknown, fallback: number) => {
  const n = numeric(value, NaN)
  return Number.isFinite(n) && n >= 0.1 && n <= 10 ? n : fallback
}

/**
 * 143: staircase layouts live under the staircase ROOM id, not the active 3D
 * filtered room list. Enumerate every existing Blueprint level and preserve
 * its physical elevation, so stairs assigned to other levels are not lost.
 * This is a read-only adapter; no migration or localStorage writes.
 */
export function build3DStairsAcrossLevels143(floor: Floor, rooms: Room[], activeLevel: BlueprintLevelView, storage: KeyValueReader): StairSceneData143 {
  const prefix = `strom.floorplan.layers.${floor.id}.`
  const rawLayers = readJson(storage, prefix + 'list')
  const rawDirections147 = readJson(storage, prefix + 'stairDirections147')
  const directions147 = rawDirections147 && typeof rawDirections147 === 'object' && !Array.isArray(rawDirections147)
    ? rawDirections147 as Record<string, unknown> : {}

  const fallback = heightM(floor.heightM, 2.5)
  const levels = Array.isArray(rawLayers)
    ? rawLayers.flatMap((item: unknown) => {
      if (!item || typeof item !== 'object') return []
      const entry = item as Record<string, unknown>
      if (typeof entry.id !== 'string' || !entry.id) return []
      return [{ id: entry.id, heightM: heightM(entry.heightM, fallback), slabThicknessM: cleanSlab149(entry.slabThicknessM) }]
    }) : []
  if (!levels.length) levels.push({ id: 'layer-main', heightM: fallback, slabThicknessM: 0 })
  const roomAssignmentsRaw = readJson(storage, prefix + 'roomAssignments')
  const assignments = roomAssignmentsRaw && typeof roomAssignmentsRaw === 'object' && !Array.isArray(roomAssignmentsRaw)
    ? roomAssignmentsRaw as Record<string, unknown> : {}
  const activeRoomIds = new Set(activeLevel.rooms.map((room) => room.id))
  const groups = new Map(levels.map((level) => [level.id, [] as Room[]]))
  let savedLayouts = 0
  let activeLayouts = 0
  for (const room of rooms) {
    const layout = readJson(storage, `strom-stair-layout:${room.id}`)
    if (!Array.isArray(layout) || !layout.some((item) => item && typeof item === 'object' && ['stair', 'turn', 'landing'].includes((item as Record<string, unknown>).kind as string))) continue
    savedLayouts++
    if (activeRoomIds.has(room.id)) activeLayouts++
    const levelId = typeof assignments[room.id] === 'string' && groups.has(assignments[room.id] as string)
      ? assignments[room.id] as string : activeRoomIds.has(room.id) ? activeLevel.id : 'layer-main'
    const group = groups.get(levelId) ?? groups.get(levels[0].id)
    group?.push(room)
  }
  const surfaces: PlacedStairSurface143[] = []
  const elevations149 = levelElevationsDatum151(levels,floor.id,storage)
  for (const level of levels) {
    const offset = Math.round((elevations149[level.id] - activeLevel.elevationM) * 1000) / 1000
    const levelRooms = groups.get(level.id) ?? []
    for (const surface of buildStair3DSurfaces(levelRooms, stairRise149(levels,level.id), storage)) {
      surfaces.push({ ...surface, levelId: level.id, levelOffsetM: offset, direction147: directions147[surface.roomId] === 'down' ? 'down' : 'up' })
    }
  }
  return { surfaces, savedLayouts, activeLayouts }
}
