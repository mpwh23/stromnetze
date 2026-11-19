/** STROM150_CAMERA_BRIDGE: coordinate view navigation without delaying React rendering. */
export type BlueprintFrame150={floorId:string;levelId:string;cx:number;cy:number;widthM:number;heightM:number}
export type Mode150='wall'|'threeD'
export type Enter150={mode:Mode150;frame:BlueprintFrame150}
let pending150:Enter150|null=null
let current150:Enter150|null=null
let activeExit150:((done:()=>void)=>void)|null=null
let activeReady150:(()=>void)|null=null
let exitPending150=false
let readySent150=false
export const ENTER_FADE150=250
export const DURATION150=750

function storedLevel150(floorId:string):string{
  try {
    const raw=window.localStorage.getItem(`strom.floorplan.layers.${floorId}.active`)
    const value:unknown=JSON.parse(raw||'null')
    return typeof value==='string'?value:''
  }catch{return ''}
}
function viewFrame150(floorId:string):BlueprintFrame150{
  const result:BlueprintFrame150={floorId,levelId:storedLevel150(floorId),cx:0,cy:0,widthM:0,heightM:0}
  try {
    const svg=document.querySelector('svg[aria-label="Blueprint Editor"]') as SVGSVGElement|null
    const container=(svg?.closest('.canvas-scroll,.canvas-viewport,.canvas-scroll-area')||svg?.parentElement) as HTMLElement|null
    const matrix=svg?.getScreenCTM()
    const rect=container?.getBoundingClientRect()
    if(svg&&matrix&&rect&&rect.width>30&&rect.height>30){
      const center=svg.createSVGPoint();center.x=rect.left+rect.width/2;center.y=rect.top+rect.height/2
      const p=center.matrixTransform(matrix.inverse())
      result.cx=(p.x-670)/60;result.cy=(p.y-670)/60
      const pxPerUnit=Math.hypot(matrix.a,matrix.b)
      if(pxPerUnit>1e-5){result.widthM=rect.width/(60*pxPerUnit);result.heightM=rect.height/(60*pxPerUnit)}
    }
  }catch{/* fallback to model-room geometry if no live SVG was found */}
  return result
}
export function queueEntry150(mode:Mode150,floorId:string){
  pending150={mode,frame:viewFrame150(floorId)}
  current150=pending150
  exitPending150=false
  readySent150=false
}
export function consumeEntry150():Enter150|null{
  const value=pending150
  pending150=null
  return value
}
export function restoreEntry150(value:Enter150){if(!pending150)pending150=value}
export function currentFrame150():BlueprintFrame150|null{return current150?.frame||null}
export function registerEnterReady150(handler:()=>void):()=>void{
  activeReady150=handler
  return ()=>{if(activeReady150===handler)activeReady150=null}
}
export function notifyEnterReady150(){
  if(readySent150)return
  readySent150=true
  try {activeReady150?.()} catch {/* UI fade is optional */}
}
export function registerExit150(handler:(done:()=>void)=>void):()=>void{
  activeExit150=handler
  return ()=>{if(activeExit150===handler)activeExit150=null}
}
export function requestExit150(finish:()=>void):boolean{
  if(!activeExit150){pending150=null;current150=null;return false}
  if(exitPending150)return true
  exitPending150=true
  let completed=false
  const timeout=window.setTimeout(complete,1100)
  function complete(){if(completed)return;completed=true;window.clearTimeout(timeout);exitPending150=false;finish()}
  try {activeExit150(complete)}catch{complete()}
  return true
}
