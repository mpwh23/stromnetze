/** STROM150_CAMERA_BRIDGE: coordinate view navigation without delaying React rendering. */
export type BlueprintScreen150o={x:number;y:number;ax:number;ay:number;bx:number;by:number}
export type BlueprintFrame150={floorId:string;levelId:string;cx:number;cy:number;widthM:number;heightM:number;screen150o?:BlueprintScreen150o}
export type Mode150='wall'|'threeD'
export type Enter150={mode:Mode150;frame:BlueprintFrame150}
let pending150:Enter150|null=null
let current150:Enter150|null=null
let activeExit150:((done:()=>void)=>void)|null=null
let activeReady150:(()=>void)|null=null
let exitPending150=false
let readySent150=false
// STROM150I_ANALYSIS_5S: temporary diagnostic timings; no camera geometry changes.
export const ENTER_FADE150=5000
export const DURATION150=5000

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
      // STROM150O_PRE_NAV_SNAPSHOT: saved at the click, before the DOM is reparented/reflowed.
      // SVG world units: mToX/Y(m) = 670 + 60*m. getScreenCTM gives CSS screen pixels.
      const pxX=60*Math.hypot(matrix.a,matrix.b)
      const pxY=60*Math.hypot(matrix.c,matrix.d)
      if(pxX>2&&pxY>2&&pxX<1000&&pxY<1000&&Math.abs(pxX-pxY)<Math.max(pxX,pxY)*0.07){
        result.screen150o={
          x:670*(matrix.a+matrix.c)+matrix.e,
          y:670*(matrix.b+matrix.d)+matrix.f,
          ax:60*matrix.a,ay:60*matrix.b,
          bx:60*matrix.c,by:60*matrix.d,
        }
      }
      // Freeze the ORIGINAL Blueprint's layout in the overlay: no geometry changes
      // when FloorplanEditor becomes position:absolute during 3D mount.
      const plan=svg.closest('.floorplan-layout') as HTMLElement|null
      const host=plan?.parentElement
      const planRect=plan?.getBoundingClientRect()
      const hostRect=host?.getBoundingClientRect()
      if(plan&&planRect&&hostRect&&planRect.width>50&&planRect.height>50){
        plan.style.setProperty('--strom150o-left',`${planRect.left-hostRect.left}px`)
        plan.style.setProperty('--strom150o-top',`${planRect.top-hostRect.top}px`)
        plan.style.setProperty('--strom150o-width',`${planRect.width}px`)
        plan.style.setProperty('--strom150o-height',`${planRect.height}px`)
        plan.classList.add('strom150o-viewport-frozen')
      }

      const center=svg.createSVGPoint();center.x=rect.left+rect.width/2;center.y=rect.top+rect.height/2
      const p=center.matrixTransform(matrix.inverse())
      result.cx=(p.x-670)/60;result.cy=(p.y-670)/60
      const pxPerUnit=Math.hypot(matrix.a,matrix.b)
      if(pxPerUnit>1e-5){result.widthM=rect.width/(60*pxPerUnit);result.heightM=rect.height/(60*pxPerUnit)}
    }
  }catch{/* fallback to model-room geometry if no live SVG was found */}
  return result
}
// STROM150P_BLUEPRINT_EXTENTS: CSS-pixel positions of the actual rendered room polygons,
// sampled at the click BEFORE the Blueprint gets moved, faded or unmounted.
type Bounds150p = { minX:number;maxX:number;minY:number;maxY:number;count:number }
function measureVisibleRooms150p(svg:SVGSVGElement,includeGhost:boolean):Bounds150p|null{
  const polygons=Array.from(svg.querySelectorAll<SVGPolygonElement>('polygon.room'))
  let minX=Infinity,maxX=-Infinity,minY=Infinity,maxY=-Infinity,count=0
  for(const polygon of polygons){
    if(!includeGhost && polygon.closest('.ghost-layer, .ghost-room-group'))continue
    // Invisible layers and rooms are excluded; no assumption that the whole drawing fits in the viewport.
    if(polygon.closest('[hidden]'))continue
    const transform=polygon.getScreenCTM()
    const vertices=polygon.points
    if(!transform||!vertices||!vertices.numberOfItems)continue
    for(let i=0;i<vertices.numberOfItems;i++){
      const point=vertices.getItem(i)
      const x=transform.a*point.x+transform.c*point.y+transform.e
      const y=transform.b*point.x+transform.d*point.y+transform.f
      if(!Number.isFinite(x)||!Number.isFinite(y))continue
      minX=Math.min(minX,x);maxX=Math.max(maxX,x)
      minY=Math.min(minY,y);maxY=Math.max(maxY,y);count++
    }
  }
  return count?{minX,maxX,minY,maxY,count}:null
}
function collectBlueprintExtents150p(mode:Mode150,floorId:string){
  const svg=document.querySelector('svg[aria-label="Blueprint Editor"]') as SVGSVGElement|null
  if(!svg)return
  const viewport=(svg.closest('.canvas-scroll')||svg.parentElement) as HTMLElement|null
  const workspace=svg.closest('.workspace') as HTMLElement|null
  const viewportRect=viewport?.getBoundingClientRect()
  if(!viewportRect||viewportRect.width<=1||viewportRect.height<=1)return
  const main=measureVisibleRooms150p(svg,false)
  const visibleIncludingGhost=measureVisibleRooms150p(svg,true)
  if(!main&&!visibleIncludingGhost)return
  const round=(v:number)=>Math.round(v*10)/10
  const describe=(bounds:Bounds150p|null,rect:DOMRect|null)=>{
    if(!bounds||!rect)return null
    const xMin=round(bounds.minX-rect.left),xMax=round(bounds.maxX-rect.left)
    const yMin=round(bounds.minY-rect.top),yMax=round(bounds.maxY-rect.top)
    return {
      xMinPx:xMin,xMaxPx:xMax,yMinPx:yMin,yMaxPx:yMax,
      widthPx:round(bounds.maxX-bounds.minX),heightPx:round(bounds.maxY-bounds.minY),
      points:bounds.count,
      outsidePx:{left:round(Math.max(0,-xMin)),right:round(Math.max(0,xMax-rect.width)),
        top:round(Math.max(0,-yMin)),bottom:round(Math.max(0,yMax-rect.height))},
    }
  }
  const active=main||visibleIncludingGhost
  const workspaceRect=workspace?.getBoundingClientRect()||null
  const data={
    version:'150p',phase:'vor Umschalten',mode,floorId,
    measuredAt:new Date().toISOString(),units:'CSS-Pixel',
    viewport:{selector:viewport?.className||'svg parent',screenLeft:round(viewportRect.left),
      screenTop:round(viewportRect.top),width:round(viewportRect.width),height:round(viewportRect.height)},
    drawing:describe(active,viewportRect),
    workspace:workspaceRect?{width:round(workspaceRect.width),height:round(workspaceRect.height),
      drawing:describe(active,workspaceRect)}:null,
    includingGhost:describe(visibleIncludingGhost,viewportRect),
  }
  try{window.localStorage.setItem('strom.camera150p.blueprintExtents',JSON.stringify(data))}catch{/* optional */}
  console.info('[STROM 150p] Blueprint-Koordinaten vor dem Wechsel',data)
  const d=data.drawing
  if(!d)return
  const panelId='strom-150p-viewport-geometry'
  let panel=document.getElementById(panelId)
  if(!panel){
    panel=document.createElement('pre')
    panel.id=panelId
    panel.setAttribute('role','status')
    panel.style.cssText='position:fixed;top:16px;right:16px;z-index:2147483647;pointer-events:none;'
      +'padding:12px 14px;border-radius:8px;background:rgba(18,32,54,.94);color:#fff;'
      +'box-shadow:0 3px 15px rgba(0,0,0,.25);font:12px/1.5 ui-monospace,monospace;'
      +'max-width:430px;white-space:pre-wrap;'
    document.body.appendChild(panel)
  }
  const o=d.outsidePx
  panel.textContent=`Blueprint → ${mode==='wall'?'Wanddetail':'3D-Haus'} · Messung vor Wechsel\n`
    +`Viewport: ${data.viewport.width} × ${data.viewport.height} px\n`
    +`Xmin: ${d.xMinPx} px  | Xmax: ${d.xMaxPx} px\n`
    +`Ymin: ${d.yMinPx} px  | Ymax: ${d.yMaxPx} px\n`
    +`Außerhalb L/R/O/U: ${o.left} / ${o.right} / ${o.top} / ${o.bottom} px\n`
    +`Arbeitsfläche: ${data.workspace?`${data.workspace.width} × ${data.workspace.height} px`:'nicht erfasst'}\n`
    +'Details: Browser-Konsole [STROM 150p]'
}

export function queueEntry150(mode:Mode150,floorId:string){
  try{collectBlueprintExtents150p(mode,floorId)}catch(error){console.warn("[STROM 150p] Viewport-Messung fehlgeschlagen",error)}
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
  const timeout=window.setTimeout(complete,DURATION150+1000)
  function complete(){if(completed)return;completed=true;window.clearTimeout(timeout);exitPending150=false;finish()}
  try {activeExit150(complete)}catch{complete()}
  return true
}
