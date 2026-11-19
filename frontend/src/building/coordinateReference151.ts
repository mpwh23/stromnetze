import {levelElevations149, type Level149} from './levelGeometry149'

/** STROM151_COORDINATE_DATUM: Blueprint defines model coordinates in metres.
 * Architectural X/Y are plan axes, Z is height; Three.js renders them as X/Y(up)/Z.
 * No implicit scaling, rotation, camera offset or geometry recentering occurs here. */
export type BlueprintXYZ151={x:number;y:number;z:number}
export type ThreeXYZ151={x:number;y:number;z:number}
export const ZERO_LEVEL_KEY_SUFFIX151='zeroLevel151'
export const zeroLevelKey151=(floorId:string)=>`strom.floorplan.layers.${floorId}.${ZERO_LEVEL_KEY_SUFFIX151}`

export function resolveZeroLevel151<T extends Pick<Level149,'id'>>(levels:readonly T[],candidate:string|null|undefined):string{
  if(levels.length===0)return ''
  // Existing objects retain their old bottom-floor Z=0 until a different datum is chosen.
  return candidate&&levels.some(level=>level.id===candidate)?candidate:levels[levels.length-1].id
}
export function readZeroLevel151<T extends Pick<Level149,'id'>>(
  floorId:string, levels:readonly T[], storage:Pick<Storage,'getItem'>
):string{
  if(levels.length<=1)return levels[0]?.id??''
  try{
    const raw=storage.getItem(zeroLevelKey151(floorId))
    if(!raw)return resolveZeroLevel151(levels,null)
    // JSON string is canonical; tolerate legacy unquoted values when present.
    let saved:unknown=raw
    try{saved=JSON.parse(raw)}catch{/* no legacy data migration required */}
    return resolveZeroLevel151(levels,typeof saved==='string'?saved:null)
  }catch{return resolveZeroLevel151(levels,null)}
}
export function writeZeroLevel151(floorId:string,levelId:string,storage:Pick<Storage,'setItem'>):void{
  if(!floorId||!levelId)throw Error('Invalid zero-level selection')
  storage.setItem(zeroLevelKey151(floorId),JSON.stringify(levelId))
  if(typeof window!=='undefined'){
    window.dispatchEvent(new CustomEvent('strom:zero-level151',{detail:{floorId,levelId}}))
  }
}

/** Finished-floor elevations relative to selected Z=0, keeping every inter-floor
 * distance and slab thickness exactly as in 149. Negative values are valid. */
export function levelElevationsDatum151<T extends Level149>(
  levelsTopFirst:readonly T[],floorId:string,storage:Pick<Storage,'getItem'>
):Record<string,number>{
  if(levelsTopFirst.length===0)return {}
  const original=levelElevations149(levelsTopFirst,0)
  const zeroId=readZeroLevel151(floorId,levelsTopFirst,storage)
  const offset=original[zeroId]??0
  const result:Record<string,number>={}
  for(const level of levelsTopFirst){
    result[level.id]=Math.round((original[level.id]-offset)*1000)/1000
  }
  return result
}

/** Explicit 1:1 axis mapping; Blueprint X,Y,Z -> Three.js X,Y(up),Z(depth). */
export function blueprintToThree151(p:BlueprintXYZ151):ThreeXYZ151{
  return {x:p.x,y:p.z,z:p.y}
}
export function threeToBlueprint151(p:ThreeXYZ151):BlueprintXYZ151{
  return {x:p.x,y:p.z,z:p.y}
}
