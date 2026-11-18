import type { PointM } from '../types'
import type { BuildingModel } from './model'

export type WallHitSelection3D = { roomId: string; edgeIndex: number }

/**
 * STROM140_3D_WALL_EDITOR: identify the specific Blueprint room edge whose
 * solid surface was clicked. The 3D wall is a single union mesh in 139, so it
 * cannot be identified from a mesh ID. Use the hit's real world X/Z point,
 * an edge-segment projection and a small preference for editable room sides.
 * This is a selection calculation only, not a new geometry representation.
 */
export function selectWallEdgeFrom3DHit(model: BuildingModel, hit: PointM): WallHitSelection3D | null {
  let chosen: WallHitSelection3D | null = null
  let best = Number.POSITIVE_INFINITY
  let nearest = Number.POSITIVE_INFINITY
  for (const room of model.rooms) {
    const vertices = room.vertices
    if (!vertices || vertices.length < 2) continue
    for (let edgeIndex = 0; edgeIndex < vertices.length; edgeIndex++) {
      const a = vertices[edgeIndex]
      const b = vertices[(edgeIndex + 1) % vertices.length]
      const vx = b.x - a.x
      const vy = b.y - a.y
      const len2 = vx * vx + vy * vy
      if (len2 < 0.0025) continue
      const raw = ((hit.x - a.x) * vx + (hit.y - a.y) * vy) / len2
      const t = Math.max(0, Math.min(1, raw))
      const px = a.x + t * vx
      const py = a.y + t * vy
      const gap = Math.hypot(hit.x - px, hit.y - py)
      // Select an actual wall segment, not a faraway edge at a corner.
      // A maximum gap accounts for unusually thick physical wall volumes.
      if (gap > 0.90) continue
      const endpointPenalty = raw < -0.02 || raw > 1.02 ? .3 : 0
      const score = gap + endpointPenalty + (room.kind === 'outer' ? .025 : 0)
      if (score < best) {
        best = score
        nearest = gap
        chosen = { roomId: room.id, edgeIndex }
      }
    }
  }
  if (nearest > 0.90) return null
  return chosen
}
