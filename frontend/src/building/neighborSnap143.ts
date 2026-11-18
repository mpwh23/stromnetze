import type { PointM } from '../types'

/** 143b: Ghost-level snapping is geometric alignment, never wall clearance. */
export type NeighborSnapTarget = { vertices: PointM[] }
export type SnapHandle143 = 'left' | 'right' | 'top' | 'bottom'
type DragAxis143 = 'x' | 'y' | null
const LIMIT = 0.18 // metres; snap capture radius, NOT an offset
const EPS = 1e-7
const r3 = (v: number) => Math.round(v * 1000) / 1000
function bounds(vertices: PointM[]) {
  if (!vertices.length) return null
  return { minX: Math.min(...vertices.map(p => p.x)), maxX: Math.max(...vertices.map(p => p.x)),
    minY: Math.min(...vertices.map(p => p.y)), maxY: Math.max(...vertices.map(p => p.y)) }
}
function closestOnSegment(p: PointM, a: PointM, b: PointM): PointM {
  const dx = b.x - a.x, dy = b.y - a.y
  const t = dx * dx + dy * dy > EPS
    ? Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / (dx * dx + dy * dy))) : 0
  return { x: a.x + t * dx, y: a.y + t * dy }
}
function distance(a: PointM, b: PointM) { return Math.hypot(a.x - b.x, a.y - b.y) }

/** Corner to corner, or corner to a true edge; exact coordinates, no wall spacing. */
export function snapPointToVisibleRooms143(point: PointM, targets: NeighborSnapTarget[], _wallM = 0): PointM {
  let best = point, score = LIMIT
  for (const target of targets) {
    const vs = target.vertices
    for (let i = 0; i < vs.length; i++) {
      const candidates = [vs[i], closestOnSegment(point, vs[i], vs[(i + 1) % vs.length])]
      for (const candidate of candidates) {
        const d = distance(point, candidate)
        if (d < score - EPS) { best = candidate; score = d }
      }
    }
  }
  return best === point ? point : { x: r3(best.x), y: r3(best.y) }
}

/** Move a selected rectangle edge to a visible ghost edge (0 mm gap). */
export function snapRectangleHandle143(vertices: PointM[], handle: SnapHandle143, targets: NeighborSnapTarget[], _wallM = 0): PointM[] {
  const b = bounds(vertices)
  if (!b) return vertices
  const vertical = handle === 'left' || handle === 'right'
  const current = handle === 'left' ? b.minX : handle === 'right' ? b.maxX : handle === 'top' ? b.minY : b.maxY
  let snapped = current, score = LIMIT
  for (const target of targets) {
    const other = bounds(target.vertices)
    if (!other) continue
    const overlaps = vertical
      ? b.minY <= other.maxY + LIMIT && b.maxY >= other.minY - LIMIT
      : b.minX <= other.maxX + LIMIT && b.maxX >= other.minX - LIMIT
    if (!overlaps) continue
    const coords = vertical ? [other.minX, other.maxX] : [other.minY, other.maxY]
    for (const p of target.vertices) coords.push(vertical ? p.x : p.y)
    for (const value of coords) {
      const error = Math.abs(value - current)
      if (error < score - EPS) { score = error; snapped = value }
    }
  }
  if (Math.abs(snapped - current) < 0.0005) return vertices
  const next = { ...b }
  if (handle === 'left') next.minX = Math.min(next.maxX - 0.1, snapped)
  if (handle === 'right') next.maxX = Math.max(next.minX + 0.1, snapped)
  if (handle === 'top') next.minY = Math.min(next.maxY - 0.1, snapped)
  if (handle === 'bottom') next.maxY = Math.max(next.minY + 0.1, snapped)
  return [
    { x: r3(next.minX), y: r3(next.minY) }, { x: r3(next.maxX), y: r3(next.minY) },
    { x: r3(next.maxX), y: r3(next.maxY) }, { x: r3(next.minX), y: r3(next.maxY) },
  ]
}

/** Move an entire room/group rigidly: corner-to-corner or parallel edge-to-edge. */
export function snapMovedVerticesToVisibleRooms143(vertices: PointM[], targets: NeighborSnapTarget[], axis: DragAxis143 = null): PointM[] {
  if (!vertices.length || !targets.length) return vertices
  let bestDx = 0, bestDy = 0, score = LIMIT
  const trySnap = (dx: number, dy: number) => {
    if ((axis === 'x' && Math.abs(dy) > EPS) || (axis === 'y' && Math.abs(dx) > EPS)) return
    const d = Math.hypot(dx, dy)
    if (d > EPS && d < score - EPS) { bestDx = dx; bestDy = dy; score = d }
  }
  for (const target of targets) {
    for (const sourcePoint of vertices) {
      for (let j = 0; j < target.vertices.length; j++) {
        const a = target.vertices[j], b = target.vertices[(j + 1) % target.vertices.length]
        const near = closestOnSegment(sourcePoint, a, b)
        trySnap(near.x - sourcePoint.x, near.y - sourcePoint.y)
        trySnap(a.x - sourcePoint.x, a.y - sourcePoint.y)
      }
    }
    // Align edges when they overlap but no vertex is near the opposing edge.
    for (let i = 0; i < vertices.length; i++) {
      const a = vertices[i], b = vertices[(i + 1) % vertices.length]
      for (let j = 0; j < target.vertices.length; j++) {
        const c = target.vertices[j], d = target.vertices[(j + 1) % target.vertices.length]
        const sourceVertical = Math.abs(a.x - b.x) < EPS
        const targetVertical = Math.abs(c.x - d.x) < EPS
        if (sourceVertical && targetVertical && Math.max(Math.min(a.y, b.y), Math.min(c.y, d.y)) <= Math.min(Math.max(a.y, b.y), Math.max(c.y, d.y)) + EPS) {
          trySnap(c.x - a.x, 0)
        }
        const sourceHorizontal = Math.abs(a.y - b.y) < EPS
        const targetHorizontal = Math.abs(c.y - d.y) < EPS
        if (sourceHorizontal && targetHorizontal && Math.max(Math.min(a.x, b.x), Math.min(c.x, d.x)) <= Math.min(Math.max(a.x, b.x), Math.max(c.x, d.x)) + EPS) {
          trySnap(0, c.y - a.y)
        }
      }
    }
  }
  if (score === LIMIT) return vertices
  return vertices.map(p => ({ x: r3(p.x + bestDx), y: r3(p.y + bestDy) }))
}
