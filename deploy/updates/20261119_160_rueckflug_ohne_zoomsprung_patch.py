#!/usr/bin/env python3
"""STROM160: replace only the reverse transition, preserving entry verbatim.

A source mismatch is fatal: Git & Stage stay unchanged. 157-159b may have
changed the return handler but the stable registerExit150/useFrame interfaces
must remain. This patch is intentionally anchored to the AST-like structure.
"""
from __future__ import annotations
import os,re
from pathlib import Path
root=Path(os.environ['STROM160_ROOT'])/'frontend/src'
flight=root/'components/CameraFlight150.tsx'
helper=root/'components/returnFlight160.ts'
if not flight.is_file():raise RuntimeError('160 missing CameraFlight150.tsx')
s=flight.read_text('utf8')
marker='STROM160_REVERSE_FROM_SAVED_TOP_VIEW'
if marker in s or helper.exists():raise RuntimeError('160 already installed; no changes made')
for token in ('STROM156_BLUEPRINT_CAMERA_CENTER','registerExit150','useFrame','applyViewOffset156', 'const flight = useRef', 'const lock =', 'const get = useThree', 'const invalidate = useThree'):
    if token not in s:raise RuntimeError('160 prerequisite missing: '+token)

def replace_one(old,new,desc):
    global s
    n=s.count(old)
    if n!=1:raise RuntimeError(f'160 {desc}: required exactly once, got {n}')
    s=s.replace(old,new,1)

replace_one("import * as THREE from 'three'", "import * as THREE from 'three'\nimport { clonePose160, interpolatePose160, easeOut160, type ReturnPose160, type ReturnLens160 } from './returnFlight160' // STROM160_REVERSE_FROM_SAVED_TOP_VIEW", 'import')

# New state is confined to the return path; neither entry setup nor timings change.
ref_pattern=re.compile(r'(?m)^(?P<indent>[ \t]*)const flight = useRef<[^\n]+\n')
found=list(ref_pattern.finditer(s))
if len(found)!=1:raise RuntimeError(f'160 flight ref not unique ({len(found)})')
m=found[0]
indent=m.group('indent')
addition=(
    f"{indent}const entryAnchor160 = useRef<{{pose: ReturnPose160; lens: ReturnLens160 | null}} | null>(null)\n"
    f"{indent}const reverseRequest160 = useRef<(() => void) | null>(null)\n"
    f"{indent}const reverse160 = useRef<{{start: ReturnPose160; end: ReturnPose160; lens: ReturnLens160 | null; started: number; done: () => void; closing: boolean}} | null>(null)\n"
)
s=s[:m.end()]+addition+s[m.end():]

# Replace only registered EXIT callback body; leave the prior handler intact as
# fallback for direct 3D loads without a saved Blueprint entry.
p=re.compile(r'\bregisterExit150\s*\(\s*\(?([A-Za-z_$][\w$]*)\)?\s*=>\s*\{')
matches=list(p.finditer(s))
if len(matches)!=1:raise RuntimeError(f'160 exit handler not unique ({len(matches)})')
m=matches[0]
start=m.end()

def closing_brace(src,start):
    depth=1; i=start; mode='code'; quote=''
    while i<len(src):
        ch=src[i];nx=src[i+1] if i+1<len(src) else ''
        if mode=='line':
            if ch=='\n':mode='code'
            i+=1;continue
        if mode=='block':
            if ch=='*' and nx=='/':mode='code';i+=2;continue
            i+=1;continue
        if mode=='string':
            if ch=='\\':i+=2;continue
            if ch==quote:mode='code'
            i+=1;continue
        if ch=='/' and nx=='/':mode='line';i+=2;continue
        if ch=='/' and nx=='*':mode='block';i+=2;continue
        if ch in "'\"`":quote=ch;mode='string';i+=1;continue
        if ch=='{':depth+=1
        if ch=='}':
            depth-=1
            if depth==0:return i
        i+=1
    raise RuntimeError('160 unterminated registerExit150 body')
end=closing_brace(s,start)
old_body=s[start:end].strip('\n')
# Preserve original code as a fallback, with indentation inside else block.
old_indented='\n'.join('      '+line if line.strip() else '' for line in old_body.splitlines())
name=m.group(1)
new_body=(f'\n      // STROM160: use the camera pose actually displayed during forward fade.\n'
          f'      if (entryAnchor160.current) {{\n'
          f'        reverseRequest160.current = {name}\n'
          f'        invalidate()\n'
          f'      }} else {{\n{old_indented}\n      }}\n    ')
s=s[:start]+new_body+s[end:]

# Camera state is read on the SAME render frame as the actual forward top-view,
# before the lens compensator is eased out. That is the exact return endpoint.
frame_pattern=re.compile(r'\buseFrame\s*\(\s*state\s*=>\s*\{\s*\n(?P<indent>[ \t]*)const camera = state\.camera\b[^\n]*\n')
found=list(frame_pattern.finditer(s))
if len(found)!=1:raise RuntimeError(f'160 expected one R3F frame camera ({len(found)})')
m=found[0]
insert=r"""
    // STROM160_REVERSE_FROM_SAVED_TOP_VIEW: remember the *actual* calibrated
    // blueprint pose and its lens offset, not a freshly calculated top view.
    const entry160 = flight.current as unknown as {
      kind?: string; phase?: string; start?: ReturnPose160; viewOffset156?: ReturnLens160
    } | null
    if (!entryAnchor160.current && entry160?.kind === 'entry' &&
        (entry160.phase === 'fade' || entry160.phase === 'flight') && entry160.start) {
      entryAnchor160.current = {
        pose: clonePose160(entry160.start),
        lens: entry160.viewOffset156 ? {...entry160.viewOffset156} : null,
      }
    }

    // The entry path below is unchanged. The reverse driver takes ownership
    // only when the EXIT callback was invoked after a completed entry.
    if (reverseRequest160.current && entryAnchor160.current) {
      const finish160 = reverseRequest160.current
      reverseRequest160.current = null
      const control160 = (get().controls || null) as {target?: THREE.Vector3; enabled?: boolean} | null
      const cam160 = camera as THREE.OrthographicCamera
      const start160: ReturnPose160 = {
        position: camera.position.clone(),
        rotation: camera.quaternion.clone(),
        target: control160?.target?.clone() || new THREE.Vector3(),
        up: camera.up.clone(),
        zoom: Number.isFinite(cam160.zoom) ? cam160.zoom : 1,
      }
      lock()
      reverse160.current = {
        start: start160,
        end: clonePose160(entryAnchor160.current.pose),
        lens: entryAnchor160.current.lens ? {...entryAnchor160.current.lens} : null,
        started: performance.now(),
        done: finish160,
        closing: false,
      }
      // Do not invoke any of the old reverse calibration/reset handlers.
    }
    if (reverse160.current) {
      const return160 = reverse160.current
      const t160 = Math.min(1, Math.max(0, (performance.now() - return160.started) / 1000))
      const k160 = easeOut160(t160)
      const value160 = interpolatePose160(return160.start, return160.end, k160)
      camera.position.copy(value160.position)
      camera.quaternion.copy(value160.rotation)
      camera.up.copy(value160.up)
      const zoomCamera160 = camera as THREE.PerspectiveCamera
      if (typeof zoomCamera160.zoom === 'number') {
        zoomCamera160.zoom = value160.zoom
        zoomCamera160.updateProjectionMatrix()
      }
      const controls160 = (get().controls || null) as {target?: THREE.Vector3; enabled?: boolean} | null
      controls160?.target?.copy(value160.target)
      if (controls160) controls160.enabled = false
      if (return160.lens) applyViewOffset156(camera, return160.lens, k160)
      camera.updateMatrixWorld(true)
      invalidate()
      // Keep the exact top-view (including off-axis projection) throughout
      // the existing 500 ms reverse fade. Finish is signalled once only.
      if (t160 >= 1 && !return160.closing) {
        return160.closing = true
        return160.done()
      }
      return
    }
"""
s=s[:m.end()]+insert+s[m.end():]
# Check no removal of forward execution and required symbols.
for token in ('STROM156_BLUEPRINT_CAMERA_CENTER','alignBlueprintCenter156','notifyEnterReady150','registerExit150'):
    if token not in s:raise RuntimeError('160 lost critical forward marker '+token)
flight.write_text(s,'utf8')
helper.write_text(Path(__file__).with_name('returnFlight160.ts').read_text('utf8'),'utf8')
print('PASS 160: actual stored entry pose drives 1s reverse; no new top view/zoom calibration; entry unchanged')
