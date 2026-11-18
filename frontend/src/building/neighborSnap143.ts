import type { PointM } from '../types'

/** Read-only anchors (metres) from rooms on visible Blueprint layers. */
export type NeighborSnapTarget = { vertices: PointM[] }
export type SnapHandle143 = 'left' | 'right' | 'top' | 'bottom'
const LIMIT = 0.18
const rounded = (value: number) => Math.round(value * 1000) / 1000
function bounds(vertices: PointM[]) {
  if (!vertices.length) return null
  return {
    minX: Math.min(...vertices.map((p) => p.x)), maxX: Math.max(...vertices.map((p) => p.x)),
    minY: Math.min(...vertices.map((p) => p.y)), maxY: Math.max(...vertices.map((p) => p.y)),
  }
}
function nearest(value: number, candidates: number[]): number {
  let best = value, score = LIMIT
  for (const target of candidates) {
    const error = Math.abs(target - value)
    if (error < score - 1e-8) { score = error; best = target }
  }
  return rounded(best)
}
function segmentProjection(point: PointM, a: PointM, b: PointM) {
  const dx = b.x-a.x, dy = b.y-a.y
  const length = dx*dx + dy*dy
  const t = length > 1e-12 ? Math.max(0, Math.min(1, ((point.x-a.x)*dx+(point.y-a.y)*dy)/length)) : 0
  return { x: a.x + t*dx, y: a.y + t*dy }
}

/**
 * Point/vertex creation: snap to nearby exact corners or polygon edges,
 * including oblique walls. No snap across an unrelated distant room.
 */
export function snapPointToVisibleRooms143(point: PointM, targets: NeighborSnapTarget[], wallM: number): PointM {
  if (!targets.length) return point
  let closest = point, distance = LIMIT
  for (const target of targets) {
    for (let i=0; i<target.vertices.length; i++) {
      const a=target.vertices[i], b=target.vertices[(i+1)%target.vertices.length]
      for (const p of [a, segmentProjection(point,a,b)]) {
        const d=Math.hypot(p.x-point.x,p.y-point.y)
        if (d < distance - 1e-8) { closest=p; distance=d }
      }
    }
  }
  if (closest !== point) return { x: rounded(closest.x), y: rounded(closest.y) }
  // The user-specified W is an optional wall-to-wall clearance, not a global grid.
  const clearance = Math.min(0.6, Math.max(0, wallM))
  if (clearance < 0.001) return point
  let best=point, score=LIMIT
  for (const target of targets) {
    for (let i=0; i<target.vertices.length; i++) {
      const a=target.vertices[i], b=target.vertices[(i+1)%target.vertices.length]
      const dx=b.x-a.x, dy=b.y-a.y, length=Math.hypot(dx,dy)
      if (length < 1e-8) continue
      const normal={x:-dy/length,y:dx/length}
      for (const sign of [-1,1]) {
        const p=segmentProjection(point,{x:a.x+sign*normal.x*clearance,y:a.y+sign*normal.y*clearance},{x:b.x+sign*normal.x*clearance,y:b.y+sign*normal.y*clearance})
        const d=Math.hypot(p.x-point.x,p.y-point.y)
        if (d<score-1e-8) {score=d;best=p}
      }
    }
  }
  return best===point ? point : {x:rounded(best.x),y:rounded(best.y)}
}

/** Snap only the dragged rectangle edge; leave its opposite edge untouched. */
export function snapRectangleHandle143(vertices: PointM[], handle: SnapHandle143, targets: NeighborSnapTarget[], wallM: number): PointM[] {
  const b = bounds(vertices)
  if (!b || !targets.length) return vertices
  const vertical = handle === 'left' || handle === 'right'
  const current = handle === 'left' ? b.minX : handle === 'right' ? b.maxX : handle === 'top' ? b.minY : b.maxY
  const wall = Math.max(0, Math.min(0.6,wallM))
  const candidates: number[] = []
  for (const target of targets) {
    const other=bounds(target.vertices)
    if (!other) continue
    // Do not snap to a room on the far side of the canvas.
    const overlap = vertical
      ? b.minY <= other.maxY + LIMIT && b.maxY >= other.minY - LIMIT
      : b.minX <= other.maxX + LIMIT && b.maxX >= other.minX - LIMIT
    if (!overlap) continue
    const coords = vertical ? [other.minX,other.maxX] : [other.minY,other.maxY]
    for (const value of coords) candidates.push(value, value-wall, value+wall)
    for (const p of target.vertices) candidates.push(vertical ? p.x : p.y)
  }
  const snapped = nearest(current,candidates)
  if (Math.abs(snapped-current) < 0.0005) return vertices
  const next = { ...b }
  if (handle==='left') next.minX=Math.min(next.maxX-0.1,snapped)
  else if (handle==='right') next.maxX=Math.max(next.minX+0.1,snapped)
  else if (handle==='top') next.minY=Math.min(next.maxY-0.1,snapped)
  else next.maxY=Math.max(next.minY+0.1,snapped)
  return [
    {x:rounded(next.minX),y:rounded(next.minY)}, {x:rounded(next.maxX),y:rounded(next.minY)},
    {x:rounded(next.maxX),y:rounded(next.maxY)}, {x:rounded(next.minX),y:rounded(next.maxY)},
  ]
}
