import type { Floor, Room } from '../types'

/**
 * 142: Read the existing Blueprint layer storage format without changing keys.
 * This is a transitional adapter: no room or layer is duplicated for 3D.
 * Cross-browser DB persistence of layer metadata is a separate later migration.
 */
export type BlueprintLevelView = {
  id: string
  name: string
  heightM: number
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
  const layers: Array<{ id: string; name: string; heightM: number }> = Array.isArray(storedLayers)
    ? storedLayers.flatMap((value: unknown, index: number) => {
      if (!value || typeof value !== 'object') return []
      const layer = value as Record<string, unknown>
      if (typeof layer.id !== 'string' || !layer.id) return []
      return [{
        id: layer.id,
        name: typeof layer.name === 'string' ? layer.name : `Ebene ${index + 1}`,
        heightM: clampHeight(Number(layer.heightM), fallbackHeightM),
      }]
    })
    : []
  if (!layers.length) layers.push({ id: DEFAULT_LAYER_ID, name: 'Ebene 1', heightM: fallbackHeightM })
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
    elevationM: roundMm((Number(floor.elevationM) || 0) + layers.slice(0, index).reduce((sum, layer) => sum + layer.heightM, 0)),
    rooms: rooms.filter((room) => (typeof assignments[room.id] === 'string' ? assignments[room.id] : DEFAULT_LAYER_ID) === current.id),
    layerCount: layers.length,
  }
}

export function active3DFloor(floor: Floor, level: BlueprintLevelView): Floor {
  return { ...floor, heightM: level.heightM, elevationM: level.elevationM, name: `${floor.name} / ${level.name}` }
}
