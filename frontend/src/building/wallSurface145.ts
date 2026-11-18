/** STROM145_WALL_SURFACE
 * Correct overlapping COPLANAR faces in the existing watertight wall shell.
 * The building model, wall coordinates, door openings and stair geometry are not changed.
 * If a plane is already non-overlapping, its original triangles pass through unchanged.
 */
export type SurfaceRepairStats145 = {
  positions: number[]
  inputTriangles: number
  outputTriangles: number
  repairedPlanes: number
  skippedPlanes: number
}

type P2 = { x: number; y: number }
type P3 = [number, number, number]
type Face = { points: [P2, P2, P2]; sign: number; original: number[] }
type Segment = { a: P2; b: P2 }
type Plane = {
  kind: 'horizontal' | 'vertical'
  nx: number
  nz: number
  d: number
  faces: Face[]
}
const EPS = 1e-8
const keyRound = (v: number, factor: number) => Math.round(v * factor)
const cross2 = (a: P2, b: P2, c: P2) => (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
const area2 = (p: P2[]) => Math.abs(cross2(p[0], p[1], p[2]))
const inside = (p: P2, triangle: P2[]) => {
  const s1 = cross2(triangle[0], triangle[1], p)
  const s2 = cross2(triangle[1], triangle[2], p)
  const s3 = cross2(triangle[2], triangle[0], p)
  return (s1 >= -EPS && s2 >= -EPS && s3 >= -EPS) || (s1 <= EPS && s2 <= EPS && s3 <= EPS)
}

// Clip a convex polygon by a triangle's directed half planes. Returns the
// true INTERSECTION, not just the intersection of axis-aligned bounding boxes.
function overlapArea(a: P2[], b: P2[]) {
  let result = [...a]
  const sign = cross2(b[0], b[1], b[2]) >= 0 ? 1 : -1
  for (let i = 0; i < 3 && result.length; i++) {
    const s = b[i], t = b[(i + 1) % 3]
    const next: P2[] = []
    for (let j = 0; j < result.length; j++) {
      const p = result[j], q = result[(j + 1) % result.length]
      const ap = sign * cross2(s, t, p), aq = sign * cross2(s, t, q)
      const pin = ap >= -EPS, qin = aq >= -EPS
      if (pin && qin) next.push(q)
      else if (pin !== qin) {
        const den = ap - aq
        const u = Math.abs(den) > EPS ? ap / den : .5
        const mid = { x: p.x + (q.x - p.x) * u, y: p.y + (q.y - p.y) * u }
        next.push(mid)
        if (qin) next.push(q)
      }
    }
    result = next
  }
  if (result.length < 3) return 0
  let twice = 0
  for (let i = 0; i < result.length; i++) {
    const p = result[i], q = result[(i + 1) % result.length]
    twice += p.x * q.y - p.y * q.x
  }
  return Math.abs(twice) / 2
}

function hasOverlap(faces: Face[]) {
  for (let i = 0; i < faces.length; i++) {
    const a = faces[i].points
    const ax0 = Math.min(...a.map((p) => p.x)), ax1 = Math.max(...a.map((p) => p.x))
    const ay0 = Math.min(...a.map((p) => p.y)), ay1 = Math.max(...a.map((p) => p.y))
    for (let j = i + 1; j < faces.length; j++) {
      const b = faces[j].points
      if (Math.min(ax1, Math.max(...b.map((p) => p.x))) - Math.max(ax0, Math.min(...b.map((p) => p.x))) < 1e-6) continue
      if (Math.min(ay1, Math.max(...b.map((p) => p.y))) - Math.max(ay0, Math.min(...b.map((p) => p.y))) < 1e-6) continue
      if (overlapArea(a, b) > 1e-9) return true
    }
  }
  return false
}

function lineY(segment: Segment, x: number) {
  return segment.a.y + (segment.b.y - segment.a.y) * (x - segment.a.x) / (segment.b.x - segment.a.x)
}
function projectedPoint(plane: Plane, p: P2): P3 {
  if (plane.kind === 'horizontal') return [p.x, plane.d, p.y]
  return [plane.nx * plane.d - plane.nz * p.x, p.y, plane.nz * plane.d + plane.nx * p.x]
}
function pushTriangle(out: number[], plane: Plane, a: P2, b: P2, c: P2, sign: number) {
  const pts = sign > 0 ? [a, c, b] : [a, b, c]
  for (const p of pts) out.push(...projectedPoint(plane, p))
}

function reconstruct(plane: Plane) {
  const edges: Segment[] = []
  const eventSet = new Set<number>()
  for (const face of plane.faces) {
    for (let i = 0; i < 3; i++) {
      const a = face.points[i], b = face.points[(i + 1) % 3]
      eventSet.add(a.x)
      eventSet.add(b.x)
      if (Math.abs(a.x - b.x) > EPS) edges.push({ a, b })
    }
  }
  // Bands also split where two triangle boundaries intersect. Thus the
  // vertical ordering of edges cannot change inside any one band.
  for (let i = 0; i < edges.length; i++) {
    const a = edges[i]
    for (let j = i + 1; j < edges.length; j++) {
      const b = edges[j]
      const xMin = Math.max(Math.min(a.a.x, a.b.x), Math.min(b.a.x, b.b.x))
      const xMax = Math.min(Math.max(a.a.x, a.b.x), Math.max(b.a.x, b.b.x))
      if (xMax - xMin < 1e-7) continue
      const x1 = xMin, x2 = xMax
      const da = lineY(a, x2) - lineY(a, x1)
      const db = lineY(b, x2) - lineY(b, x1)
      const delta = da - db
      if (Math.abs(delta) < EPS) continue
      const u = (lineY(b, x1) - lineY(a, x1)) / delta
      if (u > 1e-7 && u < 1 - 1e-7) eventSet.add(x1 + u * (x2 - x1))
    }
  }
  const events = [...eventSet].sort((a, b) => a - b)
  const out: number[] = []
  for (let i = 0; i + 1 < events.length; i++) {
    const u0 = events[i], u1 = events[i + 1]
    if (u1 - u0 < 1e-8) continue
    const mid = (u0 + u1) * .5
    const cuts = edges.filter((e) => mid > Math.min(e.a.x, e.b.x) + 1e-9 && mid < Math.max(e.a.x, e.b.x) - 1e-9)
      .map((edge) => ({ edge, value: lineY(edge, mid) }))
      .sort((a, b) => a.value - b.value)
    const distinct: typeof cuts = []
    for (const cut of cuts) {
      if (distinct.length && Math.abs(distinct[distinct.length - 1].value - cut.value) < 1e-8) continue
      distinct.push(cut)
    }
    for (let j = 0; j + 1 < distinct.length; j++) {
      const lower = distinct[j], upper = distinct[j + 1]
      if (upper.value - lower.value < 1e-8) continue
      const center = { x: mid, y: (lower.value + upper.value) * .5 }
      const covering = plane.faces.filter((face) => inside(center, face.points))
      if (!covering.length) continue
      // Never erase a physical surface when two coincident faces have
      // inconsistent winding. A single DoubleSide triangle remains visible.
      const balance = covering.reduce((sum, face) => sum + face.sign, 0)
      const faceSign = Math.sign(balance) || covering[0].sign
      const a = { x: u0, y: lineY(lower.edge, u0) }, b = { x: u1, y: lineY(lower.edge, u1) }
      const c = { x: u1, y: lineY(upper.edge, u1) }, d = { x: u0, y: lineY(upper.edge, u0) }
      if (area2([a,b,c]) > 1e-10) pushTriangle(out, plane, a,b,c, faceSign)
      if (area2([a,c,d]) > 1e-10) pushTriangle(out, plane, a,c,d, faceSign)
    }
  }
  return out
}

/** All positions are in metres. This module deliberately has NO Three.js deps. */
export function repairWallSurface145(source: ArrayLike<number>): SurfaceRepairStats145 {
  if (source.length % 9 !== 0) throw new Error('Incomplete wall triangle buffer')
  const groups = new Map<string, Plane>()
  const kept: number[] = []
  let repairedPlanes = 0, skippedPlanes = 0
  for (let i = 0; i < source.length; i += 9) {
    const raw = Array.from({ length: 9 }, (_, j) => Number(source[i + j]))
    if (!raw.every(Number.isFinite)) throw new Error('Non-finite wall vertex')
    const a: P3 = [raw[0],raw[1],raw[2]], b: P3 = [raw[3],raw[4],raw[5]], c: P3=[raw[6],raw[7],raw[8]]
    const ux=b[0]-a[0], uy=b[1]-a[1], uz=b[2]-a[2]
    const vx=c[0]-a[0], vy=c[1]-a[1], vz=c[2]-a[2]
    const nx=uy*vz-uz*vy, ny=uz*vx-ux*vz, nz=ux*vy-uy*vx
    const mag=Math.hypot(nx,ny,nz)
    if (mag < 1e-12) continue
    const normals = [nx/mag,ny/mag,nz/mag]
    let kind: Plane['kind'], canonicalX=0, canonicalZ=0, planeD=0
    if (Math.abs(normals[1]) > 1-1e-7) {
      kind='horizontal'; planeD=a[1]
    } else if (Math.abs(normals[1]) < 1e-7) {
      kind='vertical'
      const orient = Math.abs(normals[0]) > 1e-8 ? Math.sign(normals[0]) : Math.sign(normals[2])
      canonicalX=normals[0]*orient; canonicalZ=normals[2]*orient
      planeD=canonicalX*a[0]+canonicalZ*a[2]
    } else {
      // Unsupported oblique plane. Pass it through, never distort its shape.
      kept.push(...raw); continue
    }
    const sign = kind==='horizontal' ? Math.sign(normals[1]) : Math.sign(normals[0]*canonicalX + normals[2]*canonicalZ)
    const toP2 = (p: P3): P2 => kind==='horizontal'
      ? {x:p[0],y:p[2]}
      : {x:-canonicalZ*p[0]+canonicalX*p[2],y:p[1]}
    const face: Face = {points:[toP2(a),toP2(b),toP2(c)],sign,original:raw}
    const key = kind==='horizontal' ? `h:${keyRound(planeD, 100000)}`
      : `v:${keyRound(canonicalX,1000000)}:${keyRound(canonicalZ,1000000)}:${keyRound(planeD,100000)}`
    const group = groups.get(key)
    if (group) group.faces.push(face)
    else groups.set(key,{kind,nx:canonicalX,nz:canonicalZ,d:planeD,faces:[face]})
  }
  for (const group of groups.values()) {
    if (group.faces.length < 2 || !hasOverlap(group.faces)) {
      for (const face of group.faces) kept.push(...face.original)
      continue
    }
    if (group.faces.length > 350) {
      skippedPlanes++
      for (const face of group.faces) kept.push(...face.original)
      continue
    }
    const result = reconstruct(group)
    if (!result.length) {
      skippedPlanes++
      for (const face of group.faces) kept.push(...face.original)
      continue
    }
    if (!result.every(Number.isFinite)) {
      skippedPlanes++
      for (const face of group.faces) kept.push(...face.original)
      continue
    }
    repairedPlanes++
    kept.push(...result)
  }
  return { positions: kept, inputTriangles: source.length/9, outputTriangles: kept.length/9, repairedPlanes, skippedPlanes }
}
