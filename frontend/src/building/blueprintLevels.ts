import type { Floor, Room } from '../types'
// STROM149_LEVEL_GEOMETRY: top-to-bottom list, floor slab below each finished floor.
import { levelElevations149, cleanSlab149 } from './levelGeometry149'

/**
 * 142: Read the existing Blueprint layer storage format without changing keys.
 * This is a transitional adapter: no room or layer is duplicated for 3D.
 * Cross-browser DB persistence of layer metadata is a separate later migration.
 */
export type BlueprintLevelView = {
  id: string
  name: string
  heightM: number
  slabThicknessM: number
  elevationM: number
  rooms: Room[]
  layerCount: number
}

export type KeyValueReader = { getItem(key: string): string | null }

const DEFAULT_LAYER_ID = 'layer-main'
const roundMm = (value: number) => Math.round(value * 1000) / 1000
const clampHeight = (height: number, fallback: number) => Number.isFinite(height) && height >= 0.1 && height <= 10 ? roundMm(height) : fallback

function readJson(storage: KeyValueReader, key: string): unknown {
  try {
    const raw = storage.getItem(key)
    return raw ? JSON.parse(raw) as unknown : null
  } catch {
    return null
  }
}

export function readActiveBlueprintLevel(floor: Floor, rooms: Room[], storage: KeyValueReader): BlueprintLevelView {
  const prefix = `strom.floorplan.layers.${floor.id}.`
  const storedLayers = readJson(storage, prefix + 'list')
  const fallbackHeightM = clampHeight(Number(floor.heightM), 2.5)
  const layers: Array<{ id: string; name: string; heightM: number; slabThicknessM: number }> = Array.isArray(storedLayers)
    ? storedLayers.flatMap((value: unknown, index: number) => {
      if (!value || typeof value !== 'object') return []
      const layer = value as Record<string, unknown>
      if (typeof layer.id !== 'string' || !layer.id) return []
      return [{
        id: layer.id,
        name: typeof layer.name === 'string' ? layer.name : `Ebene ${index + 1}`,
        heightM: clampHeight(Number(layer.heightM), fallbackHeightM),
        slabThicknessM: cleanSlab149(layer.slabThicknessM),
      }]
    })
    : []
  if (!layers.length) layers.push({ id: DEFAULT_LAYER_ID, name: 'Ebene 1', heightM: fallbackHeightM, slabThicknessM: 0 })
  const activeId = readJson(storage, prefix + 'active')
  const activeIndex = layers.findIndex((layer) => layer.id === activeId)
  const index = activeIndex >= 0 ? activeIndex : 0
  const current = layers[index]
  const roomAssignmentsRaw = readJson(storage, prefix + 'roomAssignments')
  const assignments = roomAssignmentsRaw && typeof roomAssignmentsRaw === 'object' && !Array.isArray(roomAssignmentsRaw)
    ? roomAssignmentsRaw as Record<string, unknown>
    : {}
  return {
    id: current.id,
    name: current.name,
    heightM: current.heightM,
    slabThicknessM: current.slabThicknessM,
    elevationM: levelElevations149(layers, Number(floor.elevationM)||0)[current.id],
    rooms: rooms.filter((room) => (typeof assignments[room.id] === 'string' ? assignments[room.id] : DEFAULT_LAYER_ID) === current.id),
    layerCount: layers.length,
  }
}

export function active3DFloor(floor: Floor, level: BlueprintLevelView): Floor {
  return { ...floor, heightM: level.heightM, elevationM: level.elevationM, name: `${floor.name} / ${level.name}` }
}


/** STROM144_LEVEL_OPTIONS: shared Blueprint layer selector for Wanddetail. */
export type BlueprintLevelOption144 = { id: string; name: string; heightM: number; slabThicknessM: number }
export function listBlueprintLevelOptions144(floor: Floor, storage: KeyValueReader): BlueprintLevelOption144[] {
  const raw = readJson(storage, `strom.floorplan.layers.${floor.id}.list`)
  const fallback = clampHeight(Number(floor.heightM), 2.5)
  const result: BlueprintLevelOption144[] = []
  if (Array.isArray(raw)) for (const item of raw as unknown[]) {
    if (!item || typeof item !== 'object') continue
    const entry = item as Record<string, unknown>
    if (typeof entry.id !== 'string' || !entry.id || result.some((level) => level.id === entry.id)) continue
    result.push({
      id: entry.id,
      name: typeof entry.name === 'string' && entry.name.trim() ? entry.name : `Ebene ${result.length + 1}`,
      heightM: clampHeight(Number(entry.heightM), fallback),
      slabThicknessM: cleanSlab149(entry.slabThicknessM),
    })
  }
  return result.length ? result : [{ id: DEFAULT_LAYER_ID, name: 'Ebene 1', heightM: fallback, slabThicknessM: 0 }]
}

export function selectBlueprintLevel144(
  floor: Floor, id: string, storage: KeyValueReader & { setItem(key: string, value: string): void },
): boolean {
  if (!listBlueprintLevelOptions144(floor, storage).some((level) => level.id === id)) return false
  try {
    storage.setItem(`strom.floorplan.layers.${floor.id}.active`, JSON.stringify(id))
    return true
  } catch { return false }
}
