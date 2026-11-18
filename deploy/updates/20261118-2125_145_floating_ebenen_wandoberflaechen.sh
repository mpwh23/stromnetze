#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261118-2125_145_floating_ebenen_wandoberflaechen"
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
COMMIT_MESSAGE="Update 145: shared floating floor picker in Blueprint/Wanddetail/3D Haus, repair coplanar wall surfaces"
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
  echo "2) Aktuellen Stage-Source + Update 144a nach GitHub pushen ..."
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

  echo "1.3) Update 144a auf Git-Source anwenden und Build pruefen ..."
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


log "=== Update 145 / Floating Ebenenauswahl und physische Wandoberflaechen ==="
log "Stage: $STAGE_DIR"
log "Diagnose: $DIAG_LOG"
log "Produktion/DB/Blueprint/Room-Geometry/Treppe/Wandbearbeitung bleiben unveraendert."
for required in \
  frontend/src/App.tsx \
  frontend/src/styles.css \
  frontend/src/components/StromIcon.tsx \
  frontend/src/components/Building3DWorkspace.tsx \
  frontend/src/building/meshCleanup144.ts \
  frontend/src/building/solidGeometry.ts \
  frontend/src/building/blueprintLevels.ts \
  frontend/src/building/stair3d.ts \
  frontend/public/strom-icons-v7.svg; do
  [ -f "$STAGE_DIR/$required" ] || fail "Update 145 benoetigt Stage 144a: $required fehlt."
done
for marker in STROM144_LEVEL_PICKER STROM143B_STAIR_AUDIT STROM141_WALL_HOVER; do
  grep -q "$marker" "$STAGE_DIR/frontend/src/components/Building3DWorkspace.tsx" || fail "Update 145: Stage hat Marker $marker nicht (144a zuerst deployen)."
done
grep -q 'STROM144_BLUEPRINT_DOOR_LEVEL' "$STAGE_DIR/frontend/src/App.tsx" || fail "Update 145: Tueren-Ebenenfilter aus 144a fehlt."
select_node

log "1) Stage-Sicherung erstellen ..."
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PATCH_ONLY: isolierte Git-Arbeitskopie, kein Backup noetig."
else
  cp -a "$STAGE_DIR" "$BACKUP_DIR" || fail "Stage-Sicherung fehlgeschlagen."
fi

log "2) Isolierte Arbeitskopie vorbereiten ..."
rsync -a --exclude='/frontend/node_modules' --exclude='/frontend/dist' --exclude='/.git' \
  "$STAGE_DIR/" "$WORK_DIR/" >>"$DIAG_LOG" 2>&1 || fail "Arbeitskopie fehlgeschlagen."
mkdir -p "$WORK_DIR/frontend/src/building" "$WORK_DIR/docs"
rm -rf "$WORK_DIR/frontend/node_modules"
DEPENDENCIES=""
for candidate in \
  "$STAGE_DIR/frontend/node_modules" \
  "$PROD_DIR/frontend/node_modules" \
  /home/mpwh/strom_stage/frontend/node_modules; do
  if [ -d "$candidate/typescript" ] && [ -d "$candidate/vite" ] && [ -d "$candidate/three" ]; then
    DEPENDENCIES="$candidate"; break
  fi
done
[ -n "$DEPENDENCIES" ] || fail "Frontend-Abhaengigkeiten fehlen (typescript/vite/three)."
ln -s "$DEPENDENCIES" "$WORK_DIR/frontend/node_modules"

log "3) Floating Ebenenwahl und ueberlagerungsarme Wandoberflaechen installieren ..."
cat > "$WORK_DIR/.strom145_wallSurface.ts" <<'STROM145_SURFACE_TS'
/** STROM145_WALL_SURFACE
 * Correct overlapping COPLANAR faces in the existing watertight wall shell.
 * The building model, wall coordinates, door openings and stair geometry are not changed.
 * If a plane is already non-overlapping, its original triangles pass through unchanged.
 */
export type SurfaceRepairStats145 = {
  positions: number[]
  inputTriangles: number
  outputTriangles: number
  repairedPlanes: number
  skippedPlanes: number
}

type P2 = { x: number; y: number }
type P3 = [number, number, number]
type Face = { points: [P2, P2, P2]; sign: number; original: number[] }
type Segment = { a: P2; b: P2 }
type Plane = {
  kind: 'horizontal' | 'vertical'
  nx: number
  nz: number
  d: number
  faces: Face[]
}
const EPS = 1e-8
const keyRound = (v: number, factor: number) => Math.round(v * factor)
const cross2 = (a: P2, b: P2, c: P2) => (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
const area2 = (p: P2[]) => Math.abs(cross2(p[0], p[1], p[2]))
const inside = (p: P2, triangle: P2[]) => {
  const s1 = cross2(triangle[0], triangle[1], p)
  const s2 = cross2(triangle[1], triangle[2], p)
  const s3 = cross2(triangle[2], triangle[0], p)
  return (s1 >= -EPS && s2 >= -EPS && s3 >= -EPS) || (s1 <= EPS && s2 <= EPS && s3 <= EPS)
}

// Clip a convex polygon by a triangle's directed half planes. Returns the
// true INTERSECTION, not just the intersection of axis-aligned bounding boxes.
function overlapArea(a: P2[], b: P2[]) {
  let result = [...a]
  const sign = cross2(b[0], b[1], b[2]) >= 0 ? 1 : -1
  for (let i = 0; i < 3 && result.length; i++) {
    const s = b[i], t = b[(i + 1) % 3]
    const next: P2[] = []
    for (let j = 0; j < result.length; j++) {
      const p = result[j], q = result[(j + 1) % result.length]
      const ap = sign * cross2(s, t, p), aq = sign * cross2(s, t, q)
      const pin = ap >= -EPS, qin = aq >= -EPS
      if (pin && qin) next.push(q)
      else if (pin !== qin) {
        const den = ap - aq
        const u = Math.abs(den) > EPS ? ap / den : .5
        const mid = { x: p.x + (q.x - p.x) * u, y: p.y + (q.y - p.y) * u }
        next.push(mid)
        if (qin) next.push(q)
      }
    }
    result = next
  }
  if (result.length < 3) return 0
  let twice = 0
  for (let i = 0; i < result.length; i++) {
    const p = result[i], q = result[(i + 1) % result.length]
    twice += p.x * q.y - p.y * q.x
  }
  return Math.abs(twice) / 2
}

function hasOverlap(faces: Face[]) {
  for (let i = 0; i < faces.length; i++) {
    const a = faces[i].points
    const ax0 = Math.min(...a.map((p) => p.x)), ax1 = Math.max(...a.map((p) => p.x))
    const ay0 = Math.min(...a.map((p) => p.y)), ay1 = Math.max(...a.map((p) => p.y))
    for (let j = i + 1; j < faces.length; j++) {
      const b = faces[j].points
      if (Math.min(ax1, Math.max(...b.map((p) => p.x))) - Math.max(ax0, Math.min(...b.map((p) => p.x))) < 1e-6) continue
      if (Math.min(ay1, Math.max(...b.map((p) => p.y))) - Math.max(ay0, Math.min(...b.map((p) => p.y))) < 1e-6) continue
      if (overlapArea(a, b) > 1e-9) return true
    }
  }
  return false
}

function lineY(segment: Segment, x: number) {
  return segment.a.y + (segment.b.y - segment.a.y) * (x - segment.a.x) / (segment.b.x - segment.a.x)
}
function projectedPoint(plane: Plane, p: P2): P3 {
  if (plane.kind === 'horizontal') return [p.x, plane.d, p.y]
  return [plane.nx * plane.d - plane.nz * p.x, p.y, plane.nz * plane.d + plane.nx * p.x]
}
function pushTriangle(out: number[], plane: Plane, a: P2, b: P2, c: P2, sign: number) {
  const pts = sign > 0 ? [a, c, b] : [a, b, c]
  for (const p of pts) out.push(...projectedPoint(plane, p))
}

function reconstruct(plane: Plane) {
  const edges: Segment[] = []
  const eventSet = new Set<number>()
  for (const face of plane.faces) {
    for (let i = 0; i < 3; i++) {
      const a = face.points[i], b = face.points[(i + 1) % 3]
      eventSet.add(a.x)
      eventSet.add(b.x)
      if (Math.abs(a.x - b.x) > EPS) edges.push({ a, b })
    }
  }
  // Bands also split where two triangle boundaries intersect. Thus the
  // vertical ordering of edges cannot change inside any one band.
  for (let i = 0; i < edges.length; i++) {
    const a = edges[i]
    for (let j = i + 1; j < edges.length; j++) {
      const b = edges[j]
      const xMin = Math.max(Math.min(a.a.x, a.b.x), Math.min(b.a.x, b.b.x))
      const xMax = Math.min(Math.max(a.a.x, a.b.x), Math.max(b.a.x, b.b.x))
      if (xMax - xMin < 1e-7) continue
      const x1 = xMin, x2 = xMax
      const da = lineY(a, x2) - lineY(a, x1)
      const db = lineY(b, x2) - lineY(b, x1)
      const delta = da - db
      if (Math.abs(delta) < EPS) continue
      const u = (lineY(b, x1) - lineY(a, x1)) / delta
      if (u > 1e-7 && u < 1 - 1e-7) eventSet.add(x1 + u * (x2 - x1))
    }
  }
  const events = [...eventSet].sort((a, b) => a - b)
  const out: number[] = []
  for (let i = 0; i + 1 < events.length; i++) {
    const u0 = events[i], u1 = events[i + 1]
    if (u1 - u0 < 1e-8) continue
    const mid = (u0 + u1) * .5
    const cuts = edges.filter((e) => mid > Math.min(e.a.x, e.b.x) + 1e-9 && mid < Math.max(e.a.x, e.b.x) - 1e-9)
      .map((edge) => ({ edge, value: lineY(edge, mid) }))
      .sort((a, b) => a.value - b.value)
    const distinct: typeof cuts = []
    for (const cut of cuts) {
      if (distinct.length && Math.abs(distinct[distinct.length - 1].value - cut.value) < 1e-8) continue
      distinct.push(cut)
    }
    for (let j = 0; j + 1 < distinct.length; j++) {
      const lower = distinct[j], upper = distinct[j + 1]
      if (upper.value - lower.value < 1e-8) continue
      const center = { x: mid, y: (lower.value + upper.value) * .5 }
      const covering = plane.faces.filter((face) => inside(center, face.points))
      if (!covering.length) continue
      // Never erase a physical surface when two coincident faces have
      // inconsistent winding. A single DoubleSide triangle remains visible.
      const balance = covering.reduce((sum, face) => sum + face.sign, 0)
      const faceSign = Math.sign(balance) || covering[0].sign
      const a = { x: u0, y: lineY(lower.edge, u0) }, b = { x: u1, y: lineY(lower.edge, u1) }
      const c = { x: u1, y: lineY(upper.edge, u1) }, d = { x: u0, y: lineY(upper.edge, u0) }
      if (area2([a,b,c]) > 1e-10) pushTriangle(out, plane, a,b,c, faceSign)
      if (area2([a,c,d]) > 1e-10) pushTriangle(out, plane, a,c,d, faceSign)
    }
  }
  return out
}

/** All positions are in metres. This module deliberately has NO Three.js deps. */
export function repairWallSurface145(source: ArrayLike<number>): SurfaceRepairStats145 {
  if (source.length % 9 !== 0) throw new Error('Incomplete wall triangle buffer')
  const groups = new Map<string, Plane>()
  const kept: number[] = []
  let repairedPlanes = 0, skippedPlanes = 0
  for (let i = 0; i < source.length; i += 9) {
    const raw = Array.from({ length: 9 }, (_, j) => Number(source[i + j]))
    if (!raw.every(Number.isFinite)) throw new Error('Non-finite wall vertex')
    const a: P3 = [raw[0],raw[1],raw[2]], b: P3 = [raw[3],raw[4],raw[5]], c: P3=[raw[6],raw[7],raw[8]]
    const ux=b[0]-a[0], uy=b[1]-a[1], uz=b[2]-a[2]
    const vx=c[0]-a[0], vy=c[1]-a[1], vz=c[2]-a[2]
    const nx=uy*vz-uz*vy, ny=uz*vx-ux*vz, nz=ux*vy-uy*vx
    const mag=Math.hypot(nx,ny,nz)
    if (mag < 1e-12) continue
    const normals = [nx/mag,ny/mag,nz/mag]
    let kind: Plane['kind'], canonicalX=0, canonicalZ=0, planeD=0
    if (Math.abs(normals[1]) > 1-1e-7) {
      kind='horizontal'; planeD=a[1]
    } else if (Math.abs(normals[1]) < 1e-7) {
      kind='vertical'
      const orient = Math.abs(normals[0]) > 1e-8 ? Math.sign(normals[0]) : Math.sign(normals[2])
      canonicalX=normals[0]*orient; canonicalZ=normals[2]*orient
      planeD=canonicalX*a[0]+canonicalZ*a[2]
    } else {
      // Unsupported oblique plane. Pass it through, never distort its shape.
      kept.push(...raw); continue
    }
    const sign = kind==='horizontal' ? Math.sign(normals[1]) : Math.sign(normals[0]*canonicalX + normals[2]*canonicalZ)
    const toP2 = (p: P3): P2 => kind==='horizontal'
      ? {x:p[0],y:p[2]}
      : {x:-canonicalZ*p[0]+canonicalX*p[2],y:p[1]}
    const face: Face = {points:[toP2(a),toP2(b),toP2(c)],sign,original:raw}
    const key = kind==='horizontal' ? `h:${keyRound(planeD, 100000)}`
      : `v:${keyRound(canonicalX,1000000)}:${keyRound(canonicalZ,1000000)}:${keyRound(planeD,100000)}`
    const group = groups.get(key)
    if (group) group.faces.push(face)
    else groups.set(key,{kind,nx:canonicalX,nz:canonicalZ,d:planeD,faces:[face]})
  }
  for (const group of groups.values()) {
    if (group.faces.length < 2 || !hasOverlap(group.faces)) {
      for (const face of group.faces) kept.push(...face.original)
      continue
    }
    if (group.faces.length > 350) {
      skippedPlanes++
      for (const face of group.faces) kept.push(...face.original)
      continue
    }
    const result = reconstruct(group)
    if (!result.length) {
      skippedPlanes++
      for (const face of group.faces) kept.push(...face.original)
      continue
    }
    if (!result.every(Number.isFinite)) {
      skippedPlanes++
      for (const face of group.faces) kept.push(...face.original)
      continue
    }
    repairedPlanes++
    kept.push(...result)
  }
  return { positions: kept, inputTriangles: source.length/9, outputTriangles: kept.length/9, repairedPlanes, skippedPlanes }
}
STROM145_SURFACE_TS

cat > "$WORK_DIR/.strom145_patch.py" <<'STROM145_PATCH_PY'
from pathlib import Path
import os
import re
root=Path(os.environ['STROM145_ROOT'])
scene=root/'frontend/src/components/Building3DWorkspace.tsx'
css=root/'frontend/src/styles.css'
module=root/'frontend/src/building/wallSurface145.ts'
for p in (scene,css,root/'frontend/src/building/blueprintLevels.ts',root/'frontend/src/building/solidGeometry.ts',root/'frontend/src/components/StromIcon.tsx',root/'frontend/src/building/meshCleanup144.ts'):
    if not p.is_file(): raise RuntimeError(f'145 required file missing: {p}')
s=scene.read_text(encoding='utf8')
style=css.read_text(encoding='utf8')
if 'STROM145_FLOATING_LEVELS' in s or module.exists():
    raise RuntimeError('145 already installed - not patching twice')
for required in ('STROM144_LEVEL_PICKER','STROM143B_STAIR_AUDIT','STROM141_WALL_HOVER','cleanWallSurface144(surface.positions)','function SolidWallMeshes(', 'function RealBuildingScene('):
    if required not in s: raise RuntimeError(f'145 requires successfully deployed 144a and working wall selection: missing {required}')

def exactly(source, old, new, description):
    count=source.count(old)
    if count!=1: raise RuntimeError(f'145 {description}: expected 1 anchor, found {count}')
    return source.replace(old,new,1)

# The 144a sorter drops triangles by vertex set, even when winding differs,
# and rendered only the front of the transparent wall. Restore the complete
# original physical surface, then merge partial overlapping coplanar patches
# without moving a single wall coordinate or changing door/window openings.
s=exactly(s,
    "import { cleanWallSurface144 } from '../building/meshCleanup144'",
    "import { repairWallSurface145 } from '../building/wallSurface145'",
    'safe surface repair module import')
start=s.index('function SolidWallMeshes(')
end=s.index('function DoorHandle(',start)
wall=s[start:end]
for required in ('onPointerMove={hoverAt}','onPointerOut={() => setHovered(null)}','onSelectWall'):
    if required not in wall: raise RuntimeError(f'145: working wall-editor behavior missing: {required}')
wall=exactly(wall,
    'new THREE.Float32BufferAttribute(cleanWallSurface144(surface.positions).positions, 3)',
    'new THREE.Float32BufferAttribute(repaired145.positions, 3)',
    'repair overdraw also for partially overlapping triangles')
wall=exactly(wall,
    '    const surface = buildSolidSurface(model)\n    const mesh = new THREE.BufferGeometry()',
    '''    const surface = buildSolidSurface(model)
    const repaired145 = repairWallSurface145(surface.positions)
    if (repaired145.repairedPlanes || repaired145.skippedPlanes) {
      console.info('[STROM145 Wandgeometrie]', {
        vorher: repaired145.inputTriangles, nachher: repaired145.outputTriangles,
        reparierteFlaechen: repaired145.repairedPlanes, uebersprungeneFlaechen: repaired145.skippedPlanes,
      })
    }
    const mesh = new THREE.BufferGeometry()''',
    'calculate repair once per wall model and record non-sensitive diagnostics')
wall=exactly(wall,
    'depthWrite={!transparent}',
    'depthWrite={true}',
    'depth buffer also for transparent wall: prevent transparent self-overdraw')
wall=exactly(wall,
    '''          side={transparent ? THREE.FrontSide : THREE.DoubleSide}
          forceSinglePass={transparent}''',
    '''          side={THREE.DoubleSide}
          forceSinglePass={false}''',
    'restore complete visible outside/inside surface, no front-only loss')
s=s[:start]+wall+s[end:]

# The 144a selector is a toolbar-only dropdown. In Blueprint, the layer menu
# is a floating window at the top right of the canvas, using canvas-layer-menu.
# Replace the dropdown, use that SAME visual component CSS in both 3D variants.
old_picker='''        {variant === 'wall' ? (
          <label className="building3d-level-picker144" title="Blueprint-Ebene im Wanddetail waehlen; verwendet dieselben gespeicherten Ebenen">
            <StromIcon name="layers-current" size={20} title="Ebenen aus Blueprint" />
            <span>Ebene</span>
            <select aria-label="Aktive Blueprint-Ebene im Wanddetail" value={activeLevel.id}
              onChange={(event) => chooseWallDetailLevel144(event.currentTarget.value)}>
              {levelOptions144.map((level) => (
                <option key={level.id} value={level.id}>{level.name} · {Math.round(level.heightM * 1000)} mm</option>
              ))}
            </select>
          </label>
        ) : (
          <span>Etage: {activeLevel.name} · {Math.round(activeLevel.heightM * 1000)} mm</span>
        )}'''
s=exactly(s,old_picker,'        {/* STROM145_FLOATING_LEVELS: layer selection lives in the canvas overlay. */}','remove Wanddetail toolbar-only selector')
s=exactly(s,
    "  const [selectedDoorId, setSelectedDoorId] = useState('')",
    "  const [selectedDoorId, setSelectedDoorId] = useState('')\n  const [levelsOpen145, setLevelsOpen145] = useState(false)",
    'shared floating selector state')
# Keep current logic that writes exactly the Blueprint active-layer storage key.
# It also clears wall and door selections across levels, as in 144a.
if 'function chooseWallDetailLevel144(id: string)' not in s or 'selectBlueprintLevel144(floor, id, window.localStorage)' not in s:
    raise RuntimeError('145 active-level sync API from 144a missing')

floating='''
          {/* STROM145_FLOATING_LEVELS: reuse the Blueprint floating layer-menu classes. */}
          <div className={`canvas-layer-menu building3d-floating-levels145 ${levelsOpen145 ? 'open' : ''}`} aria-label="Ebenen">
            <button type="button" title="Ebenenauswahl wie im Blueprint" aria-label="Ebenenauswahl öffnen oder schließen"
              aria-expanded={levelsOpen145} onClick={() => setLevelsOpen145((value) => !value)}>
              <StromIcon name="chevron-down" size={19} title="Ebenen" />
              <span>{activeLevel.name}</span>
            </button>
            {levelsOpen145 && (
              <div className="layer-menu-panel" role="group" aria-label="Blueprint-Ebenen">
                <div className="layer-list">
                  {levelOptions144.map((level) => {
                    const selected = level.id === activeLevel.id
                    return (
                      <button type="button" key={level.id}
                        className={`layer-row building3d-floating-level-row145 ${selected ? 'active effectively-visible' : 'effectively-hidden'}`}
                        title={`${level.name} wählen – ${Math.round(level.heightM * 1000)} mm Geschosshöhe`}
                        aria-current={selected ? 'true' : undefined}
                        onClick={() => { chooseWallDetailLevel144(level.id); setLevelsOpen145(false) }}>
                        <StromIcon name={selected ? 'layers-current' : 'layers-neighbor'} size={19} title={selected ? 'Aktive Ebene' : 'Andere Ebene'} />
                        <span className="building3d-level-name145">{level.name}</span>
                        <small>{Math.round(level.heightM * 1000)} mm</small>
                      </button>
                    )
                  })}
                </div>
                <p className="building3d-level-note145">Die aktive Ebene ist dieselbe wie im Blueprint. Ebenenverwaltung und Höhenänderung erfolgen im Blueprint.</p>
              </div>
            )}
          </div>
'''
# Do not patch other scene components (StairSolid, floor, room selection).
match=list(re.finditer(r'(?m)^\s*<RealBuildingScene\b[^\n]*?/>',s))
if len(match)!=1:
    raise RuntimeError(f'145 3D canvas renderer insertion point: expected one, found {len(match)}')
pos=match[0].end()
s=s[:pos]+floating+s[pos:]

style+='''
/* STROM145_FLOATING_LEVELS: consistent floating Blueprint picker in both real 3D views. */
.building3d-view .building3d-floating-levels145 {
  position: absolute; top: 30px; right: 12px; z-index: 44;
  min-width: 0; pointer-events: none;
}
.building3d-view .building3d-floating-levels145 > button {
  display: inline-flex; align-items: center; gap: 7px;
  max-width: 235px; padding: 0 12px; pointer-events: auto;
}
.building3d-floating-levels145 > button .strom-ui-icon { flex: 0 0 19px; }
.building3d-floating-levels145 > button span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.building3d-floating-levels145 .layer-menu-panel { width: 236px; pointer-events: auto; }
.building3d-floating-levels145 .layer-list { max-height: 300px; }
.building3d-floating-levels145 .layer-menu-panel button.building3d-floating-level-row145 {
  display: grid; grid-template-columns: 20px minmax(0, 1fr) auto;
  align-items: center; width: 100%; height: auto; min-height: 40px;
  gap: 8px; padding: 6px 8px; border-radius: 11px; text-align: left;
  cursor: pointer; border: 1px solid #e2e8f0; background: #f8fafc;
  color: #1e293b; box-shadow: none;
}
.building3d-floating-levels145 .layer-menu-panel button.building3d-floating-level-row145.active {
  background: #eff6ff; border-color: #2563eb; color: #1d4ed8;
  box-shadow: inset 3px 0 0 #2563eb;
}
.building3d-floating-levels145 .layer-menu-panel button.building3d-floating-level-row145:hover { background: #e8f0ff; }
.building3d-floating-levels145 .building3d-level-name145 { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.building3d-floating-levels145 .building3d-floating-level-row145 small { font-size: 10px; font-weight: 650; white-space: nowrap; color: #526581; }
.building3d-floating-levels145 .building3d-level-note145 { margin: 3px 1px 0; color: #64748b; font-size: 11px; line-height: 1.35; }
'''
module.write_text(Path(os.environ['STROM145_MODULE']).read_text('utf8'), encoding='utf8')
scene.write_text(s,encoding='utf8')
css.write_text(style,encoding='utf8')
print('145: Blueprint-style floating picker in Wanddetail+3D Haus; existing shared level IDs, heights and selection; robust coplanar wall repair and restored double-sided material.')
STROM145_PATCH_PY

[ -s "$WORK_DIR/.strom145_wallSurface.ts" ] || fail "Geometriemodul wurde nicht erzeugt."
[ -s "$WORK_DIR/.strom145_patch.py" ] || fail "Quellpatch wurde nicht erzeugt."
STROM145_ROOT="$WORK_DIR" STROM145_MODULE="$WORK_DIR/.strom145_wallSurface.ts" \
  python3 "$WORK_DIR/.strom145_patch.py" >>"$DIAG_LOG" 2>&1 || fail "Quellpatch 145 fehlgeschlagen. Kein Git-Push/Stage-Deployment."
rm -f "$WORK_DIR/.strom145_wallSurface.ts" "$WORK_DIR/.strom145_patch.py"

cat > "$WORK_DIR/docs/STROM_UPDATE_145.md" <<'STROM145_DOC'
# Update 145: Floating Ebenenwahl und Wandoberflaechen
- Blueprint floating Ebenenauswahl bleibt unveraendert.
- Wanddetail und 3D Haus zeigen dieselbe floating Ebenenauswahl mit exakt den Blueprint Ebenen-IDs, Namen und Hoehen. Beim Wechsel wird derselbe localStorage active key verwendet.
- Der 144a Toolbar Selector wird durch den Floating Selector oben rechts ersetzt.
- Das 139-Wandvolumen bleibt die Datenquelle. Die 144a Dreieck-Filterung wird durch eine coplanare Oberflaechenvereinigung ersetzt: vollstaendige und teilweise ueberlappende Koplanar-Dreiecke ergeben eine einzelne sichtbare Deckflaeche. Ungeruehrte Ebenen behalten alle Originaldreiecke.
- Der 144a FrontSide-only Transparenzmodus wird zurueckgenommen, Material hat DoubleSide und transparenten Tiefentest/Depthwrite; keine Aenderung an Tueren, Raumkoordinaten, Treppen oder Wandauswahl.
- Nur Stage; keine Datenmigration und keine Produktionsaenderung.
STROM145_DOC

log "4) Strenge Frontend-Pruefung / Build (vor GitHub) ..."
( cd "$WORK_DIR/frontend"; VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 \
  || fail "Frontend-Build fehlgeschlagen. Kein Git-Push/Stage-Deployment."

log "4.1) Geometrie-, Ebenen- und Wandbearbeitungs-Regressionstests ..."
export STROM145_ROOT="$WORK_DIR"
export STROM145_TYPESCRIPT="$DEPENDENCIES/typescript"
node <<'STROM145_TEST_JS' >>"$DIAG_LOG" 2>&1 || fail "145 Regressionstests fehlgeschlagen. Kein Git-Push/Stage-Deployment."
'use strict'
const fs=require('fs'), ts=require(process.env.STROM145_TYPESCRIPT), root=process.env.STROM145_ROOT
const mPath=root+'/frontend/src/building/wallSurface145.ts'
const tsSource=fs.readFileSync(mPath,'utf8')
const transpiled=ts.transpileModule(tsSource,{fileName:mPath,reportDiagnostics:true,compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}})
if(transpiled.diagnostics?.some(d=>d.category===ts.DiagnosticCategory.Error))throw Error('surface145 transpile failed')
const m={exports:{}}
new Function('module','exports',transpiled.outputText)(m,m.exports)
const {repairWallSurface145}=m.exports
function area(data){let a=0;for(let i=0;i<data.length;i+=9){const p=data.slice(i,i+9),u=[p[3]-p[0],p[4]-p[1],p[5]-p[2]],v=[p[6]-p[0],p[7]-p[1],p[8]-p[2]];a+=Math.hypot(u[1]*v[2]-u[2]*v[1],u[2]*v[0]-u[0]*v[2],u[0]*v[1]-u[1]*v[0])/2}return a}
const a=[0,0,0,0,1,0,1,1,0], opposite=[0,0,0,1,1,0,0,1,0]
const b=[0.5,0,0,0.5,1,0,1.5,1,0]
const scenarios=[['single',a,.5],['identical',[...a,...a],.5],['opposite winding',[...a,...opposite],.5],['partial overlap',[...a,...b],.875]]
for(const [name,input,expected] of scenarios){const repaired=repairWallSurface145(input);if(Math.abs(area(repaired.positions)-expected)>1e-6)throw Error(name+' union area unexpected '+area(repaired.positions));console.log('PASS',name,repaired.inputTriangles,'->',repaired.outputTriangles,'triangles')}
const scene=fs.readFileSync(root+'/frontend/src/components/Building3DWorkspace.tsx','utf8')
const app=fs.readFileSync(root+'/frontend/src/App.tsx','utf8')
if(!scene.includes('STROM145_FLOATING_LEVELS')||!scene.includes('building3d-floating-levels145')||!scene.includes('levelOptions144.map')||!scene.includes('chooseWallDetailLevel144(level.id)'))throw Error('floating selector missing or disconnected')
if(!scene.includes('side={THREE.DoubleSide}')||!scene.includes('depthWrite={true}')||!scene.includes('repairWallSurface145(surface.positions)'))throw Error('new wall material / surface repair missing')
if(!scene.includes('onPointerMove={hoverAt}')||!scene.includes('onSelectWall')||!scene.includes('<StairSolid'))throw Error('wall editor, hover, or 3D stairs were removed')
if(!app.includes('STROM144_BLUEPRINT_DOOR_LEVEL')||!app.includes('canvas-layer-menu'))throw Error('existing Blueprint / door layer filtering changed')
const jsx=ts.transpileModule(scene,{fileName:'Building3DWorkspace.tsx',reportDiagnostics:true,compilerOptions:{jsx:ts.JsxEmit.ReactJSX,module:ts.ModuleKind.ESNext,target:ts.ScriptTarget.ES2022}})
if(jsx.diagnostics?.some(d=>d.category===ts.DiagnosticCategory.Error))throw Error('React TSX syntactically invalid')
console.log('PASS: shared floating picker, sync, real 3D wall + hover, stairs, Blueprint unchanged')
STROM145_TEST_JS

log "5) Gepruefte Dateien in Stage-Source uebernehmen ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
  "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "Stage-Source-Synchronisation fehlgeschlagen. Backup: $BACKUP_DIR"

if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PATCH_ONLY: Build und Tests erfolgreich. Kein Web-Deploy."
  exit 0
fi

log "6) Stage-Frontend bauen und nach /strom-test/ ausliefern ..."
( cd "$STAGE_DIR/frontend"; VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 \
  || fail "Stage-Build fehlgeschlagen. Backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "Stage-Buildausgabe fehlt."
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 \
  || fail "Web-Deployment fehlgeschlagen. Backup: $BACKUP_DIR"
log ""
log "Update 145 erfolgreich auf Stage: https://home.moja.de/strom-test/"
log "  - Ebenenwahl als schwebendes Fenster, wie Blueprint, auch in Wanddetail und 3D Haus."
log "  - Teilweise koplanare Ueberlagerungen im Wandmesh werden zu einer Oberflaeche vereinigt."
log "  - Render-Regression aus 144a (FrontSide only) zurueckgenommen."
log "  - Blueprint, Tueren, Treppe, Hover, Wand-Popup und Produktion bleiben unveraendert."
log "Backup: $BACKUP_DIR"
