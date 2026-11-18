import type { PointM } from '../types'

/**
 * STROM141_WALL_HOVER: highlight the exact *visible* triangles of a wall face.
 *
 * The 139 wall geometry is a single unioned surface, not one object per wall.
 * We therefore cannot simply recolor the clicked mesh. Instead, we copy only
 * triangles on the hovered physical face, clipped to the chosen Blueprint edge.
 * Existing door/window holes remain holes because the source surface contains
 * no triangles there. This module neither edits nor persists building geometry.
 */
export type WallHoverPlane = {
  normalX: number
  normalZ: number
  offsetM: number
}

type Vertex3 = { x: number; y: number; z: number }
type Face3 = { vertices: [Vertex3, Vertex3, Vertex3]; normalX: number; normalY: number; normalZ: number }
const EPS = 1e-8

function triangleAt(array: ArrayLike<number>, faceIndex: number): Face3 | null {
  const i = faceIndex * 9
  if (!Number.isInteger(faceIndex) || i < 0 || i + 8 >= array.length) return null
  const a = { x: Number(array[i]), y: Number(array[i + 1]), z: Number(array[i + 2]) }
  const b = { x: Number(array[i + 3]), y: Number(array[i + 4]), z: Number(array[i + 5]) }
  const c = { x: Number(array[i + 6]), y: Number(array[i + 7]), z: Number(array[i + 8]) }
  const ux = b.x - a.x, uy = b.y - a.y, uz = b.z - a.z
  const vx = c.x - a.x, vy = c.y - a.y, vz = c.z - a.z
  const nx = uy * vz - uz * vy
  const ny = uz * vx - ux * vz
  const nz = ux * vy - uy * vx
  const len = Math.hypot(nx, ny, nz)
  if (len < EPS) return null
  return { vertices: [a, b, c], normalX: nx / len, normalY: ny / len, normalZ: nz / len }
}

function edgeBasis(a: PointM, b: PointM) {
  const length = Math.hypot(b.x - a.x, b.y - a.y)
  if (length < 0.05) return null
  return { length, dx: (b.x - a.x) / length, dz: (b.y - a.y) / length }
}

function plausibleVerticalFace(face: Face3, tx: number, tz: number) {
  // A vertical face parallel to the selected Blueprint edge.
  return Math.abs(face.normalY) < 0.22 && Math.abs(face.normalX * tx + face.normalZ * tz) < 0.17
}

/** Find the actually hit vertical plane, or its closest physical face when the cursor is on its top. */
export function pickWallHoverPlane(
  positions: ArrayLike<number>, a: PointM, b: PointM,
  hit: PointM, faceIndex?: number,
): WallHoverPlane | null {
  const edge = edgeBasis(a, b)
  if (!edge) return null
  const hitFace = faceIndex !== undefined ? triangleAt(positions, faceIndex) : null
  if (hitFace && plausibleVerticalFace(hitFace, edge.dx, edge.dz)) {
    return {
      normalX: hitFace.normalX,
      normalZ: hitFace.normalZ,
      offsetM: hitFace.normalX * hit.x + hitFace.normalZ * hit.y,
    }
  }

  // A top/edge-of-wall click has an upward normal. Find the nearest vertical
  // surface on the selected segment instead of highlighting the entire union.
  let winner: WallHoverPlane | null = null
  let best = Number.POSITIVE_INFINITY
  const hitT = (hit.x - a.x) * edge.dx + (hit.y - a.y) * edge.dz
  if (hitT < -0.12 || hitT > edge.length + 0.12) return null
  for (let i = 0; i + 8 < positions.length; i += 9) {
    const face = triangleAt(positions, i / 9)
    if (!face || !plausibleVerticalFace(face, edge.dx, edge.dz)) continue
    const center = {
      x: (face.vertices[0].x + face.vertices[1].x + face.vertices[2].x) / 3,
      y: (face.vertices[0].z + face.vertices[1].z + face.vertices[2].z) / 3,
    }
    const t = (center.x - a.x) * edge.dx + (center.y - a.y) * edge.dz
    if (t < -0.15 || t > edge.length + 0.15) continue
    const offset = face.normalX * center.x + face.normalZ * center.y
    const gap = Math.abs(face.normalX * hit.x + face.normalZ * hit.y - offset)
    if (gap < best && gap < 0.91) {
      winner = { normalX: face.normalX, normalZ: face.normalZ, offsetM: offset }
      best = gap
    }
  }
  return winner
}

function clipAlongEdge(vertices: Vertex3[], a: PointM, dx: number, dz: number, boundary: number, keepAbove: boolean): Vertex3[] {
  if (!vertices.length) return vertices
  const at = (v: Vertex3) => (v.x - a.x) * dx + (v.z - a.y) * dz
  const inside = (v: Vertex3) => keepAbove ? at(v) >= boundary - 1e-7 : at(v) <= boundary + 1e-7
  const output: Vertex3[] = []
  for (let i = 0; i < vertices.length; i += 1) {
    const first = vertices[i]
    const second = vertices[(i + 1) % vertices.length]
    const fi = inside(first)
    const si = inside(second)
    if (fi) output.push(first)
    if (fi !== si) {
      const from = at(first), to = at(second)
      const alpha = Math.max(0, Math.min(1, (boundary - from) / (to - from)))
      output.push({
        x: first.x + (second.x - first.x) * alpha,
        y: first.y + (second.y - first.y) * alpha,
        z: first.z + (second.z - first.z) * alpha,
      })
    }
  }
  return output
}

/** Copies the exact surface fragments on the hovered plane, leaving true openings empty. */
export function buildWallHoverTriangles(
  positions: ArrayLike<number>, a: PointM, b: PointM, plane: WallHoverPlane,
): number[] {
  const edge = edgeBasis(a, b)
  if (!edge) return []
  const output: number[] = []
  for (let i = 0; i + 8 < positions.length; i += 9) {
    const face = triangleAt(positions, i / 9)
    if (!face || !plausibleVerticalFace(face, edge.dx, edge.dz)) continue
    if (Math.abs(face.normalX * plane.normalX + face.normalZ * plane.normalZ) < 0.98) continue
    if (face.vertices.some((p) => Math.abs(plane.normalX * p.x + plane.normalZ * p.z - plane.offsetM) > 0.005)) continue

    let polygon: Vertex3[] = face.vertices
    polygon = clipAlongEdge(polygon, a, edge.dx, edge.dz, 0, true)
    polygon = clipAlongEdge(polygon, a, edge.dx, edge.dz, edge.length, false)
    if (polygon.length < 3) continue
    for (let j = 1; j < polygon.length - 1; j += 1) {
      const p0 = polygon[0], p1 = polygon[j], p2 = polygon[j + 1]
      const ux = p1.x - p0.x, uy = p1.y - p0.y, uz = p1.z - p0.z
      const vx = p2.x - p0.x, vy = p2.y - p0.y, vz = p2.z - p0.z
      const area2 = Math.hypot(uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx)
      if (area2 < 1e-8) continue
      for (const p of [p0, p1, p2]) output.push(p.x, p.y, p.z)
    }
  }
  return output
}
