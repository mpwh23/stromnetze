/** STROM150_CAMERA_BRIDGE: coordinate view navigation without delaying React rendering.
 * STROM165_ONE_CAMERA_OWNER: Messung des Blueprints an einer Stelle; alte Diagnosefenster entfernt. */
export type BlueprintScreen150o={x:number;y:number;ax:number;ay:number;bx:number;by:number}
export type BlueprintRect165={left:number;top:number;width:number;height:number}
export type BlueprintFrame150={floorId:string;levelId:string;cx:number;cy:number;widthM:number;heightM:number;screen150o?:BlueprintScreen150o;layout150o?:{left:number;top:number;width:number;height:number};viewport163?:BlueprintRect165}
export type BlueprintMeasure165={screen:BlueprintScreen150o;viewport:BlueprintRect165}
export type Mode150='wall'|'threeD'
export type Enter150={mode:Mode150;frame:BlueprintFrame150}
let pending150:Enter150|null=null
let current150:Enter150|null=null
let activeExit150:((done:()=>void)=>void)|null=null
let activeReady150:(()=>void)|null=null
let activeFailed165:((reason:string)=>void)|null=null
let exitPending150=false
let readySent150=false
// STROM159_TIMINGS: loading remains readiness-driven; milliseconds below.
export const ENTER_FADE150=750
export const DURATION150=2500
/** STROM166_REVERSE_MIRROR: der Rueckweg ist der Hinweg rueckwaerts, doppelt so schnell.
 * Erst Flug (Ease-in) in die Draufsicht, dann Blende zum Blueprint. */
export const EXIT_FLIGHT159=DURATION150/2
/** Rueckblende; die CSS-Dauer in styles.css (STROM166_REVERSE_MIRROR) muss gleich sein. */
export const EXIT_FADE158=ENTER_FADE150/2

function storedLevel150(floorId:string):string{
  try {
    const raw=window.localStorage.getItem(`strom.floorplan.layers.${floorId}.active`)
    const value:unknown=JSON.parse(raw||'null')
    return typeof value==='string'?value:''
  }catch{return ''}
}
function blueprintSvg165():SVGSVGElement|null{
  return document.querySelector('svg[aria-label="Blueprint Editor"]') as SVGSVGElement|null
}
/** STROM165_LIVE_BLUEPRINT: Bildschirmmatrix (CSS-Pixel je Meter) und tatsaechlich sichtbarer
 * Zeichenbereich des Blueprints, so wie er JETZT im Browser steht. Ohne Rollbalken.
 * SVG-Einheiten: mToX/Y(m) = 670 + 60*m. */
export function measureBlueprint165():BlueprintMeasure165|null{
  try {
    const svg=blueprintSvg165()
    const container=(svg?.closest('.canvas-scroll,.canvas-viewport,.canvas-scroll-area')||svg?.parentElement) as HTMLElement|null
    const matrix=svg?.getScreenCTM()
    const rect=container?.getBoundingClientRect()
    if(!svg||!container||!matrix||!rect||rect.width<=30||rect.height<=30)return null
    const pxX=60*Math.hypot(matrix.a,matrix.b)
    const pxY=60*Math.hypot(matrix.c,matrix.d)
    if(!(pxX>2&&pxY>2&&pxX<1000&&pxY<1000))return null
    const width=container.clientWidth>30?container.clientWidth:rect.width
    const height=container.clientHeight>30?container.clientHeight:rect.height
    return {
      screen:{
        x:670*(matrix.a+matrix.c)+matrix.e,
        y:670*(matrix.b+matrix.d)+matrix.f,
        ax:60*matrix.a,ay:60*matrix.b,
        bx:60*matrix.c,by:60*matrix.d,
      },
      viewport:{left:rect.left+container.clientLeft,top:rect.top+container.clientTop,width,height},
    }
  }catch{return null}
}
function viewFrame150(floorId:string):BlueprintFrame150{
  const result:BlueprintFrame150={floorId,levelId:storedLevel150(floorId),cx:0,cy:0,widthM:0,heightM:0}
  try {
    const measured=measureBlueprint165()
    const svg=blueprintSvg165()
    if(svg&&measured){
      // STROM163_BLUEPRINT_VIEWPORT_TRUTH / STROM150O_PRE_NAV_SNAPSHOT: one atomic capture at the click.
      result.viewport163=measured.viewport
      result.screen150o=measured.screen
      // Freeze the ORIGINAL Blueprint's layout in the overlay: no geometry changes
      // when FloorplanEditor becomes position:absolute during 3D mount.
      const plan=svg.closest('.floorplan-layout') as HTMLElement|null
      const host=plan?.parentElement
      const planRect=plan?.getBoundingClientRect()
      const hostRect=host?.getBoundingClientRect()
      if(plan&&planRect&&hostRect&&planRect.width>50&&planRect.height>50){
        result.layout150o={left:planRect.left-hostRect.left,top:planRect.top-hostRect.top,
          width:planRect.width,height:planRect.height}
        plan.style.setProperty('--strom150o-left',`${planRect.left-hostRect.left}px`)
        plan.style.setProperty('--strom150o-top',`${planRect.top-hostRect.top}px`)
        plan.style.setProperty('--strom150o-width',`${planRect.width}px`)
        plan.style.setProperty('--strom150o-height',`${planRect.height}px`)
        plan.classList.add('strom150o-viewport-frozen')
      }
      const s=measured.screen,v=measured.viewport
      const determinant=s.ax*s.by-s.ay*s.bx
      const pixelsPerMetre=Math.hypot(s.ax,s.ay)
      if(Math.abs(determinant)>1e-9&&pixelsPerMetre>1e-5){
        const dx=v.left+v.width/2-s.x,dy=v.top+v.height/2-s.y
        result.cx=(s.by*dx-s.bx*dy)/determinant
        result.cy=(-s.ay*dx+s.ax*dy)/determinant
        result.widthM=v.width/pixelsPerMetre
        result.heightM=v.height/pixelsPerMetre
      }
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
/** STROM165_FAIL_FAST: die 3D-Ansicht meldet einen Abbruch sofort statt nach 30 s Wartezeit. */
export function registerEnterFailed165(handler:(reason:string)=>void):()=>void{
  activeFailed165=handler
  return ()=>{if(activeFailed165===handler)activeFailed165=null}
}
export function notifyEnterFailed165(reason:string){
  if(readySent150)return
  readySent150=true
  try {activeFailed165?.(reason)} catch {/* the 30 s guard in App remains as a second net */}
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
  const timeout=window.setTimeout(complete,EXIT_FLIGHT159+2000)
  function complete(){if(completed)return;completed=true;window.clearTimeout(timeout);exitPending150=false;finish()}
  try {activeExit150(complete)}catch{complete()}
  return true
}
