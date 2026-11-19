import type { PointM, Room } from '../types'
import type { RoofSlope148 } from './roofSlopes148'
import { dragRoofLine149 } from './levelGeometry149'

// STROM149E_ROOF_SNAP: same 0.18 m proximity as the Blueprint room snapping.
const THRESHOLD149E = 0.18
const rounded149e = (n: number) => Math.round(n*1000)/1000
const point149e = (point: PointM): PointM => ({x:rounded149e(point.x),y:rounded149e(point.y)})

function nearestOnSegment149e(point: PointM,a:PointM,b:PointM):PointM {
  const dx=b.x-a.x,dy=b.y-a.y
  const len=dx*dx+dy*dy
  if (len<1e-12) return a
  const t=Math.max(0,Math.min(1,((point.x-a.x)*dx+(point.y-a.y)*dy)/len))
  return {x:a.x+t*dx,y:a.y+t*dy}
}

/** Single-point snapping to rooms, wall lines, corners and other roof endpoints. */
export function snapRoofPoint149e(point:PointM, rooms:readonly Room[],roofs:readonly RoofSlope148[],ignoreRoofId?:string):PointM {
  let best=point
  let bestD=THRESHOLD149E
  const offer=(p:PointM)=>{
    const distance=Math.hypot(point.x-p.x,point.y-p.y)
    if(distance<bestD-1e-9){bestD=distance;best=p}
  }
  for(const room of rooms){
    const vertices=room.vertices
    for(let i=0;i<vertices.length;i++){
      const a=vertices[i],b=vertices[(i+1)%vertices.length]
      offer(a)
      offer(nearestOnSegment149e(point,a,b))
      // Existing Blueprint walls can snap to matching exterior faces.
      const wall=Math.max(0,room.wallThicknessM||0)
      if(wall>0&&wall<1){
        const dx=b.x-a.x,dy=b.y-a.y,den=Math.hypot(dx,dy)
        if(den>1e-9){
          const normal={x:-dy/den*wall,y:dx/den*wall}
          offer(nearestOnSegment149e(point,{x:a.x+normal.x,y:a.y+normal.y},{x:b.x+normal.x,y:b.y+normal.y}))
          offer(nearestOnSegment149e(point,{x:a.x-normal.x,y:a.y-normal.y},{x:b.x-normal.x,y:b.y-normal.y}))
        }
      }
    }
  }
  for(const roof of roofs){
    if(roof.id===ignoreRoofId)continue
    offer(roof.start);offer(roof.end)
    offer(nearestOnSegment149e(point,roof.start,roof.end))
  }
  // Also align individual axes, as for regular room/element handles.
  let x=best.x,y=best.y
  let xD=Math.abs(x-point.x)>1e-9?Math.abs(x-point.x):0.12
  let yD=Math.abs(y-point.y)>1e-9?Math.abs(y-point.y):0.12
  for(const room of rooms)for(const p of room.vertices){
    const dx=Math.abs(p.x-point.x),dy=Math.abs(p.y-point.y)
    if(dx<xD-1e-9){xD=dx;x=p.x}
    if(dy<yD-1e-9){yD=dy;y=p.y}
  }
  for(const roof of roofs){if(roof.id===ignoreRoofId)continue
    for(const p of [roof.start,roof.end]){
      const dx=Math.abs(p.x-point.x),dy=Math.abs(p.y-point.y)
      if(dx<xD-1e-9){xD=dx;x=p.x}
      if(dy<yD-1e-9){yD=dy;y=p.y}
    }
  }
  return point149e({x,y})
}

/** Keep line length when moving; snap the moved endpoints without deforming the roof. */
export function snapRoofDrag149e(
  roof:RoofSlope148,mode:'move'|'start'|'end'|'direction',
  dx:number,dy:number,pointer:PointM,
  rooms:readonly Room[],roofs:readonly RoofSlope148[],shiftKey=false
):RoofSlope148 {
  if(mode==='direction'){
    const center={x:(roof.start.x+roof.end.x)/2,y:(roof.start.y+roof.end.y)/2}
    if(Math.hypot(pointer.x-center.x,pointer.y-center.y)<0.03)return roof
    let angle=(Math.atan2(pointer.y-center.y,pointer.x-center.x)*180/Math.PI+360)%360
    const increment=shiftKey?15:90
    const closest=Math.round(angle/increment)*increment
    if(shiftKey||Math.abs(angle-closest)<4||Math.abs(angle-closest+360)<4||Math.abs(angle-closest-360)<4){angle=closest}
    return {...roof,directionDeg:rounded149e((angle+360)%360)}
  }
  const moved=dragRoofLine149(roof,mode,dx,dy)
  if(mode!=='move'){
    const p=mode==='start'?moved.start:moved.end
    const snapped=snapRoofPoint149e(p,rooms,roofs,roof.id)
    return dragRoofLine149(roof,mode,snapped.x-(mode==='start'?roof.start.x:roof.end.x),snapped.y-(mode==='start'?roof.start.y:roof.end.y))
  }
  let bestShift={x:0,y:0},bestDistance=THRESHOLD149E
  for(const endpoint of [moved.start,moved.end]){
    const snapped=snapRoofPoint149e(endpoint,rooms,roofs,roof.id)
    const d=Math.hypot(snapped.x-endpoint.x,snapped.y-endpoint.y)
    if(d>1e-8&&d<bestDistance){bestDistance=d;bestShift={x:snapped.x-endpoint.x,y:snapped.y-endpoint.y}}
  }
  return {...moved,start:point149e({x:moved.start.x+bestShift.x,y:moved.start.y+bestShift.y}),end:point149e({x:moved.end.x+bestShift.x,y:moved.end.y+bestShift.y})}
}
