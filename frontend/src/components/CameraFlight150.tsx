import {useLayoutEffect,useMemo,useRef} from 'react'
import {useFrame,useThree} from '@react-three/fiber'
import * as THREE from 'three'
import {consumeEntry150,restoreEntry150,currentFrame150,registerExit150,DURATION150,ENTER_FADE150,notifyEnterReady150} from './cameraTransitions150'
import type {BlueprintFrame150} from './cameraTransitions150'

type P150={x:number;y:number}
type Control150={target?:THREE.Vector3;enabled?:boolean;update?:()=>void}
type Pose150={position:THREE.Vector3;rotation:THREE.Quaternion;target:THREE.Vector3;zoom:number}
type Flight150={start:Pose150;end:Pose150;started:number;done?:()=>void;restoreControls?:boolean}
const easing150=(t:number)=>1-Math.pow(1-t,3)
const clamp150=(n:number,a:number,b:number)=>Math.min(b,Math.max(a,n))
const UP150=new THREE.Vector3(0,0,-1)

function planBounds150(points:readonly P150[],frame:BlueprintFrame150|null){
  let minX=Infinity,maxX=-Infinity,minY=Infinity,maxY=-Infinity
  for(const p of points){if(!Number.isFinite(p.x)||!Number.isFinite(p.y))continue
    minX=Math.min(minX,p.x);maxX=Math.max(maxX,p.x);minY=Math.min(minY,p.y);maxY=Math.max(maxY,p.y)
  }
  if(!Number.isFinite(minX)){minX=-4;maxX=4;minY=-3;maxY=3}
  const cx=(minX+maxX)/2,cy=(minY+maxY)/2
  const width=Math.max(2,maxX-minX),height=Math.max(2,maxY-minY)
  if(frame&&frame.widthM>0.1&&frame.heightM>0.1&&frame.widthM<150&&frame.heightM<150){
    return {cx:frame.cx,cy:frame.cy,width:frame.widthM,height:frame.heightM}
  }
  return {cx,cy,width:width*1.14,height:height*1.14}
}
function lookQuat150(position:THREE.Vector3,target:THREE.Vector3){
  const view=new THREE.Matrix4().lookAt(position,target,UP150)
  return new THREE.Quaternion().setFromRotationMatrix(view)
}
function snapshot150(camera:THREE.Camera,control:Control150|null,target:THREE.Vector3):Pose150{
  const zoom=(camera as THREE.OrthographicCamera).zoom||1
  const actualTarget=control?.target?.clone()||target.clone()
  const position=camera.position.clone()
  return {position,rotation:lookQuat150(position,actualTarget),target:actualTarget,zoom}
}
function topPose150(camera:THREE.Camera,bounds:ReturnType<typeof planBounds150>,aspect:number):Pose150{
  const target=new THREE.Vector3(bounds.cx,0,bounds.cy)
  const zoom=Math.max(1,(camera as THREE.OrthographicCamera).zoom||1)
  let distance=12
  let newZoom=zoom
  if((camera as THREE.PerspectiveCamera).isPerspectiveCamera){
    const fov=THREE.MathUtils.degToRad((camera as THREE.PerspectiveCamera).fov||45)
    const tangent=Math.max(0.05,Math.tan(fov/2))
    distance=clamp150(Math.max(bounds.height/2/tangent,bounds.width/2/Math.max(0.3,aspect)/tangent),2,500)
  }else if((camera as THREE.OrthographicCamera).isOrthographicCamera){
    const ortho=camera as THREE.OrthographicCamera
    const viewWidth=Math.abs(ortho.right-ortho.left),viewHeight=Math.abs(ortho.top-ortho.bottom)
    newZoom=clamp150(Math.min(viewWidth/bounds.width,viewHeight/bounds.height),0.05,100)
    distance=Math.max(10,bounds.height*2,bounds.width*2)
  }
  const position=new THREE.Vector3(bounds.cx,distance,bounds.cy)
  return {position,rotation:lookQuat150(position,target),target,zoom:newZoom}
}

/** 750ms eased spatial camera motion; entering is held 250ms so the frozen Blueprint can fade into the loaded 3D start pose. */
export default function CameraFlight150({points}:{points:readonly P150[]}){
  const camera=useThree(state=>state.camera)
  const controls=useThree(state=>(state.controls||null) as Control150|null)
  const size=useThree(state=>state.size)
  const invalidate=useThree(state=>state.invalidate)
  const gl=useThree(state=>state.gl)
  const entryRenderFrame=useRef(0)
  const entryWaiting=useRef(false)
  const flight=useRef<Flight150|null>(null)
  const latest=useRef<{points:readonly P150[];aspect:number}>({points,aspect:Math.max(.3,size.width/Math.max(size.height,1))})
  latest.current={points,aspect:Math.max(.3,size.width/Math.max(size.height,1))}
  const fallback=useMemo(()=>new THREE.Vector3(0,0,0),[])

  const apply=(pose:Pose150)=>{
    camera.position.copy(pose.position)
    camera.quaternion.copy(pose.rotation)
    if(controls?.target)controls.target.copy(pose.target)
    const ortho=camera as THREE.OrthographicCamera
    if(ortho.isOrthographicCamera){ortho.zoom=pose.zoom;ortho.updateProjectionMatrix()}
    camera.updateMatrixWorld()
    invalidate()
  }
  useLayoutEffect(()=>{
    const previousControlsEnabled=controls?.enabled
    const original=snapshot150(camera,controls,fallback)
    const incoming=consumeEntry150()
    if(incoming){
      const bounds=planBounds150(latest.current.points,incoming.frame)
      const bird=topPose150(camera,bounds,latest.current.aspect)
      apply(bird)
      // First frame must be painted before Blueprint fades to the start camera pose.
      entryRenderFrame.current=gl.info.render.frame
      entryWaiting.current=true
      flight.current={start:bird,end:original,started:Number.POSITIVE_INFINITY,restoreControls:previousControlsEnabled}
      if(controls)controls.enabled=false
    }
    const unregister=registerExit150((done)=>{
      const bounds=planBounds150(latest.current.points,currentFrame150())
      const bird=topPose150(camera,bounds,latest.current.aspect)
      const current=snapshot150(camera,controls,bird.target)
      entryWaiting.current=false
      flight.current={start:current,end:bird,started:performance.now(),done,restoreControls:previousControlsEnabled}
      if(controls)controls.enabled=false
    })
    return ()=>{
      unregister()
      if(controls&&previousControlsEnabled!==undefined)controls.enabled=previousControlsEnabled
      if(incoming&&flight.current&&!flight.current.done){apply(original);restoreEntry150(incoming)}
      flight.current=null
    }
  // Keep the camera and controls bound to the same Canvas instance.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  },[camera,controls,gl])
  useFrame(()=>{
    const running=flight.current
    if(!running)return
    if(entryWaiting.current){
      // At least one complete R3F / Three.js render happened with the bird's-eye pose.
      if(gl.info.render.frame>entryRenderFrame.current){
        entryWaiting.current=false
        running.started=performance.now()+ENTER_FADE150
        notifyEnterReady150()
      }
      // Needed if the Canvas runs with frameloop='demand'.
      invalidate()
      return
    }
    const t=clamp150((performance.now()-running.started)/DURATION150,0,1)
    const k=easing150(t)
    const a=running.start,b=running.end
    const next:Pose150={position:a.position.clone().lerp(b.position,k),
      rotation:a.rotation.clone().slerp(b.rotation,k),target:a.target.clone().lerp(b.target,k),zoom:a.zoom+(b.zoom-a.zoom)*k}
    apply(next)
    if(t>=1){
      apply(b)
      flight.current=null
      if(running.done){
        // Reverse: leave OrbitControls disabled until the 3D Canvas unmounts.
        // Updating the controller here would snap the polar angle at the finish.
        running.done()
      }else if(controls){
        controls.enabled=running.restoreControls??true
        controls.update?.()
      }
    }
  })
  return null
}
