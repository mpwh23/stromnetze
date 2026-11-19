#!/usr/bin/env python3
"""STROM 161b: restore 159b forward from the pre-160 Stage backup and
repair reverse in the *existing* single R3F animation loop.

Unlike 161, NEVER assumes a particular const-top/overheadPose expression.
It locates the one verified exit-flight assignment and replaces only its END,
while preserving the entire 157-159b outward path verbatim.

All modifications are done in memory before any source is written.
"""
from __future__ import annotations

import os
import re
from pathlib import Path

stage_root = Path(os.environ['STROM161B_ROOT'])
src = stage_root / 'frontend/src'
flight_path = src / 'components/CameraFlight150.tsx'
helper160 = src / 'components/returnFlight160.ts'
if not flight_path.is_file():
    raise RuntimeError('161b: CameraFlight150.tsx missing')
current = flight_path.read_text(encoding='utf-8')
if 'STROM161B_RETURN_SAVED_CALIBRATED_POSE' in current:
    raise RuntimeError('161b: already installed, no source changed')
if 'STROM160_REVERSE_FROM_SAVED_TOP_VIEW' not in current:
    raise RuntimeError('161b: expected failed 160 in Stage, source unchanged')


def unique_pattern(s: str, pattern: str, purpose: str, flags: int = 0) -> re.Match[str]:
    matches = list(re.finditer(pattern, s, flags))
    if len(matches) != 1:
        raise RuntimeError(f'161b {purpose}: expected one match, got {len(matches)}')
    return matches[0]


def unique_replace(s: str, old: str, new: str, purpose: str) -> str:
    n = s.count(old)
    if n != 1:
        raise RuntimeError(f'161b {purpose}: expected one occurrence, got {n}')
    return s.replace(old, new, 1)


def brace_close(s: str, open_brace: int) -> int:
    """Return matching } index for a { at open_brace in a TS/TSX snippet.

    Supports ordinary strings/comments and nested objects; targeted snippets
    are regular callback/object bodies, not JSX or template substitutions.
    """
    if open_brace >= len(s) or s[open_brace] != '{':
        raise RuntimeError('161b: opening brace not found')
    depth, i, mode, quote = 1, open_brace + 1, 'code', ''
    while i < len(s):
        a = s[i]
        b = s[i + 1] if i + 1 < len(s) else ''
        if mode == 'line':
            if a == '\n': mode = 'code'
            i += 1
            continue
        if mode == 'block':
            if a == '*' and b == '/': mode = 'code'; i += 2; continue
            i += 1
            continue
        if mode == 'string':
            if a == '\\': i += 2; continue
            if a == quote: mode = 'code'
            i += 1
            continue
        if a == '/' and b == '/': mode = 'line'; i += 2; continue
        if a == '/' and b == '*': mode = 'block'; i += 2; continue
        if a in ('\'', '"', '`'):
            quote, mode = a, 'string'; i += 1; continue
        if a == '{': depth += 1
        elif a == '}':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise RuntimeError('161b: callback/object has no matching closing brace')


def pre160_backup() -> Path | None:
    """Prefer the explicitly verified pre-160 backup from the user's Pi log."""
    root = Path(os.environ.get('STROM161B_BACKUP_DIR', '/home/mpwh'))
    prefix = 'strom_stage_backup_20261119_160_rueckflug_ohne_zoomsprung_'
    paths = []
    if root.is_dir():
        paths.extend(root.glob(prefix + '*'))
    preferred = 'strom_stage_backup_20261119_160_rueckflug_ohne_zoomsprung_20261119-203527'
    if (root / preferred).is_dir():
        paths = [root / preferred] + [d for d in sorted(set(paths), key=lambda x: x.name, reverse=True) if d.name != preferred]
    else:
        paths = sorted(set(paths), key=lambda x: x.name, reverse=True)
    for d in paths:
        p = d / 'frontend/src/components/CameraFlight150.tsx'
        if not p.is_file(): continue
        body = p.read_text('utf-8')
        if ('STROM156_BLUEPRINT_CAMERA_CENTER' in body and
            'STROM160_REVERSE_FROM_SAVED_TOP_VIEW' not in body and
            'STROM161B_RETURN_SAVED_CALIBRATED_POSE' not in body):
            return p
    return None


def inverse160(f: str) -> str:
    """Conservative fallback if the 160 predeployment backup was removed.

    This is last resort and validates that all 160 additions were removed.
    """
    f = unique_replace(f,
        "import { clonePose160, interpolatePose160, easeOut160, type ReturnPose160, type ReturnLens160 } from './returnFlight160' // STROM160_REVERSE_FROM_SAVED_TOP_VIEW\n",
        '', 'remove 160 import')
    ref = r'(?m)^[ \t]*const (?:entryAnchor160|reverseRequest160|reverse160) = useRef<[^\n]+\n'
    if len(re.findall(ref, f)) != 3:
        raise RuntimeError('161b: unsafe inverse160: three added refs not found')
    f = re.sub(ref, '', f)
    m = unique_pattern(f,
        r'\bregisterExit150\s*\(\s*\(?[A-Za-z_$][\w$]*\)?\s*=>\s*\{',
        'inverse 160 exit callback')
    a = m.end() - 1
    b = brace_close(f, a)
    old_block = f[a + 1:b]
    start = re.search(
        r'\A\s*// STROM160:.*?\n\s*if\s*\(entryAnchor160\.current\)\s*\{.*?\}\s*else\s*\{\n',
        old_block, re.S)
    if not start:
        raise RuntimeError('161b: inverse160 callback wrapper differs')
    tail = old_block[start.end():]
    if not re.search(r'\n\s*\}\s*$', tail):
        raise RuntimeError('161b: inverse160 callback else branch differs')
    restored = re.sub(r'\n\s*\}\s*$', '', tail)
    restored = '\n'.join(line[6:] if line.startswith('      ') else line
                         for line in restored.splitlines())
    f = f[:a + 1] + '\n' + restored + '\n    ' + f[b:]
    frame_extra = f.find('    // STROM160_REVERSE_FROM_SAVED_TOP_VIEW: remember the *actual* calibrated')
    frame_end = f.find('    const control = orbit()', frame_extra)
    if frame_extra < 0 or frame_end < 0 or frame_end - frame_extra > 8500:
        raise RuntimeError('161b: inverse160 standalone frame driver differs')
    f = f[:frame_extra] + f[frame_end:]
    if 'STROM160' in f or 'reverse160.current' in f:
        raise RuntimeError('161b: incomplete inverse160')
    return f


backup = pre160_backup()
if backup is not None:
    base = backup.read_text(encoding='utf-8')
    print('161b: VERIFIED pre-160 backup used: ' + str(backup))
else:
    base = inverse160(current)
    print('161b: 160 additions reversed from Stage source (no pre-160 backup)')

for anchor in (
    'STROM156_BLUEPRINT_CAMERA_CENTER', 'STROM150N_NO_END_JUMP',
    'const flight = useRef', 'registerExit150', 'notifyEnterReady150',
    'useFrame(state => {', 'viewOffset156', 'alignBlueprintCenter156',
    'clearViewOffset156(camera)', 'const control = orbit()',
):
    if anchor not in base:
        raise RuntimeError('161b: pre-160 source lacks '+anchor)
if 'STROM160' in base:
    raise RuntimeError('161b: restored backup still contains 160 additions')
if len(re.findall(r'\buseFrame\s*\(', base)) != 1:
    raise RuntimeError('161b: camera must have exactly one useFrame driver')

f = base
# 1) A separate immutable snapshot; no alterations to the entry phase logic.
m = unique_pattern(f,
    r'(?m)^(?P<indent>[ \t]*)const flight = useRef<[^\n]+\n',
    'single flight state ref')
added = (m.group('indent') +
    'const savedTop161b = useRef<{pose: CameraPose; lens: ViewOffset156 | null} | null>(null) // STROM161B_RETURN_SAVED_CALIBRATED_POSE\n')
f = f[:m.end()] + added + f[m.end():]

# 2) Record once the exact post-calibration forward pose AND view offset.
# The snapshot is taken during the fade/flight, never the settling phase.
m = unique_pattern(f,
    r'\buseFrame\s*\(\s*state\s*=>\s*\{\s*\n(?P<indent>[ \t]*)const camera = state\.camera\b[^\n]*\n',
    'one frame-camera callback')
snapshot = '''
    // 161b: Save the real calibrated top view. No writes to the entry camera.
    const entering161b = flight.current
    if (!savedTop161b.current && entering161b?.kind === 'entry' &&
        (entering161b.phase === 'fade' || entering161b.phase === 'flight')) {
      const p161b = entering161b.start
      savedTop161b.current = {
        pose: {
          position: p161b.position.clone(), rotation: p161b.rotation.clone(),
          target: p161b.target.clone(), up: p161b.up.clone(), zoom: p161b.zoom,
        },
        lens: entering161b.viewOffset156 ? {...entering161b.viewOffset156} : null,
      }
    }
'''
f = f[:m.end()] + snapshot + f[m.end():]

# 3) A NEW forward handoff clears the prior snapshot. Existing forward code
# is otherwise identical to the restored backup. Inserting directly after the
# guarded entry branch is robust to changes in pending.current assignment form.
frame_marker = unique_pattern(f, r'\buseFrame\s*\(\s*state\s*=>\s*\{', 'frame branch for entry reset')
entry_match = unique_pattern(
    f[frame_marker.start():], r'\bif\s*\(\s*pending\.current\s*\)\s*\{',
    'one new-entry guard in frame')
open_entry = frame_marker.start() + entry_match.end() - 1
f = (f[:open_entry + 1] +
     '\n      savedTop161b.current = null // a NEW Blueprint -> 3D flight' +
     f[open_entry + 1:])

# 4) Do NOT match overheadPose or the name of the local `top` expression.
# The pre-160 Stage backup can have a custom return-setup from 157-159b.
# Instead find the unique existing `flight.current = {...}` exit assignment
# and override its destination AFTER its own setup has finished.
exit_guard = unique_pattern(f,
    r'\bif\s*\(\s*requestedExit\.current\s*\)\s*\{',
    'single reverse request guard')
exit_start = exit_guard.end() - 1
exit_end = brace_close(f, exit_start)
exit_body = f[exit_start + 1:exit_end]
assn = unique_pattern(exit_body,
    r'(?m)^(?P<indent>[ \t]*)flight\.current\s*=\s*\{',
    'exactly one reverse flight assignment')
assign_open = assn.end() - 1
assign_end = brace_close(exit_body, assign_open)
old_assignment = exit_body[assign_open + 1:assign_end]
if not re.search(r'\bkind\s*:\s*[\'\"]exit[\'\"]', old_assignment):
    raise RuntimeError('161b: reverse flight is not an explicit exit flight')
if not re.search(r'\bstart\s*:', old_assignment) or not re.search(r'\bend\s*:', old_assignment):
    raise RuntimeError('161b: reverse flight start/end missing, refusing override')
# Allow an optional semicolon on `flight.current={...};`.
post = assign_end + 1
if post < len(exit_body) and exit_body[post] == ';': post += 1
indent = assn.group('indent')
addition = ("\n" + indent + "// 161b: Override ONLY the exit target with the genuine forward start.\n" +
    indent + "const savedEnd161b = savedTop161b.current\n" +
    indent + "if (savedEnd161b && flight.current?.kind === 'exit') {\n" +
    indent + "  flight.current.end = {\n" +
    indent + "    position: savedEnd161b.pose.position.clone(),\n" +
    indent + "    rotation: savedEnd161b.pose.rotation.clone(),\n" +
    indent + "    target: savedEnd161b.pose.target.clone(),\n" +
    indent + "    up: savedEnd161b.pose.up.clone(), zoom: savedEnd161b.pose.zoom,\n" +
    indent + "  }\n" +
    indent + "  flight.current.viewOffset156 = savedEnd161b.lens ? {...savedEnd161b.lens} : undefined\n" +
    indent + "}\n")
exit_body = exit_body[:post] + addition + exit_body[post:]
f = f[:exit_start + 1] + exit_body + f[exit_end:]

# 5) Change ONLY the exit time divisor. Preserve the forward DURATION150.
# `const t = clamp01(...)` is the only original R3F time interpolation.
time_pattern = (r'(?m)^(?P<indent>[ \t]*)const t\s*=\s*clamp01\s*\(\s*'
                r'\(\s*performance\.now\(\)\s*-\s*running\.startedAt\s*\)\s*/\s*'
                r'(?P<denom>[^\n]+)\)\s*$')
t = unique_pattern(f, time_pattern, 'single camera interpolation clock')
denominator = t.group('denom').strip()
# 159b may spell its exit duration as a constant instead of the literal
# 1000. Normalize ONLY the return branch and leave the original entry
# duration expression intact (including other future entry settings).
entry_denom = denominator
if 'running.kind' in denominator and '?' in denominator and ':' in denominator:
    clean = denominator.strip()
    if clean.startswith('(') and clean.endswith(')'):
        clean = clean[1:-1].strip()
    conditional = re.fullmatch(
        r"running\.kind\s*===\s*['\"](?P<branch>entry|exit)['\"]\s*\?\s*"
        r"(?P<yes>[^:]+?)\s*:\s*(?P<no>.+)", clean)
    if conditional:
        entry_denom = (conditional.group('no') if conditional.group('branch') == 'exit'
                       else conditional.group('yes')).strip()
    elif not re.search(r'\b1000\b', denominator):
        raise RuntimeError('161b: unknown existing reverse timing expression')
    else:
        # Already contains 1000 but is too complex to rewrite safely.
        entry_denom = None
if entry_denom is None:
    new_time = t.group(0)
else:
    new_time = (t.group('indent') +
        'const t = clamp01((performance.now() - running.startedAt) / '
        "(running.kind === 'exit' ? 1000 : " + entry_denom + '))')
f = f[:t.start()] + new_time + f[t.end():]

# 6) In the very same interpolation loop, ramp the original camera-lens
# offset smoothly from 0 to the saved blueprint value on exit.
# The incoming (entry) offset behavior stays EXACTLY unchanged.
apply_site = unique_pattern(f,
    r'(?m)^(?P<indent>[ \t]*)apply\(camera,\s*pose\)\s*$',
    'one interpolated camera apply')
ind = apply_site.group('indent')
reverse_offset = ("\n" + ind +
    "if (running.kind === 'exit' && running.viewOffset156)\n" + ind +
    '  applyViewOffset156(camera, running.viewOffset156, k) '
    '// STROM161B_REVERSE_LENS_TO_SAVED_TOP')
f = f[:apply_site.end()] + reverse_offset + f[apply_site.end():]

if len(re.findall(r'\buseFrame\s*\(', f)) != 1:
    raise RuntimeError('161b: second frame driver detected after patch')
for anchor in (
    'STROM156_BLUEPRINT_CAMERA_CENTER', 'STROM150N_NO_END_JUMP',
    'alignBlueprintCenter156', 'notifyEnterReady150',
    "running.kind === 'entry'", 'clearViewOffset156(camera)',
    'STROM161B_RETURN_SAVED_CALIBRATED_POSE',
    'STROM161B_REVERSE_LENS_TO_SAVED_TOP',
):
    if anchor not in f: raise RuntimeError('161b: forward invariant missing '+anchor)
if 'STROM160' in f or 'reverse160.current' in f:
    raise RuntimeError('161b: legacy 160 driver still present')

baseline_file = os.environ.get('STROM161B_BASELINE_PATH')
if baseline_file:
    Path(baseline_file).write_text(base, encoding='utf-8')
# All potentially failing checks are complete: publish files only now.
flight_path.write_text(f, encoding='utf-8')
if helper160.is_file() and 'STROM160_REVERSE_FROM_SAVED_TOP_VIEW' in helper160.read_text('utf-8'):
    helper160.unlink()
print('PASS 161b: original good forward restored; destination override works without overheadPose; single 1000ms reverse driver')
