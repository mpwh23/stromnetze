#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261119_160_rueckflug_ohne_zoomsprung"
MAC_PROJECT_DIR="${MAC_PROJECT_DIR:-/Users/andreasmelcher/_AM/PRIVAT/strom}"
REMOTE_HOST="${REMOTE_HOST:-mpwh@192.168.1.21}"
REMOTE_DEPLOY_DIR="${REMOTE_DEPLOY_DIR:-/home/mpwh/deploy}"
REMOTE_TMP_DIR="${REMOTE_TMP_DIR:-/tmp}"
STAGE_DIR="${STAGE_DIR:-/home/mpwh/strom_stage}"
PROD_DIR="${PROD_DIR:-/home/mpwh/strom}"
WEB_TEST_DIR="${WEB_TEST_DIR:-/var/www/strom-test}"
BACKUP_BASE="${BACKUP_BASE:-/home/mpwh}"
GITHUB_OWNER="mpwh23"
GITHUB_REPO="stromnetze"
GITHUB_BRANCH="main"
GITHUB_ALIAS="github-stromnetze"
GITHUB_REMOTE="git@${GITHUB_ALIAS}:${GITHUB_OWNER}/${GITHUB_REPO}.git"
COMMIT_MESSAGE="Update 160: reverse flight without zoom reset; entry unchanged"
SELF_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
MODE="${1:-}"

# -----------------------------------------------------------------------------
# Mac launcher
# One SSH master connection is opened first. This asks for the Pi password once;
# all following ssh/scp calls reuse the same authenticated connection.
# -----------------------------------------------------------------------------
if [ "$(uname -s)" = "Darwin" ] && [ -z "$MODE" ]; then
  echo "=== $SCRIPT_NAME / Mac ==="
  echo "Startordner:   $MAC_PROJECT_DIR"
  echo "GitHub:        https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}"
  echo "Branch:        $GITHUB_BRANCH"
  echo "Pi:            $REMOTE_HOST"
  echo ""

  [ "$(pwd)" = "$MAC_PROJECT_DIR" ] || {
    echo "FEHLER: Bitte aus $MAC_PROJECT_DIR starten." >&2
    exit 1
  }
  command -v ssh >/dev/null 2>&1 || { echo "FEHLER: ssh fehlt auf dem Mac." >&2; exit 1; }
  command -v scp >/dev/null 2>&1 || { echo "FEHLER: scp fehlt auf dem Mac." >&2; exit 1; }

  SSH_CONTROL_PATH="/tmp/strom-ssh-${UID:-0}-$$"
  SSH_CONTROL_OPTS=(-o ControlMaster=auto -o ControlPath="$SSH_CONTROL_PATH" -o ControlPersist=600)

  close_ssh_master() {
    ssh -o ControlPath="$SSH_CONTROL_PATH" -O exit "$REMOTE_HOST" >/dev/null 2>&1 || true
    rm -f "$SSH_CONTROL_PATH" >/dev/null 2>&1 || true
  }
  trap close_ssh_master EXIT INT TERM

  echo "0) SSH-Verbindung zum Pi aufbauen ..."
  echo "   Das Pi-Passwort wird fuer diesen kompletten Lauf nur einmal abgefragt."
  ssh -M -N -f -o ControlMaster=yes -o ControlPath="$SSH_CONTROL_PATH" -o ControlPersist=600 "$REMOTE_HOST"
  ssh "${SSH_CONTROL_OPTS[@]}" "$REMOTE_HOST" "true" >/dev/null
  echo "   SSH-Masterverbindung steht."

  REMOTE_TMP_SCRIPT="${REMOTE_TMP_DIR}/$(basename "$SELF_PATH")"
  REMOTE_DEPLOY_SCRIPT="${REMOTE_DEPLOY_DIR}/$(basename "$SELF_PATH")"

  echo ""
  echo "1) Temporaere Hilfskopie auf den Pi uebertragen ..."
  echo "   Nur fuer den Git-Push mit dem dort vorhandenen Deploy-Key; noch kein Stage-Deployment."
  scp "${SSH_CONTROL_OPTS[@]}" "$SELF_PATH" "$REMOTE_HOST:$REMOTE_TMP_SCRIPT"

  echo ""
  echo "2) Update 160 im isolierten Git-Checkout bauen und nach GitHub pushen ..."
  ssh -t "${SSH_CONTROL_OPTS[@]}" "$REMOTE_HOST" "chmod +x '$REMOTE_TMP_SCRIPT' && '$REMOTE_TMP_SCRIPT' --git-phase"

  echo ""
  echo "3) Git-Push erfolgreich. Update-Script jetzt nach ~/deploy kopieren ..."
  scp "${SSH_CONTROL_OPTS[@]}" "$SELF_PATH" "$REMOTE_HOST:$REMOTE_DEPLOY_SCRIPT"

  echo ""
  echo "4) Stage-Update auf dem Pi ausfuehren ..."
  ssh -t "${SSH_CONTROL_OPTS[@]}" "$REMOTE_HOST" "rm -f '$REMOTE_TMP_SCRIPT'; chmod +x '$REMOTE_DEPLOY_SCRIPT'; cd '$REMOTE_DEPLOY_DIR'; './$(basename "$SELF_PATH")' --stage-phase"
  exit $?
fi

# -----------------------------------------------------------------------------
# Pi Git phase. Uses the already configured HomePi deploy key:
#   Host github-stromnetze -> /root/.ssh/.../github-stromnetze
# No Mac Git repository and no GitHub CLI are required.
# -----------------------------------------------------------------------------
if [ "$MODE" = "--git-phase" ]; then
  if [ "$(id -u)" -ne 0 ]; then
    exec sudo -H "$SELF_PATH" --git-phase-root
  fi
  MODE="--git-phase-root"
fi

if [ "$MODE" = "--git-phase-root" ]; then
  [ "$(id -u)" -eq 0 ] || { echo "FEHLER: Git-Phase muss als root laufen." >&2; exit 1; }
  [ -d "$STAGE_DIR/frontend/src" ] || { echo "FEHLER: Stage nicht gefunden: $STAGE_DIR" >&2; exit 1; }
  [ -f /root/.ssh/config ] || { echo "FEHLER: /root/.ssh/config fehlt." >&2; exit 1; }
  grep -Eq '^[[:space:]]*Host[[:space:]]+.*github-stromnetze([[:space:]]|$)' /root/.ssh/config || {
    echo "FEHLER: SSH-Alias github-stromnetze fehlt in /root/.ssh/config." >&2
    exit 1
  }

  GIT_TMP="/tmp/${SCRIPT_NAME}_gitrepo_$$"
  GIT_BUILD_BACKUP="/tmp/${SCRIPT_NAME}_gitbackup_$$"
  rm -rf "$GIT_TMP" "$GIT_BUILD_BACKUP"

  cleanup_git_phase() {
    rm -rf "$GIT_TMP" "$GIT_BUILD_BACKUP" 2>/dev/null || true
  }
  trap cleanup_git_phase EXIT

  echo "=== $SCRIPT_NAME / Git-Phase auf Pi ==="
  echo "GitHub Remote: $GITHUB_REMOTE"
  echo "Quelle:        $STAGE_DIR"
  echo ""

  echo "1.1) GitHub-Repository temporaer klonen ..."
  GIT_SSH_COMMAND="ssh -F /root/.ssh/config" git clone --branch "$GITHUB_BRANCH" "$GITHUB_REMOTE" "$GIT_TMP"

  echo "1.2) Aktuellen Stage-Source in das Git-Checkout synchronisieren ..."
  for dir in backend db deploy frontend tools; do
    if [ -d "$STAGE_DIR/$dir" ]; then
      mkdir -p "$GIT_TMP/$dir"
      if [ "$dir" = "frontend" ]; then
        rsync -a --delete --exclude 'node_modules/' --exclude 'dist/' "$STAGE_DIR/$dir/" "$GIT_TMP/$dir/"
      elif [ "$dir" = "deploy" ]; then
        # Git-only Update-Historie nicht durch den Stage-Sync loeschen.
        rsync -a --delete --exclude 'updates/' "$STAGE_DIR/$dir/" "$GIT_TMP/$dir/"
      else
        rsync -a --delete "$STAGE_DIR/$dir/" "$GIT_TMP/$dir/"
      fi
    fi
  done
  for file in .gitignore .env.example Makefile README.md; do
    if [ -f "$STAGE_DIR/$file" ]; then
      cp -a "$STAGE_DIR/$file" "$GIT_TMP/$file"
    fi
  done

  echo "1.3) Update 160 isoliert anwenden, TypeScript/Vite-Build und Tests pruefen ..."
  PATCH_ONLY=1 \
    STAGE_DIR="$GIT_TMP" \
    PROD_DIR="$STAGE_DIR" \
    BACKUP_BASE=/tmp \
    "$SELF_PATH" --stage-phase

  mkdir -p "$GIT_TMP/deploy/updates"
  cp -a "$SELF_PATH" "$GIT_TMP/deploy/updates/$(basename "$SELF_PATH")"
  chmod 755 "$GIT_TMP/deploy/updates/$(basename "$SELF_PATH")"

  # 132f hat durch einen vorhandenen Symlink frontend/node_modules als Git-Eintrag
  # aufnehmen koennen. Ab 132g werden Abhaengigkeiten/Build-Artefakte nie versioniert.
  rm -rf "$GIT_TMP/frontend/node_modules" "$GIT_TMP/frontend/dist"
  git -C "$GIT_TMP" rm -r -f --cached --ignore-unmatch frontend/node_modules frontend/dist >/dev/null 2>&1 || true

  echo "1.4) Source committen ..."
  git -C "$GIT_TMP" config user.name "HomePi Adminpanel"
  git -C "$GIT_TMP" config user.email "homepi-adminpanel@localhost"
  git -C "$GIT_TMP" add -A
  if git -C "$GIT_TMP" diff --cached --quiet; then
    echo "Keine neue Git-Aenderung; pruefe/pushe Branch trotzdem."
  else
    git -C "$GIT_TMP" commit -m "$COMMIT_MESSAGE"
  fi
  git -C "$GIT_TMP" branch -M "$GITHUB_BRANCH"

  echo "1.5) Git-Push ueber HomePi Deploy-Key ..."
  GIT_SSH_COMMAND="ssh -F /root/.ssh/config" git -C "$GIT_TMP" push "$GITHUB_REMOTE" "$GITHUB_BRANCH:$GITHUB_BRANCH"

  echo ""
  echo "Git-Push erfolgreich."
  echo "Commit: $(git -C "$GIT_TMP" rev-parse --short HEAD)"
  exit 0
fi


if [ "$MODE" != "--stage-phase" ]; then
  echo "FEHLER: Unbekannter Modus '$MODE'. Auf dem Mac ohne Parameter starten." >&2
  exit 1
fi


DEPLOY_DIR="$REMOTE_DEPLOY_DIR"
if [ ! -d "$BACKUP_BASE" ]; then BACKUP_BASE="$(dirname "$STAGE_DIR")"; fi
BACKUP_DIR="$BACKUP_BASE/strom_stage_backup_${SCRIPT_NAME}_$(date +%Y%m%d-%H%M%S)"
WORK_DIR="$(mktemp -d "/tmp/${SCRIPT_NAME}_work_$(id -u)_XXXXXX")"
DIAG_LOG="/tmp/${SCRIPT_NAME}_diagnostics_$(date +%Y%m%d-%H%M%S)_$$.log"
run_sudo() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi; }
log() { echo "$@" | tee -a "$DIAG_LOG"; }
fail() { log ""; log "ERROR: $*"; log "Diagnostics: $DIAG_LOG"; if [ -f "$DIAG_LOG" ]; then echo '--- Last diagnostic lines ---'; tail -n 100 "$DIAG_LOG"; fi; exit 1; }
cleanup_work() { [ -n "${WORK_DIR:-}" ] && [ -d "$WORK_DIR" ] && rm -rf -- "$WORK_DIR" || true; }
trap cleanup_work EXIT
node_supported() {
  local major minor patch
  IFS=. read -r major minor patch <<< "${1#v}"
  major="${major:-0}"; minor="${minor:-0}"
  if [ "$major" -eq 20 ] && [ "$minor" -ge 19 ]; then return 0; fi
  if [ "$major" -eq 22 ] && [ "$minor" -ge 12 ]; then return 0; fi
  [ "$major" -gt 22 ]
}
select_node() {
  local candidate version best="" best_v=""
  for candidate in /home/mpwh/.nvm/versions/node/*/bin/node /root/.nvm/versions/node/*/bin/node /usr/local/bin/node /usr/bin/node; do
    [ -x "$candidate" ] || continue
    version="$($candidate -p 'process.versions.node' 2>/dev/null || true)"
    node_supported "$version" || continue
    if [ -z "$best" ] || [ "$(printf '%s\n%s\n' "$best_v" "$version" | sort -V | tail -n 1)" = "$version" ]; then best="$candidate";best_v="$version"; fi
  done
  [ -n "$best" ] || fail "Node >=20.19 or >=22.12 missing"
  export PATH="$(dirname "$best"):$PATH";hash -r 2>/dev/null || true
  log "Node: $best ($best_v), npm: $(npm -v 2>/dev/null || echo missing)"
}


log "=== Update 160: 1 s reverse flight to saved Blueprint pose; NO forward changes ==="
log "Stage: $STAGE_DIR"
log "Diagnostics: $DIAG_LOG"
for file in frontend/src/components/CameraFlight150.tsx frontend/src/components/cameraTransitions150.ts frontend/src/components/cameraBlueprintCenter156.ts; do
  [ -s "$STAGE_DIR/$file" ] || fail "160 required source missing: $file"
done
grep -Fq 'STROM156_BLUEPRINT_CAMERA_CENTER' "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx" ||   fail "160 requires existing forward calibration 156; no changes made."
grep -Fq 'registerExit150' "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx" ||   fail "160 requires existing reverse callback; no changes made."
if grep -Fq 'STROM160_REVERSE_FROM_SAVED_TOP_VIEW' "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx"; then
  fail "160 already installed; no changes made."
fi
select_node
log "1) Backup Stage ..."
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PATCH_ONLY: isolated Git checkout; no Stage backup"
else
  cp -a "$STAGE_DIR" "$BACKUP_DIR" || fail "Stage backup failed"
fi
log "2) Prepare isolated source ..."
rsync -a --exclude='/frontend/node_modules' --exclude='/frontend/dist' --exclude='/.git' \
  "$STAGE_DIR/" "$WORK_DIR/" >>"$DIAG_LOG" 2>&1 || fail "160 source copy failed"
DEPENDENCIES=""
for candidate in "$STAGE_DIR/frontend/node_modules" "$PROD_DIR/frontend/node_modules" /home/mpwh/strom_stage/frontend/node_modules; do
  if [ -f "$candidate/typescript/lib/typescript.js" ] && [ -d "$candidate/vite" ] && \
     [ -d "$candidate/three" ] && [ -d "$candidate/@react-three/fiber" ]; then
    DEPENDENCIES="$candidate";break
  fi
done
[ -n "$DEPENDENCIES" ] || fail "160 TypeScript/Vite/Three dependencies unavailable"
ln -s "$DEPENDENCIES" "$WORK_DIR/frontend/node_modules"
RESOURCE_DIR="$WORK_DIR/160_resources"
mkdir -p "$RESOURCE_DIR"
cat > "$RESOURCE_DIR/patch160.py" <<'STROM160_PY'
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
STROM160_PY
cat > "$RESOURCE_DIR/returnFlight160.ts" <<'STROM160_TS'
import type * as THREE from 'three'

/** STROM160_REVERSE_FROM_SAVED_TOP_VIEW
 * Pure interpolation for the reverse camera flight. No camera reset, no
 * recomputation of the Blueprint field of view, no OrbitControls.update().
 */
export type ReturnLens160 = {x: number; y: number; width: number; height: number}
export type ReturnPose160 = {
  position: THREE.Vector3
  rotation: THREE.Quaternion
  target: THREE.Vector3
  up: THREE.Vector3
  zoom: number
}
export function clonePose160(p: ReturnPose160): ReturnPose160 {
  return {
    position: p.position.clone(), rotation: p.rotation.clone(),
    target: p.target.clone(), up: p.up.clone(), zoom: p.zoom,
  }
}
export function easeOut160(t: number): number {
  const clamped = Math.max(0, Math.min(1, t))
  return 1 - (1 - clamped) ** 3
}
export function interpolatePose160(a: ReturnPose160, b: ReturnPose160, k: number): ReturnPose160 {
  const f = Math.max(0, Math.min(1, k))
  return {
    position: a.position.clone().lerp(b.position, f),
    rotation: a.rotation.clone().slerp(b.rotation, f),
    target: a.target.clone().lerp(b.target, f),
    up: a.up.clone().lerp(b.up, f).normalize(),
    zoom: a.zoom + (b.zoom - a.zoom) * f,
  }
}
STROM160_TS
cat > "$RESOURCE_DIR/test160.cjs" <<'STROM160_TEST'
const fs=require('fs'),path=require('path'),assert=require('assert')
const ts=require(process.env.STROM160_TS)
const src=process.env.STROM160_SOURCE
const f=fs.readFileSync(path.join(src,'components/CameraFlight150.tsx'),'utf8')
const h=fs.readFileSync(path.join(src,'components/returnFlight160.ts'),'utf8')
for(const [name,code,kind] of [['CameraFlight150.tsx',f,ts.ScriptKind.TSX],['returnFlight160.ts',h,ts.ScriptKind.TS]]){
 const ast=ts.createSourceFile(name,code,ts.ScriptTarget.Latest,true,kind)
 assert.strictEqual(ast.parseDiagnostics.length,0,name+' '+ast.parseDiagnostics.map(e=>ts.flattenDiagnosticMessageText(e.messageText,' ')).join('; '))
}
for(const marker of ['STROM160_REVERSE_FROM_SAVED_TOP_VIEW','STROM156_BLUEPRINT_CAMERA_CENTER','alignBlueprintCenter156','notifyEnterReady150'])assert(f.includes(marker),marker)
assert(f.includes('reverseRequest160.current')&&f.includes('entryAnchor160.current'))
assert(f.includes('return160.done()'))
assert(f.includes('applyViewOffset156(camera, return160.lens, k160)'))
assert(f.includes('running.kind === \'entry\''),'forward path retained')
// Load the genuine helper's JS (only erased TypeScript imports; no WebGL needed).
const compiled=ts.transpileModule(h,{fileName:'returnFlight160.ts',compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText
const mod={exports:{}};new Function('module','exports','require',compiled)(mod,mod.exports,()=>{throw Error('unexpected module import')})
const {easeOut160,clonePose160,interpolatePose160}=mod.exports
class V{constructor(x=0,y=0,z=0){this.x=x;this.y=y;this.z=z} clone(){return new V(this.x,this.y,this.z)}lerp(b,t){this.x+=(b.x-this.x)*t;this.y+=(b.y-this.y)*t;this.z+=(b.z-this.z)*t;return this}normalize(){const l=Math.hypot(this.x,this.y,this.z)||1;this.x/=l;this.y/=l;this.z/=l;return this}}
class Q {constructor(angle=0){this.angle=angle}clone(){return new Q(this.angle)}slerp(q,k){this.angle+=(q.angle-this.angle)*k;return this}}
const a={position:new V(100,19,0),rotation:new Q(90),up:new V(0,1,0),target:new V(50,0,1),zoom:3}
const b={position:new V(5.96,20,3.849),rotation:new Q(0),up:new V(0,0,-1),target:new V(5.96,0,3.849),zoom:1}
const original=clonePose160(a)
for(const t of [0,.25,.5,.75,1]){
 const k=easeOut160(t),p=interpolatePose160(a,b,k)
 assert(k>=0&&k<=1)
 assert(p.zoom<=3&&p.zoom>=1)
 if(t===0)assert(p.position.x===100&&p.zoom===3)
 if(t===1){assert(Math.abs(p.position.x-b.position.x)<1e-9&&Math.abs(p.position.z-b.position.z)<1e-9&&Math.abs(p.zoom-b.zoom)<1e-9);assert(p.rotation.angle===0)}
}
assert.equal(a.position.x,original.position.x,'no source mutation')
assert.equal(easeOut160(1),1)
console.log('PASS 160: parse, preserved forward markers, non-mutating easing and exact reverse endpoint')
STROM160_TEST
log "3) Apply source patch in isolated tree ..."
python3 -m py_compile "$RESOURCE_DIR/patch160.py" >>"$DIAG_LOG" 2>&1 || fail "160 patch syntax failed"
STROM160_ROOT="$WORK_DIR" python3 "$RESOURCE_DIR/patch160.py" >>"$DIAG_LOG" 2>&1 || \
  fail "160 source mismatch; GitHub and Stage unchanged"
log "4) Full Vite/TypeScript build BEFORE Git push ..."
( cd "$WORK_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || \
  fail "160 Vite/TypeScript build failed; GitHub and Stage unchanged"
log "5) Return-flight regression ..."
STROM160_SOURCE="$WORK_DIR/frontend/src" STROM160_TS="$DEPENDENCIES/typescript" \
  node "$RESOURCE_DIR/test160.cjs" >>"$DIAG_LOG" 2>&1 || \
  fail "160 regression tests failed; GitHub and Stage unchanged"
mkdir -p "$WORK_DIR/deploy/updates" "$WORK_DIR/docs"
cp -a "$RESOURCE_DIR/patch160.py" "$WORK_DIR/deploy/updates/20261119_160_rueckflug_ohne_zoomsprung_patch.py"
cat > "$WORK_DIR/docs/STROM_UPDATE_160.md" <<'STROM160_DOC'
# Stromnetze 160 - reverse flight without zoom jump

The forward transition is untouched: 750 ms cross-fade + 2500 ms flight from the current 159b implementation.

At the forward fade, store the actual rendered top-view camera pose (position,
rotation, up, target, zoom) and 156 camera viewOffset. On reverse, use the current
3D camera pose for the START; interpolate for 1000 ms using ease-out to the
stored top-view END, without invoking `overheadPose`, `alignBlueprintCenter156`
or any other field-of-view recalculation. Hold the exact end pose until the
existing 500 ms reverse Blueprint cross-fade unmounts the 3D Canvas.

The prior exit registration remains available as fallback for a directly opened
3D workspace without a captured Blueprint top view.

This is a reconstructed patch because the prior 160 attachment is unavailable.
It checks markers and builds against the real current Stage source before any
Git push. Production `/strom/` is never changed.
STROM160_DOC
rm -rf "$RESOURCE_DIR"
log "6) Synchronize checked source into Stage ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
  "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "160 Stage transfer failed; backup: $BACKUP_DIR"
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PASS PATCH_ONLY: no web deployment"
  exit 0
fi
log "7) Build Stage and deploy ONLY /strom-test/ ..."
( cd "$STAGE_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || \
  fail "160 Stage build failed; backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "160 frontend/dist missing"
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || \
  fail "160 test deployment failed; backup: $BACKUP_DIR"
log "SUCCESS: 160 deployed at https://home.moja.de/strom-test/"
log "Production /strom/ unchanged. Stage backup: $BACKUP_DIR"
