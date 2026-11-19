import type { Room } from '../types'
import { sameStairFootprint147, type StairDirection147 } from './stairOverlay147'

/** STROM148: stable identities remain linked even if their room polygons diverge. */
export const stairPairsKey148=(floorId:string)=>`strom.floorplan.layers.${floorId}.stairPairs148`
export type StairPairs148 = Record<string,string>
export function readStairPairs148(floorId:string, storage:Pick<Storage,'getItem'>):StairPairs148 {
  try {
    const value:unknown=JSON.parse(storage.getItem(stairPairsKey148(floorId))||'{}')
    if (!value||typeof value!=='object'||Array.isArray(value))return {}
    const next:StairPairs148={}
    for(const [a,b] of Object.entries(value))if(typeof b==='string'&&a!==b&&b)next[a]=b
    return next
  }catch{return {}}
}
export function saveStairPairs148(floorId:string, pairs:StairPairs148) {
  window.localStorage.setItem(stairPairsKey148(floorId),JSON.stringify(pairs))
  window.dispatchEvent(new Event('strom:blueprint-levels-changed'))
}
export function linkStairs148(current:StairPairs148, a:string,b:string):StairPairs148 {
  if(a===b)throw Error('Ein Raum kann nicht mit sich selbst verknüpft werden.')
  const next={...current}
  // Detach only existing links involving the two requested rooms.
  for(const [id,other] of Object.entries(next))if([a,b].includes(id)||[a,b].includes(other))delete next[id]
  next[a]=b;next[b]=a
  return next
}
/** One-time upgrade for existing v147 paired up/down stair rooms. */
export function inferLegacyStairPairs148(
  rooms:Room[], assignments:Record<string,string>, directions:Record<string,StairDirection147>, pairs:StairPairs148,
):StairPairs148 {
  let next={...pairs}
  for(const room of rooms) {
    if(room.roomType!=='stair'||directions[room.id]!=='up'||next[room.id])continue
    const candidates=rooms.filter(other=>other.roomType==='stair'&&other.id!==room.id&&
      directions[other.id]==='down'&&!next[other.id]&&
      (assignments[other.id]||'layer-main')===(assignments[room.id]||'layer-main'))
    const matches=candidates.filter(other=>sameStairFootprint147(room,other))
    if(matches.length===1) {next=linkStairs148(next,room.id,matches[0].id);continue}
    // The 147b clone carries the explicit "(abwärts)" suffix. Migrate a pair
    // whose shape was edited before the stable ID mapping existed, but only
    // when the name-based match is unambiguous.
    const prefix=room.name.trim().replace(/\s*\((?:aufwärts|abwärts)\)$/i,'')
    const byCloneName=candidates.filter(other=>other.name.trim()===`${prefix} (abwärts)`)
    if(byCloneName.length===1)next=linkStairs148(next,room.id,byCloneName[0].id)
  }
  return next
}
export type StairPortal148={room:Room;sourceLayerId:string;targetLayerId:string}
/** A physical staircase is referenced on the next floor; it is not duplicated as a database room. */
export function linkedStairPortals148(
  rooms:Room[],layers:{id:string}[],assignments:Record<string,string>,directions:Record<string,StairDirection147>,targetLayerId:string,
):StairPortal148[] {
  const targetIndex=layers.findIndex(l=>l.id===targetLayerId)
  if(targetIndex<0)return []
  return rooms.flatMap(room=>{
    if(room.roomType!=='stair')return []
    const sourceLayerId=assignments[room.id]||'layer-main'
    const sourceIndex=layers.findIndex(l=>l.id===sourceLayerId)
    const direction=directions[room.id]
    if(sourceIndex<0 || !((direction==='up' && sourceIndex+1===targetIndex)||(direction==='down'&&sourceIndex-1===targetIndex)))return []
    return [{room,sourceLayerId,targetLayerId}]
  })
}
