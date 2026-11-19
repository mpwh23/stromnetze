import type { PointM, Room } from '../types'

/** STROM148: one physical roof-slope record, shared by Blueprint and both true-3D views. */
export type RoofSlope148 = {
  id: string
  roomId: string
  levelId: string
  start: PointM
  end: PointM
  /** Degrees clockwise from +X on the Blueprint (0=right, 90=down). */
  directionDeg: number
  pitchDeg: number
  /** Height above the floor of the roof's own level (metres). */
  startHeightM: number
}
export const ROOF_EVENT148 = 'strom:roof-slopes-changed148'
export const roofKey148 = (floorId: string) => `strom.floorplan.roofSlopes148.${floorId}`

function validPoint(point: unknown): point is PointM {
  if (!point || typeof point !== 'object') return false
  const p = point as Record<string, unknown>
  return typeof p.x === 'number' && Number.isFinite(p.x) && typeof p.y === 'number' && Number.isFinite(p.y)
}
export function normalizeSlope148(v: unknown): RoofSlope148 | null {
  if (!v || typeof v !== 'object') return null
  const r = v as Record<string, unknown>
  if (typeof r.id !== 'string' || !r.id || typeof r.roomId !== 'string' || !r.roomId ||
      typeof r.levelId !== 'string' || !r.levelId || !validPoint(r.start) || !validPoint(r.end)) return null
  const pitchDeg = Number(r.pitchDeg), startHeightM = Number(r.startHeightM), directionDeg = Number(r.directionDeg)
  if (![pitchDeg, startHeightM, directionDeg].every(Number.isFinite) ||
      pitchDeg < 0 || pitchDeg > 65 || startHeightM < 0 || startHeightM > 15 ||
      Math.hypot(r.end.x-r.start.x, r.end.y-r.start.y) < 0.03) return null
  return {id:r.id,roomId:r.roomId,levelId:r.levelId,start:{...r.start},end:{...r.end},
    directionDeg: ((directionDeg%360)+360)%360, pitchDeg, startHeightM}
}
export function readRoofSlopes148(floorId: string, store: Pick<Storage,'getItem'>): RoofSlope148[] {
  try {
    const value: unknown = JSON.parse(store.getItem(roofKey148(floorId)) || '[]')
    if (!Array.isArray(value)) return []
    const used = new Set<string>()
    return value.flatMap((entry: unknown) => {
      const roof = normalizeSlope148(entry)
      if (!roof || used.has(roof.id)) return []
      used.add(roof.id)
      return [roof]
    })
  } catch { return [] }
}
export function saveRoofSlopes148(floorId: string, list: RoofSlope148[]) {
  if (typeof window === 'undefined') return
  const valid = list.map(normalizeSlope148)
  if (valid.some((roof) => !roof)) throw Error('Dachschräge: ungültige Geometrie oder Parameter.')
  window.localStorage.setItem(roofKey148(floorId), JSON.stringify(valid))
  window.dispatchEvent(new CustomEvent(ROOF_EVENT148, { detail: {floorId} }))
}
export function angleVector148(angle: number): PointM {
  const rad = angle*Math.PI/180
  return {x:Math.cos(rad), y:Math.sin(rad)}
}
export function roofHeight148(roof: RoofSlope148, p: PointM): number {
  const axis = angleVector148(roof.directionDeg)
  const run = (p.x-roof.start.x)*axis.x + (p.y-roof.start.y)*axis.y
  return roof.startHeightM + run * Math.tan(roof.pitchDeg*Math.PI/180)
}
/** Choose the inward-facing normal for a line drawn on a room boundary. */
export function inwardRoofAngle148(start: PointM, end: PointM, vertices: PointM[]): number {
  const centroid = vertices.reduce((s,p)=>({x:s.x+p.x/vertices.length,y:s.y+p.y/vertices.length}),{x:0,y:0})
  const vx=end.x-start.x, vy=end.y-start.y
  const n1={x:-vy,y:vx}
  const mid={x:(start.x+end.x)/2,y:(start.y+end.y)/2}
  const dot=n1.x*(centroid.x-mid.x)+n1.y*(centroid.y-mid.y)
  const n=dot>=0?n1:{x:-n1.x,y:-n1.y}
  return Math.round(((Math.atan2(n.y,n.x)*180/Math.PI)%360+360)%360)
}
export function nearestRoomEdge148(point: PointM, vertices: PointM[], toleranceM = 0.3): PointM {
  let best:PointM=point, bestD=toleranceM
  for(let i=0;i<vertices.length;i++) {
    const a=vertices[i],b=vertices[(i+1)%vertices.length]
    const dx=b.x-a.x,dy=b.y-a.y, denom=dx*dx+dy*dy
    if (denom<1e-12) continue
    const t=Math.max(0,Math.min(1,((point.x-a.x)*dx+(point.y-a.y)*dy)/denom))
    const projected={x:a.x+t*dx,y:a.y+t*dy}
    const d=Math.hypot(projected.x-point.x,projected.y-point.y)
    if (d<bestD) {bestD=d;best=projected}
  }
  return best
}
export function roofsForRoom148(rooms: Room[], slopes: RoofSlope148[], roomId: string, levelId: string) {
  return rooms.some(r=>r.id===roomId) ? slopes.filter(r=>r.roomId===roomId && r.levelId===levelId) : []
}
