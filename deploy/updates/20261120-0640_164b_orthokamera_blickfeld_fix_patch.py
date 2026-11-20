#!/usr/bin/env python3
"""Patch 164: one exact Blueprint-grid-to-camera mapping and every-5m grid marks.
Apply only to isolated source. Reject duplicate/unexpected source structure.
"""
from pathlib import Path
import os

root = Path(os.environ['STROM164_ROOT'])/'frontend/src'
flight = root/'components/CameraFlight150.tsx'
grid = root/'components/CanonicalGrid152.tsx'
style = root/'styles.css'
app = root/'App.tsx'
helper = root/'components/cameraGridAnalytic164.ts'
for p in (flight, grid, style, app):
    if not p.is_file():raise RuntimeError('164 required source missing: '+str(p))
if helper.exists():raise RuntimeError('164 already installed: cameraGridAnalytic164.ts')
f=flight.read_text('utf8');g=grid.read_text('utf8');s=style.read_text('utf8');a=app.read_text('utf8')
for marker in ('STROM163_BLUEPRINT_VIEWPORT_TRUTH','STROM162_EXACT_RENDERED_BLUEPRINT_RETURN',
               'STROM150N_NO_END_JUMP'):
    if marker not in f:raise RuntimeError(f'164 camera prerequisite missing: {marker}')
for marker in ('STROM152_BLUEPRINT_GRID','STROM153_3D_AXIS_STYLES'):
    if marker not in g:raise RuntimeError(f'164 grid prerequisite missing: {marker}')
for marker in ('STROM153_AXIS_PIXEL_WIDTH','STROM153_BP_AXIS_STYLES'):
    if marker not in (s+a):raise RuntimeError(f'164 Blueprint prerequisite missing: {marker}')
if 'STROM164_' in f+g+s:raise RuntimeError('164 already applied')

def one(text,old,new,label):
    count=text.count(old)
    if count!=1:raise RuntimeError(f'164 {label}: expected exactly one anchor, found {count}')
    return text.replace(old,new,1)

# Replace only the final late pre-fade camera alignment. Other camera state,
# forward/back times and return lens driver remain untouched.
f=one(f,"import { alignViewportExactly163 } from './cameraViewportExact163' // STROM163_BLUEPRINT_VIEWPORT_TRUTH",
      "import { alignGridAnalytic164 } from './cameraGridAnalytic164' // STROM164_ONE_EXACT_TRANSFORM",'camera import')
f=one(f,'const exact163=alignViewportExactly163(state.scene,camera,state.gl.domElement,',
      'const exact163=alignGridAnalytic164(state.scene,camera,state.gl.domElement,','one pre-fade call')
f=one(f,'        if(exact163)running.viewOffset156=exact163',
      '''        if(!exact163){
          // Retry with current (not guessed) scene/canvas geometry on next frame.
          // Never start a fade using an unverified camera or grid.
          running.preparedFrames += 1
          if(running.preparedFrames<=120)invalidate()
          else if(running.preparedFrames===121)
            console.error('[STROM164] Exact grid alignment unavailable: no unverified fade started')
          return
        }
        running.viewOffset156=exact163''','reject unverified alignment')
if f.count('alignGridAnalytic164(')!=1 or f.count('useFrame(')!=1:
    raise RuntimeError('164 camera has multiple alignments / drivers')

# The 3D grid must cover the actual Blueprint viewport at handoff, not just
# a model bounding box. The same click-time matrix provides its exact corners.
g=one(g,"import * as THREE from 'three'",
      "import * as THREE from 'three'\nimport { currentFrame150 } from './cameraTransitions150' // STROM164_VIEWPORT_GRID_EXTENT",
      'grid viewport import')
g=one(g,'    return Math.ceil(Math.min(500,extent+10)/5)*5\n  },[points])',
'''    // Cover every visible Blueprint corner even when the model is panned away.
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
  },[points])''','grid viewport extent')

# Grid: draw a 1-m minor line AND a 2-CSS-pixel 5-m line. Browser WebGL
# commonly ignores gl.lineWidth>1, so major lines are real flat quads.
g=one(g,'  const step=half>150?5:1\n','  // STROM164_FIVE_METRE_GRID: do not drop the 1-m lines at large zoom ranges.\n', 'old coarse grid step')
g=one(g,'''    for(let n=-half;n<=half;n+=step){
      if(Math.abs(n)<1e-8)continue // Zero is drawn once, with thick explicit X/Y axes.
      data.push(n,-0.018,-half,n,-0.018,half)
      data.push(-half,-0.018,n,half,-0.018,n)
    }''','''    for(let n=-half;n<=half;n+=1){
      if(n===0||n%5===0)continue // 0: colored axes; multiples of 5: major mesh.
      data.push(n,-0.018,-half,n,-0.018,half)
      data.push(-half,-0.018,n,half,-0.018,n)
    }''','1-m minor grid without 5-m overlaps')
g=one(g,'  },[half,step])\n  useEffect(()=>()=>gridGeometry.dispose(),[gridGeometry])', '''  },[half])
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
  const majorScale164=useMemo(()=>new THREE.Vector3(),[])''','major geometries')
g=one(g,'  useFrame(()=>{','  useFrame((state)=>{','3D grid frame callback')
needle='''      group.current.matrixWorldNeedsUpdate=true
    }
    // Legacy helper meshes'''
ins='''      group.current.matrixWorldNeedsUpdate=true
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
    // Legacy helper meshes'''
g=one(g,needle,ins,'5-m screen-space ribbon update')
g=one(g,'''      </lineSegments>
      {/* STROM153_3D_AXIS_STYLES: matched viewport-pixel width, no thick boxes. */}''','''      </lineSegments>
      <primitive object={majorMesh164} />
      {/* STROM153_3D_AXIS_STYLES: matched viewport-pixel width, no thick boxes. */}''','major mesh render')

# Colored zero axes must be on EXACTLY the same physical grid plane as
# the 1-m and 5-m lines; even 5mm of Y parallax breaks a close-up blend.
g=one(g,'x:make([-half,-0.013,0,half,-0.013,0])',
      'x:make([-half,-0.018,0,half,-0.018,0])','X zero-axis grid plane')
g=one(g,'y:make([0,-0.012,-half,0,-0.012,half])',
      'y:make([0,-0.018,-half,0,-0.018,half])','Y zero-axis grid plane')

# Blueprint: minor=1px, every fifth metre=2px, colored 0 axes=1px.
# The preceding 153 stylesheet had erroneously made major lines 1px too.
s+='''
/* STROM164_FIVE_METRE_GRID: identical Blueprint and 3D screen-pixel cadence. */
.floorplan-canvas .grid line { stroke-width:1px !important; vector-effect:non-scaling-stroke; }
.floorplan-canvas .grid line.major:not(.strom153-zero-x):not(.strom153-zero-y) {
  stroke-width:2px !important;
}
.floorplan-canvas .grid line.strom153-zero-x,
.floorplan-canvas .grid line.strom153-zero-y { stroke-width:1px !important; }
'''

helper.write_text(Path(__file__).with_name('cameraGridAnalytic164.ts').read_text('utf8'),'utf8')
flight.write_text(f,'utf8')
grid.write_text(g,'utf8')
style.write_text(s,'utf8')
print('PASS 164: one direct BP-to-rendered-grid transform, all 1-m minor and 5-m thick major lines')
