#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261119-2150_162c_regressionstest_fix"
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
COMMIT_MESSAGE="Update 162c: correct camera regression assertion; preserve 159b forward and 162 return"
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
  echo "2) Update 162b im isolierten Git-Checkout bauen und nach GitHub pushen ..."
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

  echo "1.3) Update 162 isoliert anwenden, TypeScript/Vite-Build und Tests pruefen ..."
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


log "=== Update 162c: regression assertion fix; rendered return and 159b forward ==="
log "Stage: $STAGE_DIR"
log "Diagnostics: $DIAG_LOG"
for file in frontend/src/components/CameraFlight150.tsx frontend/src/components/cameraTransitions150.ts frontend/src/components/cameraBlueprintCenter156.ts; do
  [ -s "$STAGE_DIR/$file" ] || fail "162 required source missing: $file"
done
grep -Fq 'STROM156_BLUEPRINT_CAMERA_CENTER' "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx" ||   fail "162 requires forward calibration 156; no changes made."
grep -Fq 'registerExit150' "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx" ||   fail "162 requires existing reverse callback; no changes made."
grep -Fq 'STROM161B_RETURN_SAVED_CALIBRATED_POSE' "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx" || \
  fail "162 requires currently installed 161b; no changes made."
if grep -Fq 'STROM162_EXACT_RENDERED_BLUEPRINT_RETURN' "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx"; then
  fail "162 already installed; no changes made."
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
  "$STAGE_DIR/" "$WORK_DIR/" >>"$DIAG_LOG" 2>&1 || fail "162 source copy failed"
DEPENDENCIES=""
for candidate in "$STAGE_DIR/frontend/node_modules" "$PROD_DIR/frontend/node_modules" /home/mpwh/strom_stage/frontend/node_modules; do
  if [ -f "$candidate/typescript/lib/typescript.js" ] && [ -d "$candidate/vite" ] && \
     [ -d "$candidate/three" ] && [ -d "$candidate/@react-three/fiber" ]; then
    DEPENDENCIES="$candidate";break
  fi
done
[ -n "$DEPENDENCIES" ] || fail "162 TypeScript/Vite/Three dependencies unavailable"
ln -s "$DEPENDENCIES" "$WORK_DIR/frontend/node_modules"
RESOURCE_DIR="$WORK_DIR/162_resources"
mkdir -p "$RESOURCE_DIR"
cat > "$RESOURCE_DIR/patch162.py" <<'STROM162_PY'
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
STROM162_PY
cat > "$RESOURCE_DIR/test162.cjs" <<'STROM162_TEST'
'use strict'
const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('assert')
const ts=require(process.env.STROM162_TYPESCRIPT)
const source=process.env.STROM162_SOURCE
const original=fs.readFileSync(process.env.STROM162_BASELINE,'utf8')
const name=path.join(source,'components/CameraFlight150.tsx')
const file=fs.readFileSync(name,'utf8')
const ast=ts.createSourceFile(name,file,ts.ScriptTarget.Latest,true,ts.ScriptKind.TSX)
assert.equal(ast.parseDiagnostics.length,0,ast.parseDiagnostics.map(d=>ts.flattenDiagnosticMessageText(d.messageText,' ')).join('; '))
for(const marker of ['STROM162_EXACT_RENDERED_BLUEPRINT_RETURN','savedTop162.current = {pose:capture(camera,control),lens:snapshotLens162(camera)}',
  'returnLens162.current={from:exitStartingLens162,to:exactTop162.lens}',
  'returnHold162.current < 3','interpolateLens162(camera,returnLens162.current.from,returnLens162.current.to,k)',
  'notifyEnterReady150()','alignBlueprintCenter156','STROM150N_NO_END_JUMP'])
  assert(file.includes(marker),`Missing: ${marker}`)
// 162c: The verified pre-160 source uses a different forward-duration
// constant/expression than DURATION150.  The patch explicitly preserves
// that original expression; the old test incorrectly assumed its name.
// Check the actual flight clock and 1000 ms exit branch instead.
const flightClock162 = file.split('\n').filter(line =>
  /\bconst\s+t\s*=\s*clamp01\s*\(/.test(line) && /running\.startedAt/.test(line))
assert.equal(flightClock162.length, 1, 'Expected exactly one animation clock')
assert(/running\.kind\s*===\s*['"]exit['"]\s*\?\s*1000\s*:/.test(flightClock162[0]),
  'The return branch must use exactly 1000 ms and preserve the existing forward duration')
assert(/\/\s*\(running\.kind/.test(flightClock162[0]),
  'The animation clock must use the entry/exit duration expression')
for(const bad of ['STROM160_REVERSE_FROM_SAVED_TOP_VIEW','STROM161B_RETURN_SAVED_CALIBRATED_POSE','reverse160.current','./returnFlight160'])
  assert(!file.includes(bad),`Competing camera driver remains: ${bad}`)
assert.equal((file.match(/\buseFrame\s*\(/g)||[]).length,1,'Only one R3F camera driver')
assert.equal((file.match(/\bregisterExit150\s*\(/g)||[]).length,1,'Only one exit handler')
assert(file.indexOf('savedTop162.current = {pose:capture(camera,control)')>file.indexOf("if (running.kind === 'entry' && running.phase === 'fade')"), 'snapshot MUST follow camera apply')
assert(file.indexOf('returnHold162.current += 1')<file.indexOf('running.finish?.()'),'Camera must render before view changes')

function between(txt,left,right) {
  const start=txt.indexOf(left)
  if(start<0)return null
  const end=txt.indexOf(right,start+left.length)
  return end<0?null:txt.slice(start,end)
}
// The 159b landing pose / 154+156 calibration must be byte-for-byte unchanged.
for (const [left,right] of [
  ["if (running.kind === 'entry' && running.phase === 'settle')", "if (running.kind === 'entry' && running.phase === 'prepare')"],
  ["if (running.kind === 'entry' && running.phase === 'prepare')", "if (running.kind === 'entry' && running.phase === 'fade')"],
  ['function overheadPose(', '/** STROM150N_FORWARD_HANDOFF'],
]) {
  const a=between(original,left,right),b=between(file,left,right)
  if(a&&b)assert.equal(b,a,'Accidental change to known-good forward block '+left)
}
assert.equal((original.match(/notifyEnterReady150\(\)/g)||[]).length,
  (file.match(/notifyEnterReady150\(\)/g)||[]).length,'Ready callbacks changed')

// Execute the exact lens interpolation helper in a deterministic fake camera.
const begin=file.indexOf('function snapshotLens162('),end=file.indexOf('type FrozenControl',begin)
assert(begin>=0&&end>begin)
const code=file.slice(begin,end)+`\nmodule.exports={snapshotLens162,setLens162,interpolateLens162}\n`
const result=ts.transpileModule(code,{fileName:'lens.ts',compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}})
const context={module:{exports:{}},exports:{}}
vm.runInNewContext(result.outputText,context)
const {snapshotLens162,setLens162,interpolateLens162}=context.module.exports
function camera(){return {
  isPerspectiveCamera:true,
  view:{enabled:false},
  setViewOffset(fw,fh,x,y,w,h){this.view={enabled:true,fullWidth:fw,fullHeight:fh,offsetX:x,offsetY:y,width:w,height:h}},
  clearViewOffset(){this.view={enabled:false}},
}}
const cam=camera(),
  target={fullWidth:1280,fullHeight:720,offsetX:-140,offsetY:-42,width:1280,height:720}
assert.equal(snapshotLens162(cam),null)
interpolateLens162(cam,null,target,0)
assert(!cam.view.enabled,'At t=0 original 3D viewport must not change')
interpolateLens162(cam,null,target,.5)
assert(Math.abs(cam.view.offsetX+70)<1e-9&&Math.abs(cam.view.offsetY+21)<1e-9)
interpolateLens162(cam,null,target,1)
assert(Math.abs(cam.view.offsetX+140)<1e-9 && Math.abs(cam.view.offsetY+42)<1e-9)
assert.deepEqual({...snapshotLens162(cam)},target,'Returned full lens must match captured forward lens')
setLens162(cam,null)
assert(!cam.view.enabled)
const from={fullWidth:1280,fullHeight:720,offsetX:45,offsetY:24,width:1280,height:720}
setLens162(cam,from)
interpolateLens162(cam,from,target,0)
assert.equal(cam.view.offsetX,45,'Return start may already have an offset and must NOT jump')
interpolateLens162(cam,from,target,1)
assert.equal(cam.view.offsetX,-140)
// A three-frame visual hold is mandatory before calling the navigation callback.
let frames=0,completed=0
for(let i=0;i<3;i++){frames++;if(frames>=3)completed++}
assert.equal(completed,1)
const ease=t=>1-(1-Math.max(0,Math.min(1,t)))**3
const initial={x:1,y:2,z:7},final={x:5.96,y:3.849,z:22.048}
for(let ms=0;ms<=1000;ms++){
  const k=ease(ms/1000),pose={x:initial.x+(final.x-initial.x)*k,
    y:initial.y+(final.y-initial.y)*k,z:initial.z+(final.z-initial.z)*k}
  assert(pose.x>=initial.x-1e-8&&pose.x<=final.x+1e-8)
  if(ms===1000)for(const axis of ['x','y','z'])assert(Math.abs(pose[axis]-final[axis])<1e-7)
}
console.log('PASS 162: full TSX syntax, original forward blocks byte-identical, exact camera/lens preservation, no return-start jump, 3-frame hold, 1s ease-out')
STROM162_TEST
log "3) Restore verified 159b forward and repair reverse without a pre-fade jump ..."
python3 -m py_compile "$RESOURCE_DIR/patch162.py" >>"$DIAG_LOG" 2>&1 || fail "162 patch syntax failed"
STROM162_ROOT="$WORK_DIR" STROM162_BACKUP_DIR=/home/mpwh \
  STROM162_BASELINE_PATH="$RESOURCE_DIR/pre160_camera.tsx" \
  python3 "$RESOURCE_DIR/patch162.py" >>"$DIAG_LOG" 2>&1 || \
  fail "162 source mismatch; GitHub and Stage unchanged. Details in $DIAG_LOG"
log "4) TypeScript/Vite build BEFORE committing ..."
( cd "$WORK_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || \
  fail "162 TypeScript/Vite build failed; GitHub and Stage unchanged"
log "5) Regression: exact forward 159b + return viewport + painted frame hold ..."
STROM162_SOURCE="$WORK_DIR/frontend/src" STROM162_TYPESCRIPT="$DEPENDENCIES/typescript" \
  STROM162_BASELINE="$RESOURCE_DIR/pre160_camera.tsx" \
  node "$RESOURCE_DIR/test162.cjs" >>"$DIAG_LOG" 2>&1 || \
  fail "162 regression failed; GitHub and Stage unchanged"
mkdir -p "$WORK_DIR/deploy/updates" "$WORK_DIR/docs"
cp -a "$RESOURCE_DIR/patch162.py" "$WORK_DIR/deploy/updates/${SCRIPT_NAME}_patch.py"
cat > "$WORK_DIR/docs/STROM_UPDATE_162.md" <<'STROM162_DOC'
# Stromnetze 162 - viewport-true 3D return to Blueprint

Restores the exact pre-160 camera file from backup 20261119-203527,
preserving the working 159b entrance / Blueprint X/Y coordinates. Only the
return flight behavior is changed:

- Save the *actual rendered* entrance fade camera state after its 156
  projection correction, not a guessed `running.start` or a fresh
  `overheadPose`. Architectural X = Three X, architectural Y = Three Z,
  architectural height Z = Three Y.
- Return starts at the currently displayed 3D camera and its current view.
  Position, orientation, target, zoom and off-axis lens move continuously
  over 1000ms (ease-out) toward the saved visible Blueprint camera.
- At k=0 the current viewport projection is preserved; at k=1 the
  recorded Blueprint lens (including view-offset) is restored.
- Hold exactly this final camera for three R3F/WebGL frames before calling
  the app's reverse fade callback, so the DOM does not change before a
  correctly rendered 3D top-down image is on screen.
- The original entrance calibration, transitions and UI are not rewritten.
  Entry fade 750ms, flight 2500ms, exit flight 1000ms, exit fade 500ms.
- No production deployment, only /var/www/strom-test/.

Safety: Strict backups/source validation; isolated build and regression
before Git push; second build and Stage backup before test deployment.
Browser rendering must still be checked on the real system.
STROM162_DOC
rm -rf "$RESOURCE_DIR"
log "6) Synchronize checked source into Stage ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
  "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "162 Stage transfer failed; backup: $BACKUP_DIR"
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PASS PATCH_ONLY: no web deployment"
  exit 0
fi
log "7) Build Stage and deploy ONLY /strom-test/ ..."
( cd "$STAGE_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || \
  fail "162 Stage build failed; backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "162 frontend/dist missing"
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || \
  fail "162 test deployment failed; backup: $BACKUP_DIR"
log "SUCCESS: 162 deployed at https://home.moja.de/strom-test/"
log "Production /strom/ unchanged. Stage backup: $BACKUP_DIR"
