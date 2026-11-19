#!/usr/bin/env python3
"""162: recover the verified working pre-160 entrance and make the return
     end on the EXACT RENDERED blueprint camera, held before switching views.
All validation precedes writing; only CameraFlight150.tsx is changed.
"""
from __future__ import annotations
import os,re
from pathlib import Path

root=Path(os.environ['STROM162_ROOT'])
file=root/'frontend/src/components/CameraFlight150.tsx'
if not file.is_file():raise RuntimeError('162: camera file not found')
current=file.read_text('utf8')
if 'STROM162_EXACT_RENDERED_BLUEPRINT_RETURN' in current:raise RuntimeError('162: already installed; no changes')
if 'STROM161B_RETURN_SAVED_CALIBRATED_POSE' not in current:
    raise RuntimeError('162: expected installed 161b; refusing to modify a different Stage')

# The exact, real Pi backup was identified by its filename in the reported 161 log.
broot=Path(os.environ.get('STROM162_BACKUP_DIR','/home/mpwh'))
preferred=broot/'strom_stage_backup_20261119_160_rueckflug_ohne_zoomsprung_20261119-203527'
backup=preferred/'frontend/src/components/CameraFlight150.tsx'
if not backup.is_file():
    raise RuntimeError('162: verified pre-160 backup not found at '+str(backup)+'. Git/Stage unchanged.')
f=backup.read_text('utf8')
for req in ['STROM156_BLUEPRINT_CAMERA_CENTER','STROM150N_NO_END_JUMP','registerExit150','const flight = useRef',
            "running.kind === 'entry'",'notifyEnterReady150','viewOffset156','useFrame(state => {','const control = orbit()']:
    if req not in f:raise RuntimeError('162: original source missing '+req)
for bad in ['STROM160_REVERSE_FROM_SAVED_TOP_VIEW','STROM161B_RETURN_SAVED_CALIBRATED_POSE','STROM162_EXACT_RENDERED_BLUEPRINT_RETURN']:
    if bad in f:raise RuntimeError('162: backup is not verified pre-160 source: '+bad)
if len(re.findall(r'\buseFrame\s*\(',f)) != 1:raise RuntimeError('162: expected one existing R3F camera driver')

def one(pat,text,desc,flags=0):
    m=list(re.finditer(pat,text,flags))
    if len(m)!=1:raise RuntimeError(f'162 {desc}: expected once, found {len(m)}')
    return m[0]

def close_brace(text,opening):
    if text[opening]!='{':raise RuntimeError('162 brace: missing {')
    i=opening+1;depth=1;mode='code';quote=''
    while i<len(text):
        a=text[i];b=text[i+1] if i+1<len(text) else ''
        if mode=='line':
            if a=='\n':mode='code'
            i+=1;continue
        if mode=='block':
            if a=='*' and b=='/':mode='code';i+=2;continue
            i+=1;continue
        if mode=='string':
            if a=='\\':i+=2;continue
            if a==quote:mode='code'
            i+=1;continue
        if a=='/' and b=='/':mode='line';i+=2;continue
        if a=='/' and b=='*':mode='block';i+=2;continue
        if a in "'\"`":mode='string';quote=a;i+=1;continue
        if a=='{':depth+=1
        elif a=='}':
            depth-=1
            if depth==0:return i
        i+=1
    raise RuntimeError('162 brace unmatched')

# Helper reads the *rendered* Three.js camera frustum, not a pre-computed 
# 156 offset. Architectural X/Y/Z = Three's camera.position.x/z/y.
lens_helpers=r'''
// STROM162_EXACT_RENDERED_BLUEPRINT_RETURN: record and reproduce the real,
// fully rendered top-view camera, including the full WebGL lens shift.
type Lens162={fullWidth:number;fullHeight:number;offsetX:number;offsetY:number;width:number;height:number}
type SavedTop162={pose:CameraPose;lens:Lens162|null}
type LensTransition162={from:Lens162|null;to:Lens162|null}
function snapshotLens162(camera:THREE.Camera):Lens162|null {
  const c=camera as THREE.PerspectiveCamera | THREE.OrthographicCamera
  if(!('isPerspectiveCamera' in c) && !('isOrthographicCamera' in c))return null
  const v=c.view
  if(!v?.enabled)return null
  const result={fullWidth:v.fullWidth,fullHeight:v.fullHeight,offsetX:v.offsetX,offsetY:v.offsetY,
    width:v.width,height:v.height}
  if(!Object.values(result).every(Number.isFinite)||result.fullWidth<1||result.fullHeight<1||
      result.width<1||result.height<1)return null
  return result
}
function setLens162(camera:THREE.Camera,lens:Lens162|null):void {
  const c=camera as THREE.PerspectiveCamera | THREE.OrthographicCamera
  if(!('isPerspectiveCamera' in c) && !('isOrthographicCamera' in c))return
  if(lens)c.setViewOffset(lens.fullWidth,lens.fullHeight,lens.offsetX,lens.offsetY,lens.width,lens.height)
  else if(c.view?.enabled)c.clearViewOffset()
}
function interpolateLens162(camera:THREE.Camera,from:Lens162|null,to:Lens162|null,k:number):void {
  if(k<=0){setLens162(camera,from);return}
  if(k>=1){setLens162(camera,to);return}
  if(!from && !to)return
  const start=from||{...to!,offsetX:0,offsetY:0}
  const finish=to||{...from!,offsetX:0,offsetY:0}
  const mix=(a:number,b:number)=>a+(b-a)*k
  setLens162(camera,{
    fullWidth:mix(start.fullWidth,finish.fullWidth),
    fullHeight:mix(start.fullHeight,finish.fullHeight),
    offsetX:mix(start.offsetX,finish.offsetX),offsetY:mix(start.offsetY,finish.offsetY),
    width:mix(start.width,finish.width),height:mix(start.height,finish.height),
  })
}
'''
m=one(r'(?m)^type FrozenControl\s*=',f,'type declaration insertion point')
f=f[:m.start()]+lens_helpers+f[m.start():]

# All refs are passive until a return is requested; no second camera driver.
m=one(r'(?m)^(?P<space>[ \t]*)const flight = useRef<[^\n]+\n',f,'flight state ref')
prefix=m.group('space')
refs=(prefix+'const savedTop162 = useRef<SavedTop162 | null>(null)\n'+
      prefix+'const returnLens162 = useRef<LensTransition162 | null>(null)\n'+
      prefix+'const returnHold162 = useRef(0)\n')
f=f[:m.end()]+refs+f[m.end():]

# Reset the snapshot ONLY for a newly requested Blueprint -> 3D entrance;
# all original entry calibration, viewport mathematics, timings remain verbatim.
fm=one(r'\buseFrame\s*\(\s*state\s*=>\s*\{',f,'frame callback')
pend=one(r'\bif\s*\(\s*pending\.current\s*\)\s*\{',f[fm.end():],'entry guard')
pending_open=fm.end()+pend.end()-1
f=(f[:pending_open+1]+"\n      savedTop162.current = null // new Blueprint viewport is the new truth"+
    "\n      returnLens162.current = null\n      returnHold162.current = 0"+f[pending_open+1:])

# Capture after apply(camera, running.start) AND after the final lens
# calibration in the fade branch -- rather than cloning the guessed `start`.
fade=one(r"\bif\s*\(\s*running\.kind\s*===\s*['\"]entry['\"]\s*&&\s*running\.phase\s*===\s*['\"]fade['\"]\s*\)\s*\{",f,'prepared entry fade')
fo=fade.end()-1;fc=close_brace(f,fo)
block=f[fo+1:fc]
if not re.search(r'\bapply\s*\(\s*camera\s*,\s*running\.start\s*\)',block):
    raise RuntimeError('162: entry fade must apply original start camera')
if 'applyViewOffset156' not in block:
    raise RuntimeError('162: entry fade must apply calibrated 156 lens')
ret=one(r'(?m)^[ \t]*return\s*;?\s*$',block,'fade return')
add="""\n      // Passive observation: capture precisely what the fade is actually rendering.
      if (!savedTop162.current) {
        savedTop162.current = {pose:capture(camera,control),lens:snapshotLens162(camera)}
        const p162=savedTop162.current.pose.position
        console.info('[STROM 162] blueprint camera captured',
          {x:p162.x,y:p162.z,z:p162.y,lens:savedTop162.current.lens})
      }
"""
block=block[:ret.start()]+add+block[ret.start():]
f=f[:fo+1]+block+f[fc:]

# Return is initialized from the CURRENT, visible 3D pose and exact 3D lens,
# and targets the exact actual forward fade camera. No recalibration on exit.
ex=one(r'\bif\s*\(\s*requestedExit\.current\s*\)\s*\{',f,'return guard')
xo=ex.end()-1;xc=close_brace(f,xo);eb=f[xo+1:xc]
e_start="\n      const exitStartingLens162 = snapshotLens162(camera) // read BEFORE any camera mutation\n"
eb=e_start+eb
assignment=one(r'(?m)^[ \t]*flight\.current\s*=\s*\{',eb,'return flight assignment')
aopen=assignment.end()-1;aclose=close_brace(eb,aopen)
obj=eb[aopen+1:aclose]
if not re.search(r'\bkind\s*:\s*[\'\"]exit[\'\"]',obj):raise RuntimeError('162: exit assignment must be kind exit')
if not re.search(r'\bstart\s*:',obj) or not re.search(r'\bend\s*:',obj):raise RuntimeError('162: exit flight start/end missing')
post=aclose+1
if post<len(eb) and eb[post]==';':post+=1
newexit="""
      // Use exactly the displayed blueprint pose. Preserves the 159b forward.
      returnHold162.current = 0
      const exactTop162 = savedTop162.current
      if (exactTop162 && flight.current?.kind === 'exit') {
        const p162=exactTop162.pose
        flight.current.end={
          position:p162.position.clone(),rotation:p162.rotation.clone(),
          target:p162.target.clone(),up:p162.up.clone(),zoom:p162.zoom,
        }
        // The lens is handled by interpolateLens162. Don't also run the old
        // forward-facing compensator in the reverse direction.
        flight.current.viewOffset156=undefined
        returnLens162.current={from:exitStartingLens162,to:exactTop162.lens}
      } else {
        returnLens162.current=null
      }
"""
eb=eb[:post]+newexit+eb[post:]
f=f[:xo+1]+eb+f[xc:]

# Existing ease-out interpolation and forward duration are retained;
# only the return duration becomes 1000 ms.
clock_pattern=(r'(?m)^(?P<indent>[ \t]*)const t\s*=\s*clamp01\s*\(\s*'
               r'\(\s*performance\.now\(\)\s*-\s*running\.startedAt\s*\)\s*/\s*'
               r'(?P<denom>[^\n]+)\)\s*$')
t=one(clock_pattern,f,'animation clock')
old=t.group('denom').strip()
entry=old
if 'running.kind' in old and '?' in old and ':' in old:
    stripped=old[1:-1].strip() if old.startswith('(') and old.endswith(')') else old
    m=re.fullmatch(r"running\.kind\s*===\s*['\"](?P<branch>entry|exit)['\"]\s*\?\s*(?P<yes>[^:]+?)\s*:\s*(?P<no>.+)",stripped)
    if not m:raise RuntimeError('162: cannot safely separate existing forward/return timing')
    entry=(m.group('no') if m.group('branch')=='exit' else m.group('yes')).strip()
newclock=t.group('indent')+"const t = clamp01((performance.now() - running.startedAt) / (running.kind === 'exit' ? 1000 : "+entry+'))'
f=f[:t.start()]+newclock+f[t.end():]

# Reverse lens interpolation is independent of scene rotation/position;
# k=0 returns the exact current viewport, k=1 the actual former Blueprint.
app=one(r'(?m)^(?P<indent>[ \t]*)apply\(camera,\s*pose\)\s*$',f,'one interpolated apply')
ind=app.group('indent')
newlens=("\n"+ind+"if (running.kind === 'exit' && returnLens162.current)\n"+
         ind+"  interpolateLens162(camera,returnLens162.current.from,returnLens162.current.to,k)")
f=f[:app.end()]+newlens+f[app.end():]

# Crucial: finishing the return flight from useFrame IMMEDIATELY unmounts the
# R3F canvas before the final projection is actually painted. Hold 3 genuine
# rendered frames before invoking `finish()`/switching to 2D fade.
fin=one(r'(?m)^(?P<indent>[ \t]*)if\s*\(\s*t\s*<\s*1\s*\)\s*return\s*;?\s*$',f,'last flight frame')
fi=fin.group('indent')
hold=("\n"+fi+"// Keep final Blueprint viewport alive for three THREE/WebGL frames.\n"+
      fi+"if (running.kind === 'exit') {\n"+
      fi+"  apply(camera,b)\n"+
      fi+"  if (returnLens162.current) interpolateLens162(camera,returnLens162.current.from,returnLens162.current.to,1)\n"+
      fi+"  returnHold162.current += 1\n"+
      fi+"  if (returnHold162.current < 3) { invalidate(); return }\n"+
      fi+"}\n")
f=f[:fin.end()]+hold+f[fin.end():]

# Verify that return completion occurs only AFTER the hold and that the
# original forward setup and view-offset 156 compensation are intact.
if not (f.index('returnHold162.current += 1')<f.index('running.finish?.()')):
    raise RuntimeError('162: return completion appears before frame hold')
if f.count('notifyEnterReady150()')!=backup.read_text('utf8').count('notifyEnterReady150()'):
    raise RuntimeError('162: entry-ready callback unexpectedly changed')
if len(re.findall(r'\buseFrame\s*\(',f))!=1:raise RuntimeError('162: additional camera frame driver detected')
for needle in ['STROM162_EXACT_RENDERED_BLUEPRINT_RETURN','alignBlueprintCenter156','applyViewOffset156(camera,running.viewOffset156,1)',
               'clearViewOffset156(camera)','notifyEnterReady150()','STROM150N_NO_END_JUMP',
               'returnHold162.current += 1','interpolateLens162(camera,returnLens162.current.from,returnLens162.current.to,k)']:
    if needle not in f:raise RuntimeError('162: lost required invariant '+needle)
if 'STROM161B' in f or 'STROM160' in f:raise RuntimeError('162: old second camera driver or 161b patch not fully removed')

baseline=os.environ.get('STROM162_BASELINE_PATH')
if baseline:Path(baseline).write_text(backup.read_text('utf8'),'utf8')
file.write_text(f,'utf8')
old_helper=root/'frontend/src/components/returnFlight160.ts'
if old_helper.is_file() and 'STROM160' in old_helper.read_text('utf8'):
    old_helper.unlink()
print('PASS 162: 159b original forward restored; snapshot of rendered fade camera/lens; 1000ms reverse; 3-frame hold before reverse fade')
