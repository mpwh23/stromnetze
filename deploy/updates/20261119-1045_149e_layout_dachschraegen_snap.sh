#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261119-1045_149e_layout_dachschraegen_snap"
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
COMMIT_MESSAGE="Update 149e: compact level rows, named roofs, roof snapping and plane selection"
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
  echo "2) Update 149e im isolierten Git-Checkout bauen und nach GitHub pushen ..."
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

  echo "1.3) Update 149e isoliert anwenden, TypeScript/Vite-Build und Tests pruefen ..."
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
log "=== 149e: add-on to installed 149c; do not replay 149 ==="
log "Stage: $STAGE_DIR"
log "Diagnostics: $DIAG_LOG"
for file in frontend/src/App.tsx frontend/src/styles.css frontend/src/components/Building3DWorkspace.tsx \
  frontend/src/components/RoofEditor148.tsx frontend/src/building/roofSlopes148.ts \
  frontend/src/building/levelGeometry149.ts; do
  [ -s "$STAGE_DIR/$file" ] || fail "Stage source missing: $file"
done
grep -Fq STROM149_ROOF_DRAG "$STAGE_DIR/frontend/src/App.tsx" || fail "Update 149c not installed in Stage"
grep -Fq STROM149_CUT_WALL "$STAGE_DIR/frontend/src/components/Building3DWorkspace.tsx" || fail "149c 3D prerequisite missing"
select_node
log "1) Save current Stage source backup ..."
if [ "${PATCH_ONLY:-0}" = "1" ]; then log "PATCH_ONLY: isolated Git checkout; no live Stage backup"; else cp -a "$STAGE_DIR" "$BACKUP_DIR" || fail "Stage backup failed"; fi
log "2) Prepare isolated build directory ..."
rsync -a --exclude='/frontend/node_modules' --exclude='/frontend/dist' --exclude='/.git' "$STAGE_DIR/" "$WORK_DIR/" >>"$DIAG_LOG" 2>&1 || fail "Copy into isolated build failed"
DEPENDENCIES=""
for candidate in "$STAGE_DIR/frontend/node_modules" "$PROD_DIR/frontend/node_modules" /home/mpwh/strom_stage/frontend/node_modules; do
  if [ -f "$candidate/typescript/lib/typescript.js" ] && [ -d "$candidate/vite" ] && [ -d "$candidate/three" ]; then DEPENDENCIES="$candidate";break; fi
done
[ -n "$DEPENDENCIES" ] || fail "Existing Vite/TS dependencies not found"
ln -s "$DEPENDENCIES" "$WORK_DIR/frontend/node_modules"
mkdir -p "$WORK_DIR/149e_resources"
RESOURCE_DIR="$WORK_DIR/149e_resources"
cat > "$RESOURCE_DIR/patch149e.py" <<'STROM149E_PY'
#!/usr/bin/env python3
"""Incremental change on top of already deployed 149c, never reapplies 149."""
from pathlib import Path
import os,re

root=Path(os.environ['STROM149E_ROOT'])
asset=Path(os.environ['STROM149E_ASSETS'])
src=root/'frontend/src'
app=src/'App.tsx'
roof=src/'building/roofSlopes148.ts'
editor=src/'components/RoofEditor148.tsx'
css=src/'styles.css'
snap=src/'building/roofSnap149e.ts'
for p in (app,roof,editor,css,src/'building/levelGeometry149.ts',src/'components/Building3DWorkspace.tsx'):
    if not p.is_file():raise RuntimeError(f'149e source missing: {p.name}')
a=app.read_text('utf8');r=roof.read_text('utf8');ed=editor.read_text('utf8');c=css.read_text('utf8')
if 'STROM149E_ROOF_SNAP' in a or 'STROM149E_ROOF_SNAP' in c or snap.exists():
    raise RuntimeError('149e already applied; refusing double patch')
for key in ('STROM149_ROOF_DRAG','setLayerSlab149','beginRoofDrag149','moveRoofDrag149','RoofEditor148'):
    if key not in a:raise RuntimeError(f'149c Blueprint prerequisite missing: {key}')
if 'STROM149_CUT_WALL' not in (src/'components/Building3DWorkspace.tsx').read_text('utf8'):
    raise RuntimeError('149c 3D prerequisite missing')
if 'inheritRoofPlane149' not in ed or 'export type RoofSlope148' not in r:
    raise RuntimeError('149c roof model prerequisite missing')

def one(text,old,new,label):
    n=text.count(old)
    if n!=1:raise RuntimeError(f'149e {label}: expected unique anchor, got {n}')
    return text.replace(old,new,1)

# Rewrite only the roof-drag scope; preserve all 149c floor/elevation/3D modules.
app_start=a.index('function FloorplanEditor(')
app_end=a.index('type StairEditorElementKind',app_start)
e=a[app_start:app_end]
e=one(e,
    "mode:'move'|'start'|'end';initial:RoofSlope148;origin:PointM",
    "mode:'move'|'start'|'end'|'direction';initial:RoofSlope148;origin:PointM",
    'roof mode extension')
e=one(e,
    "mode:'move'|'start'|'end') {",
    "mode:'move'|'start'|'end'|'direction') {",
    'pointer mode extension')
e=one(e,
    '    const next=dragRoofLine149(active.initial,active.mode,dx,dy)',
    '    const next=snapRoofDrag149e(active.initial,active.mode,dx,dy,pos,rooms,roofLive149.current,event.shiftKey)',
    'roof snap applied')

line='''<line x1={mToX(roof.start.x)} y1={mToY(roof.start.y)} x2={mToX(roof.end.x)} y2={mToY(roof.end.y)}/>'''
start=e.find(line)
if start<0 or e.count(line)!=1:raise RuntimeError('149e roof geometry line not uniquely found')
# The 149c endpoint handles are injected directly after the line, within one roof <g>.
old_grips='''                {selectedRoof148===roof.id&&<>
                  <circle className="strom-roof-handle149" cx={mToX(roof.start.x)} cy={mToY(roof.start.y)} r={8/zoom}
                    onPointerDown={event=>beginRoofDrag149(event,roof,'start')}><title>Startpunkt der Dachlinie drehen oder verschieben</title></circle>
                  <circle className="strom-roof-handle149" cx={mToX(roof.end.x)} cy={mToY(roof.end.y)} r={8/zoom}
                    onPointerDown={event=>beginRoofDrag149(event,roof,'end')}><title>Endpunkt der Dachlinie drehen oder verschieben</title></circle>
                </>}'''
new_grips='''                {/* STROM149E_ROOF_HANDLES: movable end points and draggable direction */}
                {(()=>{
                  const centerX=(roof.start.x+roof.end.x)/2
                  const centerY=(roof.start.y+roof.end.y)/2
                  const angle=roof.directionDeg*Math.PI/180
                  const endX=centerX+Math.cos(angle)*0.55
                  const endY=centerY+Math.sin(angle)*0.55
                  return <>
                    <line className="strom-roof-direction149e" x1={mToX(centerX)} y1={mToY(centerY)} x2={mToX(endX)} y2={mToY(endY)}/>
                    {selectedRoof148===roof.id&&<>
                      <circle className="strom-roof-handle149" cx={mToX(roof.start.x)} cy={mToY(roof.start.y)} r={8/zoom}
                        onPointerDown={event=>beginRoofDrag149(event,roof,'start')}><title>Startpunkt verschieben</title></circle>
                      <circle className="strom-roof-handle149" cx={mToX(roof.end.x)} cy={mToY(roof.end.y)} r={8/zoom}
                        onPointerDown={event=>beginRoofDrag149(event,roof,'end')}><title>Endpunkt verschieben</title></circle>
                      <circle className="strom-roof-direction-grip149e" cx={mToX(endX)} cy={mToY(endY)} r={9/zoom}
                        onPointerDown={event=>beginRoofDrag149(event,roof,'direction')}><title>Richtungswinkel ziehen; Shift: 15-Grad-Raster</title></circle>
                    </>}
                  </>
                })()}'''
e=one(e,old_grips,new_grips,'roof direction indicator/handles')
a=a[:app_start]+e+a[app_end:]
a=one(a,
    "import { cleanSlab149, dragRoofLine149 } from './building/levelGeometry149'",
    "import { cleanSlab149, dragRoofLine149 } from './building/levelGeometry149'\nimport { snapRoofDrag149e } from './building/roofSnap149e' // STROM149E_ROOF_SNAP",
    'snap module import')
# Since the helper dragRoofLine149 is now delegated to roofSnap149e, remove unused import in App.
a=one(a,
    "import { cleanSlab149, dragRoofLine149 } from './building/levelGeometry149'",
    "import { cleanSlab149 } from './building/levelGeometry149'",
    'unused drag import')
# Add only one property to the actual editor invocation, retaining all of its old callbacks.
occurrences=list(re.finditer(r'<RoofEditor148\b',a))
if len(occurrences)!=1:raise RuntimeError(f'149e expected one JSX RoofEditor148 invocation, got {len(occurrences)}')
x=occurrences[0].end()
a=a[:x]+ ' onSelectRoof149e={setSelectedRoof148}' +a[x:]

# Preserve all pre-existing roof data and extend its normalized type with a name.
old_type='''  start: PointM
  end: PointM
  /** Degrees clockwise'''
new_type='''  start: PointM
  end: PointM
  name?: string // STROM149E_ROOF_NAME; legacy slopes remain valid
  /** Degrees clockwise'''
r=one(r,old_type,new_type,'roof optional name type')
old_return='''  return {id:r.id,roomId:r.roomId,levelId:r.levelId,start:{...r.start},end:{...r.end},
    directionDeg: ((directionDeg%360)+360)%360, pitchDeg, startHeightM}'''
new_return='''  return {id:r.id,roomId:r.roomId,levelId:r.levelId,start:{...r.start},end:{...r.end},
    ...(typeof r.name==='string'&&r.name.trim()?{name:r.name.trim().slice(0,60)}:{}),
    directionDeg: ((directionDeg%360)+360)%360, pitchDeg, startHeightM}'''
r=one(r,old_return,new_return,'name retained by roof model')

# Force each floor entry to one row and make the number inputs 5/4 digits wide.
# Grid areas are intentionally specific to the Blueprint layer menu, not wall detail.
c+='''
/* STROM149E_LEVEL_ROW: one level = one row, numeric inputs have sufficient width. */
.canvas-layer-menu:not(.wall-layer-menu) .layer-row {
  display:grid !important;
  grid-template-columns:26px 26px minmax(52px,1fr) minmax(76px,84px) minmax(62px,68px) !important;
  grid-template-areas:"eye grip name height slab" !important;
  gap:4px !important;
  align-items:center !important;
  padding:4px !important;
  min-height:47px;
}
.canvas-layer-menu:not(.wall-layer-menu) .layer-row > .layer-eye { grid-area:eye; }
.canvas-layer-menu:not(.wall-layer-menu) .layer-row > .layer-grip { grid-area:grip; }
.canvas-layer-menu:not(.wall-layer-menu) .layer-row > input[aria-label="Ebenenname"] { grid-area:name; width:100% !important;min-width:0;box-sizing:border-box;padding:2px !important; }
.canvas-layer-menu:not(.wall-layer-menu) .layer-row > .layer-height-control:not(.layer-slab-control149) {grid-area:height;}
.canvas-layer-menu:not(.wall-layer-menu) .layer-row > .layer-slab-control149 {grid-area:slab;}
.canvas-layer-menu:not(.wall-layer-menu) .layer-row > .layer-height-control {
  display:flex !important;flex-direction:column !important;align-items:stretch !important;
  min-width:0 !important;width:100% !important;max-width:none !important;
  gap:2px;margin:0 !important;padding:0 !important;border:0 !important;
}
.canvas-layer-menu:not(.wall-layer-menu) .layer-row > .layer-height-control span {
  white-space:nowrap !important;font-size:10px !important;line-height:1.1 !important;
  display:block !important;max-width:100%;
}
.canvas-layer-menu:not(.wall-layer-menu) .layer-row > .layer-height-control input {
  display:block !important;width:100% !important;max-width:100% !important;min-width:0 !important;
  box-sizing:border-box !important;padding:3px 2px !important;font-size:12px !important;
  text-align:left !important;height:28px !important;
}
.canvas-layer-menu:not(.wall-layer-menu) .layer-list {overflow-x:hidden;}
.strom-roof-direction149e {stroke:#2563eb;stroke-width:1.6;stroke-dasharray:5 3;pointer-events:none;opacity:.8;}
.strom-roof-direction-grip149e {fill:#dbecff;stroke:#1550a0;stroke-width:2;cursor:grab;pointer-events:all;touch-action:none;}
.strom-roof-reference-list149e {display:grid;gap:5px;max-height:150px;overflow:auto;}
.strom-roof-reference-entry149e {display:flex;gap:5px;align-items:center;}
.strom-roof-reference-entry149e button:first-child {min-width:0;flex:1;text-align:left;}
.strom-roof-reference-entry149e button:last-child {flex:0 0 auto;}
.strom-roof-reference149 > label {display:grid;gap:3px;font-size:11px;}
.strom-roof-field148 input[type="text"] {max-width:100%;min-height:30px;box-sizing:border-box;}
'''

# Atomic validation: only publish source edits after all markers validated.
new_editor=(asset/'RoofEditor148.tsx').read_text('utf8')
new_snap=(asset/'roofSnap149e.ts').read_text('utf8')
if 'STROM149E_ROOF_EDITOR' not in new_editor or 'STROM149E_ROOF_SNAP' not in new_snap:
    raise RuntimeError('149e resources failed verification')
for file,body in [(app,a),(roof,r),(css,c),(editor,new_editor),(snap,new_snap)]:
    file.write_text(body,encoding='utf8')
print('PASS 149e: incremental layout, named roofs, selection, physical inheritance, snapping and draggable direction applied')
STROM149E_PY
cat > "$RESOURCE_DIR/RoofEditor148.tsx" <<'STROM149E_EDITOR'
import { useEffect, useState, type ChangeEvent } from 'react'
import { readRoofSlopes148, saveRoofSlopes148, ROOF_EVENT148, type RoofSlope148 } from '../building/roofSlopes148'
import { cleanSlab149, levelElevations149, inheritRoofPlane149 } from '../building/levelGeometry149'

// STROM149E_ROOF_EDITOR: names, visible selection, cross-level physical plane and close-on-apply.
const dirs=[{value:0,label:'→ Osten / rechts'},{value:90,label:'↓ Süden / unten'},{value:180,label:'← Westen / links'},{value:270,label:'↑ Norden / oben'}]
const value=(num:number)=>Number.isFinite(num)?num:0
function roofName149e(item:RoofSlope148,index:number){return item.name?.trim() || `Dachschräge ${index+1}`}

export default function RoofEditor148({floorId,roofId,onClose,onChanged,onSelectRoof149e}: {
  floorId:string;roofId:string;onClose:()=>void;onChanged?:()=>void;onSelectRoof149e?:(id:string)=>void
}) {
  const [draft,setDraft]=useState<RoofSlope148|null>(null)
  const [notice,setNotice]=useState('')
  const [sourceRoofId149,setSourceRoofId149]=useState('')
  useEffect(()=>{
    setDraft(readRoofSlopes148(floorId,window.localStorage).find(item=>item.id===roofId)??null)
    setSourceRoofId149('');setNotice('')
  },[floorId,roofId])
  useEffect(()=>{
    const refresh=()=>setDraft(readRoofSlopes148(floorId,window.localStorage).find(item=>item.id===roofId)??null)
    window.addEventListener(ROOF_EVENT148,refresh)
    return ()=>window.removeEventListener(ROOF_EVENT148,refresh)
  },[floorId,roofId])
  if(!draft)return null
  const patch=(next:Partial<RoofSlope148>)=>setDraft(current=>current?{...current,...next}:current)
  const numeric=(label:string,n:number,step:number,min:number,max:number,update:(val:number)=>void,unit:string)=><label className="strom-roof-field148" key={label}>{label}
    <span><input type="number" value={Number(n.toFixed(3))} min={min} max={max} step={step}
      title={`${label} ${unit}`} onChange={(e:ChangeEvent<HTMLInputElement>)=>update(value(Number(e.target.value)))} />{unit}</span>
  </label>

  const allRoofs149e=readRoofSlopes148(floorId,window.localStorage)
  const otherRoofs149=allRoofs149e.filter(item=>item.id!==draft.id)
  const named149e=(item:RoofSlope148)=>roofName149e(item,allRoofs149e.findIndex(v=>v.id===item.id))

  function applySource149e(source:RoofSlope148){
    if(!draft)return
    try{
      const raw:unknown=JSON.parse(window.localStorage.getItem(`strom.floorplan.layers.${floorId}.list`)||'[]')
      const layers:Array<{id:string;heightM:number;slabThicknessM:number}>=Array.isArray(raw)?raw.flatMap((entry:unknown)=>{
        if(!entry||typeof entry!=='object')return []
        const obj=entry as Record<string,unknown>
        const height=Number(obj.heightM)
        return typeof obj.id==='string'&&Number.isFinite(height)?[{id:obj.id,heightM:height,slabThicknessM:cleanSlab149(obj.slabThicknessM)}]:[]
      }):[]
      // Same-level inheritance remains valid even if legacy levels lack metadata.
      const bothKnown=layers.some(item=>item.id===source.levelId)&&layers.some(item=>item.id===draft.levelId)
      if(!bothKnown&&source.levelId!==draft.levelId){
        setNotice('Ebene nicht gefunden. Bitte zuerst die vorhandenen Geschosse im Blueprint prüfen.');return
      }
      const elevations=bothKnown?levelElevations149(layers):{}
      const zSource=bothKnown?elevations[source.levelId]:0
      const zTarget=bothKnown?elevations[draft.levelId]:0
      const converted=inheritRoofPlane149(source,draft.start,draft.end,zSource,zTarget)
      if(converted.startHeightM<-15||converted.startHeightM>15){
        setNotice('Übernahme nicht möglich: Anfangshöhe außerhalb des gültigen Bereichs.');return
      }
      // Never replace the target's id, room, name, level or start/end positions.
      patch({pitchDeg:converted.pitchDeg,directionDeg:converted.directionDeg,startHeightM:converted.startHeightM})
      setSourceRoofId149(source.id)
      setNotice(`Dachebene von „${named149e(source)}“ übernommen. Mit Anwenden speichern.`)
    }catch(error){setNotice(error instanceof Error?error.message:String(error))}
  }
  function save(){
    if(!draft)return
    try{
      const list=readRoofSlopes148(floorId,window.localStorage)
      const index=list.findIndex(item=>item.id===draft.id)
      if(index<0)throw Error('Dachschräge nicht mehr vorhanden.')
      list[index]={...draft,name:draft.name?.trim().slice(0,60)||undefined}
      saveRoofSlopes148(floorId,list)
      onChanged?.()
      onClose()
    }catch(error){setNotice(error instanceof Error?error.message:String(error))}
  }
  function remove(){
    if(!draft)return
    try{
      saveRoofSlopes148(floorId,readRoofSlopes148(floorId,window.localStorage).filter(item=>item.id!==draft.id))
      onChanged?.();onClose()
    }catch(error){setNotice(error instanceof Error?error.message:String(error))}
  }
  return <section className="strom-roof-editor148" aria-label="Dachschräge bearbeiten">
    <header><strong>Dachschräge · Eigenschaften</strong><button type="button" title="Schließen" onClick={onClose}>×</button></header>
    <label className="strom-roof-field148">Name
      <input type="text" maxLength={60} value={draft.name??''} placeholder={named149e(draft)}
        onChange={(e:ChangeEvent<HTMLInputElement>)=>patch({name:e.target.value})}/>
    </label>
    {numeric('Neigung',draft.pitchDeg,1,0,65,v=>patch({pitchDeg:v}),'°')}
    {numeric('Beginnhöhe',Math.round(draft.startHeightM*1000),50,-15000,15000,v=>patch({startHeightM:v/1000}),'mm')}
    <label className="strom-roof-field148">Steigungsrichtung
      <select title="Ausrichtung der ansteigenden Dachfläche" value={dirs.some(item=>item.value===draft.directionDeg)?draft.directionDeg:'custom'}
        onChange={(e:ChangeEvent<HTMLSelectElement>)=>{if(e.target.value!=='custom')patch({directionDeg:Number(e.target.value)})}}>
        {dirs.map(d=><option key={d.value} value={d.value}>{d.label}</option>)}
        <option value="custom">Frei / Winkel</option>
      </select>
    </label>
    {numeric('Ausrichtung als Winkel',draft.directionDeg,1,0,359,v=>patch({directionDeg:v}),'°')}
    <fieldset className="strom-roof-reference149" aria-label="Bestehende Dachfläche übernehmen">
      <legend>Vorhandene Dachschrägen</legend>
      <label>Andere Schräge bearbeiten
        <select aria-label="Andere Dachschräge bearbeiten" value={draft.id} onChange={(event:ChangeEvent<HTMLSelectElement>)=>onSelectRoof149e?.(event.target.value)}>
          {allRoofs149e.map(item=><option key={item.id} value={item.id}>{named149e(item)} · {item.levelId}</option>)}
        </select>
      </label>
      <label>Dachebene übernehmen
        <select aria-label="Dachebene übernehmen von" value={sourceRoofId149}
          onChange={(event:ChangeEvent<HTMLSelectElement>)=>setSourceRoofId149(event.target.value)}>
          <option value="">Dachschräge auswählen …</option>
          {otherRoofs149.map(item=><option key={item.id} value={item.id}>{named149e(item)} · {item.levelId} · {item.pitchDeg}°</option>)}
        </select>
      </label>
      <button type="button" disabled={!sourceRoofId149} onClick={()=>{
        const source=otherRoofs149.find(item=>item.id===sourceRoofId149)
        if(source)applySource149e(source)
      }}>Dachebene übernehmen</button>
      <div className="strom-roof-reference-list149e" aria-label="Dachschrägen per Klick auswählen">
        {otherRoofs149.map(item=><div className="strom-roof-reference-entry149e" key={item.id}>
          <button type="button" onClick={()=>onSelectRoof149e?.(item.id)} title="Diese Dachschräge bearbeiten">{named149e(item)} · {item.levelId}</button>
          <button type="button" onClick={()=>applySource149e(item)} title="Parameter der vorhandenen Dachebene übernehmen">Kopieren</button>
        </div>)}
      </div>
    </fieldset>
    <details><summary>Start- und Endpunkte (mm)</summary>
      {numeric('Start X',draft.start.x*1000,50,-100000,100000,v=>patch({start:{...draft.start,x:v/1000}}),'mm')}
      {numeric('Start Y',draft.start.y*1000,50,-100000,100000,v=>patch({start:{...draft.start,y:v/1000}}),'mm')}
      {numeric('Ende X',draft.end.x*1000,50,-100000,100000,v=>patch({end:{...draft.end,x:v/1000}}),'mm')}
      {numeric('Ende Y',draft.end.y*1000,50,-100000,100000,v=>patch({end:{...draft.end,y:v/1000}}),'mm')}
    </details>
    <div className="strom-roof-actions148">
      <button type="button" onClick={save} title="Speichern und Fenster schließen">Anwenden</button>
      <button type="button" onClick={remove} title="Dachschräge löschen">Löschen</button>
    </div>
    {notice&&<p role="status">{notice}</p>}
  </section>
}
STROM149E_EDITOR
cat > "$RESOURCE_DIR/roofSnap149e.ts" <<'STROM149E_SNAP'
import type { PointM, Room } from '../types'
import type { RoofSlope148 } from './roofSlopes148'
import { dragRoofLine149 } from './levelGeometry149'

// STROM149E_ROOF_SNAP: same 0.18 m proximity as the Blueprint room snapping.
const THRESHOLD149E = 0.18
const rounded149e = (n: number) => Math.round(n*1000)/1000
const point149e = (point: PointM): PointM => ({x:rounded149e(point.x),y:rounded149e(point.y)})

function nearestOnSegment149e(point: PointM,a:PointM,b:PointM):PointM {
  const dx=b.x-a.x,dy=b.y-a.y
  const len=dx*dx+dy*dy
  if (len<1e-12) return a
  const t=Math.max(0,Math.min(1,((point.x-a.x)*dx+(point.y-a.y)*dy)/len))
  return {x:a.x+t*dx,y:a.y+t*dy}
}

/** Single-point snapping to rooms, wall lines, corners and other roof endpoints. */
export function snapRoofPoint149e(point:PointM, rooms:readonly Room[],roofs:readonly RoofSlope148[],ignoreRoofId?:string):PointM {
  let best=point
  let bestD=THRESHOLD149E
  const offer=(p:PointM)=>{
    const distance=Math.hypot(point.x-p.x,point.y-p.y)
    if(distance<bestD-1e-9){bestD=distance;best=p}
  }
  for(const room of rooms){
    const vertices=room.vertices
    for(let i=0;i<vertices.length;i++){
      const a=vertices[i],b=vertices[(i+1)%vertices.length]
      offer(a)
      offer(nearestOnSegment149e(point,a,b))
      // Existing Blueprint walls can snap to matching exterior faces.
      const wall=Math.max(0,room.wallThicknessM||0)
      if(wall>0&&wall<1){
        const dx=b.x-a.x,dy=b.y-a.y,den=Math.hypot(dx,dy)
        if(den>1e-9){
          const normal={x:-dy/den*wall,y:dx/den*wall}
          offer(nearestOnSegment149e(point,{x:a.x+normal.x,y:a.y+normal.y},{x:b.x+normal.x,y:b.y+normal.y}))
          offer(nearestOnSegment149e(point,{x:a.x-normal.x,y:a.y-normal.y},{x:b.x-normal.x,y:b.y-normal.y}))
        }
      }
    }
  }
  for(const roof of roofs){
    if(roof.id===ignoreRoofId)continue
    offer(roof.start);offer(roof.end)
    offer(nearestOnSegment149e(point,roof.start,roof.end))
  }
  // Also align individual axes, as for regular room/element handles.
  let x=best.x,y=best.y
  let xD=Math.abs(x-point.x)>1e-9?Math.abs(x-point.x):0.12
  let yD=Math.abs(y-point.y)>1e-9?Math.abs(y-point.y):0.12
  for(const room of rooms)for(const p of room.vertices){
    const dx=Math.abs(p.x-point.x),dy=Math.abs(p.y-point.y)
    if(dx<xD-1e-9){xD=dx;x=p.x}
    if(dy<yD-1e-9){yD=dy;y=p.y}
  }
  for(const roof of roofs){if(roof.id===ignoreRoofId)continue
    for(const p of [roof.start,roof.end]){
      const dx=Math.abs(p.x-point.x),dy=Math.abs(p.y-point.y)
      if(dx<xD-1e-9){xD=dx;x=p.x}
      if(dy<yD-1e-9){yD=dy;y=p.y}
    }
  }
  return point149e({x,y})
}

/** Keep line length when moving; snap the moved endpoints without deforming the roof. */
export function snapRoofDrag149e(
  roof:RoofSlope148,mode:'move'|'start'|'end'|'direction',
  dx:number,dy:number,pointer:PointM,
  rooms:readonly Room[],roofs:readonly RoofSlope148[],shiftKey=false
):RoofSlope148 {
  if(mode==='direction'){
    const center={x:(roof.start.x+roof.end.x)/2,y:(roof.start.y+roof.end.y)/2}
    if(Math.hypot(pointer.x-center.x,pointer.y-center.y)<0.03)return roof
    let angle=(Math.atan2(pointer.y-center.y,pointer.x-center.x)*180/Math.PI+360)%360
    const increment=shiftKey?15:90
    const closest=Math.round(angle/increment)*increment
    if(shiftKey||Math.abs(angle-closest)<4||Math.abs(angle-closest+360)<4||Math.abs(angle-closest-360)<4){angle=closest}
    return {...roof,directionDeg:rounded149e((angle+360)%360)}
  }
  const moved=dragRoofLine149(roof,mode,dx,dy)
  if(mode!=='move'){
    const p=mode==='start'?moved.start:moved.end
    const snapped=snapRoofPoint149e(p,rooms,roofs,roof.id)
    return dragRoofLine149(roof,mode,snapped.x-(mode==='start'?roof.start.x:roof.end.x),snapped.y-(mode==='start'?roof.start.y:roof.end.y))
  }
  let bestShift={x:0,y:0},bestDistance=THRESHOLD149E
  for(const endpoint of [moved.start,moved.end]){
    const snapped=snapRoofPoint149e(endpoint,rooms,roofs,roof.id)
    const d=Math.hypot(snapped.x-endpoint.x,snapped.y-endpoint.y)
    if(d>1e-8&&d<bestDistance){bestDistance=d;bestShift={x:snapped.x-endpoint.x,y:snapped.y-endpoint.y}}
  }
  return {...moved,start:point149e({x:moved.start.x+bestShift.x,y:moved.start.y+bestShift.y}),end:point149e({x:moved.end.x+bestShift.x,y:moved.end.y+bestShift.y})}
}
STROM149E_SNAP

log "3) Apply incremental 149e in isolated source ..."
python3 -m py_compile "$RESOURCE_DIR/patch149e.py" >>"$DIAG_LOG" 2>&1 || fail "149e patch Python syntax failed"
STROM149E_ROOT="$WORK_DIR" STROM149E_ASSETS="$RESOURCE_DIR" \
  python3 "$RESOURCE_DIR/patch149e.py" >>"$DIAG_LOG" 2>&1 || fail "149e patch failed; GitHub and Stage unchanged"
log "4) TypeScript AST audit ..."
STROM149E_SOURCE="$WORK_DIR/frontend/src" STROM149E_TS="$DEPENDENCIES/typescript" node <<'STROM149E_AST' >>"$DIAG_LOG" 2>&1 || fail "AST/JSX audit failed"
const fs=require('fs'),path=require('path'),ts=require(process.env.STROM149E_TS),root=process.env.STROM149E_SOURCE
const items=['App.tsx','components/RoofEditor148.tsx','building/roofSlopes148.ts','building/roofSnap149e.ts','components/Building3DWorkspace.tsx']
for(const rel of items){
 const file=path.join(root,rel),text=fs.readFileSync(file,'utf8')
 const ast=ts.createSourceFile(file,text,ts.ScriptTarget.Latest,true,rel.endsWith('tsx')?ts.ScriptKind.TSX:ts.ScriptKind.TS)
 if(ast.parseDiagnostics.length)throw Error(rel+' parse: '+ast.parseDiagnostics.map(x=>ts.flattenDiagnosticMessageText(x.messageText,' ')).join('; '))
 function walk(node){
  if(ts.isJsxOpeningElement(node)||ts.isJsxSelfClosingElement(node)){
   const found=new Set()
   for(const prop of node.attributes.properties){if(!ts.isJsxAttribute(prop))continue;const key=prop.name.getText(ast);if(found.has(key))throw Error(rel+': duplicate JSX attr '+key);found.add(key)}
  }
  ts.forEachChild(node,walk)
 }
 walk(ast)
}
const app=fs.readFileSync(path.join(root,'App.tsx'),'utf8')
for(const marker of ['STROM149_ROOF_DRAG','STROM149E_ROOF_SNAP','STROM149E_ROOF_HANDLES','STROM148_ROOF_EDIT'])if(!app.includes(marker))throw Error('Blueprint marker missing '+marker)
console.log('PASS AST: TS/TSX syntax, no duplicate JSX props, old features preserved')
STROM149E_AST
log "5) Full TypeScript and Vite build ..."
( cd "$WORK_DIR/frontend"; VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || fail "TypeScript/Vite build failed before GitHub push"
log "5.1) Snap and roof persistence regression tests ..."
STROM149E_SOURCE="$WORK_DIR/frontend/src" STROM149E_TS="$DEPENDENCIES/typescript" node <<'STROM149E_TEST' >>"$DIAG_LOG" 2>&1 || fail "149e regression test failed"
const assert=require('assert'),fs=require('fs'),path=require('path'),ts=require(process.env.STROM149E_TS),root=process.env.STROM149E_SOURCE
function load(rel,mocks={}){
 const code=fs.readFileSync(path.join(root,rel),'utf8')
 const transp=ts.transpileModule(code,{fileName:rel,reportDiagnostics:true,compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}})
 if(transp.diagnostics?.some(d=>d.category===ts.DiagnosticCategory.Error))throw Error(rel+' transpile parse error')
 const m={exports:{}};new Function('module','exports','require',transp.outputText)(m,m.exports,id=>mocks[id]||{})
 return m.exports
}
const geo=load('building/levelGeometry149.ts')
const roofModule=load('building/roofSlopes148.ts')
const snap=load('building/roofSnap149e.ts',{'./levelGeometry149':geo})
const room={id:'r1',floorId:'f',name:'room',shapeType:'rectangle',wallThicknessM:.15,vertices:[{x:0,y:0},{x:5,y:0},{x:5,y:4},{x:0,y:4}]}
const roof={id:'roof1',roomId:'r1',levelId:'L1',start:{x:1,y:1},end:{x:1,y:3},directionDeg:0,pitchDeg:32,startHeightM:1.1,name:'Suedost'}
const n=roofModule.normalizeSlope148(roof)
assert.strictEqual(n.name,'Suedost')
assert.strictEqual(roofModule.normalizeSlope148({...roof,name:undefined}).name,undefined)
const rotated=snap.snapRoofDrag149e(roof,'direction',0,0,{x:2,y:2},[room],[roof])
assert.strictEqual(rotated.directionDeg,0)
assert.strictEqual(rotated.pitchDeg,32)
const moved=snap.snapRoofDrag149e(roof,'move',.3,.2,{x:1.3,y:1.2},[],[roof])
assert(Math.abs((moved.end.y-moved.start.y)-2)<.0001)
assert(Math.abs(moved.start.x-1.3)<.0001)
const near=snap.snapRoofPoint149e({x:4.97,y:.03},[room],[],roof.id)
assert(Math.abs(near.x-5)<.001&&Math.abs(near.y)<.001)
const levels=[{id:'high',heightM:2.4,slabThicknessM:.2},{id:'low',heightM:2.5,slabThicknessM:.15}]
const elev=geo.levelElevations149(levels)
const copied=geo.inheritRoofPlane149(roof,{x:2,y:1},{x:2,y:3},elev.low,elev.high)
assert(Math.abs(copied.startHeightM-(1.1+Math.tan(32*Math.PI/180)-(2.5+.2)))<.001)
console.log('PASS regression: named legacy roofs, drag/angle, endpoint snapping, cross-floor plane')
STROM149E_TEST
rm -rf -- "$RESOURCE_DIR"
mkdir -p "$WORK_DIR/docs"
cat > "$WORK_DIR/docs/STROM_UPDATE_149e.md" <<'STROM149E_DOC'
# STROM 149e: incremental improvements on 149c
- Each Blueprint level entry is one row; height inputs allow five digits and floor thickness four digits.
- Roof slopes support optional editable names; existing stored data is retained without migration.
- Other roof slopes can be selected by click and their world-space roof plane can be inherited.
- Dragging a whole roof line or endpoints snaps to wall geometry, room vertices and other roof endpoints.
- A draggable direction handle changes roof orientation; Shift constrains it to 15-degree increments.
- Applying roof properties saves and closes the editor; selecting a roof opens it again.
- Browser-local metadata remains browser-local; 3D geometry and production are unchanged.
STROM149E_DOC
log "6) Transfer verified source into Stage ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "Stage transfer failed; backup at $BACKUP_DIR"
if [ "${PATCH_ONLY:-0}" = "1" ]; then log "PATCH_ONLY passed; nothing deployed"; exit 0; fi
log "7) Build and deploy to /strom-test/ only ..."
( cd "$STAGE_DIR/frontend"; VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || fail "Stage rebuild failed; backup at $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "Build output frontend/dist missing"
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || fail "Test web deploy failed; backup at $BACKUP_DIR"
log "SUCCESS: 149e deployed to https://home.moja.de/strom-test/"
log "Production unchanged. Stage backup: $BACKUP_DIR"
