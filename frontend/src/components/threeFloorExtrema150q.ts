import * as THREE from 'three'

/** STROM150Q_3D_FLOOR_EXTENTS: project the actual active 3D model room-footprint
 * coordinates (X,Z at finished-floor Y=0) using the camera that will render
 * the first frame of the fade. No temporary camera or changed viewport. */
export type FloorPoint150q = {x:number;y:number}
export type Extrema150q = {
  xMinPx:number;xMaxPx:number;yMinPx:number;yMaxPx:number
  widthPx:number;heightPx:number;points:number
  outsidePx:{left:number;right:number;top:number;bottom:number}
}
export type FloorSnapshot150q = {
  version:'150q'; phase:'Beginn der 3D-Blende';measuredAt:string
  units:'CSS-Pixel';reference:string;floorY:number
  viewport:{screenLeft:number;screenTop:number;width:number;height:number}
  canvas:{screenLeft:number;screenTop:number;width:number;height:number}
  floor:Extrema150q; deltaToBlueprint:{xMinPx:number;xMaxPx:number;yMinPx:number;yMaxPx:number}|null
}
type BlueprintReference150q={
  viewport:{screenLeft:number;screenTop:number;width:number;height:number}
  drawing?:{xMinPx:number;xMaxPx:number;yMinPx:number;yMaxPx:number}|null
}
const round150q=(v:number)=>Math.round(v*10)/10

export function captureThreeFloorExtrema150q(
  points:readonly FloorPoint150q[],camera:THREE.Camera,canvas:HTMLCanvasElement,floorY:number,
):FloorSnapshot150q|null{
  let reference:BlueprintReference150q|null=null
  try{
    const raw=window.localStorage.getItem('strom.camera150p.blueprintExtents')
    if(raw)reference=JSON.parse(raw) as BlueprintReference150q
  }catch{/* use canvas as backup reference */}
  const bounds=canvas.getBoundingClientRect()
  if(bounds.width<1||bounds.height<1||!Number.isFinite(bounds.left)||!Number.isFinite(bounds.top))return null
  const bpView=reference?.viewport
  const left=Number.isFinite(bpView?.screenLeft)?bpView!.screenLeft:bounds.left
  const top=Number.isFinite(bpView?.screenTop)?bpView!.screenTop:bounds.top
  const width=Number.isFinite(bpView?.width)&&bpView!.width>0?bpView!.width:bounds.width
  const height=Number.isFinite(bpView?.height)&&bpView!.height>0?bpView!.height:bounds.height
  let xMin=Infinity,xMax=-Infinity,yMin=Infinity,yMax=-Infinity,count=0
  const probe=new THREE.Vector3()
  for(const point of points){
    if(!Number.isFinite(point.x)||!Number.isFinite(point.y))continue
    // Real 3D scene maps Blueprint X/Y to world X/Z; the floor is world Y=0.
    probe.set(point.x,floorY,point.y).project(camera)
    if(!Number.isFinite(probe.x)||!Number.isFinite(probe.y)||!Number.isFinite(probe.z))continue
    const x=bounds.left+(probe.x+1)*bounds.width/2-left
    const y=bounds.top+(1-probe.y)*bounds.height/2-top
    xMin=Math.min(xMin,x);xMax=Math.max(xMax,x)
    yMin=Math.min(yMin,y);yMax=Math.max(yMax,y)
    count++
  }
  if(count===0)return null
  const floor:Extrema150q={
    xMinPx:round150q(xMin),xMaxPx:round150q(xMax),
    yMinPx:round150q(yMin),yMaxPx:round150q(yMax),
    widthPx:round150q(xMax-xMin),heightPx:round150q(yMax-yMin),points:count,
    outsidePx:{left:round150q(Math.max(0,-xMin)),right:round150q(Math.max(0,xMax-width)),
      top:round150q(Math.max(0,-yMin)),bottom:round150q(Math.max(0,yMax-height))},
  }
  const drawing=reference?.drawing
  const deltaToBlueprint=drawing&&[drawing.xMinPx,drawing.xMaxPx,drawing.yMinPx,drawing.yMaxPx].every(Number.isFinite)?{
    xMinPx:round150q(floor.xMinPx-drawing.xMinPx),xMaxPx:round150q(floor.xMaxPx-drawing.xMaxPx),
    yMinPx:round150q(floor.yMinPx-drawing.yMinPx),yMaxPx:round150q(floor.yMaxPx-drawing.yMaxPx),
  }:null
  const result:FloorSnapshot150q={
    version:'150q',phase:'Beginn der 3D-Blende',measuredAt:new Date().toISOString(),units:'CSS-Pixel',
    reference:bpView?'Blueprint-Viewport (0,0)':'3D-Canvas (0,0), BP-Referenz fehlt',floorY,
    viewport:{screenLeft:round150q(left),screenTop:round150q(top),width:round150q(width),height:round150q(height)},
    canvas:{screenLeft:round150q(bounds.left),screenTop:round150q(bounds.top),width:round150q(bounds.width),height:round150q(bounds.height)},
    floor,deltaToBlueprint,
  }
  try{window.localStorage.setItem('strom.camera150q.floorExtents',JSON.stringify(result))}catch{/*optional*/}
  console.info('[STROM 150q] 3D-Bodenfläche bei Beginn der Blende',result)
  const panel=document.getElementById('strom-150p-viewport-geometry')
  if(panel){
    const existing=document.getElementById('strom-150q-floor-values')
    existing?.remove()
    const subsection=document.createElement('span')
    subsection.id='strom-150q-floor-values'
    subsection.style.cssText='display:block;margin-top:8px;color:#78e6f1;font-weight:650;'
    subsection.textContent='3D-Bodenfläche · Blendenbeginn (cyan)\n'
      +`Xmin: ${floor.xMinPx} px  | Xmax: ${floor.xMaxPx} px\n`
      +`Ymin: ${floor.yMinPx} px  | Ymax: ${floor.yMaxPx} px\n`
      +(deltaToBlueprint?`Δ zu BP Xmin/Xmax: ${deltaToBlueprint.xMinPx} / ${deltaToBlueprint.xMaxPx} px\n`
        +`Δ zu BP Ymin/Ymax: ${deltaToBlueprint.yMinPx} / ${deltaToBlueprint.yMaxPx} px\n`:'')
      +`Bodenpunkte: ${count} · Ursprung: ${result.reference}\n`
    // Place colored values directly beneath the existing Blueprint X/Y extrema.
    const node=panel.firstChild
    const raw=node?.textContent||''
    const yRow=raw.indexOf('Ymin: ')
    const rowEnd=yRow>=0?raw.indexOf('\n',yRow):-1
    if(node?.nodeType===3&&typeof (node as Text).splitText==='function'&&rowEnd>=0){
      const following=(node as Text).splitText(rowEnd+1)
      panel.insertBefore(subsection,following)
    }else panel.appendChild(subsection)
  }
  return result
}
