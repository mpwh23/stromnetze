#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261127-0550_173_ebenenmenue_fenster_verschiebbar"
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
COMMIT_MESSAGE="Update 173: one level menu for Blueprint and 3D (expanded by default); all floating panels draggable"
SELF_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
MODE="${1:-}"
# STROM173: Fingerabdruck des Bundles, das vor der Auslieferung im echten Browser geprueft wurde.
EXPECTED_BUNDLE173="3edb23654b2b92f934b7451832716bf43054d7e7fc4fcf6958f30c2fc9644ad6"
ALLOW_UNTESTED173="${STROM173_ALLOW_UNTESTED_BUNDLE:-0}"
if [ "${2:-}" = "allow-untested-bundle" ]; then ALLOW_UNTESTED173=1; fi
ALLOW_ARG173=""
if [ "$ALLOW_UNTESTED173" = "1" ]; then ALLOW_ARG173="allow-untested-bundle"; fi

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
  echo "2) Update 173 im isolierten Git-Checkout bauen, pruefen und nach GitHub pushen ..."
  ssh -t "${SSH_CONTROL_OPTS[@]}" "$REMOTE_HOST" "chmod +x '$REMOTE_TMP_SCRIPT' && '$REMOTE_TMP_SCRIPT' --git-phase $ALLOW_ARG173"

  echo ""
  echo "3) Git-Push erfolgreich. Update-Script jetzt nach ~/deploy kopieren ..."
  scp "${SSH_CONTROL_OPTS[@]}" "$SELF_PATH" "$REMOTE_HOST:$REMOTE_DEPLOY_SCRIPT"

  echo ""
  echo "4) Stage-Update auf dem Pi ausfuehren ..."
  ssh -t "${SSH_CONTROL_OPTS[@]}" "$REMOTE_HOST" "rm -f '$REMOTE_TMP_SCRIPT'; chmod +x '$REMOTE_DEPLOY_SCRIPT'; cd '$REMOTE_DEPLOY_DIR'; './$(basename "$SELF_PATH")' --stage-phase $ALLOW_ARG173"
  exit $?
fi

# -----------------------------------------------------------------------------
# Pi Git phase. Uses the already configured HomePi deploy key:
#   Host github-stromnetze -> /root/.ssh/.../github-stromnetze
# No Mac Git repository and no GitHub CLI are required.
# -----------------------------------------------------------------------------
if [ "$MODE" = "--git-phase" ]; then
  if [ "$(id -u)" -ne 0 ]; then
    exec sudo -H "$SELF_PATH" --git-phase-root $ALLOW_ARG173
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

  echo "1.3) Update 173 isoliert anwenden, TypeScript/Vite-Build, Tests und Bundle-Abgleich ..."
  PATCH_ONLY=1 \
    STAGE_DIR="$GIT_TMP" \
    PROD_DIR="$STAGE_DIR" \
    BACKUP_BASE=/tmp \
    "$SELF_PATH" --stage-phase $ALLOW_ARG173

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

# ----- 173: Hilfsfunktionen ----------------------------------------------------------------
dist_fingerprint173() {
  ( cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do sha256sum "$f"; done ) | sha256sum | cut -d' ' -f1
}
check_bundle173() {
  local have; have="$(dist_fingerprint173 "$1")"
  log "Bundle-Fingerabdruck: $have"
  if [ "$have" = "$EXPECTED_BUNDLE173" ]; then
    log "PASS: Bundle ist identisch mit dem im Browser geprueften Bundle."
  elif [ "$ALLOW_UNTESTED173" = "1" ]; then
    log "WARNUNG: Bundle weicht vom geprueften Bundle ab ($EXPECTED_BUNDLE173); ausdruecklich erlaubt."
  else
    ( cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do sha256sum "$f"; done ) >>"$DIAG_LOG" 2>&1 || true
    fail "173 Bundle weicht vom im Browser geprueften Bundle ab (erwartet $EXPECTED_BUNDLE173). $2 Bewusst trotzdem: STROM173_ALLOW_UNTESTED_BUNDLE=1 vor den Mac-Befehl setzen."
  fi
}

log "=== Update 173: Ebenenmenue einheitlich, Fenster verschiebbar ==="
log "Stage: $STAGE_DIR"
log "Diagnostics: $DIAG_LOG"
if grep -Fq 'STROM173_' "$STAGE_DIR/frontend/src/App.tsx" 2>/dev/null; then
  fail "173 ist bereits installiert; nichts veraendert"
fi
for file in frontend/src/App.tsx frontend/src/styles.css frontend/src/components/Building3DWorkspace.tsx frontend/src/components/StromIcon.tsx; do
  [ -s "$STAGE_DIR/$file" ] || fail "173 Ausgangsdatei fehlt: $file"
done
grep -Fq 'STROM172_OUTER_WALL_ADOPT' "$STAGE_DIR/frontend/src/App.tsx" || \
  fail "173 setzt den Stand 172 voraus (Aussenwand 172 fehlt); nichts veraendert"
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
  "$STAGE_DIR/" "$WORK_DIR/" >>"$DIAG_LOG" 2>&1 || fail "173 source copy failed"
DEPENDENCIES=""
for candidate in "$STAGE_DIR/frontend/node_modules" "$PROD_DIR/frontend/node_modules" /home/mpwh/strom_stage/frontend/node_modules; do
  if [ -f "$candidate/typescript/lib/typescript.js" ] && [ -d "$candidate/vite" ] && \
     [ -d "$candidate/three" ] && [ -d "$candidate/@react-three/fiber" ]; then
    DEPENDENCIES="$candidate";break
  fi
done
[ -n "$DEPENDENCIES" ] || fail "173 TypeScript/Vite/Three dependencies unavailable"
ln -s "$DEPENDENCIES" "$WORK_DIR/frontend/node_modules"
RESOURCE_DIR="$WORK_DIR/173_resources"
mkdir -p "$RESOURCE_DIR"
cat > "$RESOURCE_DIR/patch173.py" <<'STROM173_PATCH'
#!/usr/bin/env python3
"""Update 173: ein Ebenenmenue (Vorlage Blueprint) in Blueprint und 3D, standardmaessig offen;
alle schwebenden Fenster und Menues verschiebbar."""
import hashlib, os, pathlib

root = pathlib.Path(os.environ['STROM173_ROOT']) / 'frontend'
res = pathlib.Path(os.environ['STROM173_RESOURCES'])
F = {'app': root / 'src/App.tsx', 'css': root / 'src/styles.css', 'ws': root / 'src/components/Building3DWorkspace.tsx', 'icon': root / 'src/components/StromIcon.tsx'}
EXPECTED = {
    'icon': 'b206eff4f9bfb53f26d7b8634326f676263c80fd33e6bbf917bdf836cefe98b5',
    'app': '2a1206eeeef609effef4e53440dd9210e5c6f1b9a7235dafca8d65e1ec1cf6c7',
    'css': '5573f729e56042eb94740a58999f62556b902426fd552dd1a78fe1ae1dc00ed3',
    'ws': 'ba5a14ba3cb8bdb80c5a6ea1ff3afa8c62b7c699a8338b7147bed352caaf3b61',
}
for key, path in F.items():
    have = hashlib.sha256(path.read_bytes()).hexdigest()
    if have != EXPECTED[key]:
        raise RuntimeError(f'173: {path.name} entspricht nicht Stand 172 ({have})')
NEW = {
    'components/floatDrag173.ts': 'floatDrag173.ts',
    'components/LevelMenu173.tsx': 'LevelMenu173.tsx',
    'building/levelStore173.ts': 'levelStore173.ts',
}
for rel in NEW:
    if (root / 'src' / rel).exists():
        raise RuntimeError(f'173: {rel} existiert bereits')


def edit(text, label, old, new, count=1):
    have = text.count(old)
    if have != count:
        raise RuntimeError(f'173: Textstelle "{label}" {have}x gefunden (erwartet: {count})')
    return text.replace(old, new)


def replace_between(text, label, start, end, new):
    a = text.find(start)
    if a < 0 or text.count(start) != 1:
        raise RuntimeError(f'173: Anfang "{label}" nicht eindeutig')
    b = text.find(end, a)
    if b < 0:
        raise RuntimeError(f'173: Ende "{label}" fehlt')
    return text[:a] + new + text[b:]


# ------------------------------------------------------------------ App.tsx
app = F['app'].read_text(encoding='utf-8')
if 'STROM173_' in app:
    raise RuntimeError('173: bereits installiert')
app = edit(app, 'Import', "import StromIcon from './components/StromIcon'\n",
  "import StromIcon from './components/StromIcon'\n"
  "import LevelMenu173 from './components/LevelMenu173' // STROM173_LEVEL_MENU\n"
  "import { floatRef173 } from './components/floatDrag173' // STROM173_FLOAT_DRAG\n")

# Blueprint: Ebenenmenue -> gemeinsame Komponente, standardmaessig offen
app = edit(app, 'Blueprint: offen', "  const [layersOpen, setLayersOpen] = useState(false)\n"
  "  const [blueprintWallObjects, setBlueprintWallObjects]",
  "  const [layersOpen, setLayersOpen] = useState(true) // STROM173: Ebenenmenue standardmaessig offen\n"
  "  const [blueprintWallObjects, setBlueprintWallObjects]")
app = edit(app, 'Blueprint: offen nach Etagenwechsel',
  "    setLayerDeleteRequestId('')\n    setLayersOpen(false)\n",
  "    setLayerDeleteRequestId('')\n    setLayersOpen(true)\n")
app = replace_between(app, 'Blueprint-Ebenenmenue',
  "        <div className={`canvas-layer-menu ${layersOpen ? 'open' : ''}`} aria-label=\"Ebenen\">\n",
  "        {layerDeleteRequest && (\n",
  "        {/* STROM173_LEVEL_MENU: gemeinsames Ebenenmenue (auch in den 3D-Ansichten) */}\n"
  "        <LevelMenu173\n"
  "          floatId=\"blueprint-levels\"\n"
  "          levels={layers.map((layer) => ({ id: layer.id, name: layer.name, visible: layer.visible !== false, heightM: layer.heightM ?? floor.heightM, slabThicknessM: layer.slabThicknessM ?? 0 }))}\n"
  "          activeId={activeLayerId}\n"
  "          zeroId={resolveZeroLevel151(layers, zeroLevel151)}\n"
  "          radioName={`layer-zero151-${floor.id}`}\n"
  "          open={layersOpen}\n"
  "          onToggleOpen={() => setLayersOpen((current) => !current)}\n"
  "          rowState={(id) => { const state = effectiveLayerState(id); return { visible: state.visible, ghost: state.ghost } }}\n"
  "          onSelect={selectLayer}\n"
  "          onToggleVisible={toggleLayerVisibility}\n"
  "          onRename={renameLayer}\n"
  "          onHeight={setLayerHeightM}\n"
  "          onSlab={setLayerSlab149}\n"
  "          onZero={(id) => { writeZeroLevel151(floor.id, id, window.localStorage); setZeroLevel151(id) }}\n"
  "          onMove={moveLayerBefore}\n"
  "          onAdd={addLayer}\n"
  "          onDelete={requestDeleteActiveLayer}\n"
  "        />\n")

# 3D-Ansichten: Neuladen der Raeume nach dem Loeschen einer Ebene
app = edit(app, '3D: Raeume neu laden',
  "onBackToBlueprint={() => handleViewModeClick('floorplan')}\n",
  "onBackToBlueprint={() => handleViewModeClick('floorplan')}\n onReloadRooms173={reload}\n", 2)

# Klassische Wandansicht: Menue offen, beim Waehlen nicht schliessen, verschiebbar
app = edit(app, 'Wand: offen', "  const [layersOpen, setLayersOpen] = useState(false)\n", "  const [layersOpen, setLayersOpen] = useState(true) // STROM173\n")
app = edit(app, 'Wand: offen nach Wechsel',
  "    setRoomLayerAssignments(loadLayerAssignments(floor.id))\n    setLayersOpen(false)\n    setSelectedWall(null)\n",
  "    setRoomLayerAssignments(loadLayerAssignments(floor.id))\n    setLayersOpen(true)\n    setSelectedWall(null)\n")
app = edit(app, 'Wand: Auswahl schliesst nicht',
  "    onSelectRoom('')\n    setSelectedWall(null)\n    setLayersOpen(false)\n  }\n",
  "    onSelectRoom('')\n    setSelectedWall(null)\n  }\n")
app = edit(app, 'Wand: Menue verschiebbar',
  "        <div className={`canvas-layer-menu wall-layer-menu ${layersOpen ? 'open' : ''}`} aria-label=\"Ebenen\">\n",
  "        <div ref={floatRef173('wall-levels')} className={`canvas-layer-menu wall-layer-menu ${layersOpen ? 'open' : ''}`} aria-label=\"Ebenen\">\n"
  "          <span className=\"float-grip173\" title=\"Ebenenmenü verschieben (Doppelklick: zurück an den Standardplatz)\" aria-hidden=\"true\"><StromIcon name=\"drag-dots\" size={16} /></span>\n")

# Schwebende Fenster im Blueprint verschiebbar
FLOATS = [
 ('Aussenwand-Angebot', '<div className="strom-stair-direction-floating147 strom-stair-ask170 strom-outer-offer172" role="group"',
  '<div ref={floatRef173(\'blueprint-info\')} className="strom-stair-direction-floating147 strom-stair-ask170 strom-outer-offer172" role="group"'),
 ('Treppendurchgang', '<div className="strom-stair-direction-floating147 strom-stair-ask170 strom-stair-portal-panel171" role="group"',
  '<div ref={floatRef173(\'blueprint-info\')} className="strom-stair-direction-floating147 strom-stair-ask170 strom-stair-portal-panel171" role="group"'),
 ('Treppenrichtung', "<div className={`strom-stair-direction-floating147 ${selectedStairDirection147 ? '' : 'strom-stair-ask170'}`} role=\"group\"",
  "<div ref={floatRef173('blueprint-info')} className={`strom-stair-direction-floating147 ${selectedStairDirection147 ? '' : 'strom-stair-ask170'}`} role=\"group\""),
 ('Aussparung Hilfe', '<div className="canvas-settings recess-help">', '<div ref={floatRef173(\'blueprint-recess-help\')} className="canvas-settings recess-help">'),
 ('Tuer', '<div className="canvas-settings blueprint-door-settings136" aria-label="Tuerparameter">',
  '<div ref={floatRef173(\'blueprint-door\')} className="canvas-settings blueprint-door-settings136" aria-label="Tuerparameter">'),
 ('Dachschraege', '<div className="strom-roof-floating148">', '<div ref={floatRef173(\'blueprint-roof\')} className="strom-roof-floating148">'),
 ('Aussparung', '    <div className="recess-floating">\n', '    <div ref={floatRef173(\'blueprint-recess\')} className="recess-floating">\n'),
 ('Abstand', '    <div className="distance-floating-panel">\n', '    <div ref={floatRef173(\'blueprint-distance\')} className="distance-floating-panel">\n'),
 ('Rechteck', '      <div className="canvas-settings">\n        <label>Name<input value={rectInput.name}',
  '      <div ref={floatRef173(\'blueprint-draft\')} className="canvas-settings">\n        <label>Name<input value={rectInput.name}'),
 ('Polygon', '      <div className="canvas-settings">\n        <label>Name<input value={polygonName}',
  '      <div ref={floatRef173(\'blueprint-draft\')} className="canvas-settings">\n        <label>Name<input value={polygonName}'),
]
for label, old, new in FLOATS:
    app = edit(app, label, old, new)
F['app'].write_text(app, encoding='utf-8')

# ------------------------------------------------------------------ Building3DWorkspace.tsx
ws = F['ws'].read_text(encoding='utf-8')
ws = edit(ws, '3D: Importe', "import { getWallObjects, updateWallObject as updateWallObjectApi } from '../api'\n",
  "import { deleteRoom, getWallObjects, updateWallObject as updateWallObjectApi } from '../api'\n"
  "import LevelMenu173 from './LevelMenu173' // STROM173_LEVEL_MENU\n"
  "import { moveRawLayer173, patchRawLayer173, readRawLayers173, writeRawLayers173, LEVELS_CHANGED173 } from '../building/levelStore173'\n"
  "import { readZeroLevel151, writeZeroLevel151 } from '../building/coordinateReference151'\n")
ws = edit(ws, '3D: Prop', "onOpenLegacyWallDetail, onSelectWall, wallEditor, objectsRevision }: {\n",
  "onOpenLegacyWallDetail, onSelectWall, wallEditor, objectsRevision, onReloadRooms173 }: {\n"
  "  onReloadRooms173?: () => Promise<void>\n")
ws = edit(ws, '3D: offen', "  const [levelsOpen145, setLevelsOpen145] = useState(false)\n",
  "  const [levelsOpen145, setLevelsOpen145] = useState(true) // STROM173: Ebenenmenue standardmaessig offen\n"
  "  const [levelDelete173, setLevelDelete173] = useState('')\n")
ws = edit(ws, '3D: Ebenenliste',
  "  const levelOptions144 = useMemo(() => listBlueprintLevelOptions144(floor, window.localStorage), [floor, levelRevision])\n",
  "  const levelOptions144 = useMemo(() => listBlueprintLevelOptions144(floor, window.localStorage), [floor, levelRevision])\n"
  "  // STROM173_LEVEL_MENU: dieselbe Ebenenliste wie im Blueprint, inklusive Sichtbarkeit.\n"
  "  const layers173 = useMemo(() => readRawLayers173(floor), [floor, levelRevision])\n"
  "  const levelVisible173 = (id: string) => layers173.find((layer) => layer.id === id)?.visible !== false\n")
ws = edit(ws, '3D: weitere Etagen nach Sichtbarkeit',
  "    ? sceneLevels146.filter((entry146) => entry146.id !== activeLevel.id) : []\n",
  "    ? sceneLevels146.filter((entry146) => entry146.id !== activeLevel.id && levelVisible173(entry146.id)) : [] // STROM173: Auge im Ebenenmenue\n")
ws = edit(ws, '3D: Handler',
  "  const levelFloor = useMemo(() => active3DFloor(floor, activeLevel), [floor, activeLevel])\n",
  "  // STROM173_LEVEL_MENU: Bedienung wie im Blueprint, gespeichert in denselben Blueprint-Daten.\n"
  "  function levelRowState173(id: string) {\n"
  "    if (id === activeLevel.id) return { visible: true, ghost: false }\n"
  "    if (variant === 'house' && showAllLevels146 && levelVisible173(id)) return { visible: true, ghost: true }\n"
  "    return { visible: false, ghost: false }\n"
  "  }\n"
  "  function selectLevel173(id: string) {\n"
  "    if (!levelVisible173(id)) patchRawLayer173(floor, id, { visible: true })\n"
  "    chooseWallDetailLevel144(id)\n"
  "  }\n"
  "  function toggleLevel173(id: string) {\n"
  "    if (id === activeLevel.id) return\n"
  "    if (variant !== 'house') { selectLevel173(id); return }\n"
  "    if (!showAllLevels146) {\n"
  "      // Wie im Blueprint: Im Modus 'nur aktuelle Ebene' blendet das Auge die Ebene EIN.\n"
  "      if (!levelVisible173(id)) patchRawLayer173(floor, id, { visible: true })\n"
  "      setShowAllLevels146(true)\n"
  "      return\n"
  "    }\n"
  "    patchRawLayer173(floor, id, { visible: !levelVisible173(id) })\n"
  "  }\n"
  "  function addLevel173() {\n"
  "    const current = readRawLayers173(floor)\n"
  "    const active = current.find((layer) => layer.id === activeLevel.id)\n"
  "    const layer = { id: `layer-${Date.now()}`, name: `Ebene ${current.length + 1}`, visible: true, heightM: active?.heightM ?? floor.heightM, slabThicknessM: 0 }\n"
  "    window.localStorage.setItem(`strom.floorplan.layers.${floor.id}.visibilityMode`, JSON.stringify('active'))\n"
  "    writeRawLayers173(floor, [...current, layer])\n"
  "    chooseWallDetailLevel144(layer.id)\n"
  "  }\n"
  "  async function confirmDeleteLevel173() {\n"
  "    const id = levelDelete173\n"
  "    const current = readRawLayers173(floor)\n"
  "    setLevelDelete173('')\n"
  "    if (!id || current.length <= 1) return\n"
  "    let assignments: Record<string, string> = {}\n"
  "    try { assignments = JSON.parse(window.localStorage.getItem(`strom.floorplan.layers.${floor.id}.roomAssignments`) || '{}') || {} } catch { assignments = {} }\n"
  "    const targetRooms = rooms.filter((room) => (assignments[room.id] || 'layer-main') === id)\n"
  "    const remaining = current.filter((layer) => layer.id !== id)\n"
  "    const oldIndex = current.findIndex((layer) => layer.id === id)\n"
  "    const fallback = remaining[Math.max(0, Math.min(remaining.length - 1, oldIndex - 1))] ?? remaining[0]\n"
  "    try {\n"
  "      onCaptureUndo()\n"
  "      onSelectRoom('')\n"
  "      onSelectWall?.(null)\n"
  "      await Promise.all(targetRooms.map((room) => deleteRoom(room.id)))\n"
  "      const nextAssignments = { ...assignments }\n"
  "      for (const [roomId, layerId] of Object.entries(nextAssignments)) if (layerId === id) delete nextAssignments[roomId]\n"
  "      window.localStorage.setItem(`strom.floorplan.layers.${floor.id}.roomAssignments`, JSON.stringify(nextAssignments))\n"
  "      try {\n"
  "        const offsets = JSON.parse(window.localStorage.getItem(`strom.floorplan.titleOffsets.${floor.id}`) || '{}') || {}\n"
  "        targetRooms.forEach((room) => { delete offsets[room.id] })\n"
  "        window.localStorage.setItem(`strom.floorplan.titleOffsets.${floor.id}`, JSON.stringify(offsets))\n"
  "      } catch { /* Beschriftungsversatz ist optional */ }\n"
  "      window.localStorage.setItem(`strom.floorplan.layers.${floor.id}.active`, JSON.stringify(fallback.id))\n"
  "      writeRawLayers173(floor, remaining)\n"
  "      await onReloadRooms173?.()\n"
  "    } catch (error) {\n"
  "      setMessage(`Ebene konnte nicht geloescht werden: ${error instanceof Error ? error.message : String(error)}`)\n"
  "      await onReloadRooms173?.()\n"
  "    }\n"
  "  }\n"
  "  const levelDeleteLayer173 = layers173.find((layer) => layer.id === levelDelete173) ?? null\n"
  "  const levelDeleteCount173 = levelDeleteLayer173 ? (() => {\n"
  "    let assignments: Record<string, string> = {}\n"
  "    try { assignments = JSON.parse(window.localStorage.getItem(`strom.floorplan.layers.${floor.id}.roomAssignments`) || '{}') || {} } catch { assignments = {} }\n"
  "    return rooms.filter((room) => (assignments[room.id] || 'layer-main') === levelDeleteLayer173.id).length\n"
  "  })() : 0\n\n"
  "  const levelFloor = useMemo(() => active3DFloor(floor, activeLevel), [floor, activeLevel])\n")
ws = replace_between(ws, '3D-Ebenenmenue',
  "          {/* STROM145_FLOATING_LEVELS: reuse the Blueprint floating layer-menu classes. */}\n",
  "          <div className=\"building3d-help\">",
  "          {/* STROM173_LEVEL_MENU: dasselbe Ebenenmenue wie im Blueprint */}\n"
  "          <LevelMenu173\n"
  "            floatId={variant === 'wall' ? 'wall3d-levels' : 'house3d-levels'}\n"
  "            className=\"building3d-floating-levels145\"\n"
  "            levels={layers173.map((layer) => ({ id: layer.id, name: layer.name, visible: layer.visible !== false, heightM: layer.heightM ?? floor.heightM, slabThicknessM: layer.slabThicknessM ?? 0 }))}\n"
  "            activeId={activeLevel.id}\n"
  "            zeroId={readZeroLevel151(floor.id, layers173, window.localStorage)}\n"
  "            radioName={`layer-zero151-3d-${floor.id}`}\n"
  "            open={levelsOpen145}\n"
  "            onToggleOpen={() => setLevelsOpen145((value) => !value)}\n"
  "            rowState={levelRowState173}\n"
  "            eyeTitle={(id, visible) => id === activeLevel.id ? 'Aktive Ebene wird immer angezeigt'\n"
  "              : variant === 'wall' ? 'Wanddetail zeigt genau eine Ebene - klicken, um diese Ebene zu zeigen'\n"
  "              : visible ? 'Ebene eingeblendet - klicken zum Ausblenden' : 'Ebene ausgeblendet - klicken zum Einblenden'}\n"
  "            onSelect={selectLevel173}\n"
  "            onToggleVisible={toggleLevel173}\n"
  "            onRename={(id, name) => patchRawLayer173(floor, id, { name })}\n"
  "            onHeight={(id, millimetres) => { const heightM = Math.min(10, Math.max(0.1, Math.round(millimetres) / 1000)); if (Number.isFinite(millimetres) && heightM !== (layers173.find((layer) => layer.id === id)?.heightM ?? floor.heightM)) patchRawLayer173(floor, id, { heightM }) }}\n"
  "            onSlab={(id, millimetres) => { const slabThicknessM = Math.min(1.5, Math.max(0, Math.round(millimetres) / 1000)); if (Number.isFinite(millimetres) && slabThicknessM !== (layers173.find((layer) => layer.id === id)?.slabThicknessM ?? 0)) patchRawLayer173(floor, id, { slabThicknessM }) }}\n"
  "            onZero={(id) => { writeZeroLevel151(floor.id, id, window.localStorage); window.dispatchEvent(new Event(LEVELS_CHANGED173)) }}\n"
  "            onMove={(dragId, targetId) => moveRawLayer173(floor, dragId, targetId)}\n"
  "            onAdd={addLevel173}\n"
  "            onDelete={() => { if (layers173.length > 1) setLevelDelete173(activeLevel.id) }}\n"
  "          />\n"
  "          {levelDeleteLayer173 && (\n"
  "            <div className=\"modal-backdrop layer-delete-backdrop\" role=\"presentation\" onMouseDown={(event) => { if (event.target === event.currentTarget) setLevelDelete173('') }}>\n"
  "              <section className=\"confirm-modal layer-delete-modal\" role=\"dialog\" aria-modal=\"true\" aria-label=\"Ebene loeschen bestaetigen\">\n"
  "                <h2>Ebene loeschen?</h2>\n"
  "                <p>Die Ebene <strong>{levelDeleteLayer173.name}</strong> wird geloescht.</p>\n"
  "                {levelDeleteCount173 > 0 && <p className=\"warning-text\">Achtung: Dabei werden auch alle {levelDeleteCount173} Objekte auf dieser Ebene geloescht.</p>}\n"
  "                {levelDeleteCount173 === 0 && <p>Auf dieser Ebene befinden sich keine Objekte.</p>}\n"
  "                <div className=\"button-row\">\n"
  "                  <button type=\"button\" onClick={() => setLevelDelete173('')}>Abbrechen</button>\n"
  "                  <button type=\"button\" className=\"danger\" onClick={() => void confirmDeleteLevel173()}>Ja, Ebene loeschen</button>\n"
  "                </div>\n"
  "              </section>\n"
  "            </div>\n"
  "          )}\n\n          ")
F['ws'].write_text(ws, encoding='utf-8')

# ------------------------------------------------------------------ StromIcon: stabile Klickziele
icon = F['icon'].read_text(encoding='utf-8')
icon = edit(icon, 'Icon: Import', "import { iconAlias169, iconSet169 } from './iconSet169'\n",
  "import { memo } from 'react'\nimport { iconAlias169, iconSet169 } from './iconSet169'\n")
icon = edit(icon, 'Icon: memo', "export default function StromIcon(", "function StromIcon(")
icon = icon.rstrip('\n') + "\n\n// STROM173: Ohne erneutes Zeichnen bei unveraenderten Angaben. Vorher ersetzte jedes Neuzeichnen\n// der Elternkomponente die SVG-Pfade; ein Klick, waehrenddessen ging verloren.\nexport default memo(StromIcon)\n"
F['icon'].write_text(icon, encoding='utf-8')

# ------------------------------------------------------------------ CSS + neue Dateien
CSS = """
/* STROM173_LEVEL_MENU + STROM173_FLOAT_DRAG */
.level-menu173 { display: flex; align-items: center; gap: 6px; }
.canvas-layer-menu .float-grip173 {
  display: inline-flex; align-items: center; justify-content: center; flex: 0 0 auto;
  width: 26px; height: 32px; border-radius: 999px; color: #64748b; cursor: grab; pointer-events: auto !important;
  background: rgba(248,250,252,0.96); border: 1px solid rgba(148,163,184,0.46); box-shadow: 0 10px 22px rgba(15,23,42,0.10);
}
.canvas-layer-menu .float-grip173:hover { color: #1e3a8a; background: #eef4ff; }
.building3d-view .building3d-floating-levels145.level-menu173 { pointer-events: none; }
/* 3D: dieselbe Darstellung wie das Blueprint-Ebenenmenue (.floorplan-layout-Regeln uebernommen). */
.building3d-view .level-menu173 .layer-height-control { display: flex; flex-direction: column; align-items: stretch; gap: 2px; min-width: 0; font-size: 10px; font-weight: 600; color: #526581; }
.building3d-view .level-menu173 .layer-height-control input { width: 100%; min-width: 0; height: 25px; padding: 3px 4px; font-size: 12px; font-variant-numeric: tabular-nums; border: 1px solid #b6c7de; border-radius: 5px; background: white; color: #1f334b; }
.building3d-view .level-menu173 .layer-height-control input:focus { outline: 2px solid #60a5fa; }
.building3d-view .building3d-floating-levels145.level-menu173 .layer-menu-panel { width: auto; max-width: min(420px, 95vw); }
.building3d-floating-levels145.level-menu173 .layer-list { max-height: 260px; }
.building3d-view .building3d-floating-levels145.level-menu173 > button { max-width: 220px; }
[data-float173] { cursor: grab; }
[data-float173] :is(button, input, select, textarea, label, a) { cursor: auto; }
[data-float173] button { cursor: pointer; }
.floating-dragging173, .floating-dragging173 * { cursor: grabbing !important; user-select: none !important; }
/* STROM173: Icons sind nie selbst Klickziel; der Knopf darunter bleibt es auch beim Neuzeichnen. */
svg.strom-icon, svg.strom-icon * { pointer-events: none !important; }
"""
css = F['css'].read_text(encoding='utf-8')
F['css'].write_text(css.rstrip('\n') + '\n' + CSS, encoding='utf-8')
for rel, name in NEW.items():
    (root / 'src' / rel).write_text((res / name).read_text(encoding='utf-8'), encoding='utf-8')
print('173: Quelltext gepatcht')
STROM173_PATCH
cat > "$RESOURCE_DIR/floatDrag173.ts" <<'STROM173_DRAG'
/** STROM173_FLOAT_DRAG: alle schwebenden Fenster und Menues lassen sich verschieben.
 *
 * Ein Element meldet sich mit `ref={floatRef173('name')}` an. Gezogen wird an freien Flaechen
 * (Titel, Text, Hintergrund) oder am Griff `.float-grip173`; Knoepfe und Eingabefelder bleiben
 * normal bedienbar. Der Versatz wird per CSS `translate` gesetzt (unabhaengig von `transform`)
 * und je Fenster im Browser gespeichert. Doppelklick auf eine freie Flaeche setzt zurueck.
 */
type Offset173 = { x: number; y: number }
const STORE173 = 'strom.ui.floatOffsets173'
const NO_DRAG173 = 'button, input, select, textarea, a, label, option, summary, [contenteditable="true"], [draggable="true"], .no-float-drag173'
let offsets173: Record<string, Offset173> | null = null
const refs173 = new Map<string, (el: HTMLElement | null) => void>()
let installed173 = false

function load173(): Record<string, Offset173> {
  if (offsets173) return offsets173
  try {
    const value: unknown = JSON.parse(window.localStorage.getItem(STORE173) || '{}')
    offsets173 = {}
    if (value && typeof value === 'object' && !Array.isArray(value)) {
      for (const [id, raw] of Object.entries(value as Record<string, unknown>)) {
        const o = raw as Partial<Offset173> | null
        if (o && Number.isFinite(o.x) && Number.isFinite(o.y)) offsets173[id] = { x: Number(o.x), y: Number(o.y) }
      }
    }
  } catch { offsets173 = {} }
  return offsets173
}
function save173() { try { window.localStorage.setItem(STORE173, JSON.stringify(load173())) } catch { /* Speicher voll: nur fuer diese Sitzung */ } }
function apply173(el: HTMLElement, id: string) {
  const o = load173()[id]
  if (o && (o.x || o.y)) el.style.setProperty('translate', `${o.x}px ${o.y}px`)
  else el.style.removeProperty('translate')
}
const clamp173 = (v: number, lo: number, hi: number) => Math.min(Math.max(v, lo), Math.max(lo, hi))

/** Stabile Ref-Funktion je Fenster-ID. */
export function floatRef173(id: string): (el: HTMLElement | null) => void {
  let ref = refs173.get(id)
  if (!ref) {
    ref = (el: HTMLElement | null) => {
      if (!el) return
      el.dataset.float173 = id
      apply173(el, id)
      install173()
    }
    refs173.set(id, ref)
  }
  return ref
}

export function resetFloat173(id: string) {
  delete load173()[id]
  save173()
  document.querySelectorAll<HTMLElement>(`[data-float173="${CSS.escape(id)}"]`).forEach((el) => apply173(el, id))
}

function onPointerDown173(event: PointerEvent) {
  if (event.button !== 0) return
  const target = event.target as Element | null
  const el = target?.closest?.('[data-float173]') as HTMLElement | null
  if (!target || !el) return
  const grip = target.closest('.float-grip173')
  if (!grip && target.closest(NO_DRAG173)) return
  const id = el.dataset.float173 || ''
  const base = { ...(load173()[id] ?? { x: 0, y: 0 }) }
  const rect = el.getBoundingClientRect()
  const left0 = rect.left - base.x, top0 = rect.top - base.y
  const start = { x: event.clientX, y: event.clientY }
  let dragging = false
  const move = (e: PointerEvent) => {
    const dx = e.clientX - start.x, dy = e.clientY - start.y
    if (!dragging) {
      if (Math.hypot(dx, dy) < 4) return
      dragging = true
      document.documentElement.classList.add('floating-dragging173')
      window.getSelection()?.removeAllRanges()
    }
    e.preventDefault()
    // Mindestens 48 px des Fensters bleiben im sichtbaren Bereich.
    const x = clamp173(base.x + dx, 48 - rect.width - left0, window.innerWidth - 48 - left0)
    const y = clamp173(base.y + dy, -top0, window.innerHeight - 32 - top0)
    load173()[id] = { x: Math.round(x), y: Math.round(y) }
    apply173(el, id)
  }
  const up = () => {
    window.removeEventListener('pointermove', move, true)
    window.removeEventListener('pointerup', up, true)
    window.removeEventListener('pointercancel', up, true)
    if (!dragging) return
    document.documentElement.classList.remove('floating-dragging173')
    save173()
    // Der Klick nach dem Ziehen loest keine Aktion aus.
    const swallow = (e: MouseEvent) => { e.stopPropagation(); e.preventDefault() }
    window.addEventListener('click', swallow, { capture: true, once: true })
    window.setTimeout(() => window.removeEventListener('click', swallow, true), 0)
  }
  window.addEventListener('pointermove', move, true)
  window.addEventListener('pointerup', up, true)
  window.addEventListener('pointercancel', up, true)
  if (grip) event.preventDefault()
}

function onDoubleClick173(event: MouseEvent) {
  const target = event.target as Element | null
  const el = target?.closest?.('[data-float173]') as HTMLElement | null
  if (!target || !el || (!target.closest('.float-grip173') && target.closest(NO_DRAG173))) return
  const id = el.dataset.float173 || ''
  if (!load173()[id]) return
  delete load173()[id]
  save173()
  apply173(el, id)
}

function install173() {
  if (installed173 || typeof document === 'undefined') return
  installed173 = true
  document.addEventListener('pointerdown', onPointerDown173, true)
  document.addEventListener('dblclick', onDoubleClick173, true)
}
STROM173_DRAG
cat > "$RESOURCE_DIR/LevelMenu173.tsx" <<'STROM173_MENU'
import { useState, type ReactNode } from 'react'
import StromIcon from './StromIcon'
import { floatRef173 } from './floatDrag173'

/** STROM173_LEVEL_MENU: ein Ebenenmenue fuer Blueprint und 3D-Ansichten (Vorlage: Blueprint). */
export type LevelMenuLevel173 = { id: string; name: string; visible: boolean; heightM: number; slabThicknessM: number }
export type LevelRowState173 = { visible: boolean; ghost: boolean }

type LevelMenuProps173 = {
  floatId: string
  className?: string
  levels: LevelMenuLevel173[]
  activeId: string
  zeroId: string
  radioName: string
  open: boolean
  onToggleOpen: () => void
  rowState: (id: string) => LevelRowState173
  eyeTitle?: (id: string, visible: boolean) => string
  onSelect: (id: string) => void
  onToggleVisible: (id: string) => void
  onRename: (id: string, name: string) => void
  onHeight: (id: string, millimetres: number) => void
  onSlab: (id: string, millimetres: number) => void
  onZero: (id: string) => void
  onMove: (dragId: string, targetId: string) => void
  onAdd: () => void
  onDelete: () => void
  note?: ReactNode
}

const mm173 = (m: number) => Math.round(m * 1000)

export default function LevelMenu173(props: LevelMenuProps173) {
  const { floatId, className = '', levels, activeId, zeroId, radioName, open, rowState } = props
  const [dragged, setDragged] = useState('')
  const active = levels.find((level) => level.id === activeId) ?? levels[0]
  const eyeTitle = props.eyeTitle ?? ((_id: string, visible: boolean) => visible
    ? 'Ebene aktuell sichtbar - klicken zum manuellen Ausblenden'
    : 'Ebene aktuell ausgeblendet - klicken zum manuellen Einblenden')
  return (
    <div ref={floatRef173(floatId)} className={`canvas-layer-menu level-menu173 ${className} ${open ? 'open' : ''}`.replace(/\s+/g, ' ').trim()} aria-label="Ebenen">
      <span className="float-grip173" title="Ebenenmenü verschieben (Doppelklick: zurück an den Standardplatz)" aria-hidden="true"><StromIcon name="drag-dots" size={16} /></span>
      <button type="button" title="Ebenen und Geschosshoehen bearbeiten" aria-expanded={open} onClick={props.onToggleOpen}>
        <StromIcon name="chevron-down" title="Ebenenmenue" /> {active ? `${active.name} · ${mm173(active.heightM)} mm` : 'Ebenen'}
      </button>
      {open && (
        <div className="layer-menu-panel">
          <div className="layer-zero-legend151" title="Die markierte Etage hat Z = 0 m; darüber positive, darunter negative Höhen.">
            <span>Nullhöhe</span><strong>Z = 0</strong>
          </div>
          <div className="layer-list">
            {levels.map((layer) => {
              const isActive = layer.id === activeId
              const state = rowState(layer.id)
              return (
                <div
                  key={layer.id}
                  data-level173={layer.id}
                  className={`layer-row ${isActive ? 'active' : ''} ${state.visible ? 'effectively-visible' : 'effectively-hidden'} ${state.ghost ? 'preview-visible' : ''}`}
                  draggable={false}
                  onClick={() => props.onSelect(layer.id)}
                  onDragOver={(event) => event.preventDefault()}
                  onDrop={(event) => { event.preventDefault(); props.onMove(dragged, layer.id); setDragged('') }}
                >
                  <label className="layer-zero-marker151" title={levels.length === 1 ? 'Einzige Ebene: automatisch Z=0' : 'Diese Ebene als Z=0 festlegen'}
                    onMouseDown={(event) => event.stopPropagation()} onClick={(event) => event.stopPropagation()}>
                    <input type="radio" name={radioName}
                      aria-label={`${layer.name} als Z=0-Ebene auswählen`}
                      checked={zeroId === layer.id}
                      disabled={levels.length === 1}
                      onChange={() => props.onZero(layer.id)} />
                    <span aria-hidden="true">0</span>
                  </label>
                  <button type="button" className={`layer-eye ${state.visible ? 'visible' : 'hidden'}`} title={eyeTitle(layer.id, state.visible)}
                    onClick={(event) => { event.stopPropagation(); props.onToggleVisible(layer.id) }}>
                    <StromIcon name={state.visible ? 'eye' : 'eye-off'} title={state.visible ? 'Ebene sichtbar' : 'Ebene ausgeblendet'} />
                  </button>
                  <input
                    aria-label="Ebenenname"
                    draggable={false}
                    value={layer.name}
                    onMouseDown={(event) => event.stopPropagation()}
                    onClick={(event) => event.stopPropagation()}
                    onDragStart={(event) => event.preventDefault()}
                    onFocus={() => { if (!isActive) props.onSelect(layer.id) }}
                    onChange={(event) => props.onRename(layer.id, event.target.value)}
                  />
                  <label className="layer-height-control" title="Geschosshoehe dieser Ebene in Millimetern">
                    <span>Höhe (mm)</span>
                    <input
                      key={`${layer.id}-${mm173(layer.heightM)}`}
                      aria-label={`Geschosshoehe ${layer.name} in Millimetern`}
                      type="number" min="100" max="10000" step="10"
                      defaultValue={mm173(layer.heightM)}
                      onMouseDown={(event) => event.stopPropagation()}
                      onClick={(event) => event.stopPropagation()}
                      onDragStart={(event) => event.preventDefault()}
                      onBlur={(event) => props.onHeight(layer.id, Number(event.currentTarget.value))}
                      onKeyDown={(event) => { if (event.key === 'Enter') event.currentTarget.blur() }}
                    />
                  </label>
                  <label className="layer-height-control layer-slab-control149" title="Bodendicke der Etage unterhalb des fertigen Fußbodens, in Millimetern">
                    <span>Bodendicke (mm)</span>
                    <input
                      key={`${layer.id}-slab-${mm173(layer.slabThicknessM)}`}
                      aria-label={`Bodendicke ${layer.name} in Millimetern`}
                      type="number" min="0" max="1500" step="10"
                      defaultValue={mm173(layer.slabThicknessM)}
                      onMouseDown={(event) => event.stopPropagation()}
                      onClick={(event) => event.stopPropagation()}
                      onDragStart={(event) => event.preventDefault()}
                      onBlur={(event) => props.onSlab(layer.id, Number(event.currentTarget.value))}
                      onKeyDown={(event) => { if (event.key === 'Enter') event.currentTarget.blur() }}
                    />
                  </label>
                  <button
                    type="button"
                    className="layer-grip"
                    title="Ebene verschieben"
                    draggable
                    onClick={(event) => event.stopPropagation()}
                    onDragStart={(event) => { event.dataTransfer.effectAllowed = 'move'; setDragged(layer.id) }}
                    onDragEnd={() => setDragged('')}
                    onMouseDown={(event) => event.stopPropagation()}
                  ><StromIcon name="drag-dots" title="Ebene verschieben" /></button>
                </div>
              )
            })}
          </div>
          <div className="layer-menu-actions" aria-label="Ebenenaktionen">
            <button type="button" className="layer-add round-icon" title="Neue Ebene" aria-label="Neue Ebene" onClick={props.onAdd}><StromIcon name="new-object" title="Neue Ebene" /></button>
            <button type="button" className="layer-delete round-icon" title="Ausgewaehlte Ebene loeschen" aria-label="Ausgewaehlte Ebene loeschen" disabled={levels.length <= 1} onClick={props.onDelete}><StromIcon name="trash" title="Ebene loeschen" /></button>
          </div>
          {props.note}
        </div>
      )}
    </div>
  )
}
STROM173_MENU
cat > "$RESOURCE_DIR/levelStore173.ts" <<'STROM173_STORE'
import type { Floor } from '../types'

/** STROM173_LEVEL_MENU: Ebenenliste wie im Blueprint lesen/schreiben (3D-Ansichten). */
export type RawLayer173 = { id: string; name: string; visible: boolean; heightM?: number; slabThicknessM?: number }
export const layersKey173 = (floorId: string) => `strom.floorplan.layers.${floorId}.list`
export const LEVELS_CHANGED173 = 'strom:blueprint-levels-changed'

export function readRawLayers173(floor: Floor, storage: Pick<Storage, 'getItem'> = window.localStorage): RawLayer173[] {
  const result: RawLayer173[] = []
  try {
    const raw: unknown = JSON.parse(storage.getItem(layersKey173(floor.id)) || '[]')
    if (Array.isArray(raw)) for (const [index, item] of raw.entries()) {
      if (!item || typeof item !== 'object') continue
      const e = item as Record<string, unknown>
      if (typeof e.id !== 'string' || !e.id || result.some((l) => l.id === e.id)) continue
      const h = Number(e.heightM), s = Number(e.slabThicknessM)
      result.push({
        ...(e as object),
        id: e.id,
        name: typeof e.name === 'string' && e.name.trim() ? e.name : `Ebene ${index + 1}`,
        visible: e.visible !== false,
        heightM: Number.isFinite(h) && h >= 0.1 && h <= 10 ? h : undefined,
        slabThicknessM: Number.isFinite(s) && s >= 0 ? s : undefined,
      })
    }
  } catch { /* unlesbar: Standardebene */ }
  return result.length ? result : [{ id: 'layer-main', name: 'Ebene 1', visible: true }]
}

export function writeRawLayers173(floor: Floor, layers: RawLayer173[]) {
  window.localStorage.setItem(layersKey173(floor.id), JSON.stringify(layers))
  window.dispatchEvent(new Event(LEVELS_CHANGED173))
}

export function patchRawLayer173(floor: Floor, id: string, patch: Partial<RawLayer173>) {
  writeRawLayers173(floor, readRawLayers173(floor).map((layer) => layer.id === id ? { ...layer, ...patch } : layer))
}

export function moveRawLayer173(floor: Floor, dragId: string, targetId: string) {
  if (!dragId || dragId === targetId) return
  const current = readRawLayers173(floor)
  const moving = current.find((layer) => layer.id === dragId)
  if (!moving) return
  const without = current.filter((layer) => layer.id !== dragId)
  const targetIndex = without.findIndex((layer) => layer.id === targetId)
  if (targetIndex < 0) return
  without.splice(targetIndex, 0, moving)
  writeRawLayers173(floor, without)
}
STROM173_STORE
cat > "$RESOURCE_DIR/test166.mjs" <<'STROM173_TEST166'
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
STROM173_TEST166
cat > "$RESOURCE_DIR/test168.mjs" <<'STROM173_TEST168'
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
STROM173_TEST168
cat > "$RESOURCE_DIR/test169.mjs" <<'STROM173_TEST169'
// Regression 169: einheitlicher Iconsatz. Prueft den gepatchten Quelltext statisch.
import fs from 'node:fs'
import path from 'node:path'
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'

const source = process.env.STROM169_SOURCE, modulesRaw = process.env.STROM169_MODULES
assert(source && modulesRaw, 'STROM169_SOURCE/STROM169_MODULES fehlen')
const require = createRequire(path.join(fs.realpathSync(modulesRaw), 'noop.js'))
const ts = require('typescript')
const read = (rel) => fs.readFileSync(path.join(source, rel), 'utf8')

// 1) Iconsatz laden (TS -> JS) und Inhalte pruefen.
const setTs = read('components/iconSet169.ts')
const js = ts.transpileModule(setTs, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2020 } }).outputText
const { iconSet169, iconAlias169 } = await import('data:text/javascript;base64,' + Buffer.from(js).toString('base64'))
const names = Object.keys(iconSet169)
assert(names.length >= 60, `Iconsatz zu klein (${names.length})`)
const tones = new Set(['nav', 'create', 'edit', 'danger', 'view', 'layer', 'stair', 'object', 'power'])
for (const [name, [tone, body]] of Object.entries(iconSet169)) {
  assert(/^[a-z0-9-]+$/.test(name), `Iconname ungueltig: ${name}`)
  assert(tones.has(tone), `${name}: unbekannte Farbgruppe ${tone}`)
  assert(body.length > 10 && !/<script|on[a-z]+=|href=|style=|<svg/i.test(body), `${name}: unzulaessiger SVG-Inhalt`)
  // Tags ausgeglichen (nur selbstschliessende Formen oder Paare)
  const open = (body.match(/<(path|rect|circle|ellipse|line|polyline|polygon|g)\b[^>]*[^/]>/g) || []).length
  const close = (body.match(/<\/(path|rect|circle|ellipse|line|polyline|polygon|g)>/g) || []).length
  assert.equal(open, close, `${name}: SVG-Tags nicht ausgeglichen`)
  for (const cls of body.match(/class="([^"]+)"/g) || []) {
    for (const c of cls.slice(7, -1).split(/\s+/)) assert(['t', 'a', 'at', 'af', 'k', 'thin'].includes(c), `${name}: Klasse ${c}`)
  }
}
for (const [from, to] of Object.entries(iconAlias169)) assert(iconSet169[to], `Alias ${from} -> ${to} fehlt`)

// 2) Alle verwendeten Iconnamen muessen im Satz stehen (auch ueber Bedingungen/Hilfsfunktionen).
const files = ['App.tsx', 'components/Building3DWorkspace.tsx', 'components/RoofEditor148.tsx']
const used = new Map()
for (const rel of files) {
  const text = read(rel)
  const sf = ts.createSourceFile(rel, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)
  assert.equal(sf.parseDiagnostics.length, 0, `${rel}: Syntaxfehler`)
  const fns = new Map()
  const walkFns = (n) => { if (ts.isFunctionDeclaration(n) && n.name) fns.set(n.name.text, n); ts.forEachChild(n, walkFns) }
  walkFns(sf)
  const leaves = (e, out) => {
    if (!e) return
    if (ts.isParenthesizedExpression(e)) return leaves(e.expression, out)
    if (ts.isStringLiteral(e) || ts.isNoSubstitutionTemplateLiteral(e)) return out.push(e.text)
    if (ts.isConditionalExpression(e)) { leaves(e.whenTrue, out); return leaves(e.whenFalse, out) }
    if (ts.isIdentifier(e)) {
      let scope = e.parent
      while (scope && !ts.isFunctionLike(scope)) scope = scope.parent
      let found = false
      const look = (n) => { if (ts.isVariableDeclaration(n) && ts.isIdentifier(n.name) && n.name.text === e.text && n.initializer) { found = true; leaves(n.initializer, out) } ts.forEachChild(n, look) }
      if (scope) look(scope)
      if (!found) out.push('?param:' + e.text)
      return
    }
    if (ts.isCallExpression(e) && ts.isIdentifier(e.expression) && fns.has(e.expression.text)) {
      const look = (n) => { if (ts.isReturnStatement(n)) leaves(n.expression, out); ts.forEachChild(n, look) }
      return look(fns.get(e.expression.text))
    }
    out.push('?expr:' + e.getText())
  }
  const visit = (n) => {
    if ((ts.isJsxSelfClosingElement(n) || ts.isJsxOpeningElement(n))) {
      const tag = n.tagName.getText()
      assert(tag !== 'StromIcon150', `${rel}: StromIcon150 noch verwendet`)
      if (tag === 'StromIcon') {
        const attr = n.attributes.properties.find((p) => ts.isJsxAttribute(p) && p.name.getText() === 'name')
        assert(attr && attr.initializer, `${rel}: StromIcon ohne name`)
        const out = []
        if (ts.isStringLiteral(attr.initializer)) out.push(attr.initializer.text)
        else leaves(attr.initializer.expression, out)
        for (const v of out) used.set(v, (used.get(v) || 0) + 1)
      }
    }
    ts.forEachChild(n, visit)
  }
  visit(sf)
}
const unknown = [...used.keys()].filter((n) => !iconSet169[n])
assert.deepEqual(unknown, [], 'Unbekannte oder nicht aufloesbare Iconnamen: ' + unknown.join(', '))
assert(used.size >= 55, `zu wenige Icons verwendet (${used.size})`)

// 3) Keine Zeichen-/Emoji-Ersatzicons und kein zweiter Iconsatz mehr.
const app = read('App.tsx'), ws = read('components/Building3DWorkspace.tsx'), css = read('styles.css')
for (const [rel, text] of [['App.tsx', app], ['Building3DWorkspace.tsx', ws]]) {
  const m = text.match(/[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}▸▾◌✕↺↻]/u)
  assert(!m, `${rel}: Zeichen-Icon ${m && m[0]} noch vorhanden`)
}
assert(!fs.existsSync(path.join(source, '../public/strom-icons-v7.svg')), 'alte Sprite-Datei noch vorhanden')
assert(!/strom-icons-v7|<use\b/.test(app + ws + read('components/StromIcon.tsx')), 'Sprite-Verweis noch vorhanden')
assert(read('components/StromIcon150.tsx').includes("import StromIcon from './StromIcon'"), 'StromIcon150 leitet nicht weiter')
assert(css.includes('STROM169_ICONS') && css.includes('[data-tone="danger"]') && css.includes('--si-accent:currentColor'), 'Icon-CSS fehlt')
assert(ws.includes('aria-pressed={transparent}><StromIcon name="walls-transparent"'), 'Waende transparent: Zustand nicht angezeigt')
assert(app.includes('function stairLibraryIcon169('), 'Treppenbibliothek ohne Icons')
// 165/166/168 bleiben erhalten.
assert(app.includes('STROM168_WHEEL_ZOOM'), '168 fehlt')
console.log(`PASS 169: ${names.length} Icons, ${used.size} verschiedene im Einsatz, alle aufloesbar, keine Zeichen-Icons, Sprite entfernt`)
STROM173_TEST169
cat > "$RESOURCE_DIR/test170.mjs" <<'STROM173_TEST170'
// Regression 170: Treppenrichtung und Raum loeschen. Statische Pruefung des gepatchten Quelltexts.
import fs from 'node:fs'
import path from 'node:path'
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'

const source = process.env.STROM170_SOURCE, modulesRaw = process.env.STROM170_MODULES
assert(source && modulesRaw, 'STROM170_SOURCE/STROM170_MODULES fehlen')
const require = createRequire(path.join(fs.realpathSync(modulesRaw), 'noop.js'))
const ts = require('typescript')
const app = fs.readFileSync(path.join(source, 'App.tsx'), 'utf8')
const css = fs.readFileSync(path.join(source, 'styles.css'), 'utf8')
const sf = ts.createSourceFile('App.tsx', app, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)
assert.equal(sf.parseDiagnostics.length, 0, 'App.tsx: Syntaxfehler')
const fn = (name) => { const s = app.indexOf(`function ${name}(`); assert(s > 0, name + ' fehlt'); return app.slice(s, app.indexOf('\n  }\n', s) + 4) }

// Treppenrichtung
const choose = fn('chooseStairDirection147')
assert(choose.includes('if (other) { onSelectRoom(other.id); return }'), 'Richtung anklicken zeigt den Treppenraum nicht')
assert(choose.includes('if (currentDirection && currentDirection !== direction) return'), 'nicht angelegte Gegenrichtung aendert die Richtung')
const create = fn('createOtherStair147')
assert(create.includes('stairCreating170.current = true') && create.includes('finally { stairCreating170.current = false'), 'Gegenrichtung nicht gegen Doppelklick geschuetzt')
assert(create.includes('onSelectRoom(selectedRoom.id)') && !create.includes('onSelectRoom(created.id)'), 'Auswahl springt nach dem Anlegen')
assert(app.includes("disabled={stairMissing170('up')}") && app.includes("disabled={stairMissing170('down')}"), 'Gegenrichtung nicht ausgegraut')
assert(app.includes('Neue Treppe · Richtung wählen') && app.includes('strom-stair-ask170'), 'Richtungsabfrage fehlt')
assert(/stairRoomsHere147\.length === 1 && \(\s*<div className="strom-stair-create-row170">/.test(app), 'Gegenrichtung-Knopf nicht an eine einzelne Richtung gebunden')
assert(app.includes("if (event.key === 'Delete' && !stairPanelOpen && (selectedRoom || allSelected))"), 'Entf im Treppeneditor loescht den Raum')
// Raum loeschen
const confirm = fn('confirmDeleteSelectedRoom')
const iWall = confirm.indexOf('await deleteWallObjectsOfRoom170(roomId, target.floorId)'), iRoom = confirm.indexOf('await deleteRoom(roomId)')
assert(iWall > 0 && iRoom > iWall, 'Wandobjekte werden nicht vor dem Raum entfernt')
assert(confirm.includes('setDeleteError170(message)') && confirm.includes('setDeleteBusy170(false)'), 'Fehler/Fortschritt im Fenster fehlt')
assert(fn('deleteWallObjectsOfRoom170').includes('entry.roomId === roomId'), 'nur Wandobjekte dieses Raums loeschen')
assert(app.includes('busy={deleteBusy170}') && app.includes('error={deleteError170}'), 'Fenster bekommt Zustand nicht')
assert(app.includes("{error && <p className=\"confirm-modal-error170\" role=\"alert\">"), 'Fehlertext im Fenster fehlt')
assert(app.includes('roomType: room.roomType, // STROM170'), 'Rueckgaengig verliert den Raumtyp')
assert(css.includes('.strom-stair-direction-actions147 button.strom-stair-missing170') && css.includes('.confirm-modal-delete170 .confirm-modal-confirm170'), 'CSS 170 fehlt')
// Vorstufen bleiben
assert(app.includes('STROM168_WHEEL_ZOOM') && fs.existsSync(path.join(source, 'components/iconSet169.ts')), '168/169 fehlen')
console.log('PASS 170: Treppenrichtung (Abfrage, ausgegraut, Gegenrichtung, Wechsel) und Raum loeschen (Wandobjekte zuerst, Fehler sichtbar)')
STROM173_TEST170
cat > "$RESOURCE_DIR/test171.mjs" <<'STROM173_TEST171'
// Regression 171: Treppendurchgang -> gekoppelter Treppenraum. Statische Pruefung + Logiktest.
import fs from 'node:fs'
import path from 'node:path'
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'

const source = process.env.STROM171_SOURCE, modulesRaw = process.env.STROM171_MODULES
assert(source && modulesRaw, 'STROM171_SOURCE/STROM171_MODULES fehlen')
const require = createRequire(path.join(fs.realpathSync(modulesRaw), 'noop.js'))
const ts = require('typescript')
const app = fs.readFileSync(path.join(source, 'App.tsx'), 'utf8')
const css = fs.readFileSync(path.join(source, 'styles.css'), 'utf8')
const sf = ts.createSourceFile('App.tsx', app, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)
assert.equal(sf.parseDiagnostics.length, 0, 'App.tsx: Syntaxfehler')

// Logik des Kopplungsmoduls
const modTs = fs.readFileSync(path.join(source, 'building/stairFlights171.ts'), 'utf8')
const js = ts.transpileModule(modTs, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2020 } }).outputText
const m = await import('data:text/javascript;base64,' + Buffer.from(js).toString('base64'))
const data = new Map([['strom.floorplan.layers.f1.stairFlights171', JSON.stringify({ d2: 'u1', x: 'x', bad: 5 })], ['other', '{"d2":"zz"}']])
const store = { get length() { return data.size }, key: (i) => [...data.keys()][i] ?? null, getItem: (k) => data.get(k) ?? null }
assert.equal(m.stairLayoutOwner171('d2', store), 'u1', 'gekoppelter Raum liest Eigentuemer')
assert.equal(m.stairLayoutOwner171('u1', store), 'u1', 'Eigentuemer liest sich selbst')
assert.equal(m.stairLayoutOwner171('x', store), 'x', 'Selbstverweis ignoriert')
assert.deepEqual(m.readStairFlights171('f1', store), { d2: 'u1' }, 'ungueltige Eintraege verworfen')
assert.equal(m.stairFlightPartner171({ d2: 'u1' }, 'u1'), 'd2')
assert.equal(m.stairFlightPartner171({ d2: 'u1' }, 'd2'), 'u1')
assert.equal(m.stairFlightPartner171({ d2: 'u1' }, 'q'), null)
assert.equal(m.baseStairName171('Treppe (abwärts)'), 'Treppe')
assert.equal(m.baseStairName171('Treppe (abwärts) (aufwärts)'), 'Treppe (abwärts)')

// Einbau in App.tsx
assert(app.includes('return `strom-stair-layout:${stairLayoutOwner171(roomId)}`'), 'Stufen nicht gemeinsam')
assert(app.includes('return `strom-stair-edge-assignments:${stairLayoutOwner171(roomId)}`'), 'Kanten nicht gemeinsam')
assert(app.includes("onClick={event=>{event.stopPropagation();setSelectedPortal171(room.id);onSelectRoom('');setTool('select')}}"), 'Durchgang nicht auswaehlbar')
assert(app.includes('function createCoupledStair171(source: Room)') && app.includes('const nextFlights: StairFlights171 = { ...stairFlights171, [created.id]: source.id }'), 'gekoppeltes Anlegen fehlt')
assert(app.includes("const here: StairDirection147 = stairDirections147[source.id] === 'down' ? 'up' : 'down'"), 'Richtung nicht gegenlaeufig')
assert(app.includes('.filter(({ room }) => { // STROM171'), 'Durchgang bleibt trotz Treppenraum sichtbar')
assert(app.includes('const gone = (id: string) => seen.has(id) && !ids.has(id)'), 'Kopplung wird zu frueh bereinigt')
assert(app.includes('const source = coupledChanged && !ownerChanged ? coupled : owner'), 'Grundriss nicht gekoppelt')
assert(app.includes('if (roomDrag || groupDrag || polygonEdgeDrag || vertexDrag || rectHandleDrag) return'), 'Abgleich waehrend des Ziehens')
assert(app.includes('{!stairPartnerId171 && <button type="button" className="strom-stair-swap170"'), 'gekoppelte Richtung tauschbar')
assert(app.includes('className="strom-stair-link171"'), 'Kopplung nicht angezeigt')
assert(app.includes('name: `${baseStairName171(selectedRoom.name)} ('), 'Name der Gegenrichtung doppelt')
assert(css.includes('.strom-stair-portal148.selected polygon') && css.includes('.strom-stair-link171'), 'CSS 171 fehlt')
assert(app.includes('STROM170_STAIR_DIRECTION') && app.includes('STROM168_WHEEL_ZOOM'), '168/170 fehlen')
console.log('PASS 171: Treppendurchgang auswaehlbar, gekoppelter Treppenraum (Stufen und Grundriss gemeinsam), Ergaenzung der Gegenrichtung')
STROM173_TEST171
cat > "$RESOURCE_DIR/test172.mjs" <<'STROM173_TEST172'
// Regression 172: Treppen im 3D je Etage; Aussenwand einer Nachbarebene uebernehmen. Statische Pruefung.
import fs from 'node:fs'
import path from 'node:path'
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'

const source = process.env.STROM172_SOURCE, modulesRaw = process.env.STROM172_MODULES
assert(source && modulesRaw, 'STROM172_SOURCE/STROM172_MODULES fehlen')
const require = createRequire(path.join(fs.realpathSync(modulesRaw), 'noop.js'))
const ts = require('typescript')
const read = (rel) => fs.readFileSync(path.join(source, rel), 'utf8')
const app = read('App.tsx'), ws = read('components/Building3DWorkspace.tsx'), css = read('styles.css')
for (const [name, text] of [['App.tsx', app], ['Building3DWorkspace.tsx', ws]]) {
  const sf = ts.createSourceFile(name, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)
  assert.equal(sf.parseDiagnostics.length, 0, name + ': Syntaxfehler')
}
// 3D: aktive Etage zeigt nur ihre Treppen
assert(ws.includes('const activeStairs146 = stairs.filter((surface146) => surface146.levelId === activeLevel.id)\n'), '3D: Treppen aller Etagen weiterhin sichtbar')
assert(ws.includes('stairs={activeStairs146}'), '3D: Szene nutzt gefilterte Treppen nicht')
assert(ws.includes('{entry146.stairs.map((surface146) => ('), '3D: weitere Etagen bringen ihre Treppen nicht mehr mit')
// Aussenwand uebernehmen
assert(app.includes('const outerWallsOf172 = (layerId: string) => rooms.filter((room) => isOuterWallRoom(room)'), 'Aussenwand-Erkennung fehlt')
assert(app.includes("if (index < 0 || outerWallsOf172(activeLayerId).length) return []"), 'Angebot trotz vorhandener Aussenwand')
assert(app.includes("relation: 'darunter'") && app.includes("relation: 'darüber'"), 'Nachbarebenen darunter/darueber fehlen')
assert(app.includes('async function adoptOuterWall172(') && app.includes('wallThicknessM: wall.wallThicknessM,') && app.includes('vertices: wall.vertices.map((point) => ({ ...point })),'), 'Kopie unvollstaendig')
assert(app.includes('for (const id of createdIds) next[id] = activeLayerId'), 'Kopie nicht der aktiven Ebene zugeordnet')
assert(app.includes('{outerOffer172 && (') && app.includes('className="strom-stair-direction-floating147 strom-stair-ask170 strom-outer-offer172"'), 'Angebotsfenster fehlt')
assert(app.includes("void chooseTool('outerwall')"), 'Selbst zeichnen fehlt')
assert(css.includes('.strom-outer-offer-outline172 polygon'), 'CSS 172 fehlt')
assert(app.includes('STROM171_STAIR_FLIGHT') && app.includes('STROM170_STAIR_DIRECTION'), '170/171 fehlen')
console.log('PASS 172: Treppen im 3D nur auf ihrer Etage; Aussenwand von Nachbarebene uebernehmen')
STROM173_TEST172
cat > "$RESOURCE_DIR/test173.mjs" <<'STROM173_TEST'
// Regression 173: ein Ebenenmenue (Blueprint/3D), standardmaessig offen; verschiebbare Fenster. Statische Pruefung.
import fs from 'node:fs'
import path from 'node:path'
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'

const source = process.env.STROM173_SOURCE, modulesRaw = process.env.STROM173_MODULES
assert(source && modulesRaw, 'STROM173_SOURCE/STROM173_MODULES fehlen')
const require = createRequire(path.join(fs.realpathSync(modulesRaw), 'noop.js'))
const ts = require('typescript')
const read = (rel) => fs.readFileSync(path.join(source, rel), 'utf8')
const files = { app: 'App.tsx', ws: 'components/Building3DWorkspace.tsx', menu: 'components/LevelMenu173.tsx', drag: 'components/floatDrag173.ts', store: 'building/levelStore173.ts', icon: 'components/StromIcon.tsx' }
const src = Object.fromEntries(Object.entries(files).map(([k, rel]) => {
  const text = read(rel)
  const sf = ts.createSourceFile(rel, text, ts.ScriptTarget.Latest, true, rel.endsWith('x') ? ts.ScriptKind.TSX : ts.ScriptKind.TS)
  assert.equal(sf.parseDiagnostics.length, 0, rel + ': Syntaxfehler')
  return [k, text]
}))
const css = read('styles.css')
// Ein Menue fuer beide
assert.equal((src.app.match(/<LevelMenu173\b/g) || []).length, 1, 'Blueprint nutzt das gemeinsame Menue nicht')
assert.equal((src.ws.match(/<LevelMenu173\b/g) || []).length, 1, '3D nutzt das gemeinsame Menue nicht')
assert(!src.app.includes("<div className={`canvas-layer-menu ${layersOpen ? 'open' : ''}`} aria-label=\"Ebenen\">"), 'altes Blueprint-Menue noch vorhanden')
assert(!src.ws.includes('building3d-floating-level-row145'), 'altes 3D-Menue noch vorhanden')
for (const part of ['layer-zero-marker151', 'layer-eye', 'aria-label="Ebenenname"', 'layer-height-control', 'layer-slab-control149', 'layer-grip', 'layer-add', 'layer-delete'])
  assert(src.menu.includes(part), 'Menue: ' + part + ' fehlt')
// standardmaessig offen
assert(src.app.includes('const [layersOpen, setLayersOpen] = useState(true) // STROM173: Ebenenmenue standardmaessig offen'), 'Blueprint-Menue nicht offen')
assert(src.ws.includes('const [levelsOpen145, setLevelsOpen145] = useState(true)'), '3D-Menue nicht offen')
assert(src.app.includes("const [layersOpen, setLayersOpen] = useState(true) // STROM173\n"), 'Wand-Menue nicht offen')
// 3D: gleiche Daten
for (const fn of ['patchRawLayer173(floor, id, { name })', 'moveRawLayer173(floor, dragId, targetId)', 'writeZeroLevel151(floor.id, id, window.localStorage)', 'async function confirmDeleteLevel173()', 'function addLevel173()'])
  assert(src.ws.includes(fn), '3D: ' + fn + ' fehlt')
assert(src.ws.includes('entry146.id !== activeLevel.id && levelVisible173(entry146.id)'), '3D: Auge wirkt nicht auf weitere Etagen')
// verschiebbar
const ids = [...(src.app + src.ws + src.menu).matchAll(/floatRef173\('([a-z0-9-]+)'\)/g)].map((m) => m[1])
for (const id of ['blueprint-info', 'blueprint-door', 'blueprint-roof', 'blueprint-recess', 'blueprint-distance', 'blueprint-draft', 'blueprint-recess-help', 'wall-levels'])
  assert(ids.includes(id), 'nicht verschiebbar: ' + id)
assert(src.menu.includes('ref={floatRef173(floatId)}') && src.ws.includes("floatId={variant === 'wall' ? 'wall3d-levels' : 'house3d-levels'}") && src.app.includes('floatId="blueprint-levels"'), 'Ebenenmenues nicht verschiebbar')
assert(src.drag.includes("el.style.setProperty('translate'") && src.drag.includes('NO_DRAG173') && src.drag.includes("addEventListener('dblclick'"), 'Verschiebe-Logik unvollstaendig')
assert(src.icon.includes('export default memo(StromIcon)') && css.includes('svg.strom-icon, svg.strom-icon * { pointer-events: none !important; }'), 'Icon-Klickziel nicht stabil')
assert(src.app.includes('STROM172_OUTER_WALL_ADOPT') && src.ws.includes('STROM172_STAIR_LEVELS'), '172 fehlt')
console.log('PASS 173: ein Ebenenmenue fuer Blueprint und 3D (offen), alle schwebenden Fenster verschiebbar')
STROM173_TEST
cat > "$RESOURCE_DIR/STROM_UPDATE_173.md" <<'STROM173_DOC'
# Strom 173: Ein Ebenenmenue, verschiebbare Fenster

## Ebenenmenue (Vorlage: Blueprint)
- Neue Komponente `components/LevelMenu173.tsx`, genutzt im Blueprint, in "3D Haus" und im Wanddetail-3D.
  Gleiche Darstellung und Bedienung: Z=0-Auswahl, Auge, Name, Geschosshoehe, Bodendicke, Reihenfolge per Griff,
  "Neue Ebene", "Ebene loeschen" (mit Rueckfrage, loescht die Objekte der Ebene).
- Die 3D-Ansichten schreiben in dieselben Blueprint-Daten (`building/levelStore173.ts`).
- Auge im 3D Haus: wie im Blueprint. Bei "Alle Etagen AUS" blendet das Auge einer anderen Ebene diese ein
  (Alle Etagen AN); danach blendet es sie aus/ein. Die aktive Ebene wird immer angezeigt.
  Im Wanddetail-3D zeigt das Auge genau diese Ebene (Wanddetail zeigt immer eine Ebene).
- Alle Ebenenmenues sind standardmaessig aufgeklappt (Blueprint, 3D Haus, Wanddetail-3D, klassische Wandansicht);
  die Ebenenwahl klappt das Menue nicht mehr zu.

## Verschiebbare Fenster (`components/floatDrag173.ts`)
- Verschiebbar: Ebenenmenues (Griff links neben dem Kopf), Treppen-/Durchgangs-/Aussenwand-Fenster, Tuer,
  Aussparung (Fenster und Hinweis), Abstand, Rechteck-/Polygon-Einstellungen, Dachschraege.
  Bereits vorher verschiebbar: Treppeneditor, Wandansicht-Fenster, Objektbibliothek.
- Ziehen an freien Flaechen oder am Griff; Knoepfe/Eingaben bleiben bedienbar; nach dem Ziehen loest der
  Klick nichts aus. Position je Fenster im Browser gespeichert; Doppelklick auf freie Flaeche/Griff: Standardplatz.
- Mindestens 48 px eines Fensters bleiben im sichtbaren Bereich.

## Nebenbefund behoben
- Icons (169) wurden bei jedem Neuzeichnen der Elternkomponente neu erzeugt; ein Klick genau in diesem Moment
  ging verloren (gemessen beim Knopf "Neue Ebene" nach einer Hoehenaenderung). `StromIcon` ist jetzt `memo`,
  und Icons sind nie selbst Klickziel (`pointer-events: none`), der Knopf darunter erhaelt den Klick.

Nur Testumgebung `/strom-test/`; Produktion `/strom/` und Backend unveraendert.
STROM173_DOC
log "3) Quelltext patchen (Ebenenmenue, verschiebbare Fenster) ..."
python3 -m py_compile "$RESOURCE_DIR/patch173.py" >>"$DIAG_LOG" 2>&1 || fail "173 Python patch syntax error"
STROM173_ROOT="$WORK_DIR" STROM173_RESOURCES="$RESOURCE_DIR" python3 "$RESOURCE_DIR/patch173.py" >>"$DIAG_LOG" 2>&1 || \
  fail "173 Ausgangsstand passt nicht; GitHub and Stage unchanged"
log "4) Full TypeScript/Vite build BEFORE committing ..."
( cd "$WORK_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || \
  fail "173 TypeScript/Vite build failed; GitHub and Stage unchanged"
log "5) Regression: 165/166, Zoom 168, Icons 169, Treppen 170/171, 3D-Treppen/Aussenwand 172, Ebenenmenue 173 ..."
STROM166_SOURCE="$WORK_DIR/frontend/src" STROM166_MODULES="$DEPENDENCIES" \
  node "$RESOURCE_DIR/test166.mjs" >>"$DIAG_LOG" 2>&1 || \
  fail "173 Regression 165/166 fehlgeschlagen; GitHub and Stage unchanged"
STROM168_SOURCE="$WORK_DIR/frontend/src" STROM168_MODULES="$DEPENDENCIES" \
  node "$RESOURCE_DIR/test168.mjs" >>"$DIAG_LOG" 2>&1 || \
  fail "173 Regression Blueprint-Zoom 168 fehlgeschlagen; GitHub and Stage unchanged"
STROM169_SOURCE="$WORK_DIR/frontend/src" STROM169_MODULES="$DEPENDENCIES" \
  node "$RESOURCE_DIR/test169.mjs" >>"$DIAG_LOG" 2>&1 || \
  fail "173 Regression Iconsatz 169 fehlgeschlagen; GitHub and Stage unchanged"
STROM170_SOURCE="$WORK_DIR/frontend/src" STROM170_MODULES="$DEPENDENCIES" \
  node "$RESOURCE_DIR/test170.mjs" >>"$DIAG_LOG" 2>&1 || \
  fail "173 Regression Treppenrichtung/Loeschen 170 fehlgeschlagen; GitHub and Stage unchanged"
STROM171_SOURCE="$WORK_DIR/frontend/src" STROM171_MODULES="$DEPENDENCIES" \
  node "$RESOURCE_DIR/test171.mjs" >>"$DIAG_LOG" 2>&1 || \
  fail "173 Regression Treppendurchgang 171 fehlgeschlagen; GitHub and Stage unchanged"
STROM172_SOURCE="$WORK_DIR/frontend/src" STROM172_MODULES="$DEPENDENCIES" \
  node "$RESOURCE_DIR/test172.mjs" >>"$DIAG_LOG" 2>&1 || \
  fail "173 Regression 3D-Treppen/Aussenwand 172 fehlgeschlagen; GitHub and Stage unchanged"
STROM173_SOURCE="$WORK_DIR/frontend/src" STROM173_MODULES="$DEPENDENCIES" \
  node "$RESOURCE_DIR/test173.mjs" >>"$DIAG_LOG" 2>&1 || \
  fail "173 Regression Ebenenmenue/Fenster fehlgeschlagen; GitHub and Stage unchanged"
grep -F -e 'PASS 166: alle' -e 'PASS 168' -e 'PASS 169' -e 'PASS 170' -e 'PASS 171' -e 'PASS 172' -e 'PASS 173' "$DIAG_LOG" | tail -n 7 || true
log "6) Bundle mit dem im Browser geprueften Bundle vergleichen ..."
check_bundle173 "$WORK_DIR/frontend/dist" "GitHub and Stage unchanged."
mkdir -p "$WORK_DIR/deploy/updates" "$WORK_DIR/docs"
cp -a "$RESOURCE_DIR/patch173.py" "$WORK_DIR/deploy/updates/${SCRIPT_NAME}_patch.py"
cp -a "$RESOURCE_DIR/STROM_UPDATE_173.md" "$WORK_DIR/docs/STROM_UPDATE_173.md"
rm -rf "$RESOURCE_DIR"
log "7) Synchronize verified source into Stage ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
  "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "173 Stage transfer failed; backup: $BACKUP_DIR"
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PASS PATCH_ONLY: no web deployment"
  exit 0
fi
log "8) Build Stage and deploy ONLY /strom-test/ ..."
( cd "$STAGE_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || \
  fail "173 Stage build failed; backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "173 frontend/dist missing"
check_bundle173 "$STAGE_DIR/frontend/dist" "Testseite unveraendert; Stage-Backup: $BACKUP_DIR."
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || \
  fail "173 test deployment failed; backup: $BACKUP_DIR"
log "SUCCESS: 173 deployed at https://home.moja.de/strom-test/"
log "Production /strom/ unchanged. Stage backup: $BACKUP_DIR"
