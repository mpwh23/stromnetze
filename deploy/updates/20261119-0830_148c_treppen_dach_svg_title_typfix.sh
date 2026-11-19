#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261119-0830_148c_treppen_dach_svg_title_typfix"
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
COMMIT_MESSAGE="Update 148c: robust Blueprint JSX insertion, stairwell links and parametric roofs"
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
  echo "2) Update 148c im isolierten Git-Checkout bauen und nach GitHub pushen ..."
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

  echo "1.3) Update 148 isoliert anwenden, TypeScript/Vite-Build und Tests pruefen ..."
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
fail() {
  log ""
  log "FEHLER: $*"
  log "Diagnose: $DIAG_LOG"
  if [ -f "$DIAG_LOG" ]; then
    echo '--- Letzte Diagnosezeilen ---'
    tail -n 100 "$DIAG_LOG"
    echo '--- Ende Diagnose ---'
  fi
  exit 1
}
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
  for candidate in \
      /home/mpwh/.nvm/versions/node/*/bin/node \
      /root/.nvm/versions/node/*/bin/node \
      /usr/local/bin/node /usr/bin/node; do
    [ -x "$candidate" ] || continue
    version="$($candidate -p 'process.versions.node' 2>/dev/null || true)"
    node_supported "$version" || continue
    if [ -z "$best" ] || [ "$(printf '%s\n%s\n' "$best_v" "$version" | sort -V | tail -n 1)" = "$version" ]; then
      best="$candidate"; best_v="$version"
    fi
  done
  [ -n "$best" ] || fail "Kein kompatibles Node fuer Vite gefunden."
  export PATH="$(dirname "$best"):$PATH"
  hash -r 2>/dev/null || true
  log "Node: $best (v$best_v), npm: $(npm -v 2>/dev/null || echo fehlt)"
}


log "=== Update 148c / JSX-robuster Blueprint-Einbau, Treppenraum-Paare und Dachschraegen ==="
log "Stage: $STAGE_DIR"
log "Diagnose: $DIAG_LOG"
log "Produktion, vorhandene Raum-/Wand-/Treppengeometrie unveraendert; neue Dachobjekte nur als Zusatz."
for file in \
  frontend/src/App.tsx \
  frontend/src/styles.css \
  frontend/src/components/Building3DWorkspace.tsx \
  frontend/src/building/stairVisibility143.ts \
  frontend/src/building/stair3d.ts; do
  [ -s "$STAGE_DIR/$file" ] || fail "148 benoetigt aktuelle STROM-Stage: $file fehlt"
done
# 148a: Verify the *result* of 147b, not a marker that 147b deliberately removed.
# The old check required "wall-front-window-mullion146"; 147b removed that JSX
# because the user requested windows without a cross. It can never be a valid
# prerequisite for 148 on a successfully patched 147b installation.
APP_SOURCE="$STAGE_DIR/frontend/src/App.tsx"
SCENE_SOURCE="$STAGE_DIR/frontend/src/components/Building3DWorkspace.tsx"
for marker in STROM146_ZOOM STROM147_STAIR_DIRECTIONS wall-front-window-frame146 wall-front-window-glass146; do
  grep -Fq "$marker" "$APP_SOURCE" || fail "148a benoetigt den erfolgreich installierten Stand 147b (App-Merkmal fehlt: $marker)"
done
for removed in 'className="wall-front-window-mullion146"' 'className="wall-front-window-transom146"'; do
  if grep -Fq "$removed" "$APP_SOURCE"; then
    fail "148a: Fensterkreuz ist noch vorhanden ($removed). Bitte erst Update 147b pruefen."
  fi
done
for marker in STROM146_ALL_LEVELS 'function StairSolid(' STROM141_WALL_HOVER STROM147_DOWN_SCENE; do
  grep -Fq "$marker" "$SCENE_SOURCE" || fail "148a: 3D-Stand inkonsistent, erwartet: $marker"
done
log "148b: Preflight 147b OK (Fenster ohne Kreuz, 3D-Treppe/Etagen vorhanden)."
select_node

log "1) Stage-Vorabpruefung und Backup ..."
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PATCH_ONLY: isolierte Git-Arbeitskopie; kein Stage-Backup."
else
  cp -a "$STAGE_DIR" "$BACKUP_DIR" || fail "Backup fehlgeschlagen. Stage bleibt unveraendert."
fi

log "2) Arbeitskopie vorbereiten ..."
rsync -a --exclude='/frontend/node_modules' --exclude='/frontend/dist' --exclude='/.git' \
  "$STAGE_DIR/" "$WORK_DIR/" >> "$DIAG_LOG" 2>&1 || fail "Arbeitskopie fehlgeschlagen"
mkdir -p "$WORK_DIR/frontend/src/building" "$WORK_DIR/docs"
rm -rf "$WORK_DIR/frontend/node_modules"
DEPENDENCIES=""
for candidate in "$STAGE_DIR/frontend/node_modules" "$PROD_DIR/frontend/node_modules" /home/mpwh/strom_stage/frontend/node_modules; do
  if [ -f "$candidate/typescript/lib/typescript.js" ] && [ -d "$candidate/vite" ] && [ -d "$candidate/three" ]; then
    DEPENDENCIES="$candidate"; break
  fi
done
[ -n "$DEPENDENCIES" ] || fail "148: TypeScript/Vite/Three.js fehlen im Stage-/Produktiv-Frontend."
ln -s "$DEPENDENCIES" "$WORK_DIR/frontend/node_modules"

log "3) Neue Treppenraum-Verknuepfung und Dachschraegen in isolierte Arbeitskopie integrieren ..."
for marker in STROM147_STAIR_DIRECTIONS; do
  grep -qF "$marker" "$WORK_DIR/frontend/src/App.tsx" || fail "148 benoetigt erfolgreiches Update 147b ($marker fehlt)"
done
for marker in STROM147_DOWN_SCENE STROM146_ALL_LEVELS; do
  grep -qF "$marker" "$WORK_DIR/frontend/src/components/Building3DWorkspace.tsx" || fail "148 benoetigt erfolgreiches Update 147b ($marker fehlt)"
done
STROM148_RESOURCES="$WORK_DIR/strom148_resources"
mkdir -p "$STROM148_RESOURCES"
cat > "$STROM148_RESOURCES/roofSlopes148.ts" <<'STROM148_ROOF_TS'
import type { PointM, Room } from '../types'

/** STROM148: one physical roof-slope record, shared by Blueprint and both true-3D views. */
export type RoofSlope148 = {
  id: string
  roomId: string
  levelId: string
  start: PointM
  end: PointM
  /** Degrees clockwise from +X on the Blueprint (0=right, 90=down). */
  directionDeg: number
  pitchDeg: number
  /** Height above the floor of the roof's own level (metres). */
  startHeightM: number
}
export const ROOF_EVENT148 = 'strom:roof-slopes-changed148'
export const roofKey148 = (floorId: string) => `strom.floorplan.roofSlopes148.${floorId}`

function validPoint(point: unknown): point is PointM {
  if (!point || typeof point !== 'object') return false
  const p = point as Record<string, unknown>
  return typeof p.x === 'number' && Number.isFinite(p.x) && typeof p.y === 'number' && Number.isFinite(p.y)
}
export function normalizeSlope148(v: unknown): RoofSlope148 | null {
  if (!v || typeof v !== 'object') return null
  const r = v as Record<string, unknown>
  if (typeof r.id !== 'string' || !r.id || typeof r.roomId !== 'string' || !r.roomId ||
      typeof r.levelId !== 'string' || !r.levelId || !validPoint(r.start) || !validPoint(r.end)) return null
  const pitchDeg = Number(r.pitchDeg), startHeightM = Number(r.startHeightM), directionDeg = Number(r.directionDeg)
  if (![pitchDeg, startHeightM, directionDeg].every(Number.isFinite) ||
      pitchDeg < 0 || pitchDeg > 65 || startHeightM < 0 || startHeightM > 15 ||
      Math.hypot(r.end.x-r.start.x, r.end.y-r.start.y) < 0.03) return null
  return {id:r.id,roomId:r.roomId,levelId:r.levelId,start:{...r.start},end:{...r.end},
    directionDeg: ((directionDeg%360)+360)%360, pitchDeg, startHeightM}
}
export function readRoofSlopes148(floorId: string, store: Pick<Storage,'getItem'>): RoofSlope148[] {
  try {
    const value: unknown = JSON.parse(store.getItem(roofKey148(floorId)) || '[]')
    if (!Array.isArray(value)) return []
    const used = new Set<string>()
    return value.flatMap((entry: unknown) => {
      const roof = normalizeSlope148(entry)
      if (!roof || used.has(roof.id)) return []
      used.add(roof.id)
      return [roof]
    })
  } catch { return [] }
}
export function saveRoofSlopes148(floorId: string, list: RoofSlope148[]) {
  if (typeof window === 'undefined') return
  const valid = list.map(normalizeSlope148)
  if (valid.some((roof) => !roof)) throw Error('Dachschräge: ungültige Geometrie oder Parameter.')
  window.localStorage.setItem(roofKey148(floorId), JSON.stringify(valid))
  window.dispatchEvent(new CustomEvent(ROOF_EVENT148, { detail: {floorId} }))
}
export function angleVector148(angle: number): PointM {
  const rad = angle*Math.PI/180
  return {x:Math.cos(rad), y:Math.sin(rad)}
}
export function roofHeight148(roof: RoofSlope148, p: PointM): number {
  const axis = angleVector148(roof.directionDeg)
  const run = (p.x-roof.start.x)*axis.x + (p.y-roof.start.y)*axis.y
  return roof.startHeightM + run * Math.tan(roof.pitchDeg*Math.PI/180)
}
/** Choose the inward-facing normal for a line drawn on a room boundary. */
export function inwardRoofAngle148(start: PointM, end: PointM, vertices: PointM[]): number {
  const centroid = vertices.reduce((s,p)=>({x:s.x+p.x/vertices.length,y:s.y+p.y/vertices.length}),{x:0,y:0})
  const vx=end.x-start.x, vy=end.y-start.y
  const n1={x:-vy,y:vx}
  const mid={x:(start.x+end.x)/2,y:(start.y+end.y)/2}
  const dot=n1.x*(centroid.x-mid.x)+n1.y*(centroid.y-mid.y)
  const n=dot>=0?n1:{x:-n1.x,y:-n1.y}
  return Math.round(((Math.atan2(n.y,n.x)*180/Math.PI)%360+360)%360)
}
export function nearestRoomEdge148(point: PointM, vertices: PointM[], toleranceM = 0.3): PointM {
  let best:PointM=point, bestD=toleranceM
  for(let i=0;i<vertices.length;i++) {
    const a=vertices[i],b=vertices[(i+1)%vertices.length]
    const dx=b.x-a.x,dy=b.y-a.y, denom=dx*dx+dy*dy
    if (denom<1e-12) continue
    const t=Math.max(0,Math.min(1,((point.x-a.x)*dx+(point.y-a.y)*dy)/denom))
    const projected={x:a.x+t*dx,y:a.y+t*dy}
    const d=Math.hypot(projected.x-point.x,projected.y-point.y)
    if (d<bestD) {bestD=d;best=projected}
  }
  return best
}
export function roofsForRoom148(rooms: Room[], slopes: RoofSlope148[], roomId: string, levelId: string) {
  return rooms.some(r=>r.id===roomId) ? slopes.filter(r=>r.roomId===roomId && r.levelId===levelId) : []
}
STROM148_ROOF_TS
cat > "$STROM148_RESOURCES/stairLinks148.ts" <<'STROM148_STAIR_TS'
import type { Room } from '../types'
import { sameStairFootprint147, type StairDirection147 } from './stairOverlay147'

/** STROM148: stable identities remain linked even if their room polygons diverge. */
export const stairPairsKey148=(floorId:string)=>`strom.floorplan.layers.${floorId}.stairPairs148`
export type StairPairs148 = Record<string,string>
export function readStairPairs148(floorId:string, storage:Pick<Storage,'getItem'>):StairPairs148 {
  try {
    const value:unknown=JSON.parse(storage.getItem(stairPairsKey148(floorId))||'{}')
    if (!value||typeof value!=='object'||Array.isArray(value))return {}
    const next:StairPairs148={}
    for(const [a,b] of Object.entries(value))if(typeof b==='string'&&a!==b&&b)next[a]=b
    return next
  }catch{return {}}
}
export function saveStairPairs148(floorId:string, pairs:StairPairs148) {
  window.localStorage.setItem(stairPairsKey148(floorId),JSON.stringify(pairs))
  window.dispatchEvent(new Event('strom:blueprint-levels-changed'))
}
export function linkStairs148(current:StairPairs148, a:string,b:string):StairPairs148 {
  if(a===b)throw Error('Ein Raum kann nicht mit sich selbst verknüpft werden.')
  const next={...current}
  // Detach only existing links involving the two requested rooms.
  for(const [id,other] of Object.entries(next))if([a,b].includes(id)||[a,b].includes(other))delete next[id]
  next[a]=b;next[b]=a
  return next
}
/** One-time upgrade for existing v147 paired up/down stair rooms. */
export function inferLegacyStairPairs148(
  rooms:Room[], assignments:Record<string,string>, directions:Record<string,StairDirection147>, pairs:StairPairs148,
):StairPairs148 {
  let next={...pairs}
  for(const room of rooms) {
    if(room.roomType!=='stair'||directions[room.id]!=='up'||next[room.id])continue
    const candidates=rooms.filter(other=>other.roomType==='stair'&&other.id!==room.id&&
      directions[other.id]==='down'&&!next[other.id]&&
      (assignments[other.id]||'layer-main')===(assignments[room.id]||'layer-main'))
    const matches=candidates.filter(other=>sameStairFootprint147(room,other))
    if(matches.length===1) {next=linkStairs148(next,room.id,matches[0].id);continue}
    // The 147b clone carries the explicit "(abwärts)" suffix. Migrate a pair
    // whose shape was edited before the stable ID mapping existed, but only
    // when the name-based match is unambiguous.
    const prefix=room.name.trim().replace(/\s*\((?:aufwärts|abwärts)\)$/i,'')
    const byCloneName=candidates.filter(other=>other.name.trim()===`${prefix} (abwärts)`)
    if(byCloneName.length===1)next=linkStairs148(next,room.id,byCloneName[0].id)
  }
  return next
}
export type StairPortal148={room:Room;sourceLayerId:string;targetLayerId:string}
/** A physical staircase is referenced on the next floor; it is not duplicated as a database room. */
export function linkedStairPortals148(
  rooms:Room[],layers:{id:string}[],assignments:Record<string,string>,directions:Record<string,StairDirection147>,targetLayerId:string,
):StairPortal148[] {
  const targetIndex=layers.findIndex(l=>l.id===targetLayerId)
  if(targetIndex<0)return []
  return rooms.flatMap(room=>{
    if(room.roomType!=='stair')return []
    const sourceLayerId=assignments[room.id]||'layer-main'
    const sourceIndex=layers.findIndex(l=>l.id===sourceLayerId)
    const direction=directions[room.id]
    if(sourceIndex<0 || !((direction==='up' && sourceIndex+1===targetIndex)||(direction==='down'&&sourceIndex-1===targetIndex)))return []
    return [{room,sourceLayerId,targetLayerId}]
  })
}
STROM148_STAIR_TS
cat > "$STROM148_RESOURCES/RoofEditor148.tsx" <<'STROM148_EDITOR_TSX'
import { useEffect, useState, type ChangeEvent } from 'react'
import { readRoofSlopes148, saveRoofSlopes148, type RoofSlope148 } from '../building/roofSlopes148'

const dirs=[{value:0,label:'→ Osten / rechts'},{value:90,label:'↓ Süden / unten'},{value:180,label:'← Westen / links'},{value:270,label:'↑ Norden / oben'}]
const value=(num:number)=>Number.isFinite(num)?num:0
export default function RoofEditor148({floorId,roofId,onClose,onChanged}: {
  floorId:string;roofId:string;onClose:()=>void;onChanged?:()=>void
}) {
  const [draft,setDraft]=useState<RoofSlope148|null>(null)
  const [notice,setNotice]=useState('')
  useEffect(()=>{
    setDraft(readRoofSlopes148(floorId,window.localStorage).find(item=>item.id===roofId)??null)
    setNotice('')
  },[floorId,roofId])
  if(!draft)return null
  const patch=(next:Partial<RoofSlope148>)=>setDraft(current=>current?{...current,...next}:current)
  const numeric=(label:string,n:number,step:number,min:number,max:number,update:(val:number)=>void,unit:string)=>
    <label className="strom-roof-field148" key={label}>{label}
      <span><input type="number" value={Number(n.toFixed(3))} min={min} max={max} step={step}
        title={`${label} ${unit}`} onChange={(e:ChangeEvent<HTMLInputElement>)=>update(value(Number(e.target.value)))} />{unit}</span>
    </label>
  function save() {
    if(!draft)return
    try {
      const list=readRoofSlopes148(floorId,window.localStorage)
      const position=list.findIndex(item=>item.id===draft.id)
      if(position<0)throw Error('Dachschräge nicht mehr vorhanden.')
      list[position]=draft
      saveRoofSlopes148(floorId,list)
      setNotice('Dachschräge gespeichert und in 2D/3D aktualisiert.')
      onChanged?.()
    }catch(error){setNotice(error instanceof Error?error.message:String(error))}
  }
  function remove() {
    if(!draft)return
    try {
      const list=readRoofSlopes148(floorId,window.localStorage).filter(item=>item.id!==draft.id)
      saveRoofSlopes148(floorId,list)
      onChanged?.();onClose()
    }catch(error){setNotice(error instanceof Error?error.message:String(error))}
  }
  return <section className="strom-roof-editor148" aria-label="Dachschräge bearbeiten">
    <header><strong>Dachschräge · Eigenschaften</strong><button type="button" title="Schließen" onClick={onClose}>×</button></header>
    {numeric('Neigung',draft.pitchDeg,1,0,65,v=>patch({pitchDeg:v}),'°')}
    {numeric('Beginnhöhe',Math.round(draft.startHeightM*1000),50,0,15000,v=>patch({startHeightM:v/1000}),'mm')}
    <label className="strom-roof-field148">Steigungsrichtung
      <select title="Ausrichtung der ansteigenden Dachfläche" value={dirs.some(d=>d.value===draft.directionDeg)?draft.directionDeg:'custom'}
        onChange={(e:ChangeEvent<HTMLSelectElement>)=>{if(e.target.value!=='custom')patch({directionDeg:Number(e.target.value)})}}>
        {dirs.map(d=><option key={d.value} value={d.value}>{d.label}</option>)}
        <option value="custom">Frei / Winkel</option>
      </select>
    </label>
    {numeric('Ausrichtung als Winkel',draft.directionDeg,1,0,359,v=>patch({directionDeg:v}),'°')}
    <details><summary>Startlinie bearbeiten (mm)</summary>
      {numeric('Start X',draft.start.x*1000,50,-100000,100000,v=>patch({start:{...draft.start,x:v/1000}}),'mm')}
      {numeric('Start Y',draft.start.y*1000,50,-100000,100000,v=>patch({start:{...draft.start,y:v/1000}}),'mm')}
      {numeric('Ende X',draft.end.x*1000,50,-100000,100000,v=>patch({end:{...draft.end,x:v/1000}}),'mm')}
      {numeric('Ende Y',draft.end.y*1000,50,-100000,100000,v=>patch({end:{...draft.end,y:v/1000}}),'mm')}
    </details>
    <div className="strom-roof-actions148"><button type="button" onClick={save} title="Änderungen in Blueprint, Wanddetail und 3D Haus übernehmen">Speichern</button>
      <button type="button" onClick={remove} title="Diese Dachschräge löschen; andere Schrägen im Raum bleiben erhalten">Löschen</button></div>
    {notice&&<p role="status">{notice}</p>}
  </section>
}
STROM148_EDITOR_TSX
cat > "$STROM148_RESOURCES/RoofMeshes148.tsx" <<'STROM148_MESH_TSX'
import { useEffect, useMemo, useState } from 'react'
import type { ThreeEvent } from '@react-three/fiber'
import * as THREE from 'three'
import type { PointM } from '../types'
import { readRoofSlopes148, roofHeight148, type RoofSlope148 } from '../building/roofSlopes148'

type Room148={id:string;vertices:PointM[];kind?:string}
type Sector148={roof:RoofSlope148;geometry:THREE.BufferGeometry}

function signedArea148(poly:PointM[]) {
  return poly.reduce((total,p,i)=>{const q=poly[(i+1)%poly.length];return total+p.x*q.y-q.x*p.y},0)/2
}
function clipHalfplane148(poly:PointM[], fn:(point:PointM)=>number):PointM[] {
  if(!poly.length)return []
  const clipped:PointM[]=[]
  for(let i=0;i<poly.length;i++) {
    const a=poly[i],b=poly[(i+1)%poly.length],da=fn(a),db=fn(b)
    const insideA=da<=0,insideB=db<=0
    if(insideA)clipped.push(a)
    if(insideA!==insideB) {
      const t=Math.min(1,Math.max(0,da/(da-db)))
      clipped.push({x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t})
    }
  }
  return clipped
}
/** Exact planar intersection of all roof slopes over every room-triangulation face.
 * Each resulting polygon belongs to exactly one roof record: no stacked coplanar meshes. */
export function roofSectors148(rooms:Room148[],slopes:RoofSlope148[]):Sector148[] {
  const output:Sector148[]=[]
  for(const room of rooms) {
    if(room.kind==='outer')continue
    const group=slopes.filter(s=>s.roomId===room.id)
    if(!group.length)continue
    const contour=room.vertices.filter((p,i,a)=>i===0||Math.hypot(p.x-a[i-1].x,p.y-a[i-1].y)>1e-7)
    if(contour.length<3)continue
    if(Math.hypot(contour[0].x-contour[contour.length-1].x,contour[0].y-contour[contour.length-1].y)<1e-7)contour.pop()
    if(contour.length<3||Math.abs(signedArea148(contour))<1e-5)continue
    const faces=THREE.ShapeUtils.triangulateShape(contour.map(p=>new THREE.Vector2(p.x,p.y)),[])
    for(let s=0;s<group.length;s++) {
      const roof=group[s],position:number[]=[]
      for(const face of faces) {
        let polygon=face.map(i=>contour[i])
        for(let other=0;other<group.length&&polygon.length>=3;other++) {
          if(s===other)continue
          // A deterministic tie break selects only one of two coplanar slopes.
          const bias=s>other?1e-7:-1e-7
          polygon=clipHalfplane148(polygon,p=>roofHeight148(roof,p)-roofHeight148(group[other],p)+bias)
        }
        if(polygon.length<3||Math.abs(signedArea148(polygon))<1e-10)continue
        for(let i=1;i<polygon.length-1;i++) {
          const tri=[polygon[0],polygon[i],polygon[i+1]]
          if(Math.abs(signedArea148(tri))<1e-10)continue
          if(signedArea148(tri)>0)tri.reverse() // upward-facing +Y in x/y/z coordinates
          for(const p of tri)position.push(p.x,roofHeight148(roof,p),p.y)
        }
      }
      if(!position.length)continue
      const geometry=new THREE.BufferGeometry()
      geometry.setAttribute('position',new THREE.Float32BufferAttribute(position,3))
      geometry.computeVertexNormals()
      output.push({roof,geometry})
    }
  }
  return output
}

export default function RoofMeshes148({floorId,levelId,rooms,revision,selectedId,onSelect,editable=true}: {
  floorId:string;levelId:string;rooms:Room148[];revision:number;selectedId:string;onSelect:(id:string)=>void;editable?:boolean
}) {
  const [hovered,setHovered]=useState('')
  const sectors=useMemo(()=>roofSectors148(rooms,readRoofSlopes148(floorId,window.localStorage).filter(s=>s.levelId===levelId)),
    [floorId,levelId,rooms,revision])
  useEffect(()=>()=>{for(const sector of sectors)sector.geometry.dispose()},[sectors])
  return <group>
    {sectors.map(({roof,geometry})=><mesh key={roof.id} geometry={geometry}
      onClick={editable?(event:ThreeEvent<MouseEvent>)=>{event.stopPropagation();onSelect(roof.id)}:undefined}
      onPointerOver={editable?(event:ThreeEvent<PointerEvent>)=>{event.stopPropagation();setHovered(roof.id)}:undefined}
      onPointerOut={editable?()=>setHovered(''):undefined}>
      <meshStandardMaterial color={selectedId===roof.id?'#428deb':hovered===roof.id?'#79baff':'#9fcddd'}
        transparent opacity={selectedId===roof.id?0.93:0.78} roughness={0.72} metalness={0.05}
        side={THREE.DoubleSide} depthWrite={false} />
    </mesh>)}
  </group>
}
STROM148_MESH_TSX
cat > "$STROM148_RESOURCES/patch148.py" <<'STROM148_PATCH_PY'
#!/usr/bin/env python3
"""STROM 148: transactional source transformations for v147b. No write until all anchors validated."""
from pathlib import Path
import os,re
root=Path(os.environ['STROM148_ROOT'])
module=Path(os.environ['STROM148_MODULE_DIR'])
app=root/'frontend/src/App.tsx'; scene=root/'frontend/src/components/Building3DWorkspace.tsx'; css=root/'frontend/src/styles.css'
for p in (app,scene,css):
    if not p.is_file():raise RuntimeError(f'148: Quelldatei fehlt: {p}')
for name in ('roofSlopes148.ts','stairLinks148.ts','RoofEditor148.tsx','RoofMeshes148.tsx'):
    if not (module/name).is_file():raise RuntimeError(f'148: eingebettetes Modul fehlt: {name}')
a=app.read_text(encoding='utf8');s=scene.read_text(encoding='utf8');c=css.read_text(encoding='utf8')
if 'STROM148_ROOF_EDIT' in a or 'STROM148_ROOF_3D' in s:
    raise RuntimeError('148: Versionsmarker bereits vorhanden; Doppelanwendung wird verhindert.')
for marker in ('STROM147_STAIR_DIRECTIONS','function FloorplanEditor(','function handleCanvasClick(','function chooseTool(','stairRoomsHere147','createOtherStair147','<CanvasRulers zoom={zoom}','<BlueprintWallObjectConnections','function isStairRoom('):
    if marker not in a:raise RuntimeError(f'148: App.tsx erwartet Update 147b, Marker fehlt: {marker}')
for marker in ('STROM147_DOWN_SCENE','STROM146_ALL_LEVELS','function RealBuildingScene(','export default function Building3DWorkspace(', 'extraLevels146.map(', 'function SceneControls('):
    if marker not in s:raise RuntimeError(f'148: 3D-Szene erwartet Update 147b, Marker fehlt: {marker}')

def one(text,old,new,label):
    count=text.count(old)
    if count!=1:raise RuntimeError(f'148 {label}: Anker {repr(old[:80])} genau 1x erwartet, {count}x gefunden')
    return text.replace(old,new,1)

def slice_between(text,start,end,label):
    if text.count(start)!=1:raise RuntimeError(f'148 {label}: Startanker {start!r} nicht eindeutig ({text.count(start)})')
    pos=text.index(start)
    stop=text.find(end,pos)
    if stop<0:raise RuntimeError(f'148 {label}: Endanker {end!r} nicht nach Start gefunden')
    return pos,stop,text[pos:stop]

# Import only known v147b names; no changes outside intended components.
a=one(a,"import { readStairDirections147, sameStairFootprint147, stairDirectionKey147, type StairDirection147 } from './building/stairOverlay147'",
'''import { readStairDirections147, sameStairFootprint147, stairDirectionKey147, type StairDirection147 } from './building/stairOverlay147'
import { readStairPairs148, saveStairPairs148, linkStairs148, inferLegacyStairPairs148, linkedStairPortals148, type StairPairs148 } from './building/stairLinks148'
import { readRoofSlopes148, saveRoofSlopes148, nearestRoomEdge148, inwardRoofAngle148, angleVector148, ROOF_EVENT148, type RoofSlope148 } from './building/roofSlopes148'
import RoofEditor148 from './components/RoofEditor148' ''', 'imports App')
tool_type=re.search(r"^type Tool = ([^\n]+)$",a,flags=re.M)
if not tool_type:raise RuntimeError('148: Tool Typdeklaration fehlt')
if "'roof'" in tool_type.group(1):raise RuntimeError('148: roof already in Tool union')
a=a[:tool_type.end(1)]+" | 'roof'"+a[tool_type.end(1):]
# Floorplan tool label only if such a helper exists (standard name is stable)
if "  if (tool === 'door') return 'Tuer zwischen Raeumen einsetzen'" in a:
    a=one(a,"  if (tool === 'door') return 'Tuer zwischen Raeumen einsetzen'", "  if (tool === 'door') return 'Tuer zwischen Raeumen einsetzen'\n  if (tool === 'roof') return 'Dachschräge zeichnen'", 'tool label')
# Scope all editor modifications to FloorplanEditor, not Wanddetail which also has layered state.
p0,p1,editor=slice_between(a,'function FloorplanEditor(', 'type StairEditorElementKind', 'Blueprint')
state='  const [stairDirections147, setStairDirections147] = useState<Record<string, StairDirection147>>('
if state not in editor:raise RuntimeError('148: stair-direction hook from 147b missing')
editor=one(editor,state,'''  const [stairPairs148, setStairPairs148] = useState<StairPairs148>(() => readStairPairs148(floor.id, window.localStorage))
  const [roofSlopes148, setRoofSlopes148] = useState<RoofSlope148[]>(() => readRoofSlopes148(floor.id, window.localStorage))
  const [roofStart148, setRoofStart148] = useState<PointM|null>(null)
  const [selectedRoof148, setSelectedRoof148] = useState('')
'''+state,'new blueprint state')
# Replace only the v147b geometry-matched pair lookup, retaining fallback for legacy.
pair_from='''  const stairRoomsHere147 = selectedRoom && isStairRoom(selectedRoom)
    ? rooms.filter((room) => isStairRoom(room)
      && (roomLayerAssignments[room.id] ?? defaultLayerId) === (roomLayerAssignments[selectedRoom.id] ?? defaultLayerId)
      && sameStairFootprint147(room, selectedRoom))
    : []'''
pair_to='''  // STROM148_STAIR_PAIR: stable room IDs survive independent editing of both outlines.
  const stairRoomsHere147 = selectedRoom && isStairRoom(selectedRoom)
    ? (() => {
      const other = rooms.find(room => room.id === stairPairs148[selectedRoom.id] && isStairRoom(room)
        && (roomLayerAssignments[room.id] ?? defaultLayerId) === (roomLayerAssignments[selectedRoom.id] ?? defaultLayerId))
      return other ? [selectedRoom, other] : rooms.filter(room => isStairRoom(room)
        && (roomLayerAssignments[room.id] ?? defaultLayerId) === (roomLayerAssignments[selectedRoom.id] ?? defaultLayerId)
        && sameStairFootprint147(room, selectedRoom))
    })() : []'''
editor=one(editor,pair_from,pair_to,'stable stair pair')
# Add localStorage restoration on floor switch, plus legacy pair migration; use effect after the existing state hook and before selectedRoom.
needle='  const selectedRoom = rooms.find((room) => room.id === selectedRoomId) ?? null'
effects='''  useEffect(() => {
    setStairPairs148(readStairPairs148(floor.id, window.localStorage))
    setRoofSlopes148(readRoofSlopes148(floor.id, window.localStorage))
    setRoofStart148(null)
    setSelectedRoof148('')
  }, [floor.id])

  useEffect(() => {
    function refreshRoof148() { setRoofSlopes148(readRoofSlopes148(floor.id, window.localStorage)) }
    window.addEventListener(ROOF_EVENT148, refreshRoof148)
    return () => window.removeEventListener(ROOF_EVENT148, refreshRoof148)
  }, [floor.id])

  useEffect(() => {
    if (!rooms.length) return
    const combined = inferLegacyStairPairs148(rooms,roomLayerAssignments,stairDirections147,stairPairs148)
    if (JSON.stringify(combined)!==JSON.stringify(stairPairs148)) {
      saveStairPairs148(floor.id,combined)
      setStairPairs148(combined)
    }
  },[floor.id,rooms,roomLayerAssignments,stairDirections147,stairPairs148])

'''
editor=one(editor,needle,effects+needle,'effects before selection')
# Stable pairing on copy. Successful room creation is the right time to link.
editor=one(editor,'''      storeStairDirections147({ ...stairDirections147, [created.id]: opposite })
      setStairPanelOpen(false)''', '''      storeStairDirections147({ ...stairDirections147, [created.id]: opposite })
      const linked148 = linkStairs148(stairPairs148, selectedRoom.id, created.id)
      saveStairPairs148(floor.id, linked148)
      setStairPairs148(linked148)
      setStairPanelOpen(false)''','create stair pair IDs')
# Render a read-only reference when a stair reaches the next level. Click jumps to real source object.
portal_anchor='  const activeLayerRooms = useMemo('
portal_code='''  // STROM148_STAIR_PORTAL: the SAME stair room is visible on its arrival level.
  // This is a reference, not a duplicate database room; opening it selects its true source floor.
  const stairPortals148 = linkedStairPortals148(rooms,layers,roomLayerAssignments,stairDirections147,activeLayerId)

'''
editor=one(editor,portal_anchor,portal_code+portal_anchor,'linked upper-floor portals')
# Roof toolbar after the single current staircase button. This is in the Blueprint toolbar only.
match=re.search(r'(?s)(\s*<button\b(?:(?!<button).)*?title="Treppe einzeichnen"(?:(?!</button>).)*?</button>)',editor)
if not match:raise RuntimeError('148: Treppen-Werkzeugbutton fuer Dachbutton nicht gefunden')
roof_button='''
          <button type="button" title="Dachschräge zeichnen: Raum auswählen, Startlinie mit zwei Klicks setzen"
            data-tooltip="Dachschräge zeichnen" aria-label="Dachschräge zeichnen"
            className={tool === 'roof' ? 'active' : ''} disabled={!selectedRoom || isStairRoom(selectedRoom) || isOuterWallRoom(selectedRoom)}
            onMouseDown={event=>event.preventDefault()} onClick={()=>void chooseTool('roof')}>
            <StromIcon name="polygon" title="Dachschräge zeichnen" />
          </button>'''
editor=editor[:match.end()]+roof_button+editor[match.end():]
# Guard invalid roof selection and reset click sequence on tool change.
editor=one(editor,"  async function chooseTool(nextTool: Tool) {", """  async function chooseTool(nextTool: Tool) {
    if (nextTool==='roof' && (!selectedRoom || isStairRoom(selectedRoom) || isOuterWallRoom(selectedRoom))) return
    setRoofStart148(null)
""",'roof chooser')
# New roof-drawing click branch after mouse coordinate and suppression checks.
needle='''    const point = eventToMeters(event)
    if (!point) return
'''
roof_click='''    const point = eventToMeters(event)
    if (!point) return

    if (tool === 'roof') {
      if (!selectedRoom || isStairRoom(selectedRoom) || isOuterWallRoom(selectedRoom)
          || (roomLayerAssignments[selectedRoom.id] ?? defaultLayerId) !== activeLayerId) return
      const snapped = nearestRoomEdge148(point,selectedRoom.vertices,Math.max(0.10,0.18/zoom))
      if(!roofStart148) {setRoofStart148(snapped);return}
      if(Math.hypot(snapped.x-roofStart148.x,snapped.y-roofStart148.y)<0.10) {onError('Startlinie muss mindestens 100 mm lang sein.');return}
      const roof:RoofSlope148={id:window.crypto?.randomUUID?.() || `roof-${Date.now()}-${Math.random().toString(36).slice(2)}`,
        roomId:selectedRoom.id,levelId:activeLayerId,start:roofStart148,end:snapped,
        directionDeg:inwardRoofAngle148(roofStart148,snapped,selectedRoom.vertices),pitchDeg:35,startHeightM:1.0}
      try {
        saveRoofSlopes148(floor.id,[...readRoofSlopes148(floor.id,window.localStorage),roof])
        setSelectedRoof148(roof.id);setRoofStart148(null);setTool('select')
        onError(null)
      } catch(error) {onError(error instanceof Error?error.message:String(error))}
      return
    }
'''
click_start,click_end,click_segment=slice_between(editor,'  function handleCanvasClick(', '  function handleCanvasDoubleClick(', 'roof canvas click')
click_segment=one(click_segment,needle,roof_click,'roof two point drawing')
editor=editor[:click_start]+click_segment+editor[click_end:]
# Add reference projection and roofs after the room map, not inside the RoomShape internal drag structures.
# The 144a level filter intentionally rewrote this JSX element across several lines:
#   <BlueprintWallObjectConnections
#     wallObjects={blueprintWallObjects.filter(...)}
#     rooms={activeLayerRooms}
#   />
# Never match its props or formatting: identify the JSX *component* and insert
# siblings immediately before it. Require exactly one occurrence inside the
# FloorplanEditor scope, and keep the existing filtered door renderer byte-for-byte.
wall_component148 = list(re.finditer(r'(?m)^([ \t]*)<BlueprintWallObjectConnections\b',editor))
if len(wall_component148)!=1:
    raise RuntimeError(f'148c Blueprint: JSX-Komponente BlueprintWallObjectConnections nicht eindeutig '
                       f'(gefunden: {len(wall_component148)}). Kein Schreiben.')
wall_at148 = wall_component148[0].start()
projection='''            {/* STROM148_STAIR_PORTAL: references to a stairwell on its adjoining storey */}
            {stairPortals148.map(({room,sourceLayerId})=>(
              <g key={`stair-portal148-${room.id}`} className="strom-stair-portal148"
                onClick={event=>{event.stopPropagation();setActiveLayerId(sourceLayerId);onSelectRoom(room.id);setTool('select')}}>
                <title>{`Treppenraum ${room.name} aus ${layers.find(l=>l.id===sourceLayerId)?.name||'Nachbarebene'} bearbeiten`}</title>
                <polygon points={pointsToSvg(room.vertices)} />
                <text x={mToX(centroid(room.vertices).x)} y={mToY(centroid(room.vertices).y)} textAnchor="middle">
                  Treppenöffnung ↕ · {room.name}
                </text>
              </g>
            ))}
            {/* STROM148_ROOF_EDIT: distinct slopes can be placed on one room; click edits parameters. */}
            {roofSlopes148.filter(roof=>roof.levelId===activeLayerId && rooms.some(room=>room.id===roof.roomId)).map(roof=>{
              const middle={x:(roof.start.x+roof.end.x)/2,y:(roof.start.y+roof.end.y)/2}
              const axis=angleVector148(roof.directionDeg)
              const tip={x:middle.x+axis.x*0.60,y:middle.y+axis.y*0.60}
              return <g key={roof.id} className={`strom-roof-line148 ${selectedRoof148===roof.id?'selected':''}`}
                onClick={event=>{event.stopPropagation();setSelectedRoof148(roof.id);onSelectRoom(roof.roomId);setTool('select')}}>
                <title>{`Dachschräge: ${roof.pitchDeg}°, Beginn ${Math.round(roof.startHeightM*1000)} mm. Anklicken zum Bearbeiten.`}</title>
                <line x1={mToX(roof.start.x)} y1={mToY(roof.start.y)} x2={mToX(roof.end.x)} y2={mToY(roof.end.y)}/>
                <line className="strom-roof-arrow148" x1={mToX(middle.x)} y1={mToY(middle.y)} x2={mToX(tip.x)} y2={mToY(tip.y)}/>
                <text x={mToX(tip.x)} y={mToY(tip.y)-7} textAnchor="middle">{roof.pitchDeg}° · {Math.round(roof.startHeightM*1000)} mm</text>
              </g>
            })}
            {roofStart148 && <circle className="strom-roof-draft148" cx={mToX(roofStart148.x)} cy={mToY(roofStart148.y)} r={7/zoom} />}

'''
editor=editor[:wall_at148]+projection+editor[wall_at148:]
# The real v147b Blueprint already filters door connections by active level.
# Verify that this still holds before proceeding so roof insertion cannot
# accidentally restore cross-level door rendering from before 144a.
wall_tail148 = editor[wall_at148+len(projection):wall_at148+len(projection)+700]
if not re.search(r'rooms\s*=\s*\{activeLayerRooms\}',wall_tail148) or not re.search(r'wallObjects\s*=\s*\{blueprintWallObjects\.filter\(',wall_tail148):
    raise RuntimeError('148c Blueprint: bestehender 144a-Tueren-Ebenenfilter fehlt oder hat sich geaendert.')

# Roof editor as an absolute floating window at the canvas top level.
needle='''        <CanvasRulers zoom={zoom} scrollLeft={scrollPosition.left} scrollTop={scrollPosition.top} />'''
editor=one(editor,needle,'''        {tool==='roof' && <div className="strom-roof-help148" title="Die Dachschräge wird im ausgewählten Raum gespeichert">Dachschräge: {roofStart148?'zweiten Punkt der Startlinie setzen':'ersten Punkt der Startlinie setzen'} · anschließend Parameter einstellen</div>}
        {selectedRoof148 && <div className="strom-roof-floating148"><RoofEditor148 floorId={floor.id} roofId={selectedRoof148}
          onClose={()=>setSelectedRoof148('')}/></div>}
'''+needle,'blueprint roof property panel')
a=a[:p0]+editor+a[p1:]
# 3D workspace: prepend imports next to stable Three.js import.
s=one(s,"import * as THREE from 'three'",'''import * as THREE from 'three'
import RoofMeshes148 from './RoofMeshes148'
import RoofEditor148 from './RoofEditor148'
import { ROOF_EVENT148 } from '../building/roofSlopes148' ''','3D imports')
start,stop,real=slice_between(s,'function RealBuildingScene(', 'function DoorForm(', '3D scene')
real=one(real,'function RealBuildingScene({ model, stairs, extraLevels146, activeOffsetM146, showAllLevels146, ',
'''function RealBuildingScene({ model, stairs, extraLevels146, activeOffsetM146, showAllLevels146, activeLevelId148, roofRevision148, selectedRoof148, onSelectRoof148, ''','3D scene props')
real=one(real,'  showAllLevels146: boolean\n','''  showAllLevels146: boolean
  activeLevelId148: string
  roofRevision148: number
  selectedRoof148: string
  onSelectRoof148: (id:string)=>void
''','3D scene prop types')
# Inject roofs within the active storey group, after existing walls, avoiding changes to wall geometry.
needle='''      </group>
      {showAllLevels146 && extraLevels146.map((entry146) => ('''
repl='''        {/* STROM148_ROOF_3D: roof faces are built from saved Blueprint slope records. */}
        <RoofMeshes148 floorId={model.floorId} levelId={activeLevelId148} rooms={model.rooms}
          revision={roofRevision148} selectedId={selectedRoof148} onSelect={onSelectRoof148} />
      </group>
      {showAllLevels146 && extraLevels146.map((entry146) => ('''
real=one(real,needle,repl,'active 3D roof group')
# Additional levels: insert within each floor group; no second mesh for active floor.
needle='''          <SolidWallMeshes model={entry146.model} onSelectRoom={() => undefined} transparent={transparent} />'''
real=one(real,needle,needle+'''
          <RoofMeshes148 floorId={entry146.model.floorId} levelId={entry146.id} rooms={entry146.model.rooms}
            revision={roofRevision148} selectedId={selectedRoof148} onSelect={onSelectRoof148} />''','extra 3D levels roof')
s=s[:start]+real+s[stop:]
# 3D frontend outer controller: shares same persistent roof key and reacts to changes in Blueprint.
start=s.index('export default function Building3DWorkspace(')
outer=s[start:]
outer=one(outer, '  const [transparent, setTransparent] = useState(false)', '''  const [selectedRoof148, setSelectedRoof148] = useState('')
  const [roofRevision148,setRoofRevision148] = useState(0)
  useEffect(()=>{
    const sync=()=>setRoofRevision148(value=>value+1)
    window.addEventListener(ROOF_EVENT148,sync)
    return ()=>window.removeEventListener(ROOF_EVENT148,sync)
  },[])
  useEffect(()=>setSelectedRoof148(''),[floor.id])
  const [transparent, setTransparent] = useState(false)''', '3D roof selection/revision hooks')
# Extend the actual scene call via AST-independent exact JSX self-closing props: only one <RealBuildingScene model...
match=re.search(r'<RealBuildingScene\s+model=\{model\}\s+stairs=\{activeStairs146\}',outer)
if not match:raise RuntimeError('148: primary RealBuildingScene props with activeStairs146 not found')
outer=outer[:match.end()]+''' activeLevelId148={activeLevel.id} roofRevision148={roofRevision148}
            selectedRoof148={selectedRoof148} onSelectRoof148={setSelectedRoof148}'''+outer[match.end():]
# Keep the existing 3D inspector as-is. Support both heading and layout variants.
roof_inspector='''
          {selectedRoof148 && <RoofEditor148 floorId={floor.id} roofId={selectedRoof148}
            onClose={()=>setSelectedRoof148('')} onChanged={()=>setRoofRevision148(value=>value+1)}/>}'''
if '<h2>3D-Eigenschaften</h2>' in outer:
    outer=one(outer,'<h2>3D-Eigenschaften</h2>','<h2>3D-Eigenschaften</h2>'+roof_inspector,'3D roof inspector')
elif '<aside className="building3d-inspector">' in outer:
    outer=one(outer,'<aside className="building3d-inspector">','<aside className="building3d-inspector">'+roof_inspector,'3D roof inspector aside')
elif '<div className="building3d-inspector">' in outer:
    outer=one(outer,'<div className="building3d-inspector">','<div className="building3d-inspector">'+roof_inspector,'3D roof inspector div')
else:
    raise RuntimeError('148: 3D inspector ist nicht vorhanden; unveraenderter Quellcode wird behalten')
s=s[:start]+outer
c+='''
/* STROM148: roof-slope tools and linked stairwell projections. */
.strom-stair-portal148 { cursor:pointer; pointer-events:auto; }
.strom-stair-portal148 polygon { fill:rgba(57,128,214,.12); stroke:#3672bb; stroke-width:3; stroke-dasharray:12 6; }
.strom-stair-portal148 text { font:600 13px system-ui,sans-serif; fill:#1f5d9b; paint-order:stroke;stroke:white;stroke-width:3; }
.strom-roof-line148 {cursor:pointer;pointer-events:visibleStroke;}
.strom-roof-line148>line:first-of-type {stroke:#cf7d42;stroke-width:5;stroke-linecap:round;}
.strom-roof-line148 .strom-roof-arrow148 {stroke:#3574c1;stroke-width:3;}
.strom-roof-line148.selected>line:first-of-type {stroke:#215ab4;stroke-width:7;}
.strom-roof-line148 text {font:700 13px system-ui,sans-serif;fill:#1d5d9d;paint-order:stroke;stroke:white;stroke-width:3;}
.strom-roof-draft148 {fill:#ffdf9d;stroke:#a45b22;stroke-width:2;}
.strom-roof-help148 {position:absolute;z-index:38;left:20px;bottom:17px;pointer-events:none;color:#23486a;background:#f7fbffed;border:1px solid #d6e3f3;border-radius:8px;padding:7px 11px;font-size:12px;}
.strom-roof-floating148 {position:absolute;z-index:54;right:16px;top:90px;max-height:calc(100% - 100px);overflow:auto;}
.strom-roof-editor148 {display:flex;flex-direction:column;gap:9px;width:290px;max-width:95%;padding:13px;border:1px solid #b9cbe5;border-radius:10px;background:#fff;color:#263c56;box-shadow:0 8px 25px #29456624;}
.strom-roof-editor148 header {display:flex;justify-content:space-between;align-items:center;gap:8px;padding:0;background:none;border:0;}
.strom-roof-editor148 header button {border:1px solid #d6e2f1;background:#f0f5ff;border-radius:6px;cursor:pointer;}
.strom-roof-field148 {display:flex;justify-content:space-between;align-items:center;gap:12px;font-size:12px;font-weight:600;}
.strom-roof-field148 span {display:flex;align-items:center;gap:3px;}
.strom-roof-field148 input,.strom-roof-field148 select {width:100px;min-height:29px;padding:3px 7px;border:1px solid #bfcede;border-radius:6px;color:#1e3b60;background:#fff;}
.strom-roof-field148 select {width:150px;}
.strom-roof-editor148 details {display:flex;flex-direction:column;padding:6px;border-top:1px solid #dce5f0;}
.strom-roof-editor148 details .strom-roof-field148 {margin-top:7px;}
.strom-roof-actions148 {display:flex;gap:8px;}
.strom-roof-actions148 button {padding:7px 10px;border-radius:7px;border:1px solid #adc1dc;background:#e5efff;color:#234467;cursor:pointer;}
.strom-roof-actions148 button:first-child {background:#285fd0;color:white;}
.strom-roof-editor148 p {font-size:12px;color:#315b8f;margin:2px 0;}
'''
# No partial patches if any anchor fails: only now commit four sources + four new modules.
for src,dest in [(module/'roofSlopes148.ts',root/'frontend/src/building/roofSlopes148.ts'),
                 (module/'stairLinks148.ts',root/'frontend/src/building/stairLinks148.ts'),
                 (module/'RoofEditor148.tsx',root/'frontend/src/components/RoofEditor148.tsx'),
                 (module/'RoofMeshes148.tsx',root/'frontend/src/components/RoofMeshes148.tsx')]:
    if dest.exists():raise RuntimeError(f'148: Zielmodul existiert bereits {dest}')
for p,source in ((app,a),(scene,s),(css,c)):
    p.write_text(source,encoding='utf8')
for name,subdir in (('roofSlopes148.ts','building'),('stairLinks148.ts','building'),('RoofEditor148.tsx','components'),('RoofMeshes148.tsx','components')):
    dest=root/'frontend/src'/subdir/name
    dest.parent.mkdir(parents=True,exist_ok=True)
    dest.write_text((module/name).read_text(encoding='utf8'),encoding='utf8')
print('PASS 148: stabile Treppenpaar-IDs, verknüpfte Treppen-Projektion, Dachschrägen in Blueprint und echten 3D-Ansichten')
STROM148_PATCH_PY
cat > "$STROM148_RESOURCES/test148.cjs" <<'STROM148_TEST_JS'
'use strict'
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path')
const ts=require(process.env.STROM148_TS_DIR||'/opt/nvm/versions/node/v22.16.0/lib/node_modules/typescript')
const root=process.env.STROM148_TEST_DIR||'/mnt/data/strom148_build/fixture147/frontend/src'
const jsx=['App.tsx','components/Building3DWorkspace.tsx','components/RoofMeshes148.tsx','components/RoofEditor148.tsx',
'building/roofSlopes148.ts','building/stairLinks148.ts']
// Regression 148b: preserve the 144a per-level door renderer in its new multiline form.
const blueprint148b=fs.readFileSync(path.join(root,'App.tsx'),'utf8')
assert.match(blueprint148b,/STROM144_BLUEPRINT_DOOR_LEVEL/, 'per-level doors marker lost')
assert.equal((blueprint148b.match(/<BlueprintWallObjectConnections\b/g)||[]).length,1,'exactly one door renderer required')
assert.match(blueprint148b,/<BlueprintWallObjectConnections\s+[\s\S]*?wallObjects=\{blueprintWallObjects\.filter\([\s\S]*?rooms=\{activeLayerRooms\}/,
  'the 144a active-layer door filter must remain intact')
assert.match(blueprint148b,/STROM148_ROOF_EDIT/,'roof overlay not mounted in Blueprint')
assert.match(blueprint148b,/<g key=\{`stair-portal148-\$\{room\.id\}`\}[\s\S]*?<title>\{`Treppenraum/, 'SVG stair portal needs a child <title> tooltip')
let attrCount=0
for(const file of jsx) {
 const content=fs.readFileSync(path.join(root,file),'utf8')
 const sf=ts.createSourceFile(file,content,ts.ScriptTarget.Latest,true,file.endsWith('.tsx')?ts.ScriptKind.TSX:ts.ScriptKind.TS)
 const errors=sf.parseDiagnostics.filter(d=>d.category===ts.DiagnosticCategory.Error)
 assert.equal(errors.length,0,`${file} parse errors: `+errors.map(d=>d.code+' '+ts.flattenDiagnosticMessageText(d.messageText,' ')).join('; '))
 function walk(node) {
  if(ts.isJsxOpeningElement(node)||ts.isJsxSelfClosingElement(node)) {
    const names=new Set()
    for(const attr of node.attributes.properties) {
      if(!ts.isJsxAttribute(attr))continue
      const key=attr.name.getText(sf)
      assert(!names.has(key),`${file}: duplicate JSX attribute ${key}`)
      // SVG elements (notably <g>) do not expose a React `title` attribute.
      // Browser tooltips are provided using a nested SVG <title> element instead.
      if (node.tagName.getText(sf)==='g' && key==='title') {
        assert.fail(`${file}: SVG <g> has invalid title attribute; use child <title> instead`)
      }
      names.add(key);attrCount++
    }
  }
  ts.forEachChild(node,walk)
 }
 walk(sf)
}
const stubThree={
 Vector2:class Vector2 {constructor(x,y){this.x=x;this.y=y}},
 ShapeUtils:{triangulateShape(points){assert(points.length===4,'test triangle stub uses rectangular room');return [[0,1,2],[0,2,3]]}},
 Float32BufferAttribute:class Float32BufferAttribute {constructor(array){this.array=array}},
 BufferGeometry:class BufferGeometry {setAttribute(key,value){this.attr=value;return this}computeVertexNormals(){}dispose(){}},
}
const modCache=new Map()
function load(source){
 if(modCache.has(source))return modCache.get(source)
 const content=fs.readFileSync(path.join(root,source),'utf8')
 const compiled=ts.transpileModule(content,{fileName:source,compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020,jsx:ts.JsxEmit.ReactJSX}})
 const mod={exports:{}}
 modCache.set(source,mod.exports)
 const localRequire=(s)=>{
  if(s==='three')return stubThree
  if(s==='react')return {useEffect(){},useMemo(){},useState(){}}
  if(s==='react/jsx-runtime')return {jsx(){},jsxs(){}}
  if(s==='@react-three/fiber')return {}
  if(s.endsWith('/roofSlopes148'))return load('building/roofSlopes148.ts')
  if(s.endsWith('/stairOverlay147'))return load('building/stairOverlay147.ts')
  throw Error('unknown require '+s)
 }
 new Function('require','module','exports',compiled.outputText)(localRequire,mod,mod.exports)
 return mod.exports
}
const roof=load('building/roofSlopes148.ts')
const stairs=load('building/stairLinks148.ts')
const room={id:'a',roomType:'stair',vertices:[{x:0,y:0},{x:4,y:0},{x:4,y:3},{x:0,y:3}]}
const roomB={...room,id:'b',vertices:[{x:1,y:1},{x:4,y:1},{x:4,y:3},{x:1,y:3}]}
const migrated=stairs.inferLegacyStairPairs148([{...room,name:'Treppe'},{...roomB,name:'Treppe (abwärts)'}],
 {a:'ground',b:'ground'},{a:'up',b:'down'}, {})
assert.equal(migrated.a,'b','legacy pair with independently edited outlines must still migrate')
const linked=stairs.linkStairs148({},room.id,roomB.id)
assert.equal(linked.a,'b');assert.equal(linked.b,'a')
const portals=stairs.linkedStairPortals148([room,roomB],[{id:'ground'},{id:'upper'}],{a:'ground',b:'ground'},
 {a:'up',b:'down'},'upper')
assert.equal(portals.length,1);assert.equal(portals[0].room.id,'a')
assert.equal(portals[0].sourceLayerId,'ground')
assert.deepEqual(stairs.linkStairs148({a:'b',b:'a'},'a','c'),{a:'c',c:'a'})
assert.equal(roof.inwardRoofAngle148({x:0,y:0},{x:0,y:3},room.vertices),0)
const slopeA={id:'r1',roomId:'living',levelId:'ground',start:{x:0,y:0},end:{x:0,y:3},pitchDeg:35,
 startHeightM:1,directionDeg:0}
const slopeB={...slopeA,id:'r2',start:{x:4,y:0},end:{x:4,y:3},directionDeg:180}
assert(Math.abs(roof.roofHeight148(slopeA,{x:2,y:0})-roof.roofHeight148(slopeB,{x:2,y:0}))<1e-8)
const storage={getItem(k){return k===roof.roofKey148('floor1')?JSON.stringify([slopeA,slopeB]):null}}
assert.equal(roof.readRoofSlopes148('floor1',storage).length,2)
const meshes=load('components/RoofMeshes148.tsx')
const sectors=meshes.roofSectors148([{id:'living',vertices:room.vertices}],[slopeA,slopeB])
assert.equal(sectors.length,2)
let totalArea=0
for(const {geometry} of sectors) {
  const pos=geometry.attr.array
  assert(pos.length>=9)
  for(let i=0;i<pos.length;i+=9) {
    const [ax,,az,bx,,bz,cx,,cz]=pos.slice(i,i+9)
    const area=Math.abs((bx-ax)*(cz-az)-(bz-az)*(cx-ax))/2
    assert(area>=0)
    totalArea+=area
  }
}
assert(Math.abs(totalArea-12)<1e-5,`Roof triangles cover ${totalArea} m² not 12 m²`)
console.log(`PASS 148: ${jsx.length} TS/TSX parsed; ${attrCount} unique JSX props; stable links, upper-floor portal, roof storage, two intersecting roof sectors w/o overlap (12m²)`)
STROM148_TEST_JS

for required in roofSlopes148.ts stairLinks148.ts RoofEditor148.tsx RoofMeshes148.tsx patch148.py test148.cjs; do
  [ -s "$STROM148_RESOURCES/$required" ] || fail "148: eingebettete Ressource fehlt: $required"
done
python3 -m py_compile "$STROM148_RESOURCES/patch148.py" >> "$DIAG_LOG" 2>&1 || fail "148: Python-Patch-Syntax ungueltig"
STROM148_ROOT="$WORK_DIR" STROM148_MODULE_DIR="$STROM148_RESOURCES" \
  python3 "$STROM148_RESOURCES/patch148.py" >> "$DIAG_LOG" 2>&1 || fail "148: Quellpatch fehlgeschlagen. Kein Git-Push/Stage-Deployment."

log "4) TSX-Parsen, doppelte Attribute und Treppen-/Dach-Geometrietests pruefen ..."
STROM148_TS_DIR="$DEPENDENCIES/typescript" STROM148_TEST_DIR="$WORK_DIR/frontend/src" \
  node "$STROM148_RESOURCES/test148.cjs" >> "$DIAG_LOG" 2>&1 || fail "148: TSX-/Geometrietests fehlgeschlagen, nichts gepusht."
rm -rf "$STROM148_RESOURCES" "$WORK_DIR/.strom148_resources"

cat > "$WORK_DIR/docs/STROM_UPDATE_148.md" <<'STROM148_DOC'
# STROM 148 - Treppenraum-Identitaet, Etagenprojektion, Dachschraegen

- Nach dem Kopieren sind Aufwaerts- und Abwaerts-Treppenraeume unabhaengige
  Raum-Datenbankobjekte. Ihr Paar wird dauerhaft per ID statt per Raumform erkannt.
- Bestehende deckungsgleiche Treppenraum-Paare werden einmalig verknuepft.
- Auf der jeweils angrenzenden Blueprint-Ebene erscheint dieselbe Treppenraumkontur
  als *verknuepfte Projektion*. Sie ist keine neue Datenbank-Raumkopie. Anklicken
  springt zur Quell-Ebene und waehlt den echten Raum zur Bearbeitung.
- Eine Blueprint-Dachschraege wird nach Raumwahl per zwei Punkten entlang
  ihrer Startlinie erzeugt. Neigung, Beginnhoehe, Ausrichtung und Linienenden
  sind parametrisch bearbeitbar. Unbegrenzt viele Schraegenelemente je Raum.
- Alle Dachschraegen eines Raumes werden zu einer gemeinsamen untersten
  Dachflaechen-Huelle geschnitten. Dadurch gibt es bei kreuzenden Schraegenelementen
  keine deckungsgleichen doppelten 3D-Flaechen.
- Echte 3D-Flaechen im Wanddetail und 3D Haus; Dachflaeche in 3D anklicken,
  dieselben Parameter bearbeiten und speichern. Beide Ansichten lesen dieselbe Datenquelle.
- Keine Veraenderung der bestehenden Wand-Triangulation oder Treppenstufen.
- Vorerst wie die Blueprint-Ebenen im lokalen Browser gespeichert, noch nicht
  in der Go-Datenbank. Geraeteuebergreifende Synchronisierung folgt separat.
- Dachschraegen verschneiden WANDKOERPER noch nicht automatisch. Realer Dach-
  /Waendeschnitt wird als spaetere gezielte Ausbaustufe umgesetzt.
STROM148_DOC

log "4.1) Vollstaendigen TypeScript-/Vite-Build vor GitHub-Push pruefen ..."
( cd "$WORK_DIR/frontend"; VITE_BASE=/strom-test/ npm run build ) >> "$DIAG_LOG" 2>&1 \
  || fail "148: Frontend TypeScript-/Vite-Build fehlgeschlagen. Kein Git-Push/Stage-Deploy."

log "5) Gepruefte Quelldateien in Stage-Arbeitskopie uebernehmen ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
  "$WORK_DIR/" "$STAGE_DIR/" >> "$DIAG_LOG" 2>&1 || fail "148 Stage-Quellkopie fehlgeschlagen. Backup: $BACKUP_DIR"

if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PATCH_ONLY: Patch, voller Build und Regressionstests bestanden. Kein Live-Deployment."
  exit 0
fi

log "6) Stage erneut bauen und nur /strom-test/ veroeffentlichen ..."
( cd "$STAGE_DIR/frontend"; VITE_BASE=/strom-test/ npm run build ) >> "$DIAG_LOG" 2>&1 \
  || fail "148 Stage-Build fehlgeschlagen. Backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "148: Stage dist fehlt. Backup: $BACKUP_DIR"
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >> "$DIAG_LOG" 2>&1 \
  || fail "148: Web-Deployment fehlgeschlagen. Backup: $BACKUP_DIR"
log ""
log "148 erfolgreich auf https://home.moja.de/strom-test/"
log "Auf/Ab-Treppenraum-Paare, Etagen-Verknuepfung, mehrfach Dachschraegen in Blueprint/Wanddetail/3D Haus."
log "Produktion und bestehende Wand-/Treppengeometrie unveraendert."
