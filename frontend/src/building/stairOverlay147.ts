import type { PointM } from '../types'

/** A stair well can contain two independent, geometrically coincident stair rooms. */
export type StairDirection147 = 'up' | 'down'
export type StairOverlay147 = { id: string; vertices: PointM[] }
export type StairDirectionStore147 = { getItem(key: string): string | null; setItem(key: string, value: string): void }
export const stairDirectionKey147 = (floorId: string) => `strom.floorplan.layers.${floorId}.stairDirections147`

export function readStairDirections147(floorId: string, storage: Pick<StairDirectionStore147, 'getItem'>): Record<string, StairDirection147> {
  try {
    const raw = storage.getItem(stairDirectionKey147(floorId))
    const value: unknown = raw ? JSON.parse(raw) : null
    if (!value || typeof value !== 'object' || Array.isArray(value)) return {}
    const result: Record<string, StairDirection147> = {}
    for (const [id, direction] of Object.entries(value)) {
      if (direction === 'up' || direction === 'down') result[id] = direction
    }
    return result
  } catch { return {} }
}

export function sameStairFootprint147(a: Pick<StairOverlay147, 'vertices'>, b: Pick<StairOverlay147, 'vertices'>): boolean {
  if (!Array.isArray(a.vertices) || !Array.isArray(b.vertices) || a.vertices.length < 3 || a.vertices.length !== b.vertices.length) return false
  const pack = (pts: PointM[]) => pts.map((p) => `${Math.round(p.x * 1000)}:${Math.round(p.y * 1000)}`).sort()
  const av = pack(a.vertices), bv = pack(b.vertices)
  return av.every((value, i) => value === bv[i])
}

