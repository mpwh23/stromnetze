import { useEffect, useMemo, useRef } from 'react'
import { createPortal, useFrame, useThree } from '@react-three/fiber'
import * as THREE from 'three'

type Point152 = { x:number; y:number }

/** STROM152_BLUEPRINT_GRID:
 * Architectural coordinates are taken directly from Blueprint (X,Y metres),
 * not from a building-centred grid. A Three.js world Y of zero is the
 * architecturally selected Z=0 datum (update 151).
 *
 * The 150r floor reference is attached beside the *actual* floor meshes.
 * The matrix of this reference gives the real mapping from Blueprint plan
 * coordinates to rendered space, even if a parent group is transformed.
 * This avoids silently assuming a centred or untransformed model.
 *
 * The canonical grid is rendered via a scene portal and therefore cannot
 * inherit accidental camera / ghost-floor / per-object transforms.
 */
export default function CanonicalGrid152({points}:{points:readonly Point152[]}) {
  const scene=useThree(s=>s.scene)
  const group=useRef<THREE.Group>(null)
  const diagnostics=useRef<string>('')
  const scanFrames=useRef(0)
  const half=useMemo(()=>{
    let extent=10
    for(const p of points){
      if(Number.isFinite(p.x)&&Number.isFinite(p.y))extent=Math.max(extent,Math.abs(p.x),Math.abs(p.y))
    }
    return Math.ceil(Math.min(500,extent+10)/5)*5
  },[points])
  const step=half>150?5:1
  const gridGeometry=useMemo(()=>{
    const data:number[]=[]
    for(let n=-half;n<=half;n+=step){
      if(Math.abs(n)<1e-8)continue // Zero is drawn once, with thick explicit X/Y axes.
      data.push(n,-0.018,-half,n,-0.018,half)
      data.push(-half,-0.018,n,half,-0.018,n)
    }
    const result=new THREE.BufferGeometry()
    result.setAttribute('position',new THREE.Float32BufferAttribute(data,3))
    result.computeBoundingSphere()
    return result
  },[half,step])
  useEffect(()=>()=>gridGeometry.dispose(),[gridGeometry])
  useFrame(()=>{
    // Default is identity: Three X = Blueprint X, Three Z = Blueprint Y.
    // Any transformation measured on a REAL floor reference takes priority.
    let marker:THREE.Object3D|null=null
    scene.traverse(obj=>{
      if(marker===null&&obj.name==='strom150r-floor-reference'&&obj.userData?.active150r===true)marker=obj
    })
    const m=marker as THREE.Object3D|null
    if(group.current){
      if(m){
        m.updateWorldMatrix(true,false)
        group.current.matrix.copy(m.matrixWorld)
        // The reference may live on any storey. The 3D coordinate plane,
        // however, always lies on the selected architectural Z=0 datum.
        group.current.matrix.elements[13]=0
        const pos=m.matrixWorld.elements
        const offset=`${pos[12].toFixed(4)} / ${pos[14].toFixed(4)}`
        if(offset!==diagnostics.current){
          diagnostics.current=offset
          if(Math.abs(pos[12])>.001||Math.abs(pos[14])>.001){
            console.info('[Strom 152] Blueprint (0,0) is rendered at world X/Z',offset,
              '(reference matrix from actual 3D floor, not an assumed centre)')
          }
        }
      }else{
        group.current.matrix.identity()
      }
      group.current.matrixWorldNeedsUpdate=true
    }
    // Legacy helper meshes from earlier 3D versions must not paint competing,
    // wrongly centred zero axes. TSX grids are hidden structurally by the patch.
    if(scanFrames.current++<180){
      scene.traverse(obj=>{
        if(obj.type==='GridHelper'||obj.type==='AxesHelper')obj.visible=false
      })
    }
  },-1)
  return createPortal(
    <group name="strom152-blueprint-grid" ref={group} matrixAutoUpdate={false}>
      <lineSegments geometry={gridGeometry} frustumCulled={false}>
        <lineBasicMaterial color="#8798ae" transparent opacity={0.45} toneMapped={false}/>
      </lineSegments>
      {/* Blueprint X=0 (through Y axis) and Y=0 (through X axis); both in real metres. */}
      <mesh name="strom152-x-axis" position={[0,-0.015,0]}>
        <boxGeometry args={[half*2,0.006,0.05]}/>
        <meshBasicMaterial color="#cb5a63" toneMapped={false}/>
      </mesh>
      <mesh name="strom152-y-axis" position={[0,-0.014,0]}>
        <boxGeometry args={[0.05,0.006,half*2]}/>
        <meshBasicMaterial color="#327aaf" toneMapped={false}/>
      </mesh>
      <mesh name="strom152-origin" position={[0,-0.008,0]}>
        <sphereGeometry args={[0.07,12,8]}/>
        <meshBasicMaterial color="#253f68" toneMapped={false}/>
      </mesh>
    </group>,scene,
  )
}
