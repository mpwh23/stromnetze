import {useLayoutEffect,useRef} from 'react'
import {useFrame,useThree} from '@react-three/fiber'
import * as THREE from 'three'
import {consumeEntry150,restoreEntry150,currentFrame150,registerExit150,DURATION150,ENTER_FADE150,notifyEnterReady150} from './cameraTransitions150'
import type {BlueprintFrame150,Enter150} from './cameraTransitions150'

type P150={x:number;y:number}
type Control150={target?:THREE.Vector3;enabled?:boolean;update?:()=>void}
type Pose150={position:THREE.Vector3;rotation:THREE.Quaternion;target:THREE.Vector3;zoom:number}
type Flight150={start:Pose150;end:Pose150;started:number;done?:()=>void;restoreControls?:boolean}
const easing150=(t:number)=>1-Math.pow(1-t,3)
const clamp150=(n:number,a:number,b:number)=>Math.min(b,Math.max(a,n))
// STROM150F_BLUEPRINT_AXES: 2D screen X -> +3D X, 2D screen Y-down -> +3D Z.
const RIGHT150F=new THREE.Vector3(1,0,0)
const UP150F=new THREE.Vector3(0,0,-1)
const BACK150F=new THREE.Vector3(0,1,0)

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
// STROM150H_LANDSCAPE: align the model's long footprint axis horizontally,
// while preserving the 150f orbit freeze, frame loading and easing behavior.
function topBasis150h(points:readonly P150[]):{right:THREE.Vector3;up:THREE.Vector3}{
  let minX=Infinity,maxX=-Infinity,minY=Infinity,maxY=-Infinity
  for(const p of points){
    if(!Number.isFinite(p.x)||!Number.isFinite(p.y))continue
    minX=Math.min(minX,p.x);maxX=Math.max(maxX,p.x)
    minY=Math.min(minY,p.y);maxY=Math.max(maxY,p.y)
  }
  const spanX=Number.isFinite(minX)?maxX-minX:0
  const spanY=Number.isFinite(minY)?maxY-minY:0
  // Rotate only when one axis is decisively longer; square plans stay on the established axes.
  if(spanY>spanX*1.12&&spanY>0.1){
    return {right:new THREE.Vector3(0,0,-1),up:new THREE.Vector3(-1,0,0)}
  }
  return {right:RIGHT150F.clone(),up:UP150F.clone()}
}

function topPose150(camera:THREE.Camera,bounds:ReturnType<typeof planBounds150>,aspect:number,points:readonly P150[]):Pose150{
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
  // Blueprint X/Y maps onto 3D X/Z; the overhead camera is exactly vertical.
  // An explicit orthogonal basis avoids roll at the camera's polar singularity.
  const {right,up}=topBasis150h(points)
  const topView=new THREE.Matrix4().makeBasis(right,up,BACK150F)
  return {position,rotation:new THREE.Quaternion().setFromRotationMatrix(topView),target,zoom:newZoom}
}
function snapshot150(camera:THREE.Camera,control:Control150|null,fallbackTarget:THREE.Vector3):Pose150{
  // STROM150D_CAMERA_FIX: preserve the actual camera quaternion. 150c replaced it
  // with a lookAt built from -Z up, which caused an instantaneous roll on both flights.
  return {position:camera.position.clone(),rotation:camera.quaternion.clone(),
    target:control?.target?.clone()||fallbackTarget.clone(),
    zoom:(camera as THREE.OrthographicCamera).zoom||1}
}

/** Hold the real Blueprint through 3D load; fade 500ms then fly 1500ms. */
export default function CameraFlight150({points}:{points:readonly P150[]}){
  // STROM150J_ACTIVE_RENDER_CAMERA: do not subscribe to a potentially changing camera.
  // Always address the camera actually used by the Canvas renderer.
  // Never subscribe to changing OrbitControls identity: its late registration caused
  // a useLayoutEffect cleanup/re-entry and jumped the camera back to its old angle.
  const getState=useThree(state=>state.get)
  const activeCamera150j=()=>getState().camera
  const size=useThree(state=>state.size)
  const invalidate=useThree(state=>state.invalidate)
  const gl=useThree(state=>state.gl)
  const entryWaitFrames150e=useRef(0) // STROM150E_NO_CONTROLS_WAIT: now counts confirmed WebGL renders
  const frameTick150k=useRef(0)
  const lastAckTick150k=useRef(-1)
  const entryWaiting=useRef(false)
  const queuedEntry=useRef<Enter150|null>(null)
  const flight=useRef<Flight150|null>(null)
  const flightCamera150j=useRef<THREE.Camera|null>(null)
  const initialPose=useRef<Pose150|null>(null)
  const initialControlsEnabled=useRef<boolean|undefined>(undefined)
  const latest=useRef<{points:readonly P150[];aspect:number}>({points,aspect:Math.max(.3,size.width/Math.max(size.height,1))})
  latest.current={points,aspect:Math.max(.3,size.width/Math.max(size.height,1))}
  const controls150=()=>((getState().controls||null) as Control150|null)
  const orbitFrozen150f=useRef<{control:Control150;update?:()=>void;enabled?:boolean}|null>(null)
  const unfreezeOrbit150f=()=>{
    const frozen=orbitFrozen150f.current
    if(!frozen)return
    if(frozen.update)frozen.control.update=frozen.update
    if(frozen.enabled!==undefined)frozen.control.enabled=frozen.enabled
    orbitFrozen150f.current=null
  }
  const freezeOrbit150f=()=>{
    const control=controls150()
    if(!control)return
    if(orbitFrozen150f.current?.control===control)return
    unfreezeOrbit150f()
    const previous={control,update:control.update,enabled:control.enabled}
    orbitFrozen150f.current=previous
    control.enabled=false
    if(control.update){
      try { control.update=()=>{} } catch { /* camera pose is reapplied after controls */ }
    }
  }

  const apply=(pose:Pose150)=>{
    const camera150j=activeCamera150j()
    camera150j.position.copy(pose.position)
    camera150j.quaternion.copy(pose.rotation)
    const controls=controls150()
    if(controls?.target)controls.target.copy(pose.target)
    const ortho=camera150j as THREE.OrthographicCamera
    if(ortho.isOrthographicCamera){ortho.zoom=pose.zoom;ortho.updateProjectionMatrix()}
    camera150j.updateMatrixWorld()
    invalidate()
  }
  // STROM150K_AFTER_RENDER_GATE: only a *rendered* and fully aligned top view may start the fade.
  const confirmRendered150k=(renderedCamera:THREE.Camera)=>{
    if(!entryWaiting.current)return
    const running=flight.current
    if(!running)return
    if(lastAckTick150k.current===frameTick150k.current)return
    const liveCamera=activeCamera150j()
    // Ignore shadow/auxiliary passes, which are rendered with another camera.
    if(renderedCamera!==liveCamera)return
    const qDot=Math.abs(renderedCamera.quaternion.dot(running.start.rotation))
    const cameraOrtho=renderedCamera as THREE.OrthographicCamera
    const zoomAligned=!cameraOrtho.isOrthographicCamera||Math.abs(cameraOrtho.zoom-running.start.zoom)<0.0001
    const aligned=renderedCamera.position.distanceTo(running.start.position)<0.0005 &&
      qDot>0.999999 && zoomAligned
    if(!aligned){entryWaitFrames150e.current=0;return}
    lastAckTick150k.current=frameTick150k.current
    entryWaitFrames150e.current++
    if(entryWaitFrames150e.current>=3){
      entryWaiting.current=false
      running.started=performance.now()+ENTER_FADE150
      notifyEnterReady150()
      invalidate()
    }
  }
  useLayoutEffect(()=>{
    // Consume once per Canvas mount; avoid reinitializing when OrbitControls registers.
    queuedEntry.current=consumeEntry150()
    const unregister=registerExit150((done)=>{
      const controls=controls150()
      const bounds=planBounds150(latest.current.points,currentFrame150())
      const bird=topPose150(activeCamera150j(),bounds,latest.current.aspect,latest.current.points)
      // Reverse starts from the exact displayed quaternion, including any user rotation.
      const current=snapshot150(activeCamera150j(),controls,bird.target)
      flightCamera150j.current=activeCamera150j()
      queuedEntry.current=null
      entryWaiting.current=false
      freezeOrbit150f()
      flight.current={start:current,end:bird,started:performance.now(),done,
        restoreControls:initialControlsEnabled.current}
      invalidate()
    })
    return ()=>{
      unregister()
      unfreezeOrbit150f()
      const controls=controls150()
      if(controls&&initialControlsEnabled.current!==undefined)
        controls.enabled=initialControlsEnabled.current
      // Teardown only: do not reset the camera angle during a normal view switch.
      if(queuedEntry.current)restoreEntry150(queuedEntry.current)
      queuedEntry.current=null
      flight.current=null
      flightCamera150j.current=null
      entryWaiting.current=false
    }
  // Camera and renderer identity are stable for this Canvas; controls can change.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  },[gl,getState])

  useFrame(()=>{
    frameTick150k.current++
    if(queuedEntry.current){
      const controls=controls150()
      // OrbitControls may register late or not exist. Camera flight still begins.
      const incoming=queuedEntry.current
      queuedEntry.current=null
      const original=snapshot150(activeCamera150j(),controls,new THREE.Vector3())
      flightCamera150j.current=activeCamera150j()
      initialPose.current=original
      initialControlsEnabled.current=controls?.enabled
      const bounds=planBounds150(latest.current.points,incoming.frame)
      const bird=topPose150(activeCamera150j(),bounds,latest.current.aspect,latest.current.points)
      freezeOrbit150f()
      apply(bird)
      // Hold the top pose until it has actually been rendered by WebGL.
      entryWaitFrames150e.current=0
      entryWaiting.current=true
      flight.current={start:bird,end:original,started:Number.POSITIVE_INFINITY,
        restoreControls:initialControlsEnabled.current}
      return
    }
    const running=flight.current
    if(!running)return
    // Re-acquire controls if Drei registers them after the first frame.
    freezeOrbit150f()
    const liveCamera150j=activeCamera150j()
    if(flightCamera150j.current!==liveCamera150j){
      entryWaitFrames150e.current=0
      if(entryWaiting.current||performance.now()<running.started){
        const bounds150j=planBounds150(latest.current.points,currentFrame150())
        running.end=snapshot150(liveCamera150j,controls150(),running.end.target)
        running.start=topPose150(liveCamera150j,bounds150j,latest.current.aspect,latest.current.points)
      }
      flightCamera150j.current=liveCamera150j
    }
    if(entryWaiting.current){
      // Keep the spinner and original Blueprint until 3 confirmed painted top frames.
      apply(running.start)
      invalidate()
      return
    }
    if(performance.now()<running.started){
      apply(running.start)
      return
    }
    const t=clamp150((performance.now()-running.started)/DURATION150,0,1)
    const k=easing150(t)
    const a=running.start,b=running.end
    const next:Pose150={position:a.position.clone().lerp(b.position,k),
      rotation:a.rotation.clone().slerp(b.rotation,k),
      target:a.target.clone().lerp(b.target,k),zoom:a.zoom+(b.zoom-a.zoom)*k}
    apply(next)
    if(t>=1){
      apply(b)
      flight.current=null
      if(running.done){
        // Stay disabled until unmount so OrbitControls cannot snap at bird's eye.
        running.done()
      }else{
        const controls=controls150()
        unfreezeOrbit150f()
        if(controls){
          // Reconcile controls at the exact original target/pose on entry completion.
          if(controls.target)controls.target.copy(b.target)
          controls.update?.()
          apply(b)
          controls.enabled=running.restoreControls??true
        }
      }
    }
  })
  return <mesh name="strom150k-render-sentinel" frustumCulled={false} renderOrder={1000000}
    onAfterRender={(_renderer,_scene,renderedCamera)=>confirmRendered150k(renderedCamera)}>
    <planeGeometry args={[0.001,0.001]} />
    <meshBasicMaterial colorWrite={false} depthWrite={false} depthTest={false} />
  </mesh>
}

