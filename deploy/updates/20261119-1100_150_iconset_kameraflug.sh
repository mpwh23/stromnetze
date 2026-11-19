#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261119-1100_150_iconset_kameraflug"
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
COMMIT_MESSAGE="Update 150: CAD SVG icon system, matched orthographic approach and 750 ms camera transitions"
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
  echo "2) Update 150 im isolierten Git-Checkout bauen und nach GitHub pushen ..."
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

  # Cleanup of the exact stale root-owned temp directory left by 132f.
  rm -rf /tmp/20260908-1025_132f_strom_wanddetail_node20_buildfix_work 2>/dev/null || true

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

  echo "1.3) Update 150 isoliert anwenden, TypeScript/Vite-Build und Tests pruefen ..."
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

log "=== Update 150: consistent CAD SVG icons and 750 ms physical 3D camera transitions ==="
log "Stage: $STAGE_DIR"
log "Diagnostics: $DIAG_LOG"
for file in frontend/src/App.tsx frontend/src/styles.css frontend/src/components/Building3DWorkspace.tsx \
 frontend/src/building/roofSnap149e.ts frontend/src/components/RoofEditor148.tsx; do
  [ -s "$STAGE_DIR/$file" ] || fail "Required Stage source missing: $file"
done
grep -Fq 'STROM149E_ROOF_SNAP' "$STAGE_DIR/frontend/src/App.tsx" || fail "150 requires deployed 149e"
grep -Fq 'STROM149_CUT_WALL' "$STAGE_DIR/frontend/src/components/Building3DWorkspace.tsx" || fail "150 requires 149c 3D scene"
select_node
log "1) Back up current Stage source ..."
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PATCH_ONLY: isolated Git checkout, no live Stage backup"
else
  cp -a "$STAGE_DIR" "$BACKUP_DIR" || fail "Stage backup failed"
fi
log "2) Prepare isolated working source ..."
rsync -a --exclude='/frontend/node_modules' --exclude='/frontend/dist' --exclude='/.git' "$STAGE_DIR/" "$WORK_DIR/" >>"$DIAG_LOG" 2>&1 || fail "Unable to copy Stage source"
DEPENDENCIES=""
for candidate in "$STAGE_DIR/frontend/node_modules" "$PROD_DIR/frontend/node_modules" /home/mpwh/strom_stage/frontend/node_modules; do
  if [ -f "$candidate/typescript/lib/typescript.js" ] && [ -d "$candidate/vite" ] && [ -d "$candidate/three" ] && [ -d "$candidate/@react-three/fiber" ]; then
    DEPENDENCIES="$candidate"; break
  fi
done
[ -n "$DEPENDENCIES" ] || fail "Missing existing TypeScript, Vite, Three.js or @react-three/fiber dependencies"
ln -s "$DEPENDENCIES" "$WORK_DIR/frontend/node_modules"
RESOURCE_DIR="$WORK_DIR/150_resources"
mkdir -p "$RESOURCE_DIR"
cat > "$RESOURCE_DIR/patch150.py" <<'STROM150_PATCH_PY'
#!/usr/bin/env python3
"""Incremental 150 patch on top of 149e: navigation, active 3D camera, SVG icon vocabulary."""
from pathlib import Path
import os,re
root=Path(os.environ['STROM150_ROOT'])
asset=Path(os.environ['STROM150_ASSETS'])
src=root/'frontend/src'
app=src/'App.tsx'
scene=src/'components/Building3DWorkspace.tsx'
css=src/'styles.css'
for p in (app,scene,css,src/'building/roofSnap149e.ts',src/'components/RoofEditor148.tsx'):
    if not p.is_file():raise RuntimeError(f'150: required source missing: {p}')
a=app.read_text('utf8');s=scene.read_text('utf8');c=css.read_text('utf8')
if 'STROM150_CAMERA_BRIDGE' in a or 'STROM150_CAMERA' in s or 'STROM150_SVG_ICONS' in c:
    raise RuntimeError('150 already applied; refusing double-patch')
if 'STROM149E_ROOF_SNAP' not in a or 'STROM149_CUT_WALL' not in s:
    raise RuntimeError('150 requires deployed 149e on top of 149c')

def one(text,old,new,label):
    n=text.count(old)
    if n!=1:raise RuntimeError(f'150 {label}: expected exactly 1 anchor, found {n}: {old[:70]}')
    return text.replace(old,new,1)

# One outer React app coordinates the transition; 2D remains mounted until reverse flight completes.
if not re.search(r'(?m)^import\s',a):raise RuntimeError('150 App import section missing')
a="import {queueEntry150,requestExit150} from './components/cameraTransitions150' // STROM150_CAMERA_BRIDGE\nimport StromIcon150 from './components/StromIcon150'\n"+a
nav_start=a.find('function handleViewModeClick(')
if nav_start<0:raise RuntimeError('150 App view navigation handler not found')
nav_end=a.find('\n  if (booting)',nav_start)
if nav_end<0 or nav_end-nav_start>7000:raise RuntimeError('150 view navigation handler section not delimitable')
nav=a[nav_start:nav_end]
nav=one(nav,'    if (!canUseViewMode(mode)) return','''    if (!canUseViewMode(mode)) return
    // STROM150_CAMERA_NAV: finish the bird's-eye flyover before unmounting 3D.
    if (mode === 'floorplan' && (viewMode === 'wall' || viewMode === 'threeD')) {
      if (requestExit150(() => setViewMode('floorplan'))) return
    }
    if (viewMode === 'floorplan' && (mode === 'wall' || mode === 'threeD') && floor) {
      queueEntry150(mode, floor.id)
    }''','view-mode navigation guard')
a=a[:nav_start]+nav+a[nav_end:]

# Original navigation icons were text glyphs. Replace their entire helper with real SVGs.
pattern=re.compile(r'(?m)^function viewModeIcon\(mode: ViewMode\)\s*\{[\s\S]*?^\}',re.M)
match=list(pattern.finditer(a))
if len(match)!=1:raise RuntimeError(f'150 expected one viewModeIcon function, found {len(match)}')
a=a[:match[0].start()]+'''function viewModeIcon(mode: ViewMode) {
  if (mode === 'floorplan') return <StromIcon150 name="blueprint" title="Blueprint" />
  if (mode === 'wall') return <StromIcon150 name="wall" title="Wanddetail" />
  if (mode === 'board') return <StromIcon150 name="power" title="Elektrik" />
  return <StromIcon150 name="house" title="3D-Haus" />
}'''+a[match[0].end():]

# The active RoofScope provider is guaranteed by 149c, and is already nested inside
# the R3F <Canvas>.  Mount the rig only there, never in the non-active ghost floor.
needle='<RoofScope149.Provider value={{levelId:activeLevelId148,revision:roofRevision148}}>'
if s.count(needle)!=1:
    # tolerate whitespace in the current source but do not attach to the ghost provider
    pattern=re.compile(r'<RoofScope149\.Provider\s+value=\{\{\s*levelId\s*:\s*activeLevelId148\s*,\s*revision\s*:\s*roofRevision148\s*\}\}\s*>')
    m=list(pattern.finditer(s))
    if len(m)!=1:raise RuntimeError(f'150 active 3D RoofScope provider missing or ambiguous: {len(m)}')
    needle=m[0].group(0)
s=one(s,needle,needle+'''\n            {/* STROM150_CAMERA: model XY = Blueprint XY, floor plane = 3D XZ */}
            <CameraFlight150 points={model.rooms.flatMap(room150 => room150.vertices)} />''','active 3D rig mounting')
# Prefix the self-contained R3F animation module; no existing camera defaults are changed.
s=one(s,"import RoofMeshes148 from './RoofMeshes148'", "import RoofMeshes148 from './RoofMeshes148'\nimport CameraFlight150 from './CameraFlight150'",'3D flight import')
# Mirror the Blueprint active level in the 3D level controller on mount.
# The original selector and manual floor changes remain intact afterwards.
level_state=re.compile(r'(?m)^([ \t]*)const \[\s*activeLevelId148\s*,\s*setActiveLevelId148\s*\]\s*=\s*useState[^\n]*\n')
level_matches=list(level_state.finditer(s))
if len(level_matches)==1:
    m=level_matches[0]
    indent=m.group(1)
    sync=(indent+'// STROM150_LEVEL_SYNC: selected Blueprint storey -> 3D landing level.\n'
       +indent+'useCameraLevelSync150(() => {\n'
       +indent+'  const id150=currentFrame150()?.levelId\n'
       +indent+'  if(id150 && id150!==activeLevelId148) setActiveLevelId148(id150)\n'
       +indent+'}, [floor?.id])\n')
    s=s[:m.end()]+sync+s[m.end():]
    s="import {useEffect as useCameraLevelSync150} from 'react'\nimport {currentFrame150} from './cameraTransitions150'\n"+s
    print('150: Blueprint active level synchronized to 3D level selector')
else:
    print(f'150: 3D selector setter found {len(level_matches)} times; existing active-level persistence left unchanged')

# Make OrbitControls reachable as R3F's state.controls. Do not replace old controls.
controls=re.compile(r'<OrbitControls\b[^>]*>',re.S)
matched=list(controls.finditer(s))
if len(matched)==1 and 'makeDefault' not in matched[0].group(0):
    tag=matched[0].group(0)
    s=s[:matched[0].start()]+tag.replace('<OrbitControls','<OrbitControls makeDefault',1)+s[matched[0].end():]
    print('150: registered existing OrbitControls as default for camera target interpolation')
else:
    print(f'150: OrbitControls tags found={len(matched)}; existing camera controls retained')

c+='''
/* STROM150_SVG_ICONS: reduced unified CAD/architecture icon language. */
.strom-icon150 {display:inline-block;width:1.15em;height:1.15em;min-width:1.05em;flex:none;vertical-align:-.19em;fill:none;stroke:currentColor;stroke-width:1.65;stroke-linecap:round;stroke-linejoin:round;overflow:visible}
.nav-icon .strom-icon150,.canvas-toolbox .strom-icon150,.canvas-layer-menu .strom-icon150 {width:19px;height:19px}
.canvas-toolbox button,.canvas-layer-menu button {align-items:center;justify-content:center}
/* Keep pre-existing button colors, focus outlines, tooltips and selected states. */
'''
for p,text in ((app,a),(scene,s),(css,c)):p.write_text(text,encoding='utf8')
for filename,subdir in [('cameraTransitions150.ts','components'),('CameraFlight150.tsx','components'),('StromIcon150.tsx','components')]:
    dest=src/subdir/filename
    if dest.exists():raise RuntimeError(f'150 new component already exists: {dest.name}')
    data=(asset/filename).read_text('utf8')
    if not data.strip():raise RuntimeError(f'150 empty component {filename}')
    dest.write_text(data,encoding='utf8')
print('PASS 150: view-mode navigation and true 3D camera rig injected; old features preserved')
STROM150_PATCH_PY
cat > "$RESOURCE_DIR/iconAst150.cjs" <<'STROM150_ICON_AST'
// STROM150_ICON_AST: change only glyphs in JSX UI controls, never measurement text or TypeScript literals.
const fs=require('fs'),path=require('path'),ts=require(process.env.STROM150_TS)
const root=process.env.STROM150_SOURCE
if(!root||!fs.existsSync(root))throw Error('STROM150_SOURCE missing')
const labels={
  '⚡':['power','Elektrik'],'⌂':['house','3D-Haus'],'▦':['blueprint','Blueprint'],'▤':['wall','Wanddetail'],
  '▣':['room','Raum'],'▭':['rectangle','Rechteck'],'⬠':['polygon','Polygon'],'▱':['recess','Aussparung'],
  '🗑':['delete','Löschen'],'🗑️':['delete','Löschen'],'🧹':['broom','Leeren'],'↖':['select','Auswählen'],
  '↔':['arrowLeftRight','Horizontal ausrichten'],'↕':['arrowUpDown','Vertikal ausrichten'],'⇔':['dimension','Bemaßen'],
  '⇵':['stair','Treppe'],'↶':['undo','Rückgängig'],'↷':['redo','Wiederholen'],'⇄':['arrowLeftRight','Umschalten'],
  '↻':['rotate','Drehen'],'⟲':['rotate','Drehen'],'⟳':['reset','Ansicht zurücksetzen'],
  '▯':['door','Tür'],'◉':['socket','Steckdose'],'◐':['layers','Ebenen'],'◑':['layers','Ebenen'],
  '◎':['focus','Zentrieren'],'①':['layers','Ebene'],'☰':['menu','Menü'],'◌':['eyeOff','Ausgeblendet'],
  '👁':['eye','Sichtbarkeit'],'👁️':['eye','Sichtbarkeit'],'👁‍🗨':['eye','Sichtbarkeit'],
  '▥':['window','Fenster'],'─':['minus','Linie'],'⛶':['fullscreen','Vollbild'],'⌖':['focus','Zentrieren'],
  '−':['zoomOut','Verkleinern'],'-':['zoomOut','Verkleinern'],'＋':['zoomIn','Vergrößern'],
  '+':['zoomIn','Vergrößern'],'×':['close','Schließen'],'✕':['close','Schließen'],
  '›':['right','Weiter'],'‹':['left','Zurück'],'▸':['right','Aufklappen'],'▾':['down','Zuklappen'],
  '☑':['check','Bestätigen'],'✓':['check','Bestätigen'],'✚':['add','Hinzufügen'],
  '⇥':['forward','Weiter'],'▹':['right','Weiter'],'⊕':['add','Hinzufügen'],'⊖':['minus','Entfernen'],
  '⚙':['gear','Einstellungen'],'⚙️':['gear','Einstellungen'],'ⓘ':['info','Information'],
  '⌗':['grid','Raster'],'⭮':['reset','Zurücksetzen'],'↺':['undo','Rückgängig'],'⇧':['up','Nach oben'],
  '⇩':['down','Nach unten'],'⬜':['rectangle','Rechteck'],'📐':['angle','Winkel'],
  '🔍':['search','Suchen'],'🔒':['lock','Sperren'],'⤢':['fullscreen','Vollbild'],
  '1:1':['zoomOne','Originalgröße'],'✎':['label','Bearbeiten'],'✏':['label','Bearbeiten'],
  '⊞':['grid','Raster'],'⦿':['focus','Fokus'],'✖':['close','Schließen'],
  '⤺':['undo','Rückgängig'],'⤻':['redo','Wiederholen'],'◀':['left','Zurück'],'▶':['right','Weiter'],
  '🏠':['house','3D-Haus'],'⚠':['warning','Warnung'],'🔧':['gear','Werkzeug']
}
const getIcon=glyph=>{const hit=labels[glyph];return hit?`<StromIcon150 name="${hit[0]}" title="${hit[1]}" />`:null}
const candidates=[]
function collect(dir){for(const entry of fs.readdirSync(dir,{withFileTypes:true})){
 if(entry.isDirectory()){if(!['node_modules','dist','.git'].includes(entry.name))collect(path.join(dir,entry.name));continue}
 if(entry.name.endsWith('.tsx')&&!['StromIcon150.tsx','CameraFlight150.tsx'].includes(entry.name))candidates.push(path.join(dir,entry.name))
}}
collect(root)
let changedFiles=0,changedIcons=0
for(const file of candidates){
 let source=fs.readFileSync(file,'utf8');const sf=ts.createSourceFile(file,source,ts.ScriptTarget.Latest,true,ts.ScriptKind.TSX)
 if(sf.parseDiagnostics.length)throw Error(file+' TSX parse failed before icon migration')
 const edits=[]
 const uiAncestor=node=>{
  let p=node.parent
  while(p){
   if(ts.isJsxElement(p)||ts.isJsxSelfClosingElement(p)){
    const name=p.openingElement?.tagName?.getText(sf)||p.tagName?.getText(sf)
    if(['button','label'].includes(name))return true
    if(name==='span'){
      const attr=p.openingElement?.attributes?.properties.find(a=>a.name?.getText(sf)==='className')
      const cl=attr?.initializer?.getText(sf)||''
      if(/icon|tool|button|handle|indicator|action/.test(cl))return true
    }
   }
   if(ts.isFunctionDeclaration(p)||ts.isSourceFile(p))break
   p=p.parent
  }
  return false
 }
 const scan=node=>{
  if(ts.isJsxText(node)&&uiAncestor(node)){
   const full=node.getText(sf);const glyph=full.trim(),tag=getIcon(glyph)
   if(tag)edits.push({start:node.getStart(sf),end:node.getEnd(),value:full.replace(glyph,tag)})
  }
  if(ts.isStringLiteral(node)&&ts.isJsxExpression(node.parent)&&uiAncestor(node)){
   const tag=getIcon(node.text)
   if(tag)edits.push({start:node.getStart(sf),end:node.getEnd(),value:tag})
  }
  ts.forEachChild(node,scan)
 }
 scan(sf)
 if(!edits.length)continue
 const filtered=edits.sort((a,b)=>b.start-a.start)
 for(let i=0;i<filtered.length;i++){
  const edit=filtered[i]
  if(i&&edit.end>filtered[i-1].start)throw Error(file+' overlapping icon edits')
  source=source.slice(0,edit.start)+edit.value+source.slice(edit.end)
 }
 const rel=path.relative(path.dirname(file),path.join(root,'components','StromIcon150')).replace(/\\/g,'/')
 const imp=(rel.startsWith('.')?rel:'./'+rel)
 const importLine=`import StromIcon150 from '${imp}' // STROM150_ICON_AST\n`
 if(!source.includes('import StromIcon150'))source=importLine+source
 const check=ts.createSourceFile(file,source,ts.ScriptTarget.Latest,true,ts.ScriptKind.TSX)
 if(check.parseDiagnostics.length)throw Error(file+' icon migration produced TSX syntax errors: '+check.parseDiagnostics.map(d=>ts.flattenDiagnosticMessageText(d.messageText,' ')).join('; '))
 fs.writeFileSync(file,source)
 changedIcons+=edits.length;changedFiles++
 console.log('STROM150 SVG',path.relative(root,file),edits.length)
}
console.log('PASS icon AST migration:',changedIcons,'glyphs in',changedFiles,'TSX files; no font icons')
STROM150_ICON_AST
cat > "$RESOURCE_DIR/cameraTransitions150.ts" <<'STROM150_BRIDGE_TS'
/** STROM150_CAMERA_BRIDGE: coordinate view navigation without delaying React rendering. */
export type BlueprintFrame150={floorId:string;levelId:string;cx:number;cy:number;widthM:number;heightM:number}
export type Mode150='wall'|'threeD'
export type Enter150={mode:Mode150;frame:BlueprintFrame150}
let pending150:Enter150|null=null
let current150:Enter150|null=null
let activeExit150:((done:()=>void)=>void)|null=null
let exitPending150=false
export const DURATION150=750

function storedLevel150(floorId:string):string{
  try {
    const raw=window.localStorage.getItem(`strom.floorplan.layers.${floorId}.active`)
    const value:unknown=JSON.parse(raw||'null')
    return typeof value==='string'?value:''
  }catch{return ''}
}
function viewFrame150(floorId:string):BlueprintFrame150{
  const result:BlueprintFrame150={floorId,levelId:storedLevel150(floorId),cx:0,cy:0,widthM:0,heightM:0}
  try {
    const svg=document.querySelector('svg[aria-label="Blueprint Editor"]') as SVGSVGElement|null
    const container=(svg?.closest('.canvas-scroll,.canvas-viewport,.canvas-scroll-area')||svg?.parentElement) as HTMLElement|null
    const matrix=svg?.getScreenCTM()
    const rect=container?.getBoundingClientRect()
    if(svg&&matrix&&rect&&rect.width>30&&rect.height>30){
      const center=svg.createSVGPoint();center.x=rect.left+rect.width/2;center.y=rect.top+rect.height/2
      const p=center.matrixTransform(matrix.inverse())
      // The Blueprint uses a 60px/m plan grid with a 70px margin and -10m origin.
      // This is the existing canvas coordinate convention, not an arbitrary 3D zoom.
      result.cx=(p.x-670)/60;result.cy=(p.y-670)/60
      const pxPerUnit=Math.hypot(matrix.a,matrix.b)
      if(pxPerUnit>1e-5){result.widthM=rect.width/(60*pxPerUnit);result.heightM=rect.height/(60*pxPerUnit)}
    }
  }catch{/* fallback to model-room geometry if no live SVG was found */}
  return result
}
export function queueEntry150(mode:Mode150,floorId:string){
  pending150={mode,frame:viewFrame150(floorId)}
  current150=pending150
  exitPending150=false
}
export function consumeEntry150():Enter150|null{
  const value=pending150
  pending150=null
  return value
}
export function restoreEntry150(value:Enter150){if(!pending150)pending150=value}
export function currentFrame150():BlueprintFrame150|null{return current150?.frame||null}
export function registerExit150(handler:(done:()=>void)=>void):()=>void{
  activeExit150=handler
  return ()=>{if(activeExit150===handler)activeExit150=null}
}
export function requestExit150(finish:()=>void):boolean{
  if(!activeExit150){pending150=null;current150=null;return false}
  if(exitPending150)return true
  exitPending150=true
  let completed=false
  const timeout=window.setTimeout(complete,1100)
  function complete(){if(completed)return;completed=true;window.clearTimeout(timeout);exitPending150=false;finish()}
  try {activeExit150(complete)}catch{complete()}
  return true
}
STROM150_BRIDGE_TS
cat > "$RESOURCE_DIR/CameraFlight150.tsx" <<'STROM150_FLIGHT_TSX'
import {useLayoutEffect,useMemo,useRef} from 'react'
import {useFrame,useThree} from '@react-three/fiber'
import * as THREE from 'three'
import {consumeEntry150,restoreEntry150,currentFrame150,registerExit150,DURATION150} from './cameraTransitions150'
import type {BlueprintFrame150} from './cameraTransitions150'

type P150={x:number;y:number}
type Control150={target?:THREE.Vector3;enabled?:boolean;update?:()=>void}
type Pose150={position:THREE.Vector3;rotation:THREE.Quaternion;target:THREE.Vector3;zoom:number}
type Flight150={start:Pose150;end:Pose150;started:number;done?:()=>void;restoreControls?:boolean}
const easing150=(t:number)=>1-Math.pow(1-t,3)
const clamp150=(n:number,a:number,b:number)=>Math.min(b,Math.max(a,n))

function planBounds150(points:readonly P150[],frame:BlueprintFrame150|null){
  let minX=Infinity,maxX=-Infinity,minY=Infinity,maxY=-Infinity
  for(const p of points){if(!Number.isFinite(p.x)||!Number.isFinite(p.y))continue
    minX=Math.min(minX,p.x);maxX=Math.max(maxX,p.x);minY=Math.min(minY,p.y);maxY=Math.max(maxY,p.y)
  }
  if(!Number.isFinite(minX)){minX=-4;maxX=4;minY=-3;maxY=3}
  const cx=(minX+maxX)/2,cy=(minY+maxY)/2
  const width=Math.max(2,maxX-minX),height=Math.max(2,maxY-minY)
  // Use the same visible Blueprint area if its SVG-to-screen matrix was captured.
  if(frame&&frame.widthM>0.1&&frame.heightM>0.1&&frame.widthM<150&&frame.heightM<150){
    return {cx:frame.cx,cy:frame.cy,width:frame.widthM,height:frame.heightM}
  }
  return {cx,cy,width:width*1.14,height:height*1.14}
}
function snapshot150(camera:THREE.Camera,control:Control150|null,target:THREE.Vector3):Pose150{
  const zoom=(camera as THREE.OrthographicCamera).zoom||1
  return {position:camera.position.clone(),rotation:camera.quaternion.clone(),target:control?.target?.clone()||target.clone(),zoom}
}
function topPose150(camera:THREE.Camera,bounds:ReturnType<typeof planBounds150>,aspect:number):Pose150{
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
  const view=new THREE.Matrix4().lookAt(position,target,new THREE.Vector3(0,0,-1))
  return {position,rotation:new THREE.Quaternion().setFromRotationMatrix(view),target,zoom:newZoom}
}

/** 750ms eased spatial camera motion; 2D and 3D share the XY plan coordinates. */
export default function CameraFlight150({points}:{points:readonly P150[]}){
  const camera=useThree(state=>state.camera)
  const controls=useThree(state=>(state.controls||null) as Control150|null)
  const size=useThree(state=>state.size)
  const invalidate=useThree(state=>state.invalidate)
  const flight=useRef<Flight150|null>(null)
  const baseline=useRef<Pose150|null>(null)
  const latest=useRef<{points:readonly P150[];aspect:number}>({points,aspect:Math.max(.3,size.width/Math.max(size.height,1))})
  latest.current={points,aspect:Math.max(.3,size.width/Math.max(size.height,1))}
  const fallback=useMemo(()=>new THREE.Vector3(0,0,0),[])

  const apply=(pose:Pose150)=>{
    camera.position.copy(pose.position)
    camera.quaternion.copy(pose.rotation)
    if(controls?.target)controls.target.copy(pose.target)
    const ortho=camera as THREE.OrthographicCamera
    if(ortho.isOrthographicCamera){ortho.zoom=pose.zoom;ortho.updateProjectionMatrix()}
    camera.updateMatrixWorld()
    invalidate()
  }
  useLayoutEffect(()=>{
    const previousControlsEnabled=controls?.enabled
    const original=snapshot150(camera,controls,fallback)
    baseline.current=original
    const incoming=consumeEntry150()
    if(incoming){
      const bounds=planBounds150(latest.current.points,incoming.frame)
      const bird=topPose150(camera,bounds,latest.current.aspect)
      apply(bird)
      flight.current={start:bird,end:original,started:performance.now(),restoreControls:previousControlsEnabled}
      if(controls)controls.enabled=false
    }
    const unregister=registerExit150((done)=>{
      const bounds=planBounds150(latest.current.points,currentFrame150())
      const bird=topPose150(camera,bounds,latest.current.aspect)
      const current=snapshot150(camera,controls,bird.target)
      flight.current={start:current,end:bird,started:performance.now(),done,restoreControls:previousControlsEnabled}
      if(controls)controls.enabled=false
    })
    return ()=>{
      unregister()
      if(controls&&previousControlsEnabled!==undefined)controls.enabled=previousControlsEnabled
      if(incoming&&flight.current&&!flight.current.done){apply(original);restoreEntry150(incoming)}
      flight.current=null
    }
  // Keep the camera and controls bound to the same Canvas instance.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  },[camera,controls])
  useFrame(()=>{
    const running=flight.current
    if(!running)return
    const t=clamp150((performance.now()-running.started)/DURATION150,0,1)
    const k=easing150(t)
    const a=running.start,b=running.end
    const next:Pose150={position:a.position.clone().lerp(b.position,k),
      rotation:a.rotation.clone().slerp(b.rotation,k),target:a.target.clone().lerp(b.target,k),zoom:a.zoom+(b.zoom-a.zoom)*k}
    apply(next)
    if(t>=1){
      apply(b)
      flight.current=null
      if(controls){controls.enabled=running.restoreControls??true;controls.update?.()}
      running.done?.()
    }
  })
  return null
}
STROM150_FLIGHT_TSX
cat > "$RESOURCE_DIR/StromIcon150.tsx" <<'STROM150_ICONS_TSX'
import type {ReactNode,SVGProps} from 'react'

/** STROM150_SVG_ICONS: one reduced monochrome CAD/architectural SVG language; no icon fonts and no text elements. */
type Glyph150 = ReactNode
const shapes150:Record<string,Glyph150>={
  blueprint:<><rect x="3" y="3" width="18" height="18" rx="1.5"/><path d="M3 11h18M11 3v18M11 15h10"/></>,
  wall:<><path d="M3 4h18v4H3zM3 16h18v4H3zM4 8v8m7-8v8m9-8v8"/><path d="M7.5 8v8m8-8v8"/></>,
  house:<><path d="m2.5 11 9.5-8 9.5 8M5 10v11h14V10M10 21v-7h4v7"/></>,
  power:<><path d="m13.5 2-8 11H12l-1.5 9 8-12H12z"/></>,
  select:<><path d="M5 3v17l4.6-5.4 3.8 7 2.5-1.4-3.8-7L19 12z"/></>,
  cursor:<><path d="M4 3v18l5.3-5.9 3.5 6.4 2.5-1.4-3.6-6.4 7.2-.6z"/></>,
  move:<><path d="M12 2v20M2 12h20M9 5l3-3 3 3M9 19l3 3 3-3M5 9l-3 3 3 3M19 9l3 3-3 3"/></>,
  pan:<><path d="M5 13V8a1.5 1.5 0 0 1 3 0v4-7a1.5 1.5 0 0 1 3 0v7-8a1.5 1.5 0 0 1 3 0v8-5a1.5 1.5 0 0 1 3 0v7l1.3-1.5a1.9 1.9 0 0 1 3 2.2l-4.5 6.7H9l-4.5-6.8a1.6 1.6 0 0 1 .5-2.1z"/></>,
  rectangle:<><rect x="3.5" y="5" width="17" height="14" rx=".6"/><circle cx="3.5" cy="5" r="1"/><circle cx="20.5" cy="19" r="1"/></>,
  polygon:<><path d="M5 4 18 3l4 10-7 8L3 17z"/><circle cx="5" cy="4" r="1"/><circle cx="18" cy="3" r="1"/><circle cx="15" cy="21" r="1"/></>,
  room:<><path d="M4 4h16v16H4V4zm0 8h7V4"/></>,
  exterior:<><rect x="3" y="3" width="18" height="18"/><rect x="7" y="7" width="10" height="10"/></>,
  recess:<><path d="M3 4h18v16H3V4zm0 7h6V8h6v7H9v5"/></>,
  erase:<><path d="m3 15 11-11 7 7-9 9H8zM11 20h10M8 10l7 7"/></>,
  broom:<><path d="m13 3 6 6M12 4l8 8M11 6l6 6M11 8 4 15l-1 5 5-1 7-7M4 15l5 5M17.5 2v3m-1.5-1.5h3"/></>,
  delete:<><path d="M4 6h16M9 6V4h6v2M6 6l1 15h10l1-15M10 10v7M14 10v7"/></>,
  undo:<><path d="M9 7 4 12l5 5M4 12h11a5 5 0 0 1 0 10"/></>,
  redo:<><path d="m15 7 5 5-5 5m5-5H9a5 5 0 0 0 0 10"/></>,
  reset:<><path d="M5 5v6h6M5 11a8 8 0 1 1 2 6"/><circle cx="12" cy="12" r="2"/></>,
  save:<><path d="M4 3h14l3 3v15H4zM8 3v7h9V3M8 21v-8h10v8"/></>,
  load:<><path d="M12 3v12m-4-4 4 4 4-4M4 18v3h16v-3"/></>,
  upload:<><path d="M12 21V9m-4 4 4-4 4 4M4 6V3h16v3"/></>,
  download:<><path d="M12 3v12m-4-4 4 4 4-4M4 18v3h16v-3"/></>,
  add:<><path d="M12 4v16M4 12h16"/></>,
  minus:<><path d="M4 12h16"/></>,
  plus:<><path d="M12 4v16M4 12h16"/></>,
  zoomIn:<><circle cx="10" cy="10" r="7"/><path d="m15 15 6 6M10 6v8M6 10h8"/></>,
  zoomOut:<><circle cx="10" cy="10" r="7"/><path d="m15 15 6 6M6 10h8"/></>,
  zoomFit:<><path d="M9 3H3v6m12-6h6v6M9 21H3v-6m12 6h6v-6M8 8h8v8H8z"/></>,
  zoomOne:<><path d="M6 3H3v6m15-6h3v6M3 15v6h6m12-6v6h-6M9 12h6M12 9v6"/></>,
  focus:<><circle cx="12" cy="12" r="6"/><circle cx="12" cy="12" r="1.3"/><path d="M12 2v4m0 12v4M2 12h4m12 0h4"/></>,
  fullscreen:<><path d="M9 3H3v6m12-6h6v6M3 15v6h6m12-6v6h-6"/></>,
  eye:<><path d="M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/></>,
  eyeOff:<><path d="M2 2 22 22M9 5.5A11.5 11.5 0 0 1 12 5c6 0 10 7 10 7a18 18 0 0 1-4 4.5M6 7a20 20 0 0 0-4 5s4 7 10 7a10.8 10.8 0 0 0 4.2-.8"/><path d="M10 10a3 3 0 0 0 4 4"/></>,
  layers:<><path d="m12 3 9 5-9 5-9-5zM3 12l9 5 9-5M3 16l9 5 9-5"/></>,
  floor:<><path d="M3 6h18v4H3zM6 10v11m12-11v11M3 21h18"/></>,
  slab:<><path d="M2 14 12 9l10 5-10 5zM2 18l10 5 10-5M2 14v4m20-4v4"/></>,
  drag:<><path d="M9 4h0M15 4h0M9 10h0M15 10h0M9 16h0M15 16h0M9 22h0M15 22h0" strokeWidth="3.5" strokeLinecap="round"/></>,
  resize:<><path d="M3 10V3h7M14 21h7v-7M3 3l7 7M21 21l-7-7"/></>,
  rotate:<><path d="M19 8a8 8 0 1 0 1 7M19 3v5h-5"/></>,
  left:<><path d="m14 5-7 7 7 7"/></>,
  right:<><path d="m10 5 7 7-7 7"/></>,
  up:<><path d="m5 14 7-7 7 7"/></>,
  down:<><path d="m5 10 7 7 7-7"/></>,
  back:<><path d="M20 12H4m7-7-7 7 7 7"/></>,
  forward:<><path d="M4 12h16m-7-7 7 7-7 7"/></>,
  arrowLeftRight:<><path d="M3 8h18m-4-4 4 4-4 4M21 16H3m4-4-4 4 4 4"/></>,
  arrowUpDown:<><path d="M8 3v18M4 7l4-4 4 4M16 21V3m-4 14 4 4 4-4"/></>,
  measure:<><path d="M2 9V4h20v5M2 15v5h20v-5M4 12h16M7 10v4m5-4v4m5-4v4"/></>,
  ruler:<><path d="m3 17 14-14 4 4L7 21zM12 8l4 4M9 11l2 2M6 14l4 4"/></>,
  dimension:<><path d="M3 4v16M21 4v16M3 12h18m-14-3-4 3 4 3m10-6 4 3-4 3"/></>,
  door:<><path d="M4 21V3h12v18M16 21V7L7 13v8M12 13h1"/></>,
  window:<><rect x="3" y="4" width="18" height="16"/><path d="M12 4v16M3 12h18"/></>,
  stair:<><path d="M2 20h5v-5h5v-5h5V5h5"/><path d="M3 5h9m-4-3 4 3-4 3"/></>,
  stairStraight:<><path d="M2 19h20M2 15h20M2 11h20M2 7h20M12 20V3m-4 4 4-4 4 4"/></>,
  stairL:<><path d="M3 20V9h10V3h8v17zM3 14h10M7 9v11m6-7h8m-4-10v10"/></>,
  socket:<><rect x="4" y="4" width="16" height="16" rx="2"/><circle cx="9" cy="12" r="1.4"/><circle cx="15" cy="12" r="1.4"/><path d="M9 17h6"/></>,
  switch:<><rect x="4" y="4" width="16" height="16" rx="2"/><path d="M10 8v8M15 12h-1"/></>,
  electrical:<><circle cx="12" cy="12" r="9"/><path d="m13 5-5 8h5l-2 6 6-9h-5z"/></>,
  device:<><rect x="5" y="3" width="14" height="18" rx="2"/><path d="M8 7h8M8 11h8"/><circle cx="12" cy="17" r="1"/></>,
  cable:<><path d="M4 6h4a4 4 0 0 1 4 4v4a4 4 0 0 0 4 4h4M4 4v4M20 16v4"/><circle cx="12" cy="12" r="2"/></>,
  connector:<><path d="M3 8h7v8H3zM14 8h7v8h-7zM10 12h4"/></>,
  gear:<><circle cx="12" cy="12" r="3"/><path d="m10 2-.5 2.3-2 1-2.3-1L3 7l1.3 2.3-1 2 1 2L3 16l2.2 2.7 2.3-1 2 1L10 21h4l.5-2.3 2-1 2.3 1L21 16l-1.3-2.7 1-2-1-2L21 7l-2.2-2.7-2.3 1-2-1L14 2z"/></>,
  settings:<><path d="M4 7h16M4 17h16"/><circle cx="9" cy="7" r="2"/><circle cx="16" cy="17" r="2"/></>,
  info:<><circle cx="12" cy="12" r="9"/><path d="M12 11v6M12 7v1"/></>,
  help:<><circle cx="12" cy="12" r="9"/><path d="M9 9a3 3 0 1 1 4 2.8c-1.2.5-1 2.2-1 2.2M12 18v.3"/></>,
  close:<><path d="M4 4 20 20M20 4 4 20"/></>,
  menu:<><path d="M3 6h18M3 12h18M3 18h18"/></>,
  grid:<><path d="M3 3h18v18H3zM3 9h18M3 15h18M9 3v18m6-18v18"/></>,
  ghost:<><path d="M5 20V10a7 7 0 0 1 14 0v10l-3-2-4 2-4-2zM9 12h1m4 0h1"/></>,
  snap:<><path d="M12 2v20M2 12h20M5 5l14 14M19 5 5 19"/><circle cx="12" cy="12" r="3"/></>,
  align:<><path d="M3 3v18M7 6h14M7 12h10M7 18h14"/></>,
  copy:<><rect x="8" y="8" width="13" height="13" rx="1"/><path d="M16 8V3H3v13h5"/></>,
  duplicate:<><rect x="8" y="8" width="13" height="13" rx="1"/><path d="M16 8V3H3v13h5"/></>,
  apply:<><circle cx="12" cy="12" r="9"/><path d="m7 12 3.5 3.5L17 9"/></>,
  check:<><path d="m4 12 5 5 11-11"/></>,
  warning:<><path d="m12 2 10 19H2zM12 9v5m0 3v.5"/></>,
  calendar:<><rect x="3" y="5" width="18" height="16" rx="1"/><path d="M7 3v4m10-4v4M3 10h18"/></>,
  search:<><circle cx="10" cy="10" r="7"/><path d="m15 15 6 6"/></>,
  lock:<><rect x="5" y="10" width="14" height="11" rx="1.5"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/></>,
  unlock:<><rect x="5" y="10" width="14" height="11" rx="1.5"/><path d="M8 10V7a4 4 0 0 1 8 0"/></>,
  user:<><circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/></>,
  users:<><circle cx="9" cy="8" r="3"/><path d="M2 20a7 7 0 0 1 14 0M17 5a3 3 0 0 1 0 6M18 14a6 6 0 0 1 4 6"/></>,
  list:<><path d="M9 6h12M9 12h12M9 18h12M3 6h1M3 12h1M3 18h1"/></>,
  export:<><path d="M14 4h7v7m-9 1 9-8M20 14v7H3V4h7"/></>,
  import:<><path d="M10 4H3v17h17v-7m-8-2 9-8m-7 0h7v7"/></>,
  label:<><path d="M3 3h12l6 9-9 9-9-6z"/><circle cx="8" cy="8" r="2"/></>,
  roof:<><path d="m2 12 10-9 10 9M4 12l8-7 8 7M4 19l8-7 8 7"/></>,
  angle:<><path d="M4 20V4M4 20h16M4 20l11-11M9 20a5 5 0 0 0-1.5-3.5"/></>,
  direction:<><path d="M3 20 19 4m-8 0h8v8M3 4v16h16"/></>,
  threeD:<><path d="m12 2 9 5v10l-9 5-9-5V7zM12 12l9-5M12 12 3 7m9 5v10"/></>,
  bird:<><path d="M12 3v18M3 12h18M4 4l16 16M20 4 4 20"/><circle cx="12" cy="12" r="5"/></>,
}

const aliases150:Record<string,string>={
  trash:'delete',clear:'broom',visible:'eye',hidden:'eyeOff',blueprint2:'blueprint',
  stairs:'stair',floorplan:'blueprint',threeDHouse:'house',threeDView:'threeD',
  expand:'fullscreen',collapse:'fullscreen',remove:'minus',create:'add',
  resetView:'reset',house3d:'house',cutout:'recess',dimensioning:'dimension',
  moveObject:'move',zoomReset:'zoomOne',object:'room',socketOutlet:'socket',
}
export default function StromIcon150({name,title,size=20,...props}:{name:string;title?:string;size?:number}&Omit<SVGProps<SVGSVGElement>,'name'>){
  const glyph=shapes150[aliases150[name]||name]||shapes150.info
  return <svg viewBox="0 0 24 24" width={size} height={size} fill="none" stroke="currentColor" strokeWidth={1.65}
    strokeLinecap="round" strokeLinejoin="round" focusable="false" aria-hidden={title?undefined:true}
    role={title?'img':undefined} className="strom-icon150" {...props}>
    {title?<title>{title}</title>:null}
    {glyph}
  </svg>
}
STROM150_ICONS_TSX

log "3) Apply Update 150 transactionally to the isolated checkout ..."
python3 -m py_compile "$RESOURCE_DIR/patch150.py" >>"$DIAG_LOG" 2>&1 || fail "150 Python syntax invalid"
STROM150_ROOT="$WORK_DIR" STROM150_ASSETS="$RESOURCE_DIR" \
 python3 "$RESOURCE_DIR/patch150.py" >>"$DIAG_LOG" 2>&1 || fail "150 source patch failed, GitHub and Stage unchanged"
STROM150_SOURCE="$WORK_DIR/frontend/src" STROM150_TS="$DEPENDENCIES/typescript" \
 node "$RESOURCE_DIR/iconAst150.cjs" >>"$DIAG_LOG" 2>&1 || fail "150 SVG icon conversion failed, GitHub and Stage unchanged"
log "4) Structural TS/TSX audit ..."
STROM150_SOURCE="$WORK_DIR/frontend/src" STROM150_TS="$DEPENDENCIES/typescript" node <<'STROM150_AUDIT' >>"$DIAG_LOG" 2>&1 || fail "150 TypeScript AST structural audit failed"
const fs=require('fs'),path=require('path'),ts=require(process.env.STROM150_TS)
const root=process.env.STROM150_SOURCE
let files=0,jsx=0
function check(dir){for(const name of fs.readdirSync(dir)){
 const file=path.join(dir,name),stat=fs.statSync(file)
 if(stat.isDirectory()){if(!['node_modules','dist','.git'].includes(name))check(file);continue}
 if(!/\.tsx?$/.test(name))continue
 const source=fs.readFileSync(file,'utf8'),ast=ts.createSourceFile(file,source,ts.ScriptTarget.Latest,true,name.endsWith('.tsx')?ts.ScriptKind.TSX:ts.ScriptKind.TS)
 if(ast.parseDiagnostics.length)throw Error(file+' parse: '+ast.parseDiagnostics.map(x=>ts.flattenDiagnosticMessageText(x.messageText,' ')).join('; '))
 const walk=node=>{
  if(ts.isJsxOpeningElement(node)||ts.isJsxSelfClosingElement(node)){
   const set=new Set();for(const attr of node.attributes.properties){if(!ts.isJsxAttribute(attr))continue
    const key=attr.name.getText(ast);if(set.has(key))throw Error(file+': duplicate JSX prop '+key);set.add(key)}jsx++
  }
  ts.forEachChild(node,walk)
 }
 walk(ast);files++
}}
check(root)
const app=fs.readFileSync(path.join(root,'App.tsx'),'utf8')
const scene=fs.readFileSync(path.join(root,'components/Building3DWorkspace.tsx'),'utf8')
for(const mark of ['STROM150_CAMERA_NAV','STROM150_CAMERA_BRIDGE','STROM149E_ROOF_SNAP'])if(!app.includes(mark))throw Error('App marker missing: '+mark)
for(const mark of ['STROM150_CAMERA','STROM149_CUT_WALL'])if(!scene.includes(mark))throw Error('Scene marker missing: '+mark)
const icons=fs.readFileSync(path.join(root,'components/StromIcon150.tsx'),'utf8')
if(/<text[\s>]/.test(icons)||/font-family/i.test(icons))throw Error('Icon text/font is forbidden')
console.log('PASS AST:',files,'TS/TSX files,',jsx,'JSX tags; no duplicate props')
STROM150_AUDIT
log "5) Full TypeScript and Vite build against Stage dependencies ..."
( cd "$WORK_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || fail "TypeScript/Vite build failed before GitHub push"
log "5.1) Camera bridge and icon regression tests ..."
STROM150_SOURCE="$WORK_DIR/frontend/src" STROM150_TS="$DEPENDENCIES/typescript" node <<'STROM150_REGRESSION' >>"$DIAG_LOG" 2>&1 || fail "150 camera/icon regression test failed"
const assert=require('assert'),fs=require('fs'),path=require('path'),ts=require(process.env.STROM150_TS)
const source=process.env.STROM150_SOURCE
let code=fs.readFileSync(path.join(source,'components/cameraTransitions150.ts'),'utf8')
const js=ts.transpileModule(code,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText
const mockWindow={localStorage:{getItem:(key)=>key.endsWith('.active')?JSON.stringify('second'):null},setTimeout:()=>1,clearTimeout:()=>{}}
const mockDocument={querySelector:()=>null}
const m={exports:{}}
new Function('module','exports','require','window','document',js)(m,m.exports,require,mockWindow,mockDocument)
const b=m.exports
b.queueEntry150('threeD','floor123')
const enter=b.consumeEntry150();assert(enter&&enter.mode==='threeD'&&enter.frame.levelId==='second')
assert.strictEqual(b.consumeEntry150(),null)
let rigCalled=false,ended=false
const unregister=b.registerExit150(done=>{rigCalled=true;done()})
assert.strictEqual(b.requestExit150(()=>{ended=true}),true)
assert(rigCalled&&ended)
unregister()
assert.strictEqual(b.requestExit150(()=>{}),false)
assert.strictEqual(b.DURATION150,750)
const flight=fs.readFileSync(path.join(source,'components/CameraFlight150.tsx'),'utf8')
assert(flight.includes('1-Math.pow(1-t,3)'))
const icons=fs.readFileSync(path.join(source,'components/StromIcon150.tsx'),'utf8')
assert((icons.match(/:<[>]|:<[a-z]/g)||[]).length>30)
console.log('PASS regression: active floor, both directions, 750ms cubic ease-out, icon vector catalogue')
STROM150_REGRESSION
rm -rf -- "$RESOURCE_DIR"
mkdir -p "$WORK_DIR/docs"
cat > "$WORK_DIR/docs/STROM_UPDATE_150.md" <<'STROM150_DOC'
# Stromnetze Update 150 – icon uniformity and immersive view transitions
- Replaces text-symbol UI icons with consistent, accessible, handcrafted monochrome SVG-line glyphs (no icon fonts).
- 3D enters from a plan-matched top-down view of the active Blueprint layer, using the captured on-screen viewport when available.
- Camera moves to the existing default view in 750 ms using cubic ease-out; all old camera configuration is preserved.
- Going from 3D house or wall detail to Blueprint runs the reverse camera movement before switching.
- Existing 149e geometry, roof slopes, stairs, databases and production frontend remain unchanged.
- Current reference style: reduced CAD/Affinity-like SVG geometry. Original historical v7 SVG file was not mounted as a resource.
STROM150_DOC
log "6) Transfer built and audited source into Stage checkout ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
 "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "Stage transfer failed; previous Stage backup: $BACKUP_DIR"
if [ "${PATCH_ONLY:-0}" = "1" ]; then log "PATCH_ONLY passed. No web deployment."; exit 0; fi
log "7) Rebuild Stage and deploy to /strom-test/ only ..."
( cd "$STAGE_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || fail "Stage rebuild failed; previous Stage backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "Frontend output dist/ missing"
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || fail "Test web deployment failed; Stage backup: $BACKUP_DIR"
log "SUCCESS: Update 150 available at https://home.moja.de/strom-test/"
log "Production /strom/ remains untouched. Stage backup: $BACKUP_DIR"
