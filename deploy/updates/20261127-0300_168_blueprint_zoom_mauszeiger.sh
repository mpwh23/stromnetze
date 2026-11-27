#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261127-0300_168_blueprint_zoom_mauszeiger"
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
COMMIT_MESSAGE="Update 168: Blueprint wheel zoom at cursor, non-passive, frame-batched; rulers decoupled"
SELF_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
MODE="${1:-}"
# STROM168: Fingerabdruck des Bundles, das vor der Auslieferung im echten Browser geprueft wurde.
EXPECTED_BUNDLE168="9c4b03d9437e1ce1c7e92b4ab3a2f2e08ad9632d26cd4e66325c9d6d6dc7d9a0"
ALLOW_UNTESTED168="${STROM168_ALLOW_UNTESTED_BUNDLE:-0}"
if [ "${2:-}" = "allow-untested-bundle" ]; then ALLOW_UNTESTED168=1; fi
ALLOW_ARG168=""
if [ "$ALLOW_UNTESTED168" = "1" ]; then ALLOW_ARG168="allow-untested-bundle"; fi

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
  echo "2) Update 168 im isolierten Git-Checkout bauen, pruefen und nach GitHub pushen ..."
  ssh -t "${SSH_CONTROL_OPTS[@]}" "$REMOTE_HOST" "chmod +x '$REMOTE_TMP_SCRIPT' && '$REMOTE_TMP_SCRIPT' --git-phase $ALLOW_ARG168"

  echo ""
  echo "3) Git-Push erfolgreich. Update-Script jetzt nach ~/deploy kopieren ..."
  scp "${SSH_CONTROL_OPTS[@]}" "$SELF_PATH" "$REMOTE_HOST:$REMOTE_DEPLOY_SCRIPT"

  echo ""
  echo "4) Stage-Update auf dem Pi ausfuehren ..."
  ssh -t "${SSH_CONTROL_OPTS[@]}" "$REMOTE_HOST" "rm -f '$REMOTE_TMP_SCRIPT'; chmod +x '$REMOTE_DEPLOY_SCRIPT'; cd '$REMOTE_DEPLOY_DIR'; './$(basename "$SELF_PATH")' --stage-phase $ALLOW_ARG168"
  exit $?
fi

# -----------------------------------------------------------------------------
# Pi Git phase. Uses the already configured HomePi deploy key:
#   Host github-stromnetze -> /root/.ssh/.../github-stromnetze
# No Mac Git repository and no GitHub CLI are required.
# -----------------------------------------------------------------------------
if [ "$MODE" = "--git-phase" ]; then
  if [ "$(id -u)" -ne 0 ]; then
    exec sudo -H "$SELF_PATH" --git-phase-root $ALLOW_ARG168
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

  echo "1.3) Update 168 isoliert anwenden, TypeScript/Vite-Build, Tests und Bundle-Abgleich ..."
  PATCH_ONLY=1 \
    STAGE_DIR="$GIT_TMP" \
    PROD_DIR="$STAGE_DIR" \
    BACKUP_BASE=/tmp \
    "$SELF_PATH" --stage-phase $ALLOW_ARG168

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
fail() { log ""; log "ERROR: $*"; log "Diagnostics: $DIAG_LOG"; if [ -f "$DIAG_LOG" ]; then echo '--- Last diagnostic lines ---'; tail -n 90 "$DIAG_LOG"; fi; exit 1; }
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

# ----- 168: Hilfsfunktionen ----------------------------------------------------------------
dist_fingerprint168() {
  ( cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do sha256sum "$f"; done ) | sha256sum | cut -d' ' -f1
}
check_bundle168() {
  local have; have="$(dist_fingerprint168 "$1")"
  log "Bundle-Fingerabdruck: $have"
  if [ "$have" = "$EXPECTED_BUNDLE168" ]; then
    log "PASS: Bundle ist identisch mit dem im Browser geprueften Bundle."
  elif [ "$ALLOW_UNTESTED168" = "1" ]; then
    log "WARNUNG: Bundle weicht vom geprueften Bundle ab ($EXPECTED_BUNDLE168); ausdruecklich erlaubt."
  else
    ( cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do sha256sum "$f"; done ) >>"$DIAG_LOG" 2>&1 || true
    fail "168 Bundle weicht vom im Browser geprueften Bundle ab (erwartet $EXPECTED_BUNDLE168). $2 Bewusst trotzdem: STROM168_ALLOW_UNTESTED_BUNDLE=1 vor den Mac-Befehl setzen."
  fi
}

log "=== Update 168: Blueprint-Zoom am Mauszeiger, ohne Ruckeln ==="
log "Stage: $STAGE_DIR"
log "Diagnostics: $DIAG_LOG"
for file in frontend/src/App.tsx frontend/src/styles.css; do
  [ -s "$STAGE_DIR/$file" ] || fail "168 Ausgangsdatei fehlt: $file"
done
if grep -Fq 'STROM168_WHEEL_ZOOM' "$STAGE_DIR/frontend/src/App.tsx"; then
  fail "168 ist bereits installiert; nichts veraendert"
fi
[ -f "$STAGE_DIR/frontend/src/components/wallGrowth166.ts" ] || \
  fail "168 setzt den Stand 166 voraus (wallGrowth166.ts fehlt); nichts veraendert"
command -v python3 >/dev/null 2>&1 || fail "python3 fehlt"
command -v rsync >/dev/null 2>&1 || fail "rsync fehlt"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum fehlt"
select_node
log "1) Backup Stage ..."
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PATCH_ONLY: isolated Git checkout; no Stage backup"
else
  cp -a "$STAGE_DIR" "$BACKUP_DIR" || fail "Stage backup failed"
  log "   Stage-Backup: $BACKUP_DIR"
fi
log "2) Prepare isolated source ..."
rsync -a --exclude='/frontend/node_modules' --exclude='/frontend/dist' --exclude='/.git' \
  "$STAGE_DIR/" "$WORK_DIR/" >>"$DIAG_LOG" 2>&1 || fail "168 source copy failed"
DEPENDENCIES=""
for candidate in "$STAGE_DIR/frontend/node_modules" "$PROD_DIR/frontend/node_modules" /home/mpwh/strom_stage/frontend/node_modules; do
  if [ -f "$candidate/typescript/lib/typescript.js" ] && [ -d "$candidate/vite" ] && \
     [ -d "$candidate/three" ] && [ -d "$candidate/@react-three/fiber" ]; then
    DEPENDENCIES="$candidate";break
  fi
done
[ -n "$DEPENDENCIES" ] || fail "168 TypeScript/Vite/Three dependencies unavailable"
ln -s "$DEPENDENCIES" "$WORK_DIR/frontend/node_modules"
RESOURCE_DIR="$WORK_DIR/168_resources"
mkdir -p "$RESOURCE_DIR"
cat > "$RESOURCE_DIR/patch168.py" <<'STROM168_PATCH'
#!/usr/bin/env python3
"""Patch 168: Blueprint-Zoom am Mauszeiger, stufenlos, ohne Sprung; Lineale ohne Editor-Neuaufbau.

Arbeitet nur auf einer isolierten Kopie. App.tsx und styles.css werden per SHA-256 mit dem
Stand 166 verglichen; bei Abweichung wird nichts veraendert.
"""
from pathlib import Path
import hashlib, os

root = Path(os.environ['STROM168_ROOT'])
app = root / 'frontend/src/App.tsx'
css = root / 'frontend/src/styles.css'
BASE = {app: '5fc12ced159f7d43e01e36c08b6fc02b4f5944448ffe0a0708bb4019dbfe51fe', css: 'f58023b5de081ba2bb19b7d4ce6891e3bc332a7e0c164ffb87cf35784de681de'}
APP_EDITS = [('Import flushSync', "import StromIcon from './components/StromIcon'\n", "import StromIcon from './components/StromIcon'\nimport { flushSync } from 'react-dom' // STROM168_WHEEL_ZOOM\n"), ('Zoom laden', 'zoom: Number.isFinite(zoom) ? clamp(round2(zoom), 0.22, 10) : 1,', 'zoom: Number.isFinite(zoom) ? clamp(Math.round(zoom * 10000) / 10000, 0.22, 10) : 1, // STROM168: stufenloser Zoom'), ('Zoom speichern', 'zoom: clamp(round2(state.zoom), 0.22, 10),', 'zoom: clamp(Math.round(state.zoom * 10000) / 10000, 0.22, 10),'), ('Refs', '  const [snapEnabled, setSnapEnabled] = useState(true)\n', '  // STROM168_WHEEL_ZOOM: aktueller Zoom ohne veralteten Closure-Wert, Lineal-Abgleich, gebuendeltes Speichern.\n  const zoomRef168 = useRef(zoom)\n  zoomRef168.current = zoom\n  const rulerSync168 = useRef<(() => void) | null>(null)\n  const viewport168 = useRef<{ floorId: string; zoom: number; left: number; top: number } | null>(null)\n  const viewportTimer168 = useRef<number | null>(null)\n  const exactScroll168 = useRef<{ left: number; top: number } | null>(null)\n  const applyZoomRef168 = useRef(applyZoom168)\n  applyZoomRef168.current = applyZoom168\n  const flushViewportRef168 = useRef(flushViewport168)\n  flushViewportRef168.current = flushViewport168\n  const [snapEnabled, setSnapEnabled] = useState(true)\n'), ('Wheel-Effect', '  useEffect(() => {\n    const viewport = loadCanvasViewport(floor.id)\n    setZoom(viewport.zoom)\n', "  // STROM168_WHEEL_ZOOM: nativer, nicht-passiver Listener. React meldet wheel passiv an;\n  // preventDefault() wirkte deshalb nicht und der Browser scrollte bei jeder Raste\n  // zusaetzlich um ca. 100 px (Zoom sprang). Pinch mit ctrlKey zoomte die ganze Seite.\n  useEffect(() => {\n    const scroll = canvasScrollRef.current\n    if (!scroll) return\n    let factor = 1\n    let anchorX = 0\n    let anchorY = 0\n    let frame = 0\n    let gestureBase = 0\n    const anchorAt = (clientX: number | undefined, clientY: number | undefined) => {\n      const rect = scroll.getBoundingClientRect()\n      anchorX = Number.isFinite(clientX) ? (clientX as number) - rect.left - scroll.clientLeft : scroll.clientWidth / 2\n      anchorY = Number.isFinite(clientY) ? (clientY as number) - rect.top - scroll.clientTop : scroll.clientHeight / 2\n    }\n    const run = () => {\n      frame = 0\n      const pending = factor\n      factor = 1\n      applyZoomRef168.current(zoomRef168.current * pending, anchorX, anchorY)\n    }\n    const onWheel = (event: WheelEvent) => {\n      event.preventDefault()\n      const unit = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? scroll.clientHeight : 1\n      const dx = event.deltaX * unit\n      const dy = event.deltaY * unit\n      if (!event.ctrlKey && Math.abs(dx) > Math.abs(dy)) {\n        scroll.scrollLeft += dx // Shift+Mausrad bzw. seitliches Wischen: waagerecht verschieben\n        return\n      }\n      if (dy === 0) return\n      const limited = Math.max(-200, Math.min(200, dy))\n      factor *= Math.pow(2, -limited * (event.ctrlKey ? 0.01 : 0.002))\n      anchorAt(event.clientX, event.clientY)\n      if (!frame) frame = window.requestAnimationFrame(run)\n    }\n    // Safari meldet Pinch als gesture*-Ereignis statt als wheel.\n    const onGestureStart = (event: Event) => {\n      event.preventDefault()\n      gestureBase = zoomRef168.current\n    }\n    const onGestureChange = (event: Event) => {\n      event.preventDefault()\n      const gesture = event as Event & { scale?: number; clientX?: number; clientY?: number }\n      if (!gestureBase || !Number.isFinite(gesture.scale) || !(gesture.scale as number > 0)) return\n      anchorAt(gesture.clientX, gesture.clientY)\n      factor = gestureBase * (gesture.scale as number) / zoomRef168.current\n      if (!frame) frame = window.requestAnimationFrame(run)\n    }\n    const passiveOff: AddEventListenerOptions = { passive: false }\n    scroll.addEventListener('wheel', onWheel, passiveOff)\n    scroll.addEventListener('gesturestart', onGestureStart, passiveOff)\n    scroll.addEventListener('gesturechange', onGestureChange, passiveOff)\n    const onPageHide = () => flushViewportRef168.current()\n    window.addEventListener('pagehide', onPageHide)\n    return () => {\n      scroll.removeEventListener('wheel', onWheel)\n      scroll.removeEventListener('gesturestart', onGestureStart)\n      scroll.removeEventListener('gesturechange', onGestureChange)\n      window.removeEventListener('pagehide', onPageHide)\n      if (frame) window.cancelAnimationFrame(frame)\n      flushViewportRef168.current() // letzte Ansicht sicher speichern (z. B. vor dem Wechsel nach 3D)\n    }\n  }, [floor.id])\n\n  useEffect(() => {\n    const viewport = loadCanvasViewport(floor.id)\n    setZoom(viewport.zoom)\n"), ('Wheel/Scroll-Handler', '  function handleCanvasWheel(event: ReactWheelEvent<HTMLDivElement>) {\n    event.preventDefault()\n    event.stopPropagation()\n    const scroll = canvasScrollRef.current\n    if (!scroll) return\n    const rect = scroll.getBoundingClientRect()\n    const mouseX = event.clientX - rect.left\n    const mouseY = event.clientY - rect.top\n    const beforeZoom = zoom\n    const contentX = (scroll.scrollLeft + mouseX) / beforeZoom\n    const contentY = (scroll.scrollTop + mouseY) / beforeZoom\n    const dominantDelta = Math.abs(event.deltaY) >= Math.abs(event.deltaX) ? event.deltaY : event.deltaX\n    if (dominantDelta === 0) return\n    const factor = dominantDelta < 0 ? 1.12 : (1 / 1.12)\n    const nextZoom = Math.min(10, Math.max(0.22, round2(beforeZoom * factor)))\n    if (nextZoom === beforeZoom) return\n    setZoom(nextZoom)\n    window.requestAnimationFrame(() => {\n      const nextScroll = canvasScrollRef.current\n      if (!nextScroll) return\n      nextScroll.scrollLeft = Math.max(0, contentX * nextZoom - mouseX)\n      nextScroll.scrollTop = Math.max(0, contentY * nextZoom - mouseY)\n      setScrollPosition({ left: nextScroll.scrollLeft, top: nextScroll.scrollTop })\n      saveCanvasViewport(floor.id, { zoom: nextZoom, left: nextScroll.scrollLeft, top: nextScroll.scrollTop })\n    })\n  }\n\n  function handleCanvasScroll() {\n    const scroll = canvasScrollRef.current\n    if (!scroll) return\n    setScrollPosition({ left: scroll.scrollLeft, top: scroll.scrollTop })\n    saveCanvasViewport(floor.id, { zoom, left: scroll.scrollLeft, top: scroll.scrollTop })\n  }\n', "  // STROM168_WHEEL_ZOOM: Zoomen wie in Karten- und CAD-Programmen.\n  // Der Punkt unter dem Mauszeiger bleibt stehen; der Zoom folgt der Drehung des Rads\n  // (2^(-deltaY * 0.002), Zwei-Finger-Zoom/Pinch zehnfach) statt fester 12-%-Schritte.\n  // Alle Ereignisse eines Bildes werden gesammelt und einmal pro Frame angewendet;\n  // das DOM wird synchron aktualisiert und erst danach gescrollt (kein Zwischenbild).\n  function applyZoom168(target: number, anchorX: number, anchorY: number) {\n    const scroll = canvasScrollRef.current\n    if (!scroll) return\n    const before = zoomRef168.current\n    const next = Math.min(10, Math.max(0.22, target))\n    if (!Number.isFinite(next) || Math.abs(next - before) < 1e-6) return\n    // Der Browser rundet scrollLeft/Top. Solange niemand anders gescrollt hat, mit dem exakten\n    // Wert weiterrechnen, sonst summiert sich der Rundungsfehler ueber viele Zoomschritte.\n    const exact = exactScroll168.current\n    const left = exact && Math.abs(exact.left - scroll.scrollLeft) < 1 ? exact.left : scroll.scrollLeft\n    const top = exact && Math.abs(exact.top - scroll.scrollTop) < 1 ? exact.top : scroll.scrollTop\n    // Gerechnet wird mit der tatsaechlich gezeichneten Groesse der Zeichnung (der Browser rundet\n    // Breiten auf 1/64 px) und ihrem Abstand zum Rand des Scrollinhalts.\n    const drawing = scroll.querySelector('svg')\n    const units = drawing?.viewBox?.baseVal?.width || canvas.width\n    const frame = scroll.getBoundingClientRect()\n    const sheet = drawing ? drawing.getBoundingClientRect() : null\n    const scaleBefore = sheet && sheet.width > 0 ? sheet.width / units : before\n    const offsetX = sheet ? sheet.left - frame.left - scroll.clientLeft + scroll.scrollLeft : 0\n    const offsetY = sheet ? sheet.top - frame.top - scroll.clientTop + scroll.scrollTop : 0\n    const contentX = (left + anchorX - offsetX) / scaleBefore\n    const contentY = (top + anchorY - offsetY) / scaleBefore\n    zoomRef168.current = next\n    flushSync(() => setZoom(next))\n    const sheetAfter = drawing ? drawing.getBoundingClientRect() : null\n    const scaleAfter = sheetAfter && sheetAfter.width > 0 ? sheetAfter.width / units : next\n    const nextLeft = contentX * scaleAfter + offsetX - anchorX\n    const nextTop = contentY * scaleAfter + offsetY - anchorY\n    scroll.scrollLeft = nextLeft\n    scroll.scrollTop = nextTop\n    exactScroll168.current = { left: nextLeft, top: nextTop }\n    rulerSync168.current?.()\n    rememberViewport168()\n  }\n\n  /** Zoomknoepfe: gleichmaessige Schritte um die Bildmitte. */\n  function zoomStep168(factor: number) {\n    const scroll = canvasScrollRef.current\n    if (!scroll) return\n    applyZoom168(zoomRef168.current * factor, scroll.clientWidth / 2, scroll.clientHeight / 2)\n  }\n\n  /** Ansicht merken; gespeichert wird hoechstens alle 200 ms (vorher bei jedem Scroll-Ereignis). */\n  function rememberViewport168() {\n    const scroll = canvasScrollRef.current\n    if (!scroll) return\n    viewport168.current = { floorId: floor.id, zoom: zoomRef168.current, left: scroll.scrollLeft, top: scroll.scrollTop }\n    if (viewportTimer168.current === null) viewportTimer168.current = window.setTimeout(flushViewport168, 200)\n  }\n\n  function flushViewport168() {\n    if (viewportTimer168.current !== null) {\n      window.clearTimeout(viewportTimer168.current)\n      viewportTimer168.current = null\n    }\n    const state = viewport168.current\n    if (state) saveCanvasViewport(state.floorId, state)\n  }\n\n  function handleCanvasScroll() {\n    // STROM168_RULERS: Lineale folgen direkt, ohne den ganzen Editor neu aufzubauen.\n    rulerSync168.current?.()\n    rememberViewport168()\n  }\n"), ('Zoom 100 %', '  function scaleCanvasTo100() {\n    const scroll = canvasScrollRef.current\n    if (!scroll) {\n      setZoom(1)\n      return\n    }\n    const contentCenterX = (scroll.scrollLeft + scroll.clientWidth / 2) / zoom\n    const contentCenterY = (scroll.scrollTop + scroll.clientHeight / 2) / zoom\n    setZoom(1)\n    window.requestAnimationFrame(() => {\n      const nextScroll = canvasScrollRef.current\n      if (!nextScroll) return\n      nextScroll.scrollLeft = Math.max(0, contentCenterX - nextScroll.clientWidth / 2)\n      nextScroll.scrollTop = Math.max(0, contentCenterY - nextScroll.clientHeight / 2)\n      setScrollPosition({ left: nextScroll.scrollLeft, top: nextScroll.scrollTop })\n      saveCanvasViewport(floor.id, { zoom: 1, left: nextScroll.scrollLeft, top: nextScroll.scrollTop })\n    })\n  }', '  function scaleCanvasTo100() {\n    // STROM168_WHEEL_ZOOM: 100 % um die Bildmitte, ohne Zwischenbild.\n    const scroll = canvasScrollRef.current\n    if (!scroll) {\n      setZoom(1)\n      return\n    }\n    applyZoom168(1, scroll.clientWidth / 2, scroll.clientHeight / 2)\n  }'), ('Zoom-Knoepfe Funktion', '  function changeZoom(next: number) {\n    const nextZoom = Math.min(10, Math.max(0.22, round2(next)))\n    setZoom(nextZoom)\n    const scroll = canvasScrollRef.current\n    if (scroll) saveCanvasViewport(floor.id, { zoom: nextZoom, left: scroll.scrollLeft, top: scroll.scrollTop })\n  }', '  function changeZoom(next: number) {\n    // STROM168_WHEEL_ZOOM: um die Bildmitte statt um die linke obere Ecke.\n    const scroll = canvasScrollRef.current\n    if (!scroll) {\n      setZoom(Math.min(10, Math.max(0.22, next)))\n      return\n    }\n    applyZoom168(next, scroll.clientWidth / 2, scroll.clientHeight / 2)\n  }'), ('Knopf verkleinern', 'onClick={() => changeZoom(zoom - 0.15)}><StromIcon name="zoom-out"', 'onClick={() => zoomStep168(1 / 1.25)}><StromIcon name="zoom-out"'), ('Knopf vergroessern', 'onClick={() => changeZoom(zoom + 0.15)}><StromIcon name="zoom-in"', 'onClick={() => zoomStep168(1.25)}><StromIcon name="zoom-in"'), ('Hilfetext', 'Mausrad scrollt, Shift+Mausrad zoomt.', 'Mausrad und Zwei-Finger-Zoom zoomen am Mauszeiger, Shift+Mausrad verschiebt waagerecht.'), ('Lineale + Scrollbereich', '        <CanvasRulers zoom={zoom} scrollLeft={scrollPosition.left} scrollTop={scrollPosition.top} />\n        <div className="canvas-scroll" ref={canvasScrollRef} onWheelCapture={handleCanvasWheel} onScroll={handleCanvasScroll}>\n', '        <CanvasRulers zoom={zoom} scrollRef={canvasScrollRef} syncRef={rulerSync168} />\n        <div className="canvas-scroll" ref={canvasScrollRef} onScroll={handleCanvasScroll}>\n'), ('Lineal-Komponente', 'function CanvasRulers({ zoom, scrollLeft, scrollTop }: { zoom: number; scrollLeft: number; scrollTop: number }) {\n  const ticks = Array.from({ length: canvas.maxM - canvas.minM + 1 }, (_, index) => canvas.minM + index)\n  return (\n    <div className="canvas-rulers" aria-hidden="true">\n      <div className="canvas-ruler-corner" />\n      <div className="canvas-ruler-top">\n        {ticks.map((meter) => {\n          const major = meter % 5 === 0\n          return (\n            <span key={`rt-${meter}`} className={`canvas-ruler-tick ${major ? \'major\' : \'\'}`} style={{ left: mToX(meter) * zoom - scrollLeft }}>\n              {major && <em>{meter}</em>}\n            </span>\n          )\n        })}\n      </div>\n      <div className="canvas-ruler-left">\n        {ticks.map((meter) => {\n          const major = meter % 5 === 0\n          return (\n            <span key={`rl-${meter}`} className={`canvas-ruler-tick ${major ? \'major\' : \'\'}`} style={{ top: mToY(meter) * zoom - scrollTop }}>\n              {major && <em>{meter}</em>}\n            </span>\n          )\n        })}\n      </div>\n    </div>\n  )\n}\n', '// STROM168_RULERS: Die Lineale verschieben sich direkt mit der Zeichnung (transform).\n// Vorher wurde bei jedem Scroll-Ereignis der ganze Blueprint-Editor neu aufgebaut.\nfunction CanvasRulers({ zoom, scrollRef, syncRef }: {\n  zoom: number\n  scrollRef: { current: HTMLDivElement | null }\n  syncRef: { current: (() => void) | null }\n}) {\n  const ticks = Array.from({ length: canvas.maxM - canvas.minM + 1 }, (_, index) => canvas.minM + index)\n  const topTrack = useRef<HTMLDivElement | null>(null)\n  const leftTrack = useRef<HTMLDivElement | null>(null)\n  useLayoutEffect(() => {\n    // Bezug ist die tatsaechliche Lage der Zeichnung. Vorher fehlte der 15-px-Scrollbalken-\n    // Abstand links (scrollbar-gutter), das obere Lineal lag 15 px neben dem Raster.\n    const sync = () => {\n      const drawing = scrollRef.current?.querySelector(\'svg\')\n      const topBox = topTrack.current?.parentElement\n      const leftBox = leftTrack.current?.parentElement\n      if (!drawing || !topBox || !leftBox || !topTrack.current || !leftTrack.current) return\n      const sheet = drawing.getBoundingClientRect()\n      topTrack.current.style.transform = `translate3d(${sheet.left - topBox.getBoundingClientRect().left}px, 0, 0)`\n      leftTrack.current.style.transform = `translate3d(0, ${sheet.top - leftBox.getBoundingClientRect().top}px, 0)`\n    }\n    syncRef.current = sync\n    sync()\n    return () => { if (syncRef.current === sync) syncRef.current = null }\n  })\n  useEffect(() => {\n    const onResize = () => syncRef.current?.()\n    window.addEventListener(\'resize\', onResize)\n    return () => window.removeEventListener(\'resize\', onResize)\n  }, [syncRef])\n  return (\n    <div className="canvas-rulers" aria-hidden="true">\n      <div className="canvas-ruler-corner" />\n      <div className="canvas-ruler-top">\n        <div className="canvas-ruler-track168" ref={topTrack}>\n          {ticks.map((meter) => {\n            const major = meter % 5 === 0\n            return (\n              <span key={`rt-${meter}`} className={`canvas-ruler-tick ${major ? \'major\' : \'\'}`} style={{ left: mToX(meter) * zoom }}>\n                {major && <em>{meter}</em>}\n              </span>\n            )\n          })}\n        </div>\n      </div>\n      <div className="canvas-ruler-left">\n        <div className="canvas-ruler-track168" ref={leftTrack}>\n          {ticks.map((meter) => {\n            const major = meter % 5 === 0\n            return (\n              <span key={`rl-${meter}`} className={`canvas-ruler-tick ${major ? \'major\' : \'\'}`} style={{ top: mToY(meter) * zoom }}>\n                {major && <em>{meter}</em>}\n              </span>\n            )\n          })}\n        </div>\n      </div>\n    </div>\n  )\n}\n')]
CSS_EDITS = [('Lineal-Spur', '/* STROM164_FIVE_METRE_GRID: identical Blueprint and 3D screen-pixel cadence. */\n', '/* STROM168_RULERS: Lineal-Inhalt wird per transform mit dem Scrollbereich verschoben. */\n.canvas-ruler-track168 { position:absolute; inset:0; will-change:transform; }\n/* STROM168_SMOOTH: keine Hintergrund-Unschaerfe ueber der Zeichnung; sie musste bei jedem Zoom-\n   und Scrollbild neu berechnet werden. Die Flaechen sind ohnehin zu 93-96 % deckend. */\n.canvas-ruler-top, .canvas-ruler-left, .canvas-toolbox, .canvas-settings { backdrop-filter: none; }\n\n/* STROM164_FIVE_METRE_GRID: identical Blueprint and 3D screen-pixel cadence. */\n')]

for path, want in BASE.items():
    if not path.is_file():
        raise RuntimeError(f'168: Ausgangsdatei fehlt: {path}')
    if 'STROM168_' in path.read_text(encoding='utf-8'):
        raise RuntimeError('168 ist bereits installiert; nichts veraendert')
    have = hashlib.sha256(path.read_bytes()).hexdigest()
    if have != want:
        raise RuntimeError(f'168: {path.name} entspricht nicht dem Stand 166 (sha256 {have[:12]}...). '
                           'Der Patch wurde gegen genau diesen Stand im Browser geprueft; nichts veraendert.')


def apply(path, edits):
    text = path.read_text(encoding='utf-8')
    for label, old, new in edits:
        count = text.count(old)
        if count != 1:
            raise RuntimeError(f'168: Textstelle "{label}" {count}x gefunden (erwartet: 1)')
        text = text.replace(old, new)
    return text

new_app = apply(app, APP_EDITS)
new_css = apply(css, CSS_EDITS)
app.write_text(new_app, encoding='utf-8')
css.write_text(new_css, encoding='utf-8')
print('168: Quelltext gepatcht')
STROM168_PATCH
cat > "$RESOURCE_DIR/test166.mjs" <<'STROM168_TEST166'
// Regression 166 (enthaelt alle Pruefungen aus 165). Echtes three, echte OrbitControls.
// Prueft (1) Quelltextstruktur, (2) die Geometrie der Draufsicht, (3) dass ungesperrte
// OrbitControls den Fehler erzeugen und gesperrte ihn beseitigen.
import fs from 'node:fs'
import path from 'node:path'
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'

const source = process.env.STROM166_SOURCE, modulesRaw = process.env.STROM166_MODULES
assert(source && modulesRaw, 'STROM166_SOURCE/STROM166_MODULES fehlen')
const modules = fs.realpathSync(modulesRaw)
const require = createRequire(path.join(modules, 'noop.js'))
const ts = require('typescript')
const THREE = await import(pathToFileURL(path.join(modules, 'three/build/three.module.js')).href)
const { OrbitControls } = await import(pathToFileURL(path.join(modules, 'three/examples/jsm/controls/OrbitControls.js')).href)
const read = name => fs.readFileSync(path.join(source, name), 'utf8')

// ---- 1) Struktur ---------------------------------------------------------------------------
const flight = read('components/CameraFlight150.tsx'), workspace = read('components/Building3DWorkspace.tsx')
const app = read('App.tsx'), bridge = read('components/cameraTransitions150.ts'), top = read('components/cameraTop165.ts')
for (const [name, code, kind] of [['CameraFlight150.tsx', flight, ts.ScriptKind.TSX],
  ['Building3DWorkspace.tsx', workspace, ts.ScriptKind.TSX], ['App.tsx', app, ts.ScriptKind.TSX],
  ['cameraTransitions150.ts', bridge, ts.ScriptKind.TS], ['cameraTop165.ts', top, ts.ScriptKind.TS]]) {
  const ast = ts.createSourceFile(name, code, ts.ScriptTarget.Latest, true, kind)
  assert.equal(ast.parseDiagnostics.length, 0, `${name}: Syntaxfehler`)
}
assert(workspace.includes('setRootState165({ controls })'), 'OrbitControls nicht im R3F-Store angemeldet')
assert.equal((workspace.match(/new OrbitControls\(/g) || []).length, 1, 'genau eine OrbitControls-Instanz')
assert.equal((flight.match(/\buseFrame\s*\(/g) || []).length, 1, 'zweiter Kameratreiber in CameraFlight150')
assert(flight.includes('control.enabled = false') && flight.includes('control.update = () => {}'), 'Controls werden nicht gesperrt')
assert(flight.includes('scene.onAfterRender'), 'Messung nach dem Zeichnen fehlt')
assert(flight.includes('measureBlueprint165()'), 'Live-Messung des Blueprints fehlt')
assert(flight.indexOf('active.verified >= VERIFY_FRAMES165') < flight.indexOf('notifyEnterReady150()'), 'Blende ohne Nachmessung')
assert(app.includes('registerEnterFailed165(') && app.includes('Building3DWorkspaceLazy165'), 'App-Anbindung 165 fehlt')
assert(!app.includes('storedViewport.zoom * 1.1'), 'alter Zoomausgleich x 1,1 noch vorhanden')
const removed = ['cameraBlueprintCenter156', 'cameraFloorMatch150r', 'cameraGridAlignment154', 'cameraGridAnalytic164',
  'cameraHandoffDiagnostics155', 'cameraViewportAlignment153', 'cameraViewportExact163', 'threeFloorExtrema150q']
const walk = dir => fs.readdirSync(dir, { withFileTypes: true }).flatMap(entry =>
  entry.isDirectory() ? walk(path.join(dir, entry.name)) : [path.join(dir, entry.name)])
for (const file of walk(source).filter(name => /\.(ts|tsx)$/.test(name))) {
  const code = fs.readFileSync(file, 'utf8')
  for (const name of removed) {
    assert(!new RegExp(`from\\s+['"][^'"]*${name}['"]`).test(code), `${path.basename(file)} importiert noch ${name}`)
  }
}
for (const name of removed) assert(!fs.existsSync(path.join(source, 'components', name + '.ts')), `${name}.ts noch vorhanden`)
console.log('PASS 165: Quelltextstruktur')

// ---- 2) Geometrie --------------------------------------------------------------------------
const js = ts.transpileModule(top, { fileName: 'cameraTop165.ts',
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS } }).outputText
const scope = { exports: {} }
new Function('require', 'module', 'exports', js)(name => {
  if (name === 'three') return THREE
  throw Error('Unerwarteter Import ' + name)
}, scope, scope.exports)
const { solveTopView165, poseAt165, gridErrorPx165, lensAt165, planToWorld165, MIN_START_DISTANCE165 } = scope.exports
const BASE_FOV = 48, START_FOV = 2
function blueprint(center, pixelsPerMetre, viewport, rotation = 0) {
  const c = Math.cos(rotation) * pixelsPerMetre, s = Math.sin(rotation) * pixelsPerMetre
  const px = viewport.left + viewport.width / 2, py = viewport.top + viewport.height / 2
  return { ax: c, ay: s, bx: -s, by: c, x: px - (c * center[0] - s * center[1]), y: py - (s * center[0] + c * center[1]) }
}
function gridMatrix({ translation = [0, 0], scale = 1, yaw = 0 } = {}) {
  return new THREE.Matrix4().compose(new THREE.Vector3(translation[0], 0, translation[1]),
    new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0, 1, 0), yaw), new THREE.Vector3(scale, scale, scale))
}
function applyPose(camera, topView, orbit, s) {
  const pose = poseAt165(topView, orbit, s, BASE_FOV, START_FOV)
  camera.position.copy(pose.position); camera.quaternion.copy(pose.quaternion); camera.fov = pose.fov
  camera.near = Math.max(0.05, pose.distance * 0.2); camera.far = pose.distance * 2 + 500
  const o = topView.offset, f = pose.offsetFactor
  if (f > 1e-6 && (Math.abs(o.x) > 1e-6 || Math.abs(o.y) > 1e-6)) camera.setViewOffset(o.width, o.height, o.x * f, o.y * f, o.width, o.height)
  else camera.clearViewOffset()
  camera.updateMatrixWorld(true)
  return pose
}
const cases = [
  { name: 'Messwerte aus dem Handover (Canvas 280 px schmaler, 107 px hoeher)', c: [5.960, 3.849], ppm: 82.68,
    vp: [330, 251, 2054, 1492.9], canvas: [330, 143.8, 1774, 1623.2] },
  { name: 'herausgezoomt, weit verschoben', c: [24.7, 10.0], ppm: 13.2, vp: [330, 252, 1526, 735], canvas: [330, 145, 1276, 850] },
  { name: 'Zoom 1000 %', c: [2, 2], ppm: 600, vp: [330, 252, 1526, 735], canvas: [330, 145, 1276, 850] },
  { name: 'negativer Bereich', c: [-8.2, -3.7], ppm: 61.1, vp: [10, 45, 900, 720], canvas: [200, -150, 730, 870] },
  { name: 'gedrehtes Blueprint-SVG', c: [5, -6], ppm: 101.31, vp: [185, 280, 2150, 1200], canvas: [0, 100, 1500, 850], bpRotation: 0.3 },
  { name: 'verschobenes, skaliertes 3D-Raster', c: [4.15, -7.21], ppm: 97.1, vp: [330, 252, 1526, 735], canvas: [330, 145, 1276, 850],
    grid: { translation: [-31, 9], scale: 1.6 } },
  { name: 'gedrehtes Blueprint und gedrehtes 3D-Raster', c: [-1.22, -5.21], ppm: 40.3, vp: [330, 252, 1526, 735],
    canvas: [330, 145, 1276, 850], bpRotation: -0.27, grid: { yaw: 0.35 } },
]
const rect = ([left, top, width, height]) => ({ left, top, width, height })
let worstTop = 0
for (const test of cases) {
  const viewport = rect(test.vp), canvas = rect(test.canvas), grid = gridMatrix(test.grid)
  const bp = blueprint(test.c, test.ppm, viewport, test.bpRotation)
  const topView = solveTopView165(bp, viewport, canvas, grid, BASE_FOV)
  assert.notEqual(typeof topView, 'string', `${test.name}: ${topView}`)
  assert(Math.abs(topView.planCenter.x - test.c[0]) < 1e-9 && Math.abs(topView.planCenter.y - test.c[1]) < 1e-9, `${test.name}: Planmitte`)
  const camera = new THREE.PerspectiveCamera(BASE_FOV, canvas.width / canvas.height, 0.05, 400)
  const iso = new THREE.PerspectiveCamera(BASE_FOV, canvas.width / canvas.height, 0.05, 400)
  const house = planToWorld165(grid, 4.5, 4).setY(1.3)
  iso.position.copy(house).add(new THREE.Vector3(11, 11.4, 11)); iso.lookAt(house); iso.updateMatrixWorld(true)
  const orbit = { pivot: house.clone(), quaternion: iso.quaternion.clone(), distance: iso.position.distanceTo(house) }
  // s = 0: senkrecht ueber der Blueprint-Mitte, Raster deckungsgleich
  const start = applyPose(camera, topView, orbit, 0)
  const direction = camera.getWorldDirection(new THREE.Vector3())
  assert(Math.abs(direction.x) < 1e-9 && Math.abs(direction.y + 1) < 1e-9 && Math.abs(direction.z) < 1e-9, `${test.name}: nicht senkrecht`)
  const centerWorld = planToWorld165(grid, test.c[0], test.c[1])
  assert(Math.abs(camera.position.x - centerWorld.x) < 1e-7 && Math.abs(camera.position.z - centerWorld.z) < 1e-7, `${test.name}: Kamera nicht ueber der Blueprint-Mitte`)
  assert(start.distance >= MIN_START_DISTANCE165 - 1e-6, `${test.name}: Starthoehe ${start.distance}`)
  const error = gridErrorPx165(bp, viewport, canvas, grid, camera)
  assert(error && error.max < 1e-4, `${test.name}: Rasterfehler ${error && error.max} px`)
  worstTop = Math.max(worstTop, error.max)
  // 2,6 m hohe Wand am Rand des sichtbaren Blueprints: hoechstens wenige Pixel neben der Linie
  const edge = { x: test.c[0] + viewport.width / 2 / test.ppm, y: test.c[1] }
  const wallTop = planToWorld165(grid, edge.x, edge.y).add(new THREE.Vector3(0, 2.6 * (test.grid?.scale || 1), 0)).project(camera)
  const foot = planToWorld165(grid, edge.x, edge.y).project(camera)
  const parallax = Math.hypot((wallTop.x - foot.x) * canvas.width / 2, (wallTop.y - foot.y) * canvas.height / 2)
  assert(parallax < 6, `${test.name}: Wandversatz ${parallax.toFixed(2)} px`)
  // s = 1: exakt die freie 3D-Ansicht, normaler Blickwinkel, keine Linsenverschiebung
  const end = applyPose(camera, topView, orbit, 1)
  assert(end.position.distanceTo(iso.position) < 1e-6 && Math.abs(end.fov - BASE_FOV) < 1e-9 && end.offsetFactor === 0, `${test.name}: Flugende`)
  assert(camera.quaternion.angleTo(iso.quaternion) < 1e-9, `${test.name}: Blickrichtung am Flugende`)
  // unterwegs: Kamera blickt immer genau auf den wandernden Blickpunkt, Abstand bleibt sicher
  let previous = null
  for (let i = 0; i <= 200; i++) {
    const s = i / 200, pose = poseAt165(topView, orbit, s, BASE_FOV, START_FOV)
    const pivot = topView.pivot.clone().lerp(orbit.pivot, s)
    const forward = new THREE.Vector3(0, 0, -1).applyQuaternion(pose.quaternion)
    assert(pose.position.clone().addScaledVector(forward, pose.distance).distanceTo(pivot) < 1e-6, `${test.name}: Blickpunkt bei s=${s}`)
    assert(pose.distance >= Math.min(topView.distanceBase, orbit.distance) - 1e-9, `${test.name}: Kamera zu nah bei s=${s}`)
    if (previous) assert(pose.fov >= previous.fov - 1e-12, `${test.name}: Blickwinkel nicht monoton`)
    previous = pose
  }
  console.log('PASS 165:', test.name, '- Rasterfehler', error.max.toExponential(1), 'px, Wandversatz am Rand', parallax.toFixed(2), 'px')
}
assert(typeof solveTopView165({ x: 0, y: 0, ax: 50, ay: 0, bx: 5, by: 45 }, rect([0, 0, 500, 400]), rect([0, 0, 500, 400]), new THREE.Matrix4(), 48) === 'string', 'verzerrtes SVG nicht abgelehnt')
assert(typeof solveTopView165({ x: 0, y: 0, ax: 50, ay: 0, bx: 0, by: -50 }, rect([0, 0, 500, 400]), rect([0, 0, 500, 400]), new THREE.Matrix4(), 48) === 'string', 'gespiegeltes SVG nicht abgelehnt')
assert(Math.abs(lensAt165(48, 2, 1).fov - 48) < 1e-12 && Math.abs(lensAt165(48, 2, 0).fov - 2) < 1e-12, 'Blickwinkel-Endwerte')

// ---- 3) Ursache und Wirkung mit echten OrbitControls ---------------------------------------
{
  const viewport = rect([330, 252, 1526, 735]), canvas = rect([330, 145, 1276, 850]), grid = new THREE.Matrix4()
  const bp = blueprint([7.5, 4], 60, viewport) // Blueprint 3 m neben der Hausmitte
  const topView = solveTopView165(bp, viewport, canvas, grid, BASE_FOV)
  const camera = new THREE.PerspectiveCamera(BASE_FOV, canvas.width / canvas.height, 0.05, 400)
  camera.position.set(15.3, 12.4, 14.8)
  const element = { style: {}, addEventListener() {}, removeEventListener() {}, clientHeight: canvas.height, clientWidth: canvas.width,
    getRootNode() { return { addEventListener() {}, removeEventListener() {} } },
    ownerDocument: { addEventListener() {}, removeEventListener() {} } }
  const controls = new OrbitControls(camera, element)
  controls.target.set(4.5, 1.3, 4); controls.enableDamping = true; controls.update()
  const orbit = { pivot: controls.target.clone(), quaternion: camera.quaternion.clone(), distance: camera.position.distanceTo(controls.target) }
  // Zustand vor 165: Kameraflug schreibt die Pose, danach laeuft controls.update() im selben Frame.
  applyPose(camera, topView, orbit, 0); controls.update(); camera.updateMatrixWorld(true)
  const before = gridErrorPx165(bp, viewport, canvas, grid, camera).max
  assert(before > 50, `Test unempfindlich: ungesperrte Controls erzeugen nur ${before} px`)
  // Zustand 165: Controls gesperrt wie in CameraFlight150.lock().
  const original = controls.update
  controls.enabled = false; controls.update = () => {}
  applyPose(camera, topView, orbit, 0); controls.update(); camera.updateMatrixWorld(true)
  const after = gridErrorPx165(bp, viewport, canvas, grid, camera).max
  assert(after < 1e-4, `gesperrte Controls: ${after} px`)
  // Flugende: Controls uebernehmen ohne Sprung.
  const end = applyPose(camera, topView, orbit, 1)
  const position = end.position.clone(), quaternion = camera.quaternion.clone()
  controls.update = original; controls.enabled = true; controls.update()
  assert(camera.position.distanceTo(position) < 1e-6 && camera.quaternion.angleTo(quaternion) < 1e-6, 'Sprung bei Uebergabe an die Controls')
  console.log(`PASS 165: OrbitControls ungesperrt ${before.toFixed(1)} px Versatz, gesperrt ${after.toExponential(1)} px, Uebergabe ohne Sprung`)
}


// ---- 4) 166: Rueckweg gespiegelt, Waende wachsen ------------------------------------------
{
  const growthSource = read('components/wallGrowth166.ts')
  const css = read('styles.css')
  assert(flight.includes('setGrowth166(pending.current ? 0 : 1)'), '166: 3D startet nicht mit Wandhoehe 0')
  assert(flight.includes('reverseTime166(active.from, tau)'), '166: Rueckweg ist nicht der gespiegelte Hinweg')
  assert(flight.includes('place(camera, active.top, active.orbit, t, grid)'), '166: Hinflug ohne Wandwachstum')
  assert(bridge.includes('export const EXIT_FLIGHT159=DURATION150/2') && bridge.includes('export const EXIT_FADE158=ENTER_FADE150/2'),
    '166: Rueckweg nicht doppelt so schnell')
  assert(css.includes('transition:opacity 375ms cubic-bezier(.75,0,.75,.9)'), '166: Rueckblende-CSS passt nicht zu EXIT_FADE158')
  assert(css.includes('transition:opacity 750ms ease'), '166: Hinblende-CSS veraendert')
  assert.equal((workspace.match(/<Growth166>/g) || []).length, 4, '166: Waende, Tueren, Treppen, Daecher der aktiven Ebene')
  assert.equal((workspace.match(/<Growth166 kind="level"/g) || []).length, 1, '166: weitere Etagen')
  for (const forbidden of ['<Growth166><FloorMesh', '<Growth166><FloorSlab149', '<Growth166><CanonicalGrid152'])
    assert(!workspace.includes(forbidden), '166: Boden/Raster duerfen nicht skaliert werden')
  const growthJs = ts.transpileModule(growthSource, { fileName: 'wallGrowth166.ts',
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText
  const growthScope = { exports: {} }
  new Function('require', 'module', 'exports', growthJs)(() => THREE, growthScope, growthScope.exports)
  const G = growthScope.exports
  // Zeitverlauf: Hinweg Kamera Ease-out, Hoehe Ease-in-out; Rueckweg exakt rueckwaerts.
  assert.equal(G.progress166(0).camera, 0); assert.equal(G.progress166(1).camera, 1)
  assert.equal(G.progress166(0).height, 0); assert.equal(G.progress166(1).height, 1)
  assert(Math.abs(G.progress166(0.5).height - 0.5) < 1e-12, 'Ease-in-out symmetrisch')
  for (const t0 of [1, 0.73, 0.2]) {
    let previous = Infinity
    for (let i = 0; i <= 100; i++) {
      const tau = i / 100, t = G.reverseTime166(t0, tau)
      assert(Math.abs(t - t0 * (1 - tau)) < 1e-12 && t <= previous + 1e-12, 'Rueckweg laeuft nicht rueckwaerts')
      previous = t
    }
    assert.equal(G.reverseTime166(t0, 0), t0); assert.equal(G.reverseTime166(t0, 1), 0)
  }
  // Ease-in auf dem Rueckweg: am Anfang langsam, an der Draufsicht schnell.
  const s = tau => G.progress166(G.reverseTime166(1, tau)).camera
  assert(1 - s(0.1) < 0.002 && s(0.9) - s(1) > 0.2, 'Rueckflug ist kein Ease-in')
  // Hoehengruppen
  const wall = new THREE.Group(), level = new THREE.Group()
  const material = new THREE.MeshStandardMaterial({ opacity: 1, transparent: false })
  level.add(new THREE.Mesh(new THREE.BoxGeometry(1, 1, 1), material))
  const offWall = G.registerGrowth166(wall, 'height'), offLevel = G.registerGrowth166(level, 'level')
  G.setGrowth166(0)
  assert.equal(wall.scale.y, G.MIN_GROWTH166); assert.equal(level.scale.y, G.MIN_GROWTH166)
  assert(G.MIN_GROWTH166 * 2.0 > 0.015, 'Waende bei Hoehe 0 liegen nicht ueber dem Boden (1,5 cm)')
  assert(!level.visible && material.transparent && material.opacity === 0 && material.depthWrite === false, 'weitere Etage nicht ausgeblendet')
  G.setGrowth166(0.5)
  assert(Math.abs(wall.scale.y - (G.MIN_GROWTH166 + (1 - G.MIN_GROWTH166) * 0.5)) < 1e-12)
  assert(level.visible && Math.abs(material.opacity - 0.5) < 1e-12)
  G.setGrowth166(1)
  assert.equal(wall.scale.y, 1); assert.equal(level.scale.y, 1)
  assert(level.visible && material.transparent === false && material.opacity === 1 && material.depthWrite === true, 'Material nicht wiederhergestellt')
  G.setGrowth166(0); offLevel()
  assert(material.transparent === false && material.opacity === 1, 'Material nach Abmelden nicht wiederhergestellt')
  offWall(); G.setGrowth166(1)
  console.log('PASS 166: Rueckweg = Hinweg rueckwaerts (1250 ms Ease-in, Blende 375 ms), Waende wachsen 1 % -> 100 %')
}
console.log('PASS 166: alle Pruefungen bestanden')
STROM168_TEST166
cat > "$RESOURCE_DIR/test168.mjs" <<'STROM168_TEST'
// Regression 168: Blueprint-Zoom. Statische Pruefung des gepatchten Quelltexts.
import fs from 'node:fs'
import path from 'node:path'
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'

const source = process.env.STROM168_SOURCE, modulesRaw = process.env.STROM168_MODULES
assert(source && modulesRaw, 'STROM168_SOURCE/STROM168_MODULES fehlen')
const require = createRequire(path.join(fs.realpathSync(modulesRaw), 'noop.js'))
const ts = require('typescript')
const app = fs.readFileSync(path.join(source, 'App.tsx'), 'utf8')
const css = fs.readFileSync(path.join(source, 'styles.css'), 'utf8')
const ast = ts.createSourceFile('App.tsx', app, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)
assert.equal(ast.parseDiagnostics.length, 0, 'App.tsx: Syntaxfehler')

const start = app.indexOf('function FloorplanEditor(')
const end = app.indexOf('function WallDetailEditor(')
assert(start > 0 && end > start, 'FloorplanEditor nicht gefunden')
const editor = app.slice(start, end)
assert(app.includes("import { flushSync } from 'react-dom'"), 'flushSync-Import fehlt')
assert(editor.includes("scroll.addEventListener('wheel', onWheel, passiveOff)") && editor.includes('{ passive: false }'),
  'Blueprint: nativer, nicht-passiver wheel-Listener fehlt')
assert(!/className="canvas-scroll" ref=\{canvasScrollRef\} onWheelCapture/.test(editor), 'Blueprint: React-onWheelCapture (passiv) noch aktiv')
assert(editor.includes('flushSync(() => setZoom(next))'), 'Zoom wird nicht synchron gezeichnet')
assert(editor.includes("Math.pow(2, -limited * (event.ctrlKey ? 0.01 : 0.002))"), 'Zoomfaktor nicht proportional zur Raddrehung')
assert(editor.includes('if (!frame) frame = window.requestAnimationFrame(run)'), 'Ereignisse werden nicht pro Bild gebuendelt')
assert(editor.includes("'gesturestart'") && editor.includes("'gesturechange'"), 'Safari-Pinch fehlt')
assert(editor.includes('flushViewportRef168.current() // letzte Ansicht'), 'Ansicht wird beim Verlassen nicht gespeichert')
assert(editor.includes('<CanvasRulers zoom={zoom} scrollRef={canvasScrollRef} syncRef={rulerSync168} />'), 'Lineale nicht entkoppelt')
assert(!/function handleCanvasScroll\(\) \{[^}]*setScrollPosition/.test(editor), 'Scroll baut den Editor weiter neu auf')
assert(editor.includes('zoomStep168(1.25)') && editor.includes('zoomStep168(1 / 1.25)'), 'Zoomknoepfe nicht multiplikativ')
assert(editor.includes('Mausrad und Zwei-Finger-Zoom zoomen am Mauszeiger'), 'Hilfetext nicht angepasst')
assert(app.includes("translate3d(${sheet.left - topBox.getBoundingClientRect().left}px, 0, 0)"), 'Lineal nicht an der Zeichnung ausgerichtet')
assert(css.includes('.canvas-ruler-track168 { position:absolute; inset:0; will-change:transform; }'), 'CSS Lineal-Spur fehlt')
assert(css.includes('.canvas-ruler-top, .canvas-ruler-left, .canvas-toolbox, .canvas-settings { backdrop-filter: none; }'), 'CSS Unschaerfe nicht entfernt')
// Wanddetail (klassisch) bleibt unveraendert.
const wall = app.slice(end)
assert(wall.includes('onWheelCapture={handleCanvasWheel}'), 'klassische Wandansicht unerwartet veraendert')
// Zoomformel: eine Raste (100 px) = 2^0,2 = +14,9 %; Hin und zurueck heben sich exakt auf.
const step = dy => Math.pow(2, -Math.max(-200, Math.min(200, dy)) * 0.002)
assert(Math.abs(step(-100) - 1.1487) < 1e-4 && Math.abs(step(-100) * step(100) - 1) < 1e-12, 'Zoomformel')
assert(Math.abs(step(-4) - 1.0056) < 1e-4, 'Trackpad: kleine Schritte')
console.log('PASS 168: Blueprint-Zoom am Mauszeiger, nicht-passiv, pro Bild gebuendelt, Lineale entkoppelt')
STROM168_TEST
cat > "$RESOURCE_DIR/STROM_UPDATE_168.md" <<'STROM168_DOC'
# Strom 168: Blueprint-Zoom wie in anderen Programmen

## Ursachen (bis 167)
- React meldet `wheel` passiv an. `preventDefault()` im Blueprint wirkte nicht: Der Browser
  scrollte bei jeder Raste zusaetzlich um ca. 100 px, das Programm korrigierte ein Bild spaeter.
  Der Punkt unter dem Mauszeiger sprang (gemessen 112 px je Raste, 700 px nach 5 Rasten).
- Jedes Rad-Ereignis zoomte fest um 12 %. Ein Trackpad schickt Dutzende kleine Ereignisse:
  40 kleine Wischbewegungen zoomten von 100 % auf das Maximum 1000 %.
- Zwei-Finger-Zoom (Pinch, ctrlKey) vergroesserte die ganze Webseite statt der Zeichnung.
- Zoom und Scroll wurden in getrennten Bildern gesetzt; jedes Scroll-Ereignis baute den
  kompletten Blueprint-Editor neu auf (nur fuer die Lineale) und schrieb in den localStorage.
- Das obere Lineal lag 15 px neben dem Raster (Scrollbalken-Abstand links nicht beruecksichtigt).
- Zoomknoepfe aenderten linear um 15 Prozentpunkte und zoomten um die linke obere Ecke.

## Aenderungen
- Nativer, nicht-passiver wheel-Listener am Zeichenbereich; Zoom am Mauszeiger.
- Zoom proportional zur Raddrehung: Faktor 2^(-deltaY * 0,002), eine Raste = +14,9 %;
  Pinch zehnfach empfindlicher; Safari-Pinch ueber gesture-Ereignisse.
- Seitliches Wischen bzw. Shift+Mausrad verschiebt waagerecht.
- Alle Ereignisse eines Bildes werden gesammelt; Zeichnung wird synchron (flushSync)
  aktualisiert und im selben Bild gescrollt. Rundungsfehler von scrollLeft/Top summieren sich nicht.
- Lineale verschieben sich per transform mit der Zeichnung, ohne Neuaufbau des Editors.
- Ansicht wird hoechstens alle 200 ms gespeichert, beim Verlassen (z. B. nach 3D) sofort.
- Zoomknoepfe: x1,25 bzw. /1,25 um die Bildmitte; 100 % ebenfalls um die Bildmitte.
- Keine Hintergrund-Unschaerfe mehr unter Linealen und Werkzeugleisten (bei jedem Bild neu berechnet).
- Zoom wird stufenlos gespeichert (4 statt 2 Nachkommastellen).
- Hilfetext korrigiert (stand vorher: "Mausrad scrollt, Shift+Mausrad zoomt").
- Klassische Wandansicht unveraendert.

Nur Testumgebung `/strom-test/`; Produktion `/strom/` unveraendert.
STROM168_DOC
log "3) Quelltext patchen (Blueprint-Zoom) ..."
python3 -m py_compile "$RESOURCE_DIR/patch168.py" >>"$DIAG_LOG" 2>&1 || fail "168 Python patch syntax error"
STROM168_ROOT="$WORK_DIR" python3 "$RESOURCE_DIR/patch168.py" >>"$DIAG_LOG" 2>&1 || \
  fail "168 Ausgangsstand passt nicht; GitHub and Stage unchanged"
log "4) Full TypeScript/Vite build BEFORE committing ..."
( cd "$WORK_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || \
  fail "168 TypeScript/Vite build failed; GitHub and Stage unchanged"
log "5) Regression: 165/166-Pruefungen und Blueprint-Zoom ..."
STROM166_SOURCE="$WORK_DIR/frontend/src" STROM166_MODULES="$DEPENDENCIES" \
  node "$RESOURCE_DIR/test166.mjs" >>"$DIAG_LOG" 2>&1 || \
  fail "168 Regression 165/166 fehlgeschlagen; GitHub and Stage unchanged"
STROM168_SOURCE="$WORK_DIR/frontend/src" STROM168_MODULES="$DEPENDENCIES" \
  node "$RESOURCE_DIR/test168.mjs" >>"$DIAG_LOG" 2>&1 || \
  fail "168 Regression Blueprint-Zoom fehlgeschlagen; GitHub and Stage unchanged"
grep -F -e 'PASS 166: alle' -e 'PASS 168' "$DIAG_LOG" | tail -n 2 || true
log "6) Bundle mit dem im Browser geprueften Bundle vergleichen ..."
check_bundle168 "$WORK_DIR/frontend/dist" "GitHub and Stage unchanged."
mkdir -p "$WORK_DIR/deploy/updates" "$WORK_DIR/docs"
cp -a "$RESOURCE_DIR/patch168.py" "$WORK_DIR/deploy/updates/${SCRIPT_NAME}_patch.py"
cp -a "$RESOURCE_DIR/STROM_UPDATE_168.md" "$WORK_DIR/docs/STROM_UPDATE_168.md"
rm -rf "$RESOURCE_DIR"
log "7) Synchronize verified source into Stage ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
  "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "168 Stage transfer failed; backup: $BACKUP_DIR"
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PASS PATCH_ONLY: no web deployment"
  exit 0
fi
log "8) Build Stage and deploy ONLY /strom-test/ ..."
( cd "$STAGE_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || \
  fail "168 Stage build failed; backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "168 frontend/dist missing"
check_bundle168 "$STAGE_DIR/frontend/dist" "Testseite unveraendert; Stage-Backup: $BACKUP_DIR."
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || \
  fail "168 test deployment failed; backup: $BACKUP_DIR"
log "SUCCESS: 168 deployed at https://home.moja.de/strom-test/"
log "Production /strom/ unchanged. Stage backup: $BACKUP_DIR"
