import type { Floor } from '../types'
import { migrateVisibility174 } from './levelVisibility174'

/** STROM173_LEVEL_MENU: Ebenenliste wie im Blueprint lesen/schreiben (3D-Ansichten). */
export type RawLayer173 = { id: string; name: string; visible: boolean; heightM?: number; slabThicknessM?: number }
export const layersKey173 = (floorId: string) => `strom.floorplan.layers.${floorId}.list`
export const LEVELS_CHANGED173 = 'strom:blueprint-levels-changed'

export function readRawLayers173(floor: Floor, storage: Pick<Storage, 'getItem'> = window.localStorage): RawLayer173[] {
  if (typeof window !== 'undefined' && storage === window.localStorage) migrateVisibility174(floor.id, window.localStorage) // STROM174
  const result: RawLayer173[] = []
  try {
    const raw: unknown = JSON.parse(storage.getItem(layersKey173(floor.id)) || '[]')
    if (Array.isArray(raw)) for (const [index, item] of raw.entries()) {
      if (!item || typeof item !== 'object') continue
      const e = item as Record<string, unknown>
      if (typeof e.id !== 'string' || !e.id || result.some((l) => l.id === e.id)) continue
      const h = Number(e.heightM), s = Number(e.slabThicknessM)
      result.push({
        ...(e as object),
        id: e.id,
        name: typeof e.name === 'string' && e.name.trim() ? e.name : `Ebene ${index + 1}`,
        visible: e.visible !== false,
        heightM: Number.isFinite(h) && h >= 0.1 && h <= 10 ? h : undefined,
        slabThicknessM: Number.isFinite(s) && s >= 0 ? s : undefined,
      })
    }
  } catch { /* unlesbar: Standardebene */ }
  return result.length ? result : [{ id: 'layer-main', name: 'Ebene 1', visible: true }]
}

export function writeRawLayers173(floor: Floor, layers: RawLayer173[]) {
  window.localStorage.setItem(layersKey173(floor.id), JSON.stringify(layers))
  window.dispatchEvent(new Event(LEVELS_CHANGED173))
}

export function patchRawLayer173(floor: Floor, id: string, patch: Partial<RawLayer173>) {
  writeRawLayers173(floor, readRawLayers173(floor).map((layer) => layer.id === id ? { ...layer, ...patch } : layer))
}

export function moveRawLayer173(floor: Floor, dragId: string, targetId: string) {
  if (!dragId || dragId === targetId) return
  const current = readRawLayers173(floor)
  const moving = current.find((layer) => layer.id === dragId)
  if (!moving) return
  const without = current.filter((layer) => layer.id !== dragId)
  const targetIndex = without.findIndex((layer) => layer.id === targetId)
  if (targetIndex < 0) return
  without.splice(targetIndex, 0, moving)
  writeRawLayers173(floor, without)
}
