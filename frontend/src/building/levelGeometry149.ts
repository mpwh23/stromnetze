/** The Blueprint list is TOP first. Elevations are measured at finished-floor level. */
export type Level149 = {id:string; heightM:number; slabThicknessM?:number}
export const FLOOR_SLAB_DEFAULT149 = 0
export function cleanSlab149(value:unknown):number {
  const n = typeof value==='number'?value:Number(value)
  return Number.isFinite(n)&&n>=0&&n<=1.5?Math.round(n*1000)/1000:FLOOR_SLAB_DEFAULT149
}
export function levelElevations149<T extends Level149>(levelsTopFirst:readonly T[],baseM=0):Record<string,number> {
  const result:Record<string,number>={}
  let height=Number.isFinite(baseM)?baseM:0
  for(let i=levelsTopFirst.length-1;i>=0;i--){
    if(i<levelsTopFirst.length-1) height+=cleanSlab149(levelsTopFirst[i].slabThicknessM)
    result[levelsTopFirst[i].id]=Math.round(height*1000)/1000
    height+=levelsTopFirst[i].heightM
  }
  return result
}
/** Stairs reach the upper level's finished-floor level, including that upper level's slab. */
export function stairRise149<T extends Level149>(levels:readonly T[],currentLevelId:string):number {
  const index=levels.findIndex(item=>item.id===currentLevelId)
  if(index<0)return 0
  return levels[index].heightM + (index>0?cleanSlab149(levels[index-1].slabThicknessM):0)
}
export function levelHeight149<T extends Level149>(levels:readonly T[],levelId:string,baseM=0):number {
  return levelElevations149(levels,baseM)[levelId]??baseM
}
export type RoofPlaneCopy149={start:{x:number;y:number};end:{x:number;y:number};startHeightM:number;directionDeg:number;pitchDeg:number}
/** Preserve world-space z(x,y)=z0 + tan(pitch)*dot(p - start, direction), even across floors. */
export function inheritRoofPlane149<T extends RoofPlaneCopy149>(source:T, newStart:{x:number;y:number},newEnd:{x:number;y:number},srcLevelZ:number,targetLevelZ:number):T {
  const r=source.directionDeg*Math.PI/180
  const run=(newStart.x-source.start.x)*Math.cos(r)+(newStart.y-source.start.y)*Math.sin(r)
  const height=srcLevelZ+source.startHeightM+run*Math.tan(source.pitchDeg*Math.PI/180)-targetLevelZ
  return {...source,start:{...newStart},end:{...newEnd},startHeightM:Math.round(height*1000)/1000}
}
/** Shift a 2D start line or turn its endpoint; an endpoint turn also rotates the roof's rise direction. */
export function dragRoofLine149<T extends RoofPlaneCopy149>(roof:T,mode:'move'|'start'|'end',dx:number,dy:number):T {
  if(mode==='move')return {...roof,start:{x:roof.start.x+dx,y:roof.start.y+dy},end:{x:roof.end.x+dx,y:roof.end.y+dy}}
  const start=mode==='start'?{x:roof.start.x+dx,y:roof.start.y+dy}:roof.start
  const end=mode==='end'?{x:roof.end.x+dx,y:roof.end.y+dy}:roof.end
  if(Math.hypot(end.x-start.x,end.y-start.y)<0.1)return roof
  const a=Math.atan2(roof.end.y-roof.start.y,roof.end.x-roof.start.x)
  const b=Math.atan2(end.y-start.y,end.x-start.x)
  return {...roof,start:{...start},end:{...end},directionDeg:((roof.directionDeg+(b-a)*180/Math.PI)%360+360)%360}
}
export function readSlabThickness149(floorId:string,levelId:string,storage:Pick<Storage,'getItem'>):number {
  try {
    const raw:unknown=JSON.parse(storage.getItem(`strom.floorplan.layers.${floorId}.list`)||'[]')
    if(!Array.isArray(raw))return 0
    const found=raw.find((r:unknown)=>r&&typeof r==='object'&&(r as {id?:unknown}).id===levelId)
    return found&&typeof found==='object'?cleanSlab149((found as {slabThicknessM?:unknown}).slabThicknessM):0
  }catch{return 0}
}
