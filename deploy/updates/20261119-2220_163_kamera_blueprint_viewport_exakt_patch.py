#!/usr/bin/env python3
"""163: reconstruct camera from the SAME click-time BP viewport and SVG matrix.
Only bridge snapshot and the final start-pose calibration are modified.
"""
from pathlib import Path
import os,re

root=Path(os.environ['STROM163_ROOT'])/'frontend/src'
bridge=root/'components/cameraTransitions150.ts'
flight=root/'components/CameraFlight150.tsx'
helper=root/'components/cameraViewportExact163.ts'
for p in (bridge,flight):
    if not p.is_file(): raise RuntimeError(f'163: required source missing: {p}')
if helper.exists(): raise RuntimeError('163: already installed')
b=bridge.read_text('utf8')
f=flight.read_text('utf8')
for a in ('STROM150O_PRE_NAV_SNAPSHOT','STROM150P_BLUEPRINT_EXTENTS','export type BlueprintFrame150='):
    if a not in b:raise RuntimeError(f'163: snapshot prerequisite missing: {a}')
for a in ('STROM162_EXACT_RENDERED_BLUEPRINT_RETURN','STROM156_BLUEPRINT_CAMERA_CENTER',
          'STROM150N_NO_END_JUMP','running.viewOffset156','notifyEnterReady150()',
          "running.kind === 'entry' && running.phase === 'prepare'"):
    if a not in f:raise RuntimeError(f'163: camera prerequisite missing: {a}')
if 'STROM163_BLUEPRINT_VIEWPORT_TRUTH' in f or 'viewport163' in b:
    raise RuntimeError('163: already installed')

# The viewport and SVG transform MUST come from the same frame/click.
frame_re=re.compile(r'(?m)^(export type BlueprintFrame150=\{)([^\n]*)(\})$')
marks=list(frame_re.finditer(b))
if len(marks)!=1: raise RuntimeError(f'163: expected one BlueprintFrame150 type; found {len(marks)}')
m=marks[0]
if 'screen150o?' not in m.group(2):raise RuntimeError('163: click-time screen matrix unavailable')
b=b[:m.start()]+m.group(1)+m.group(2)+';viewport163?:{left:number;top:number;width:number;height:number}'+m.group(3)+b[m.end():]
anchor='    if(svg&&matrix&&rect&&rect.width>30&&rect.height>30){'
if b.count(anchor)!=1:raise RuntimeError(f'163: click geometry anchor count = {b.count(anchor)}')
b=b.replace(anchor,anchor+'''
      // STROM163_BLUEPRINT_VIEWPORT_TRUTH: one atomic, before-navigation capture.
      // The 3D Canvas can occupy a different rectangle AFTER mounting.
      result.viewport163={left:rect.left,top:rect.top,width:rect.width,height:rect.height}
''',1)

# Inject at the LAST preparatory point immediately before the fade phase;
# this supersedes all earlier 154/156 estimates without changing choreography.
imp="import { alignViewportExactly163 } from './cameraViewportExact163' // STROM163_BLUEPRINT_VIEWPORT_TRUTH"
import_anchor="import { alignBlueprintCenter156,applyViewOffset156,clearViewOffset156,type ViewOffset156 } from './cameraBlueprintCenter156' // STROM156_BLUEPRINT_CAMERA_CENTER"
if f.count(import_anchor)!=1: raise RuntimeError('163: 156 import has unexpected structure')
f=f.replace(import_anchor,import_anchor+'\n'+imp,1)
pat=re.compile(r'(?m)^(?P<indent>[ \t]*)running\.phase\s*=\s*[\'\"]fade[\'\"]\s*;?[ \t]*$')
found=list(pat.finditer(f))
if len(found)!=1:raise RuntimeError(f'163: expected one prepared->fade transition, found {len(found)}')
m=found[0]
indent=m.group('indent')
pre='''// STROM163_BLUEPRINT_VIEWPORT_TRUTH: direct camera over the CURRENT
// Blueprint viewport centre. Override both earlier 154/156 estimates.
// Never recalculate this during the fade or flight.
const exact163=alignViewportExactly163(state.scene,camera,state.gl.domElement,
  running.start,currentFrame150(),pose=>apply(camera,pose))
if(exact163)running.viewOffset156=exact163
'''
insert=''.join(indent+line+'\n' for line in pre.splitlines())
f=f[:m.start()]+insert+f[m.start():]
if len(re.findall(r'\buseFrame\s*\(',f))!=1:raise RuntimeError('163: second camera driver detected')
if f.count('alignViewportExactly163(')!=1:raise RuntimeError('163: multiple viewport fitting calls')
if f.index('alignViewportExactly163(')>f.index("running.phase = 'fade'"):
    raise RuntimeError('163: fit must precede fade')
for required in ['interpolateLens162(camera,returnLens162.current.from,returnLens162.current.to,k)',
                 'returnHold162.current += 1', 'STROM150N_NO_END_JUMP']:
    if required not in f:raise RuntimeError(f'163: missing existing return invariant {required}')
# Write only after all assertions succeed.
new=Path(__file__).with_name('cameraViewportExact163.ts').read_text('utf8')
helper.write_text(new,'utf8')
bridge.write_text(b,'utf8')
flight.write_text(f,'utf8')
print('PASS 163: same-click viewport and SVG matrix; exactly centred vertical 3D camera, height and off-axis pixel registration')
