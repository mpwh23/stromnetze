import type { PointM } from '../types'

/** STROM146_EDGE_SNAP: direct topology alignment, never wall thickness offset. */
export type SnapTarget146 = { vertices: PointM[] }
export type EdgeSnapResult146 = { vertices: PointM[]; point: PointM | null; label: string }
type RectEdge146 = 'left' | 'right' | 'top' | 'bottom'
const round = (n: number) => Math.round(n * 1000) / 1000
const distance = (a: PointM, b: PointM) => Math.hypot(a.x - b.x, a.y - b.y)
const dot = (a: PointM, b: PointM) => a.x * b.x + a.y * b.y
const subtract = (a: PointM, b: PointM): PointM => ({ x: a.x - b.x, y: a.y - b.y })

function segmentProjection146(point: PointM, start: PointM, end: PointM): PointM {
  const ab = subtract(end, start)
  const size = dot(ab, ab)
  if (size < 1e-12) return start
  const t = Math.max(0, Math.min(1, dot(subtract(point, start), ab) / size))
  return { x: start.x + t * ab.x, y: start.y + t * ab.y }
}

/** Preserve the Shift-key direction even when a snap candidate is considered. */
function lockedShift146(dx: number, dy: number, referenceDx: number, referenceDy: number): PointM {
  const angle = Math.atan2(referenceDy, referenceDx)
  const step = Math.PI / 4
  const locked = Math.round(angle / step) * step
  const axis = { x: Math.cos(locked), y: Math.sin(locked) }
  const length = dx * axis.x + dy * axis.y
  return { x: axis.x * length, y: axis.y * length }
}

/** Translate BOTH ends by the same delta so moving an edge cannot shear it.
 * The shift flag restricts the complete translation, not only the final snap correction.
 * A snap is reported only when the resulting point really lies on the target.
 */
export function snapTranslatedEdge146(
  original: PointM[], indexA: number, indexB: number,
  rawDx: number, rawDy: number, targets: SnapTarget146[], thresholdM: number, shift: boolean,
): EdgeSnapResult146 {
  if (!original[indexA] || !original[indexB]) return { vertices: original, point: null, label: '' }
  const tolerance = Math.max(0.002, Math.min(0.3, thresholdM))
  const move = shift ? lockedShift146(rawDx, rawDy, rawDx, rawDy) : { x: rawDx, y: rawDy }
  const proposed = (p: PointM): PointM => ({ x: p.x + move.x, y: p.y + move.y })
  const moving = [indexA, indexB]
  let best: { dx: number; dy: number; point: PointM; label: string; dist: number } | null = null
  for (const target of targets) {
    if (!Array.isArray(target.vertices) || target.vertices.length < 2) continue
    for (const movingIndex of moving) {
      const sourcePoint = proposed(original[movingIndex])
      for (let i = 0; i < target.vertices.length; i++) {
        const a = target.vertices[i]
        const b = target.vertices[(i + 1) % target.vertices.length]
        const candidates: Array<{ point: PointM; label: string }> = [
          { point: a, label: 'Eckpunkt' },
          { point: segmentProjection146(sourcePoint, a, b), label: 'Kante' },
        ]
        for (const candidate of candidates) {
          const correction = subtract(candidate.point, sourcePoint)
          const translated = shift
            ? lockedShift146(move.x + correction.x, move.y + correction.y, rawDx, rawDy)
            : { x: move.x + correction.x, y: move.y + correction.y }
          const resulting = { x: original[movingIndex].x + translated.x, y: original[movingIndex].y + translated.y }
          const afterDistance = distance(resulting, candidate.point)
          const movedDistance = Math.hypot(translated.x - move.x, translated.y - move.y)
          if (afterDistance > Math.max(0.001, tolerance * 0.05) || movedDistance > tolerance) continue
          if (!best || movedDistance < best.dist - 1e-7 || (Math.abs(movedDistance - best.dist) < 1e-7 && candidate.label === 'Eckpunkt')) {
            best = { dx: translated.x, dy: translated.y, point: candidate.point, label: candidate.label, dist: movedDistance }
          }
        }
      }
    }
  }
  const currentMove: PointM = best ? { x: best.dx, y: best.dy } : move
  const vertices = original.map((p, i) => moving.includes(i)
    ? { x: round(p.x + currentMove.x), y: round(p.y + currentMove.y) }
    : p)
  return { vertices, point: best?.point ?? null, label: best ? `${best.label} · 0 mm` : '' }
}

/** Only the dragged side of an axis-aligned rectangular room is adjusted.
 * Opposite side and remaining dimensions are preserved. No clearance added.
 */
export function snapRectEdge146(
  vertices: PointM[], handle: RectEdge146, targets: SnapTarget146[], thresholdM: number,
): EdgeSnapResult146 {
  if (vertices.length < 4) return { vertices, point: null, label: '' }
  const vertical = handle === 'left' || handle === 'right'
  const xs = vertices.map((p) => p.x), ys = vertices.map((p) => p.y)
  const current = handle === 'left' ? Math.min(...xs) : handle === 'right' ? Math.max(...xs)
    : handle === 'top' ? Math.min(...ys) : Math.max(...ys)
  const moving = vertices.filter((p) => Math.abs((vertical ? p.x : p.y) - current) < 0.0005)
  if (moving.length < 2) return { vertices, point: null, label: '' }
  const low = Math.min(...moving.map((p) => vertical ? p.y : p.x))
  const high = Math.max(...moving.map((p) => vertical ? p.y : p.x))
  let best: { value: number; point: PointM; dist: number } | null = null
  const tolerance = Math.max(0.002, Math.min(0.3, thresholdM))
  for (const target of targets) {
    const points = target.vertices
    if (!Array.isArray(points) || points.length < 2) continue
    for (let i = 0; i < points.length; i++) {
      const a = points[i], b = points[(i + 1) % points.length]
      const tA = vertical ? a.y : a.x, tB = vertical ? b.y : b.x
      if (Math.min(tA, tB) > high + tolerance || Math.max(tA, tB) < low - tolerance) continue
      const uA = vertical ? a.x : a.y, uB = vertical ? b.x : b.y
      // Only align to parallel segments; do not pull a rectangular edge onto a diagonal.
      if (Math.abs(uB - uA) > 0.001) continue
      const candidate = (uA + uB) / 2
      const delta = Math.abs(candidate - current)
      if (delta > tolerance || (best && delta >= best.dist)) continue
      best = { value: candidate, dist: delta, point: vertical
        ? { x: candidate, y: Math.max(low, Math.min(high, (tA + tB) / 2)) }
        : { x: Math.max(low, Math.min(high, (tA + tB) / 2)), y: candidate } }
    }
  }
  if (!best) return { vertices, point: null, label: '' }
  const next = vertices.map((point) => Math.abs((vertical ? point.x : point.y) - current) < 0.0005
    ? (vertical ? { ...point, x: round(best!.value) } : { ...point, y: round(best!.value) }) : point)
  const span = vertical ? Math.max(...next.map((p) => p.x)) - Math.min(...next.map((p) => p.x))
    : Math.max(...next.map((p) => p.y)) - Math.min(...next.map((p) => p.y))
  if (span < 0.05) return { vertices, point: null, label: '' }
  return { vertices: next, point: best.point, label: 'Kante · 0 mm' }
}

