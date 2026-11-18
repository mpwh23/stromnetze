import type { PointM, Room } from '../types'
import type { KeyValueReader } from './blueprintLevels'

/** Real tread footprints in metres, shared by the 3D scene and future 2D preview. */
export type Stair3DSurface = {
  key: string
  roomId: string
  points: PointM[]
  elevationM: number
  kind: 'landing' | 'step'
}

type StairKind = 'landing' | 'stair' | 'turn'
type StairElement = {
  id: string
  kind: StairKind
  xM: number
  yM: number
  widthM: number
  heightM: number
  rotationDeg: number
  steps: number
  mirrored: boolean
}

type StairEdgeAssignment = { kind?: string; edgeIndex?: number }

const dist = (a: PointM, b: PointM) => Math.hypot(a.x - b.x, a.y - b.y)
const center = (e: StairElement): PointM => ({ x: e.xM + e.widthM / 2, y: e.yM + e.heightM / 2 })
const avg = (a: PointM, b: PointM): PointM => ({ x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 })
const safeSteps = (e: StairElement) => Math.max(1, Math.min(128, Math.round(e.steps)))
const rectCorners = (e: StairElement) => ({ left: e.xM, right: e.xM + e.widthM, top: e.yM, bottom: e.yM + e.heightM })
const r3 = (x: number) => Math.round(x * 1000) / 1000

function readArray(storage: KeyValueReader, key: string): unknown[] {
  try {
    const raw = storage.getItem(key)
    const value: unknown = raw ? JSON.parse(raw) : []
    return Array.isArray(value) ? value : []
  } catch { return [] }
}

function loadStairElements(roomId: string, storage: KeyValueReader): StairElement[] {
  return readArray(storage, `strom-stair-layout:${roomId}`).flatMap((raw) => {
    if (!raw || typeof raw !== 'object') return []
    const e = raw as Record<string, unknown>
    if (e.kind !== 'stair' && e.kind !== 'turn' && e.kind !== 'landing') return []
    const xM = Number(e.xM), yM = Number(e.yM), widthM = Number(e.widthM), heightM = Number(e.heightM)
    if (![xM, yM, widthM, heightM].every(Number.isFinite) || widthM < 0.01 || heightM < 0.01) return []
    return [{
      id: String(e.id || `${e.kind}-${xM}-${yM}`), kind: e.kind, xM, yM, widthM, heightM,
      rotationDeg: Number(e.rotationDeg) || 0, steps: Number(e.steps) || 1, mirrored: Boolean(e.mirrored),
    }]
  })
}

function mapPoint(e: StairElement, unit: PointM): PointM {
  const rotation = ((Math.round(e.rotationDeg / 90) % 4) + 4) % 4
  const dx = unit.x - 0.5, dy = unit.y - 0.5
  const rotated = rotation === 1 ? { x: 0.5 + dy, y: 0.5 - dx }
    : rotation === 2 ? { x: 0.5 - dx, y: 0.5 - dy }
      : rotation === 3 ? { x: 0.5 - dy, y: 0.5 + dx } : unit
  return { x: e.xM + rotated.x * e.widthM, y: e.yM + rotated.y * e.heightM }
}

function arrow(e: StairElement): { start: PointM; end: PointM } {
  if (e.kind !== 'turn') return { start: mapPoint(e, { x: 0.5, y: 0.78 }), end: mapPoint(e, { x: 0.5, y: 0.22 }) }
  return e.mirrored
    ? { start: mapPoint(e, { x: 0.28, y: 0.84 }), end: mapPoint(e, { x: 0.76, y: 0.56 }) }
    : { start: mapPoint(e, { x: 0.72, y: 0.84 }), end: mapPoint(e, { x: 0.24, y: 0.56 }) }
}

function currentFloorOrigin(room: Room, storage: KeyValueReader): PointM {
  const assignments = readArray(storage, `strom-stair-edge-assignments:${room.id}`) as StairEdgeAssignment[]
  const entry = assignments.find((a) => a.kind === 'current-floor' && Number.isInteger(a.edgeIndex))
  if (entry && room.vertices.length > 1) {
    const i = ((Number(entry.edgeIndex) % room.vertices.length) + room.vertices.length) % room.vertices.length
    return avg(room.vertices[i], room.vertices[(i + 1) % room.vertices.length])
  }
  return room.vertices.length ? room.vertices.reduce((acc, p) => ({ x: acc.x + p.x / room.vertices.length, y: acc.y + p.y / room.vertices.length }), { x: 0, y: 0 }) : { x: 0, y: 0 }
}

function orderElements(room: Room, elements: StairElement[], storage: KeyValueReader): StairElement[] {
  const remain = [...elements]
  if (remain.length < 2) return remain
  const ordered: StairElement[] = []
  const entry = currentFloorOrigin(room, storage)
  remain.sort((a, b) => dist(entry, arrow(a).start) - dist(entry, arrow(b).start))
  ordered.push(remain.shift()!)
  while (remain.length) {
    const current = ordered[ordered.length - 1]
    const end = arrow(current).end
    const dx = end.x - arrow(current).start.x, dy = end.y - arrow(current).start.y
    const length = Math.hypot(dx, dy) || 1
    remain.sort((a, b) => {
      const score = (e: StairElement) => {
        const next = arrow(e)
        const displacement = { x: center(e).x - end.x, y: center(e).y - end.y }
        const backwards = Math.max(0, -(displacement.x * dx + displacement.y * dy) / length)
        return dist(end, next.start) + backwards * 2.5 + (dist(end, next.end) < dist(end, next.start) ? 0.25 : 0)
      }
      return score(a) - score(b)
    })
    ordered.push(remain.shift()!)
  }
  return ordered
}

function neighborOnRight(e: StairElement, elements: StairElement[]) {
  const straight = elements.filter((other) => other.id !== e.id && other.kind === 'stair')
  const candidates = straight.length ? straight : elements.filter((other) => other.id !== e.id)
  if (!candidates.length) return !e.mirrored
  candidates.sort((a, b) => dist(center(a), center(e)) - dist(center(b), center(e)))
  return center(candidates[0]).x > center(e).x
}

function rayRect(origin: PointM, rect: ReturnType<typeof rectCorners>, angle: number): PointM {
  const dx = Math.cos(angle), dy = Math.sin(angle)
  const options: Array<{ t: number; point: PointM }> = []
  const epsilon = 1e-8
  if (Math.abs(dx) > epsilon) {
    for (const x of [rect.left, rect.right]) {
      const t = (x - origin.x) / dx
      const y = origin.y + t * dy
      if (t > epsilon && y >= rect.top - epsilon && y <= rect.bottom + epsilon) options.push({ t, point: { x, y: Math.min(rect.bottom, Math.max(rect.top, y)) } })
    }
  }
  if (Math.abs(dy) > epsilon) {
    for (const y of [rect.top, rect.bottom]) {
      const t = (y - origin.y) / dy
      const x = origin.x + t * dx
      if (t > epsilon && x >= rect.left - epsilon && x <= rect.right + epsilon) options.push({ t, point: { x: Math.min(rect.right, Math.max(rect.left, x)), y } })
    }
  }
  options.sort((a, b) => a.t - b.t)
  return options[0]?.point ?? origin
}

/**
 * Returns non-overlapping tread footprints; step elevations run from 'Diese Etage'
 * along the already stored direction arrows. Does not alter the stored layout.
 */
export function buildStair3DSurfaces(rooms: Room[], floorHeightM: number, storage: KeyValueReader): Stair3DSurface[] {
  const surfaces: Stair3DSurface[] = []
  const safeHeight = Math.max(0.1, floorHeightM)
  for (const room of rooms) {
    const elements = loadStairElements(room.id, storage)
    if (!elements.length) continue
    const ordered = orderElements(room, elements, storage)
    const total = ordered.reduce((sum, e) => sum + (e.kind === 'landing' ? 0 : safeSteps(e)), 0)
    const rise = total > 0 ? safeHeight / total : 0
    let previousSteps = 0
    for (const e of ordered) {
      const r = rectCorners(e)
      if (e.kind === 'landing') {
        surfaces.push({
          key: `${room.id}:${e.id}:landing`, roomId: room.id, kind: 'landing', elevationM: r3(previousSteps * rise),
          points: [{ x: r.left, y: r.top }, { x: r.right, y: r.top }, { x: r.right, y: r.bottom }, { x: r.left, y: r.bottom }],
        })
        continue
      }
      const n = safeSteps(e)
      if (e.kind === 'stair') {
        const rotation = ((Math.round(e.rotationDeg / 90) % 4) + 4) % 4
        for (let i = 0; i < n; i += 1) {
          const t0 = i / n, t1 = (i + 1) / n
          let left = r.left, right = r.right, top = r.top, bottom = r.bottom
          if (rotation === 1) { left = r.right - e.widthM * t1; right = r.right - e.widthM * t0 }
          else if (rotation === 3) { left = r.left + e.widthM * t0; right = r.left + e.widthM * t1 }
          else if (rotation === 2) { top = r.top + e.heightM * t0; bottom = r.top + e.heightM * t1 }
          else { top = r.bottom - e.heightM * t1; bottom = r.bottom - e.heightM * t0 }
          surfaces.push({
            key: `${room.id}:${e.id}:step${i}`, roomId: room.id, kind: 'step', elevationM: r3((previousSteps + i + 1) * rise),
            points: [{ x: left, y: top }, { x: right, y: top }, { x: right, y: bottom }, { x: left, y: bottom }],
          })
        }
      } else {
        const onRight = neighborOnRight(e, ordered)
        const origin = onRight ? { x: r.right, y: r.bottom } : { x: r.left, y: r.bottom }
        const angleA = onRight ? Math.PI : -Math.PI / 2
        const angleB = onRight ? Math.PI * 1.5 : 0
        const startPoint = rayRect(origin, r, angleA)
        const endPoint = rayRect(origin, r, angleB)
        const dir = arrow(e)
        const reverse = dist(dir.start, endPoint) + dist(dir.end, startPoint) < dist(dir.start, startPoint) + dist(dir.end, endPoint)
        const startAngle = reverse ? angleB : angleA
        const endAngle = reverse ? angleA : angleB
        for (let i = 0; i < n; i += 1) {
          const p0 = rayRect(origin, r, startAngle + (endAngle - startAngle) * i / n)
          const p1 = rayRect(origin, r, startAngle + (endAngle - startAngle) * (i + 1) / n)
          const triangle = [origin, p0, p1]
          // Zero-size degenerate step surfaces must never enter Three.js.
          const area2 = Math.abs((p0.x - origin.x) * (p1.y - origin.y) - (p0.y - origin.y) * (p1.x - origin.x))
          if (area2 < 1e-8) continue
          surfaces.push({
            key: `${room.id}:${e.id}:turn${i}`, roomId: room.id, kind: 'step', elevationM: r3((previousSteps + i + 1) * rise), points: triangle,
          })
        }
      }
      previousSteps += n
    }
  }
  return surfaces
}
