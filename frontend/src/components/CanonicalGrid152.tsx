import { useEffect, useMemo, useRef } from 'react'
import { createPortal, useFrame, useThree } from '@react-three/fiber'
import * as THREE from 'three'
import { currentFrame150 } from './cameraTransitions150' // STROM164_VIEWPORT_GRID_EXTENT

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
    // Cover every visible Blueprint corner even when the model is panned away.
    const snap=currentFrame150()
    const s=snap?.screen150o,vr=snap?.viewport163
    if(s&&vr){
      const det=s.ax*s.by-s.ay*s.bx
      if(Number.isFinite(det)&&Math.abs(det)>1e-9){
        for(const px of [vr.left,vr.left+vr.width])for(const py of [vr.top,vr.top+vr.height]){
          const dx=px-s.x,dy=py-s.y
          extent=Math.max(extent,Math.abs((s.by*dx-s.bx*dy)/det),
            Math.abs((-s.ay*dx+s.ax*dy)/det))
        }
      }
    }
    return Math.ceil(Math.min(2000,extent+10)/5)*5
  },[points])
  // STROM164_FIVE_METRE_GRID: do not drop the 1-m lines at large zoom ranges.
  const gridGeometry=useMemo(()=>{
    const data:number[]=[]
    for(let n=-half;n<=half;n+=1){
      if(n===0||n%5===0)continue // 0: colored axes; multiples of 5: major mesh.
      data.push(n,-0.018,-half,n,-0.018,half)
      data.push(-half,-0.018,n,half,-0.018,n)
    }
    const result=new THREE.BufferGeometry()
    result.setAttribute('position',new THREE.Float32BufferAttribute(data,3))
    result.computeBoundingSphere()
    return result
  },[half])
  useEffect(()=>()=>gridGeometry.dispose(),[gridGeometry])
  const majorMarks164=useMemo(()=>{
    const marks:number[]=[]
    for(let n=-half;n<=half;n+=5)if(n!==0)marks.push(n)
    return marks
  },[half])
  const majorMesh164=useMemo(()=>{
    const mesh=new THREE.InstancedMesh(new THREE.PlaneGeometry(1,1),
      new THREE.MeshBasicMaterial({color:'#8798ae',opacity:0.7,transparent:true,
        toneMapped:false,depthWrite:false,side:THREE.DoubleSide}),majorMarks164.length*2)
    mesh.name='strom164-five-metre-lines'
    mesh.frustumCulled=false
    mesh.instanceMatrix.setUsage(THREE.DynamicDrawUsage)
    return mesh
  },[majorMarks164])
  useEffect(()=>()=>{majorMesh164.geometry.dispose();majorMesh164.material.dispose()},[majorMesh164])
  const majorRotation164=useMemo(()=>new THREE.Quaternion().setFromEuler(new THREE.Euler(-Math.PI/2,0,0)),[])
  const majorMatrix164=useMemo(()=>new THREE.Matrix4(),[])
  const majorPosition164=useMemo(()=>new THREE.Vector3(),[])
  const majorScale164=useMemo(()=>new THREE.Vector3(),[])
  // STROM153_3D_AXIS_STYLES: lines are 1 CSS pixel, regardless of camera distance.
  // Red X, green plan Y (Three Z), blue height Z (Three Y).
  const axisGeometry153=useMemo(()=>{
    const make=(coords:number[])=>{
      const geo=new THREE.BufferGeometry()
      geo.setAttribute('position',new THREE.Float32BufferAttribute(coords,3))
      return geo
    }
    const z= Math.max(6,Math.min(20,half))
    return {
      x:make([-half,-0.018,0,half,-0.018,0]),
      y:make([0,-0.018,-half,0,-0.018,half]),
      z:make([0,-z,0,0,z,0]),
    }
  },[half])
  useEffect(()=>()=>Object.values(axisGeometry153).forEach(geometry=>geometry.dispose()),[axisGeometry153])

  useFrame((state)=>{
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
      group.current.updateWorldMatrix(true,false)
      // Major lines keep a 2-CSS-pixel footprint at the fade/top-down view.
      // Unlike WebGL lineWidth, planar instanced meshes work in every browser.
      const rect=state.gl.domElement.getBoundingClientRect()
      const cam=state.camera as THREE.PerspectiveCamera
      const ortho=state.camera as THREE.OrthographicCamera
      const scaleX=Math.hypot(group.current.matrixWorld.elements[0],group.current.matrixWorld.elements[2])
      const scaleY=Math.hypot(group.current.matrixWorld.elements[8],group.current.matrixWorld.elements[10])
      const planeY=new THREE.Vector3(0,-0.018,0).applyMatrix4(group.current.matrixWorld).y
      const distance=Math.abs(state.camera.position.y-planeY)
      let pxPerWorld=0
      if(cam.isPerspectiveCamera && distance>0.001)
        pxPerWorld=rect.height*cam.projectionMatrix.elements[5]/(2*distance)
      else if(ortho.isOrthographicCamera && ortho.top>ortho.bottom)
        pxPerWorld=rect.height*ortho.zoom/(ortho.top-ortho.bottom)
      if(pxPerWorld>0.01 && scaleX>0 && scaleY>0){
        const thicknessX=2/(pxPerWorld*scaleX)
        const thicknessY=2/(pxPerWorld*scaleY)
        let index=0
        for(const n of majorMarks164){
          majorPosition164.set(n,-0.018,0)
          majorScale164.set(thicknessX,half*2,1)
          majorMatrix164.compose(majorPosition164,majorRotation164,majorScale164)
          majorMesh164.setMatrixAt(index++,majorMatrix164)
          majorPosition164.set(0,-0.018,n)
          majorScale164.set(half*2,thicknessY,1)
          majorMatrix164.compose(majorPosition164,majorRotation164,majorScale164)
          majorMesh164.setMatrixAt(index++,majorMatrix164)
        }
        majorMesh164.count=index
        majorMesh164.instanceMatrix.needsUpdate=true
      }
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
      <primitive object={majorMesh164} />
      {/* STROM153_3D_AXIS_STYLES: matched viewport-pixel width, no thick boxes. */}
      <lineSegments name="strom152-x-axis" geometry={axisGeometry153.x} frustumCulled={false}>
        <lineBasicMaterial color="#e14b4b" linewidth={1} toneMapped={false}/>
      </lineSegments>
      <lineSegments name="strom152-y-axis" geometry={axisGeometry153.y} frustumCulled={false}>
        <lineBasicMaterial color="#269e59" linewidth={1} toneMapped={false}/>
      </lineSegments>
      <lineSegments name="strom153-z-axis" geometry={axisGeometry153.z} frustumCulled={false}>
        <lineBasicMaterial color="#3377db" linewidth={1} toneMapped={false}/>
      </lineSegments>
    </group>,scene,
  )
}
