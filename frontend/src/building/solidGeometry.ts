import type { PointM } from '../types'
import { wallSolidPieces, type BuildingModel, type BuildingWall } from './model'

/**
 * 139: A watertight, unioned set of wall solids, with a thick exterior infill.
 *
 * 138 generated one mesh for every longitudinal/vertical wall slice. That can
 * create overlapping coplanar faces and leave uncovered islands where an outer
 * wall encloses no individual room. Here we treat walls as ONE occupancy volume
 * and produce only its boundary triangles. No independent 3D data is stored.
 *
 * Blueprint coordinates (x, y) map to Three.js (x, z). Altitude maps to y.
 * This module is pure TypeScript and does not require Three.js or a CSG addon.
 */
export type SolidSurface = {
  positions: number[]
  triangleCount: number
  interiorFill: boolean
}

type Polygon2 = PointM[]
type Slab = { polygon: Polygon2; bottom: number; top: number }
type Segment = { a: PointM; b: PointM; xMin: number; xMax: number; zMin: number; zMax: number }
type AtX = { z: number; segment: Segment }
type Cell = { polygon: [PointM, PointM, PointM, PointM]; x: number; z: number }

type Occupancy = {
  solids: Slab[]
  openings: Slab[]
  outside: Polygon2[]
  inside: Polygon2[]
  height: number
}

const EPS = 0.00005 // 0.05 mm: well below the project's 1 mm coordinate precision
const MIN_AREA = 1e-8
const round10um = (value: number) => Math.round(value * 100000) / 100000
const clamp = (value: number, a: number, b: number) => Math.max(a, Math.min(b, value))

function pointInPoly(p: PointM, points: Polygon2): boolean {
  let inside = false
  for (let i = 0, j = points.length - 1; i < points.length; j = i++) {
    const a = points[i]
    const b = points[j]
    if ((a.y > p.y) !== (b.y > p.y)) {
      const x = a.x + (p.y - a.y) * (b.x - a.x) / (b.y - a.y)
      if (p.x < x) inside = !inside
    }
  }
  return inside
}

function pointInSlab(p: PointM, y: number, slab: Slab) {
  return y >= slab.bottom - EPS / 2 && y <= slab.top + EPS / 2 && pointInPoly(p, slab.polygon)
}

/** Testable canonical predicate: positive solids union exterior infill, cut by openings. */
export function solidAt(model: BuildingModel, point: PointM, altitude: number): boolean {
  return occupied(makeOccupancy(model), point, altitude)
}

function occupied(ctx: Occupancy, point: PointM, y: number): boolean {
  if (y < 0 || y > ctx.height) return false
  const wall = ctx.solids.some((solid) => pointInSlab(point, y, solid))
  const infill = ctx.outside.length > 0
    && ctx.outside.some((polygon) => pointInPoly(point, polygon))
    && !ctx.inside.some((polygon) => pointInPoly(point, polygon))
  if (!wall && !infill) return false
  return !ctx.openings.some((opening) => pointInSlab(point, y, opening))
}

function wallRect(wall: BuildingWall, from: number, to: number, extraThickness = 0): Polygon2 {
  const vx = (wall.end.x - wall.start.x) / wall.lengthM
  const vz = (wall.end.y - wall.start.y) / wall.lengthM
  const nx = -vz * (wall.thicknessM / 2 + extraThickness)
  const nz = vx * (wall.thicknessM / 2 + extraThickness)
  return [
    { x: wall.start.x + vx * from + nx, y: wall.start.y + vz * from + nz },
    { x: wall.start.x + vx * to + nx, y: wall.start.y + vz * to + nz },
    { x: wall.start.x + vx * to - nx, y: wall.start.y + vz * to - nz },
    { x: wall.start.x + vx * from - nx, y: wall.start.y + vz * from - nz },
  ]
}

function makeOccupancy(model: BuildingModel): Occupancy {
  const solids: Slab[] = []
  const openings: Slab[] = []
  for (const wall of model.walls) {
    if (wall.lengthM < .001 || wall.thicknessM < .001) continue
    for (const piece of wallSolidPieces(wall)) {
      if (piece.topM - piece.bottomM < .001 || piece.toM - piece.fromM < .001) continue
      solids.push({ polygon: wallRect(wall, piece.fromM, piece.toM), bottom: piece.bottomM, top: piece.topM })
    }
    for (const item of wall.openings) {
      const from = clamp(item.centerM - item.widthM / 2, 0, wall.lengthM)
      const to = clamp(item.centerM + item.widthM / 2, 0, wall.lengthM)
      if (to - from < .001 || item.heightM < .001) continue
      const bottom = clamp(item.sillM, 0, model.floorHeightM)
      const top = clamp(item.sillM + item.heightM, 0, model.floorHeightM)
      openings.push({ polygon: wallRect(wall, from, to, .005), bottom, top })
    }
  }
  return {
    solids,
    openings,
    outside: model.rooms.filter((room) => room.kind === 'outer').map((room) => room.vertices),
    inside: model.rooms.filter((room) => room.kind !== 'outer').map((room) => room.vertices),
    height: model.floorHeightM,
  }
}

function allSegments(polygons: Polygon2[]): Segment[] {
  const result: Segment[] = []
  for (const polygon of polygons) {
    for (let i = 0; i < polygon.length; i++) {
      const a = polygon[i]
      const b = polygon[(i + 1) % polygon.length]
      if (Math.hypot(b.x - a.x, b.y - a.y) < .00001) continue
      result.push({ a, b, xMin: Math.min(a.x, b.x), xMax: Math.max(a.x, b.x), zMin: Math.min(a.y, b.y), zMax: Math.max(a.y, b.y) })
    }
  }
  return result
}

/** All x event positions including crossing points, so scanline bands cannot swap z ordering. */
function xEvents(segments: Segment[]): number[] {
  const events = new Set<number>()
  const bound = segments.map((s) => {
    events.add(round10um(s.a.x))
    events.add(round10um(s.b.x))
    return s
  })
  for (let i = 0; i < bound.length; i++) {
    const a = bound[i]
    for (let j = i + 1; j < bound.length; j++) {
      const b = bound[j]
      if (Math.min(a.xMax, b.xMax) - Math.max(a.xMin, b.xMin) < .00001) continue
      if (Math.min(a.zMax, b.zMax) < Math.max(a.zMin, b.zMin) - .00001) continue
      const ax = a.b.x - a.a.x, ay = a.b.y - a.a.y
      const bx = b.b.x - b.a.x, by = b.b.y - b.a.y
      const den = ax * by - ay * bx
      if (Math.abs(den) < 1e-10) continue
      const cx = b.a.x - a.a.x, cy = b.a.y - a.a.y
      const t = (cx * by - cy * bx) / den
      const u = (cx * ay - cy * ax) / den
      if (t > .00001 && t < .99999 && u > .00001 && u < .99999) {
        events.add(round10um(a.a.x + ax * t))
      }
    }
  }
  return [...events].sort((a, b) => a - b)
}

function zAtX(segment: Segment, x: number) {
  const dx = segment.b.x - segment.a.x
  return segment.a.y + (x - segment.a.x) / dx * (segment.b.y - segment.a.y)
}

function cutsAtX(segments: Segment[], x: number): AtX[] {
  const cuts = segments.filter((s) => x > s.xMin + 1e-9 && x < s.xMax - 1e-9)
    .map((segment) => ({ z: zAtX(segment, x), segment }))
    .sort((a, b) => a.z - b.z)
  const unique: AtX[] = []
  for (const cut of cuts) {
    if (unique.length && Math.abs(unique[unique.length - 1].z - cut.z) < 1e-7) continue
    unique.push(cut)
  }
  return unique
}

const signedArea = (poly: Polygon2) => {
  let area = 0
  for (let i = 0; i < poly.length; i++) {
    const a = poly[i], b = poly[(i + 1) % poly.length]
    area += a.x * b.y - b.x * a.y
  }
  return area / 2
}

function emitTriangle(positions: number[], a: PointM, ay: number, b: PointM, by: number, c: PointM, cy: number) {
  positions.push(a.x, ay, a.y, b.x, by, b.y, c.x, cy, c.y)
}

function cap(positions: number[], cell: Cell, y: number, up: boolean) {
  const [a, b, c, d] = cell.polygon
  if (Math.abs(signedArea(cell.polygon)) <= MIN_AREA) return
  if (up) {
    emitTriangle(positions, a, y, c, y, b, y)
    emitTriangle(positions, a, y, d, y, c, y)
  } else {
    emitTriangle(positions, a, y, b, y, c, y)
    emitTriangle(positions, a, y, c, y, d, y)
  }
}

function side(positions: number[], a: PointM, b: PointM, bottom: number, top: number) {
  if (Math.hypot(b.x - a.x, b.y - a.y) < .00001) return
  // Right side of a CCW XZ polygon is the exterior. Normals are generated by
  // Three.js from winding; keep outward-facing triangles for front-only shading.
  emitTriangle(positions, a, bottom, a, top, b, top)
  emitTriangle(positions, a, bottom, b, top, b, bottom)
}

/**
 * Exact in the XZ plane for segments from the Blueprint. No overlapping slabs:
 * only the outside faces of the union are emitted. Door/window voids and the
 * exterior envelope's otherwise empty space share one occupancy definition.
 * Output coordinates are local to the floor; the scene group adds elevation.
 */
export function buildSolidSurface(model: BuildingModel): SolidSurface {
  const ctx = makeOccupancy(model)
  const planarEdges = allSegments([
    ...ctx.solids.map((item) => item.polygon),
    ...ctx.openings.map((item) => item.polygon),
    ...ctx.outside,
    ...ctx.inside,
  ])
  if (!planarEdges.length) return { positions: [], triangleCount: 0, interiorFill: false }
  const xs = xEvents(planarEdges)
  const ys = [...new Set([
    0, model.floorHeightM,
    ...ctx.solids.flatMap((slab) => [slab.bottom, slab.top]),
    ...ctx.openings.flatMap((slab) => [slab.bottom, slab.top]),
  ].map(round10um))].sort((a, b) => a - b)

  // Cache each horizontal scanline once: height affects occupancy, not the
  // planar partition. Avoid redrawing the same slice quadrilateral twice.
  const cells: Cell[] = []
  for (let i = 0; i < xs.length - 1; i++) {
    const x0 = xs[i], x1 = xs[i + 1]
    if (x1 - x0 < .00001) continue
    const x = (x0 + x1) / 2
    const crossings = cutsAtX(planarEdges, x)
    for (let j = 0; j < crossings.length - 1; j++) {
      const a = crossings[j], b = crossings[j + 1]
      if (b.z - a.z < .00001) continue
      const polygon: [PointM, PointM, PointM, PointM] = [
        { x: x0, y: zAtX(a.segment, x0) },
        { x: x1, y: zAtX(a.segment, x1) },
        { x: x1, y: zAtX(b.segment, x1) },
        { x: x0, y: zAtX(b.segment, x0) },
      ]
      if (Math.abs(signedArea(polygon)) > MIN_AREA) {
        cells.push({ polygon, x, z: (a.z + b.z) / 2 })
      }
    }
  }
  const positions: number[] = []
  for (let h = 0; h < ys.length - 1; h++) {
    const bottom = ys[h], top = ys[h + 1]
    if (top - bottom < .00001) continue
    const mid = (bottom + top) / 2
    for (const cell of cells) {
      const center = { x: cell.x, y: cell.z }
      if (!occupied(ctx, center, mid)) continue
      if (h === 0 || !occupied(ctx, center, bottom - EPS)) cap(positions, cell, bottom, false)
      if (h === ys.length - 2 || !occupied(ctx, center, top + EPS)) cap(positions, cell, top, true)
      const pts = cell.polygon
      for (let edge = 0; edge < 4; edge++) {
        const a = pts[edge], b = pts[(edge + 1) % 4]
        const dx = b.x - a.x, dz = b.y - a.y
        const length = Math.hypot(dx, dz)
        if (length < .00001) continue
        // A CCW cell has its interior on the left side of its directed edge.
        const outward = { x: (a.x + b.x) / 2 + dz / length * EPS, y: (a.y + b.y) / 2 - dx / length * EPS }
        if (!occupied(ctx, outward, mid)) side(positions, a, b, bottom, top)
      }
    }
  }
  return { positions, triangleCount: positions.length / 9, interiorFill: ctx.outside.length > 0 }
}

/** Selection stays linked to canonical rooms without adding a second 3D schema. */
export function nearestRoomForWallHit(model: BuildingModel, point: PointM): string {
  let bestRoom = ''
  let bestGap = Number.POSITIVE_INFINITY
  for (const wall of model.walls) {
    const ax = wall.start.x, az = wall.start.y
    const vx = wall.end.x - ax, vz = wall.end.y - az
    const t = clamp(((point.x - ax) * vx + (point.y - az) * vz) / Math.max(.000001, vx * vx + vz * vz), 0, 1)
    const d = Math.max(0, Math.hypot(point.x - ax - t * vx, point.y - az - t * vz) - wall.thicknessM / 2)
    if (d < bestGap) {
      bestGap = d
      bestRoom = model.rooms.find((room) => wall.roomIds?.includes(room.id) && room.kind !== 'outer')?.id ?? wall.roomId
    }
  }
  return bestRoom
}
