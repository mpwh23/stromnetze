#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261120-1025_166_rueckweg_gespiegelt_waende_wachsen"
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
COMMIT_MESSAGE="Update 166: mirrored return path at double speed, walls grow out of the Blueprint"
SELF_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
MODE="${1:-}"
# STROM166: Fingerabdruck des Bundles, das vor der Auslieferung im echten Browser geprueft wurde.
EXPECTED_BUNDLE166="d6a6f0b281e08a306092adebf13d41e7ba546f33b7999e4750ae5ec11a946041"
ALLOW_UNTESTED166="${STROM166_ALLOW_UNTESTED_BUNDLE:-0}"
if [ "${2:-}" = "allow-untested-bundle" ]; then ALLOW_UNTESTED166=1; fi
ALLOW_ARG166=""
if [ "$ALLOW_UNTESTED166" = "1" ]; then ALLOW_ARG166="allow-untested-bundle"; fi

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
  echo "2) Update 166 im isolierten Git-Checkout bauen, pruefen und nach GitHub pushen ..."
  ssh -t "${SSH_CONTROL_OPTS[@]}" "$REMOTE_HOST" "chmod +x '$REMOTE_TMP_SCRIPT' && '$REMOTE_TMP_SCRIPT' --git-phase $ALLOW_ARG166"

  echo ""
  echo "3) Git-Push erfolgreich. Update-Script jetzt nach ~/deploy kopieren ..."
  scp "${SSH_CONTROL_OPTS[@]}" "$SELF_PATH" "$REMOTE_HOST:$REMOTE_DEPLOY_SCRIPT"

  echo ""
  echo "4) Stage-Update auf dem Pi ausfuehren ..."
  ssh -t "${SSH_CONTROL_OPTS[@]}" "$REMOTE_HOST" "rm -f '$REMOTE_TMP_SCRIPT'; chmod +x '$REMOTE_DEPLOY_SCRIPT'; cd '$REMOTE_DEPLOY_DIR'; './$(basename "$SELF_PATH")' --stage-phase $ALLOW_ARG166"
  exit $?
fi

# -----------------------------------------------------------------------------
# Pi Git phase. Uses the already configured HomePi deploy key:
#   Host github-stromnetze -> /root/.ssh/.../github-stromnetze
# No Mac Git repository and no GitHub CLI are required.
# -----------------------------------------------------------------------------
if [ "$MODE" = "--git-phase" ]; then
  if [ "$(id -u)" -ne 0 ]; then
    exec sudo -H "$SELF_PATH" --git-phase-root $ALLOW_ARG166
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

  echo "1.3) Update 166 isoliert anwenden, TypeScript/Vite-Build, Tests und Bundle-Abgleich ..."
  PATCH_ONLY=1 \
    STAGE_DIR="$GIT_TMP" \
    PROD_DIR="$STAGE_DIR" \
    BACKUP_BASE=/tmp \
    "$SELF_PATH" --stage-phase $ALLOW_ARG166

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

# ----- 166: Hilfsfunktionen ----------------------------------------------------------------
dist_fingerprint166() {
  ( cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do sha256sum "$f"; done ) | sha256sum | cut -d' ' -f1
}
check_bundle166() {
  local have; have="$(dist_fingerprint166 "$1")"
  log "Bundle-Fingerabdruck: $have"
  if [ "$have" = "$EXPECTED_BUNDLE166" ]; then
    log "PASS: Bundle ist identisch mit dem im Browser geprueften Bundle."
  elif [ "$ALLOW_UNTESTED166" = "1" ]; then
    log "WARNUNG: Bundle weicht vom geprueften Bundle ab ($EXPECTED_BUNDLE166); ausdruecklich erlaubt."
  else
    ( cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do sha256sum "$f"; done ) >>"$DIAG_LOG" 2>&1 || true
    fail "166 Bundle weicht vom im Browser geprueften Bundle ab (erwartet $EXPECTED_BUNDLE166). $2 Bewusst trotzdem: STROM166_ALLOW_UNTESTED_BUNDLE=1 vor den Mac-Befehl setzen."
  fi
}

log "=== Update 166: Rueckweg gespiegelt, Waende wachsen aus dem Blueprint ==="
log "Stage: $STAGE_DIR"
log "Diagnostics: $DIAG_LOG"
for file in frontend/src/components/CameraFlight150.tsx frontend/src/components/cameraTransitions150.ts \
    frontend/src/components/Building3DWorkspace.tsx frontend/src/styles.css; do
  [ -s "$STAGE_DIR/$file" ] || fail "166 Ausgangsdatei fehlt: $file"
done
if [ -e "$STAGE_DIR/frontend/src/components/wallGrowth166.ts" ]; then
  fail "166 ist bereits installiert; nichts veraendert"
fi
grep -Fq 'STROM165_ONE_CAMERA_OWNER' "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx" || \
  fail "166 setzt den Stand 165 voraus (Marker STROM165_ONE_CAMERA_OWNER fehlt); nichts veraendert"
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
  "$STAGE_DIR/" "$WORK_DIR/" >>"$DIAG_LOG" 2>&1 || fail "166 source copy failed"
DEPENDENCIES=""
for candidate in "$STAGE_DIR/frontend/node_modules" "$PROD_DIR/frontend/node_modules" /home/mpwh/strom_stage/frontend/node_modules; do
  if [ -f "$candidate/typescript/lib/typescript.js" ] && [ -d "$candidate/vite" ] && \
     [ -d "$candidate/three" ] && [ -d "$candidate/@react-three/fiber" ]; then
    DEPENDENCIES="$candidate";break
  fi
done
[ -n "$DEPENDENCIES" ] || fail "166 TypeScript/Vite/Three dependencies unavailable"
ln -s "$DEPENDENCIES" "$WORK_DIR/frontend/node_modules"
RESOURCE_DIR="$WORK_DIR/166_resources"
mkdir -p "$RESOURCE_DIR"
cat > "$RESOURCE_DIR/patch166.py" <<'STROM166_PATCH'
#!/usr/bin/env python3
"""Patch 166: Rueckweg = Hinweg rueckwaerts (doppelt so schnell), Waende wachsen aus dem Blueprint.

Arbeitet nur auf einer isolierten Kopie. Jede Ausgangsdatei wird per SHA-256 mit dem Stand 165
verglichen; bei Abweichung wird nichts veraendert.
"""
from pathlib import Path
import hashlib, os, shutil

root = Path(os.environ['STROM166_ROOT'])
res = Path(os.environ['STROM166_RESOURCES'])
comp = root / 'frontend/src/components'

BASE = {
    'frontend/src/components/CameraFlight150.tsx': '4a3f37a338f6187b5e1a0c2f88c5c0231858b6efef58c6dc9502aa75ed5e8836',
    'frontend/src/components/cameraTransitions150.ts': '562f18eae527773c5f039fdd98398a82016e3151b5c19b4f433a348f4b7983fa',
    'frontend/src/components/Building3DWorkspace.tsx': '3555042faad2a7309c766d9127f17e390050f04623c32559790177d53db8df8e',
    'frontend/src/components/cameraTop165.ts': 'd7a454a3be8bf2bf6cd981f14a14afbced98090eacd727155e1236a6d1c31310',
    'frontend/src/styles.css': 'bbab9ffaf7da824021b1839571fc564ac0f9995ebca0e9bc66257495f3109d00',
    'frontend/src/App.tsx': '5fc12ced159f7d43e01e36c08b6fc02b4f5944448ffe0a0708bb4019dbfe51fe',
}


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f'166: Textstelle "{label}" {count}x gefunden (erwartet: 1)')
    return text.replace(old, new)


if (comp / 'wallGrowth166.ts').exists():
    raise RuntimeError('166 ist bereits installiert; nichts veraendert')
for name, want in BASE.items():
    path = root / name
    if not path.is_file():
        raise RuntimeError(f'166: Ausgangsdatei fehlt: {name}')
    have = digest(path)
    if have != want:
        raise RuntimeError(f'166: {name} entspricht nicht dem Stand 165 (sha256 {have[:12]}...). '
                           'Der Patch wurde gegen genau diesen Stand im Browser geprueft; nichts veraendert.')
for name in ('wallGrowth166.ts', 'cameraTransitions150.ts', 'CameraFlight150.tsx'):
    if not (res / name).is_file():
        raise RuntimeError(f'166: Ressource fehlt: {name}')

# 1) Kameratreiber, Zeiten, Wandhoehe -----------------------------------------------------
for name in ('wallGrowth166.ts', 'cameraTransitions150.ts', 'CameraFlight150.tsx'):
    shutil.copyfile(res / name, comp / name)

# 2) 3D-Szene: Waende, Tueren, Treppen und Daecher in Hoehengruppen -------------------------
path = comp / 'Building3DWorkspace.tsx'
text = path.read_text(encoding='utf-8')
text = once(text,
    "import type { ReactNode } from 'react'\n",
    "import type { ReactNode } from 'react'\n"
    "import { useLayoutEffect } from 'react'\n"
    "import { registerGrowth166, type GrowthKind166 } from './wallGrowth166'\n",
    'Imports')
text = once(text,
    "// STROM141_WALL_HOVER: same Blueprint wall edge for hover and click.\n",
    "/** STROM166_WALL_GROWTH: Hoehengruppe. Der Kameraflug setzt scale.y (0 = flach im Blueprint).\n"
    " * 'level' = ganze weitere Etage (Hoehe UND Lage relativ zu Z=0, beim Absenken ausgeblendet). */\n"
    "function Growth166({ kind = 'height', children }: { kind?: GrowthKind166; children: ReactNode }) {\n"
    "  const ref = useRef<THREE.Group>(null)\n"
    "  useLayoutEffect(() => (ref.current ? registerGrowth166(ref.current, kind) : undefined), [kind])\n"
    "  return <group ref={ref} name={kind === 'level' ? 'strom166-level-growth' : 'strom166-growth'}>{children}</group>\n"
    "}\n"
    "\n"
    "// STROM141_WALL_HOVER: same Blueprint wall edge for hover and click.\n",
    'Growth166')
text = once(text,
    "        {stairs.map((surface) => (\n"
    "          <StairSolid\n"
    "            key={surface.key}\n"
    "            surface={surface}\n"
    "            selected={surface.roomId === selectedRoomId}\n"
    "            onSelect={() => { onSelectRoom(surface.roomId); onSelectDoor(''); onSelectWall?.(null) }}\n"
    "          />\n"
    "        ))}\n",
    "        <Growth166>{stairs.map((surface) => (\n"
    "          <StairSolid\n"
    "            key={surface.key}\n"
    "            surface={surface}\n"
    "            selected={surface.roomId === selectedRoomId}\n"
    "            onSelect={() => { onSelectRoom(surface.roomId); onSelectDoor(''); onSelectWall?.(null) }}\n"
    "          />\n"
    "        ))}</Growth166>\n",
    'Treppen aktive Ebene')
text = once(text,
    "            <CameraFlight150 points={model.rooms.flatMap(room150 => room150.vertices)} /><SolidWallMeshes\n"
    "          model={model}\n"
    "          onSelectRoom={(id) => { onSelectRoom(id); onSelectDoor('') }}\n"
    "          onSelectWall={onSelectWall}\n"
    "          transparent={transparent}\n"
    "        /></RoofScope149.Provider>\n",
    "            <CameraFlight150 points={model.rooms.flatMap(room150 => room150.vertices)} /><Growth166><SolidWallMeshes\n"
    "          model={model}\n"
    "          onSelectRoom={(id) => { onSelectRoom(id); onSelectDoor('') }}\n"
    "          onSelectWall={onSelectWall}\n"
    "          transparent={transparent}\n"
    "        /></Growth166></RoofScope149.Provider>\n",
    'Waende aktive Ebene')
text = once(text,
    "        {model.walls.flatMap((wall) => wall.openings\n",
    "        <Growth166>{model.walls.flatMap((wall) => wall.openings\n",
    'Tueren aktive Ebene Anfang')
text = once(text,
    "                onSelectWall?.({ roomId: door.roomId, edgeIndex: door.edgeIndex })\n"
    "              }}\n"
    "            />\n"
    "          )))}\n",
    "                onSelectWall?.({ roomId: door.roomId, edgeIndex: door.edgeIndex })\n"
    "              }}\n"
    "            />\n"
    "          )))}</Growth166>\n",
    'Tueren aktive Ebene Ende')
text = once(text,
    "        <RoofMeshes148 floorId={model.floorId} levelId={activeLevelId148} rooms={model.rooms}\n"
    "          revision={roofRevision148} selectedId={selectedRoof148} onSelect={onSelectRoof148} />\n"
    "      </group>\n",
    "        <Growth166><RoofMeshes148 floorId={model.floorId} levelId={activeLevelId148} rooms={model.rooms}\n"
    "          revision={roofRevision148} selectedId={selectedRoof148} onSelect={onSelectRoof148} /></Growth166>\n"
    "      </group>\n",
    'Daecher aktive Ebene')
text = once(text,
    "      {showAllLevels146 && extraLevels146.map((entry146) => (\n"
    "        <group key={`floor-146-${entry146.id}`} position={[0, entry146.model.floorElevationM + entry146.offsetM, 0]}>\n",
    "      {showAllLevels146 && extraLevels146.map((entry146) => (\n"
    "        <Growth166 kind=\"level\" key={`floor-146-${entry146.id}`}><group position={[0, entry146.model.floorElevationM + entry146.offsetM, 0]}>\n",
    'Weitere Etagen Anfang')
text = once(text,
    "              <DoorHandle key={`${wall146.id}/${door146.id}`} door={door146} wall={wall146} selected={false} onSelect={() => undefined} />\n"
    "            )))}\n"
    "        </group>\n"
    "      ))}\n",
    "              <DoorHandle key={`${wall146.id}/${door146.id}`} door={door146} wall={wall146} selected={false} onSelect={() => undefined} />\n"
    "            )))}\n"
    "        </group></Growth166>\n"
    "      ))}\n",
    'Weitere Etagen Ende')
path.write_text(text, encoding='utf-8')

# 3) Rueckblende: halbe Dauer und zeitlich gespiegelte Kurve der Hinblende ----------------
# Hinblende: Deckkraft 1 - ease(t). Rueckwaerts abgespielt: 1 - ease(1 - t) = Bezier
# (1-0.25, 1-1, 1-0.25, 1-0.1) = cubic-bezier(.75,0,.75,.9).
path = root / 'frontend/src/styles.css'
text = path.read_text(encoding='utf-8')
text = once(text,
    ".workspace.strom158-exit-fading > .floorplan-layout {\n"
    "  opacity:1; transition:opacity 500ms ease;\n"
    "}\n",
    "/* STROM166_REVERSE_MIRROR: Hinblende (750ms ease) rueckwaerts, doppelt so schnell. */\n"
    ".workspace.strom158-exit-fading > .floorplan-layout {\n"
    "  opacity:1; transition:opacity 375ms cubic-bezier(.75,0,.75,.9);\n"
    "}\n",
    'Rueckblende CSS')
path.write_text(text, encoding='utf-8')
print('166: Quelltext gepatcht')
STROM166_PATCH
cat > "$RESOURCE_DIR/wallGrowth166.ts" <<'STROM166_GROWTH'
import type * as THREE from 'three'

/** STROM166_WALL_GROWTH
 * Gemeinsamer Zeitverlauf fuer Kameraflug und Wandhoehe beim Uebergang Blueprint <-> 3D.
 *
 * Hinweg  (t = 0 -> 1 in DURATION150):      Kamera easeOut(t), Wandhoehe easeInOut(t)
 * Rueckweg (genau rueckwaerts, doppelt so schnell): t = t0 * (1 - tau)
 *   -> Kamera laeuft mit Ease-in in die Draufsicht, die Waende sinken in den Blueprint.
 *
 * Waende, Tueren, Treppen und Daecher haengen in Gruppen, deren Hoehe (scale.y) hier gesetzt
 * wird. Boden, Deckenplatte, Raster und Kamera-Referenz bleiben unveraendert, damit die
 * Rasterdeckung aus 165 exakt bleibt und nichts in derselben Ebene flackert.
 */
export type GrowthKind166 = 'height' | 'level'
/** Kleinste Hoehe: 1 % (2,6 m -> 2,6 cm). Liegt knapp ueber dem Boden (1,5 cm), so dass die
 * Wandoberseiten in der Draufsicht voll sichtbar sind; bei 0 waere die Normalenmatrix singulaer. */
export const MIN_GROWTH166 = 0.01

type Entry166 = { object: THREE.Object3D; kind: GrowthKind166; faded: boolean }
const entries166 = new Set<Entry166>()
let growth166 = 1

export const easeOut166 = (t: number) => 1 - (1 - t) ** 3
export const easeInOut166 = (t: number) => (t < 0.5 ? 4 * t * t * t : 1 - (-2 * t + 2) ** 3 / 2)
const clamp01 = (t: number) => Math.min(1, Math.max(0, t))

/** Kamerafortschritt und Wandhoehe zum Zeitpunkt t des Hinwegs (0 = Draufsicht, 1 = 3D). */
export function progress166(t: number): { camera: number; height: number } {
  const k = clamp01(t)
  return { camera: easeOut166(k), height: easeInOut166(k) }
}
/** Zeitpunkt des Hinwegs, der auf dem Rueckweg nach tau (0..1) gezeigt wird. */
export function reverseTime166(t0: number, tau: number): number {
  return clamp01(t0) * (1 - clamp01(tau))
}

type Material166 = THREE.Material & { userData: { base166?: { opacity: number; transparent: boolean; depthWrite: boolean } } }
function materials166(object: THREE.Object3D): Material166[] {
  const mesh = object as THREE.Mesh
  const material = mesh.material as THREE.Material | THREE.Material[] | undefined
  if (!material) return []
  return (Array.isArray(material) ? material : [material]) as Material166[]
}
/** Weitere Etagen ("Alle Etagen") werden beim Absenken zusaetzlich ausgeblendet, damit die
 * Draufsicht am Ende genau die aktive Ebene des Blueprints zeigt. */
function fade166(entry: Entry166, alpha: number) {
  if (alpha >= 0.999) {
    if (!entry.faded) return
    entry.faded = false
    entry.object.visible = true
    entry.object.traverse(child => {
      for (const material of materials166(child)) {
        const base = material.userData.base166
        if (!base) continue
        if (material.transparent !== base.transparent) material.needsUpdate = true
        material.opacity = base.opacity
        material.transparent = base.transparent
        material.depthWrite = base.depthWrite
        delete material.userData.base166
      }
    })
    return
  }
  entry.faded = true
  entry.object.visible = alpha > 0.002
  entry.object.traverse(child => {
    for (const material of materials166(child)) {
      if (!material.userData.base166) {
        material.userData.base166 = { opacity: material.opacity, transparent: material.transparent, depthWrite: material.depthWrite }
      }
      if (!material.transparent) { material.transparent = true; material.needsUpdate = true }
      material.opacity = material.userData.base166.opacity * alpha
      material.depthWrite = false
    }
  })
}
function apply166(entry: Entry166) {
  const scale = growth166 >= 1 ? 1 : MIN_GROWTH166 + (1 - MIN_GROWTH166) * Math.max(0, growth166)
  if (entry.object.scale.y !== scale) {
    entry.object.scale.y = scale
    entry.object.updateMatrix()
    entry.object.updateMatrixWorld(true)
  }
  if (entry.kind === 'level') fade166(entry, growth166)
}

/** Wandhoehe 0 (flach im Blueprint) bis 1 (volle Hoehe). */
export function setGrowth166(value: number) {
  growth166 = Number.isFinite(value) ? clamp01(value) : 1
  for (const entry of entries166) apply166(entry)
}
export function currentGrowth166() { return growth166 }
export function registerGrowth166(object: THREE.Object3D, kind: GrowthKind166): () => void {
  const entry: Entry166 = { object, kind, faded: false }
  entries166.add(entry)
  apply166(entry)
  return () => {
    entries166.delete(entry)
    if (kind === 'level') fade166(entry, 1)
  }
}
STROM166_GROWTH
cat > "$RESOURCE_DIR/cameraTransitions150.ts" <<'STROM166_BRIDGE'
/** STROM150_CAMERA_BRIDGE: coordinate view navigation without delaying React rendering.
 * STROM165_ONE_CAMERA_OWNER: Messung des Blueprints an einer Stelle; alte Diagnosefenster entfernt. */
export type BlueprintScreen150o={x:number;y:number;ax:number;ay:number;bx:number;by:number}
export type BlueprintRect165={left:number;top:number;width:number;height:number}
export type BlueprintFrame150={floorId:string;levelId:string;cx:number;cy:number;widthM:number;heightM:number;screen150o?:BlueprintScreen150o;layout150o?:{left:number;top:number;width:number;height:number};viewport163?:BlueprintRect165}
export type BlueprintMeasure165={screen:BlueprintScreen150o;viewport:BlueprintRect165}
export type Mode150='wall'|'threeD'
export type Enter150={mode:Mode150;frame:BlueprintFrame150}
let pending150:Enter150|null=null
let current150:Enter150|null=null
let activeExit150:((done:()=>void)=>void)|null=null
let activeReady150:(()=>void)|null=null
let activeFailed165:((reason:string)=>void)|null=null
let exitPending150=false
let readySent150=false
// STROM159_TIMINGS: loading remains readiness-driven; milliseconds below.
export const ENTER_FADE150=750
export const DURATION150=2500
/** STROM166_REVERSE_MIRROR: der Rueckweg ist der Hinweg rueckwaerts, doppelt so schnell.
 * Erst Flug (Ease-in) in die Draufsicht, dann Blende zum Blueprint. */
export const EXIT_FLIGHT159=DURATION150/2
/** Rueckblende; die CSS-Dauer in styles.css (STROM166_REVERSE_MIRROR) muss gleich sein. */
export const EXIT_FADE158=ENTER_FADE150/2

function storedLevel150(floorId:string):string{
  try {
    const raw=window.localStorage.getItem(`strom.floorplan.layers.${floorId}.active`)
    const value:unknown=JSON.parse(raw||'null')
    return typeof value==='string'?value:''
  }catch{return ''}
}
function blueprintSvg165():SVGSVGElement|null{
  return document.querySelector('svg[aria-label="Blueprint Editor"]') as SVGSVGElement|null
}
/** STROM165_LIVE_BLUEPRINT: Bildschirmmatrix (CSS-Pixel je Meter) und tatsaechlich sichtbarer
 * Zeichenbereich des Blueprints, so wie er JETZT im Browser steht. Ohne Rollbalken.
 * SVG-Einheiten: mToX/Y(m) = 670 + 60*m. */
export function measureBlueprint165():BlueprintMeasure165|null{
  try {
    const svg=blueprintSvg165()
    const container=(svg?.closest('.canvas-scroll,.canvas-viewport,.canvas-scroll-area')||svg?.parentElement) as HTMLElement|null
    const matrix=svg?.getScreenCTM()
    const rect=container?.getBoundingClientRect()
    if(!svg||!container||!matrix||!rect||rect.width<=30||rect.height<=30)return null
    const pxX=60*Math.hypot(matrix.a,matrix.b)
    const pxY=60*Math.hypot(matrix.c,matrix.d)
    if(!(pxX>2&&pxY>2&&pxX<1000&&pxY<1000))return null
    const width=container.clientWidth>30?container.clientWidth:rect.width
    const height=container.clientHeight>30?container.clientHeight:rect.height
    return {
      screen:{
        x:670*(matrix.a+matrix.c)+matrix.e,
        y:670*(matrix.b+matrix.d)+matrix.f,
        ax:60*matrix.a,ay:60*matrix.b,
        bx:60*matrix.c,by:60*matrix.d,
      },
      viewport:{left:rect.left+container.clientLeft,top:rect.top+container.clientTop,width,height},
    }
  }catch{return null}
}
function viewFrame150(floorId:string):BlueprintFrame150{
  const result:BlueprintFrame150={floorId,levelId:storedLevel150(floorId),cx:0,cy:0,widthM:0,heightM:0}
  try {
    const measured=measureBlueprint165()
    const svg=blueprintSvg165()
    if(svg&&measured){
      // STROM163_BLUEPRINT_VIEWPORT_TRUTH / STROM150O_PRE_NAV_SNAPSHOT: one atomic capture at the click.
      result.viewport163=measured.viewport
      result.screen150o=measured.screen
      // Freeze the ORIGINAL Blueprint's layout in the overlay: no geometry changes
      // when FloorplanEditor becomes position:absolute during 3D mount.
      const plan=svg.closest('.floorplan-layout') as HTMLElement|null
      const host=plan?.parentElement
      const planRect=plan?.getBoundingClientRect()
      const hostRect=host?.getBoundingClientRect()
      if(plan&&planRect&&hostRect&&planRect.width>50&&planRect.height>50){
        result.layout150o={left:planRect.left-hostRect.left,top:planRect.top-hostRect.top,
          width:planRect.width,height:planRect.height}
        plan.style.setProperty('--strom150o-left',`${planRect.left-hostRect.left}px`)
        plan.style.setProperty('--strom150o-top',`${planRect.top-hostRect.top}px`)
        plan.style.setProperty('--strom150o-width',`${planRect.width}px`)
        plan.style.setProperty('--strom150o-height',`${planRect.height}px`)
        plan.classList.add('strom150o-viewport-frozen')
      }
      const s=measured.screen,v=measured.viewport
      const determinant=s.ax*s.by-s.ay*s.bx
      const pixelsPerMetre=Math.hypot(s.ax,s.ay)
      if(Math.abs(determinant)>1e-9&&pixelsPerMetre>1e-5){
        const dx=v.left+v.width/2-s.x,dy=v.top+v.height/2-s.y
        result.cx=(s.by*dx-s.bx*dy)/determinant
        result.cy=(-s.ay*dx+s.ax*dy)/determinant
        result.widthM=v.width/pixelsPerMetre
        result.heightM=v.height/pixelsPerMetre
      }
    }
  }catch{/* fallback to model-room geometry if no live SVG was found */}
  return result
}

export function queueEntry150(mode:Mode150,floorId:string){
  pending150={mode,frame:viewFrame150(floorId)}
  current150=pending150
  exitPending150=false
  readySent150=false
}
export function consumeEntry150():Enter150|null{
  const value=pending150
  pending150=null
  return value
}
export function restoreEntry150(value:Enter150){if(!pending150)pending150=value}
export function currentFrame150():BlueprintFrame150|null{return current150?.frame||null}
export function registerEnterReady150(handler:()=>void):()=>void{
  activeReady150=handler
  return ()=>{if(activeReady150===handler)activeReady150=null}
}
export function notifyEnterReady150(){
  if(readySent150)return
  readySent150=true
  try {activeReady150?.()} catch {/* UI fade is optional */}
}
/** STROM165_FAIL_FAST: die 3D-Ansicht meldet einen Abbruch sofort statt nach 30 s Wartezeit. */
export function registerEnterFailed165(handler:(reason:string)=>void):()=>void{
  activeFailed165=handler
  return ()=>{if(activeFailed165===handler)activeFailed165=null}
}
export function notifyEnterFailed165(reason:string){
  if(readySent150)return
  readySent150=true
  try {activeFailed165?.(reason)} catch {/* the 30 s guard in App remains as a second net */}
}
export function registerExit150(handler:(done:()=>void)=>void):()=>void{
  activeExit150=handler
  return ()=>{if(activeExit150===handler)activeExit150=null}
}
export function requestExit150(finish:()=>void):boolean{
  if(!activeExit150){pending150=null;current150=null;return false}
  if(exitPending150)return true
  exitPending150=true
  let completed=false
  const timeout=window.setTimeout(complete,EXIT_FLIGHT159+2000)
  function complete(){if(completed)return;completed=true;window.clearTimeout(timeout);exitPending150=false;finish()}
  try {activeExit150(complete)}catch{complete()}
  return true
}
STROM166_BRIDGE
cat > "$RESOURCE_DIR/CameraFlight150.tsx" <<'STROM166_FLIGHT'
import { useLayoutEffect, useRef } from 'react'
import { useFrame, useThree } from '@react-three/fiber'
import * as THREE from 'three'
import {
  consumeEntry150, restoreEntry150, currentFrame150, measureBlueprint165,
  registerExit150, notifyEnterReady150, notifyEnterFailed165,
  DURATION150, ENTER_FADE150, EXIT_FLIGHT159,
} from './cameraTransitions150'
import type { BlueprintMeasure165, Enter150 } from './cameraTransitions150'
import {
  solveTopView165, fallbackTopView165, poseAt165, gridErrorPx165, planToWorld165,
} from './cameraTop165'
import type { OrbitView165, Rect165, TopView165 } from './cameraTop165'
import { progress166, reverseTime166, setGrowth166 } from './wallGrowth166'

/** STROM165_ONE_CAMERA_OWNER
 * Einziger Kameratreiber fuer Blueprint -> 3D -> Blueprint.
 *
 * Hinweg:  settle  (3D baut sich verdeckt auf, Standardansicht wird gemerkt)
 *          prepare (Draufsicht aus dem LIVE-Blueprint berechnen, zeichnen, nachmessen)
 *          fade    (Draufsicht steht still, Blueprint blendet aus)
 *          flight  (Flug zur Standardansicht, Ease-out; Waende wachsen mit Ease-in-out)
 * Rueckweg: flight (genau der Hinflug rueckwaerts, doppelt so schnell: Kamera Ease-in,
 *                   Waende sinken in den Blueprint) -> hold (nachmessen, dann Blende)
 *
 * STROM166_REVERSE_MIRROR / STROM166_WALL_GROWTH: Kamera und Wandhoehe haengen an EINER
 * Zeitachse t (progress166). Der Rueckweg spielt t rueckwaerts ab (reverseTime166).
 *
 * Die OrbitControls sind im R3F-Store angemeldet (Building3DWorkspace) und werden hier
 * fuer die Dauer des Uebergangs wirklich gesperrt. Vor 165 fehlte die Anmeldung; die
 * Controls haben die Kamera deshalb in jedem Frame wieder auf die Hausmitte gedreht.
 */
type PlanPoint = { x: number; y: number }
type OrbitControl = { target?: THREE.Vector3; enabled?: boolean; update?: () => void }
type FrozenControl = { control: OrbitControl; update?: () => void; enabled?: boolean }
type Lens165 = { fov: number; near: number; far: number }
type OrbitState165 = OrbitView165 & { position: THREE.Vector3 }
type Check165 = { armed: boolean; measure: BlueprintMeasure165 | null; canvas: Rect165 | null; errorPx: number | null; key: string }
type Run165 = {
  kind: 'entry' | 'exit'
  phase: 'settle' | 'prepare' | 'fade' | 'flight' | 'hold' | 'done'
  top: TopView165 | null
  orbit: OrbitState165 | null
  /** Rueckweg: Zeitpunkt t des Hinwegs, an dem umgekehrt wird (1 = aus der fertigen 3D-Ansicht). */
  from: number
  startedAt: number
  frames: number
  steady: number
  verified: number
  previous: THREE.Matrix4 | null
  reason: string
  finish?: () => void
}

/** Blickwinkel waehrend der Blende. Fast parallel, damit auch Waende ueber dem Blueprint liegen. */
const START_FOV165 = 2
/** Zulaessige Abweichung zwischen Blueprint und gezeichnetem 3D-Raster in CSS-Pixeln. */
const TOLERANCE_PX165 = 1
const VERIFY_FRAMES165 = 2
const PREPARE_LIMIT165 = 240
const HOLD_LIMIT165 = 45
const GRID_NAME165 = 'strom152-blueprint-grid'
const STALE_KEYS165 = [
  'strom.camera150p.blueprintExtents', 'strom.camera150q.floorExtents', 'strom.camera150r.calibration',
  'strom.camera153.alignment', 'strom.camera154.gridAlignment', 'strom.camera155.handoff',
  'strom.camera156.center', 'strom.camera158.returnAlignment', 'strom.camera158.returnFloor',
  'strom.camera163.alignment', 'strom.camera164.alignment',
]
const clamp01 = (t: number) => Math.min(1, Math.max(0, t))

function planBounds(points: readonly PlanPoint[]) {
  let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity
  for (const point of points) {
    if (!Number.isFinite(point.x) || !Number.isFinite(point.y)) continue
    minX = Math.min(minX, point.x); maxX = Math.max(maxX, point.x)
    minY = Math.min(minY, point.y); maxY = Math.max(maxY, point.y)
  }
  if (!Number.isFinite(minX)) return { cx: 0, cy: 0, width: 10, height: 7 }
  return {
    cx: (minX + maxX) / 2, cy: (minY + maxY) / 2,
    width: Math.max(2, maxX - minX), height: Math.max(2, maxY - minY),
  }
}
function perspective(camera: THREE.Camera): THREE.PerspectiveCamera | null {
  const candidate = camera as THREE.PerspectiveCamera
  return candidate.isPerspectiveCamera === true ? candidate : null
}
function canvasRect(canvas: HTMLCanvasElement): Rect165 {
  const rect = canvas.getBoundingClientRect()
  return { left: rect.left, top: rect.top, width: rect.width, height: rect.height }
}
function measureKey(measure: BlueprintMeasure165, canvas: Rect165): string {
  const s = measure.screen, v = measure.viewport
  return [s.x, s.y, s.ax, s.ay, s.bx, s.by, v.left, v.top, v.width, v.height,
    canvas.left, canvas.top, canvas.width, canvas.height].map(value => value.toFixed(3)).join('/')
}
function report165(phase: string, data: Record<string, unknown>) {
  const record = { version: 165, phase, time: new Date().toISOString(), ...data }
  try { window.localStorage.setItem('strom.camera165.check', JSON.stringify(record)) } catch { /* optional */ }
  return record
}

export default function CameraFlight150({ points }: { points: readonly PlanPoint[] }) {
  const get = useThree(state => state.get)
  const invalidate = useThree(state => state.invalidate)
  const pending = useRef<Enter150 | null>(null)
  const requestedExit = useRef<(() => void) | null>(null)
  const run = useRef<Run165 | null>(null)
  const savedTop = useRef<TopView165 | null>(null)
  const baseLens = useRef<Lens165 | null>(null)
  const frozen = useRef<FrozenControl | null>(null)
  const check = useRef<Check165>({ armed: false, measure: null, canvas: null, errorPx: null, key: '' })
  const pointsRef = useRef(points)
  pointsRef.current = points

  const orbit = () => (get().controls || null) as OrbitControl | null
  const unlock = () => {
    const snapshot = frozen.current
    if (!snapshot) return
    if (snapshot.update) snapshot.control.update = snapshot.update
    if (snapshot.enabled !== undefined) snapshot.control.enabled = snapshot.enabled
    frozen.current = null
  }
  const lock = () => {
    const control = orbit()
    if (frozen.current?.control === control) return
    if (frozen.current) unlock()
    if (!control) return
    frozen.current = { control, update: control.update, enabled: control.enabled }
    control.enabled = false
    if (control.update) control.update = () => {}
  }
  const gridMatrix = (scene: THREE.Object3D): THREE.Matrix4 | null => {
    const grid = scene.getObjectByName(GRID_NAME165)
    if (!grid) return null
    grid.updateWorldMatrix(true, false)
    return grid.matrixWorld.clone()
  }
  const restoreLens = (camera: THREE.Camera) => {
    const cam = perspective(camera), lens = baseLens.current
    if (!cam) return
    if (lens) { cam.fov = lens.fov; cam.near = lens.near; cam.far = lens.far }
    cam.clearViewOffset() // also refreshes the projection matrix
  }
  /** Schreibt genau eine Kamerapose. Nichts anderes fasst die Kamera waehrend des Uebergangs an. */
  const apply = (camera: THREE.Camera, top: TopView165, target: OrbitView165, s: number, grid: THREE.Matrix4 | null) => {
    const cam = perspective(camera), lens = baseLens.current
    if (!cam || !lens) return
    const pose = poseAt165(top, target, s, lens.fov, START_FOV165)
    cam.position.copy(pose.position)
    cam.quaternion.copy(pose.quaternion)
    cam.fov = pose.fov
    // Schnittebenen folgen dem Abstand: genug Tiefenaufloesung auch aus grosser Hoehe.
    const bounds = planBounds(pointsRef.current)
    const center = grid ? planToWorld165(grid, bounds.cx, bounds.cy) : new THREE.Vector3(bounds.cx, 0, bounds.cy)
    const radius = 0.75 * Math.hypot(bounds.width, bounds.height) + 30
    const reach = pose.position.distanceTo(center)
    const nearFree = Math.max(lens.near, 0.5 * (reach - radius))
    cam.near = lens.near + (nearFree - lens.near) * pose.offsetFactor
    cam.far = Math.max(lens.far, reach + radius + 50, pose.distance * 1.25 + 50)
    const offset = top.offset, factor = pose.offsetFactor
    if (factor > 1e-6 && (Math.abs(offset.x) > 1e-6 || Math.abs(offset.y) > 1e-6)) {
      cam.setViewOffset(offset.width, offset.height, offset.x * factor, offset.y * factor, offset.width, offset.height)
    } else {
      cam.clearViewOffset()
    }
    cam.updateMatrixWorld(true)
    invalidate()
  }
  /** Hinweg-Zeitpunkt t (0 = Draufsicht, 1 = 3D-Standardansicht): Kamera UND Wandhoehe. */
  const place = (camera: THREE.Camera, top: TopView165, target: OrbitView165, t: number, grid: THREE.Matrix4 | null) => {
    const progress = progress166(t)
    setGrowth166(progress.height)
    apply(camera, top, target, progress.camera, grid)
  }
  const captureOrbit = (camera: THREE.Camera, grid: THREE.Matrix4 | null): OrbitState165 => {
    const control = orbit()
    const forward = camera.getWorldDirection(new THREE.Vector3())
    let pivot = control?.target?.clone() || null
    if (pivot) {
      // Blickpunkt muss auf der Sichtachse liegen; die Controls garantieren das nach update().
      const along = pivot.clone().sub(camera.position).dot(forward)
      pivot = along > 0.05 ? camera.position.clone().addScaledVector(forward, along) : null
    }
    if (!pivot) {
      const planeY = grid ? planToWorld165(grid, 0, 0).y : 0
      const reach = forward.y < -0.05 ? (camera.position.y - planeY) / -forward.y : 12
      pivot = camera.position.clone().addScaledVector(forward, Math.max(1, Math.min(500, reach)))
    }
    return {
      pivot, quaternion: camera.quaternion.clone(), position: camera.position.clone(),
      distance: Math.max(0.05, camera.position.distanceTo(pivot)),
    }
  }
  const finishOrbit = (camera: THREE.Camera, target: OrbitState165) => {
    camera.position.copy(target.position)
    camera.quaternion.copy(target.quaternion)
    restoreLens(camera)
    camera.updateMatrixWorld(true)
    setGrowth166(1)
    unlock()
    invalidate()
  }
  /** Draufsicht aus dem aktuell sichtbaren Blueprint; sonst aus dem Klick-Schnappschuss. */
  const solveFromBlueprint = (camera: THREE.Camera, canvas: Rect165, grid: THREE.Matrix4) => {
    const lens = baseLens.current
    const live = measureBlueprint165()
    const frame = currentFrame150()
    const measure = live || (frame?.screen150o && frame.viewport163
      ? { screen: frame.screen150o, viewport: frame.viewport163 } : null)
    if (!lens || !perspective(camera)) return { measure, live: false, top: 'Keine Perspektivkamera' as TopView165 | string }
    if (!measure) return { measure, live: false, top: 'Blueprint nicht messbar' as TopView165 | string }
    return { measure, live: Boolean(live), top: solveTopView165(measure.screen, measure.viewport, canvas, grid, lens.fov) }
  }

  useLayoutEffect(() => {
    pending.current = consumeEntry150()
    // STROM166_WALL_GROWTH: mit Uebergang starten die Waende flach im Blueprint.
    setGrowth166(pending.current ? 0 : 1)
    if (pending.current) invalidate()
    for (const key of STALE_KEYS165) { try { window.localStorage.removeItem(key) } catch { /* optional */ } }
    const unbind = registerExit150(done => {
      requestedExit.current = done
      invalidate()
    })
    // STROM165_RENDER_CHECK: gemessen wird NACH dem Zeichnen, mit genau der Kamera, die
    // gezeichnet hat, gegen den Blueprint, wie er in diesem Moment im Browser steht.
    const scene = get().scene
    const previousAfterRender = scene.onAfterRender
    scene.onAfterRender = (renderer, renderedScene, camera, ...rest) => {
      previousAfterRender.call(scene, renderer, renderedScene, camera, ...rest)
      const state = check.current
      if (!state.armed) return
      state.armed = false
      state.errorPx = null
      const live = measureBlueprint165()
      const grid = gridMatrix(renderedScene)
      if (!live || !grid) return
      const canvas = canvasRect(renderer.domElement)
      const error = gridErrorPx165(live.screen, live.viewport, canvas, grid, camera)
      if (!error) return
      state.measure = live
      state.canvas = canvas
      state.key = measureKey(live, canvas)
      state.errorPx = error.max
    }
    return () => {
      unbind()
      scene.onAfterRender = previousAfterRender
      if (pending.current) restoreEntry150(pending.current)
      pending.current = null
      requestedExit.current = null
      run.current = null
      unlock()
      // Never leave the transition lens behind after unmount.
      restoreLens(get().camera)
      setGrowth166(1)
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [get, invalidate])

  useFrame(state => {
    const camera = state.camera
    const cam = perspective(camera)
    const now = performance.now()

    if (requestedExit.current) {
      const finish = requestedExit.current
      requestedExit.current = null
      pending.current = null
      const active = run.current
      const grid = gridMatrix(state.scene)
      if (!cam) { run.current = null; finish(); return }
      if (!baseLens.current) baseLens.current = { fov: cam.fov, near: cam.near, far: cam.far }
      // Laeuft der Hinweg noch, kehrt der Rueckweg an genau dieser Stelle um.
      let from = 1
      let target: OrbitState165 | null = null
      let top = savedTop.current
      if (active && active.kind === 'entry') {
        // Laden/Blende: Waende sind noch flach, Kamera steht in der Draufsicht -> kein Flug.
        from = active.phase === 'flight' ? clamp01((now - active.startedAt) / DURATION150) : 0
        target = active.orbit || captureOrbit(camera, grid)
        top = active.top || top
      } else {
        if (active) restoreLens(camera)
        target = captureOrbit(camera, grid)
      }
      if (!top) {
        top = fallbackTopView165(planBounds(pointsRef.current), canvasRect(state.gl.domElement),
          grid || new THREE.Matrix4(), baseLens.current.fov)
      }
      lock()
      check.current = { armed: false, measure: null, canvas: null, errorPx: null, key: '' }
      run.current = {
        kind: 'exit', phase: 'flight', top, orbit: target, from, startedAt: now,
        frames: 0, steady: 0, verified: 0, previous: null, reason: '', finish,
      }
    }

    if (pending.current) {
      pending.current = null
      savedTop.current = null // the new Blueprint viewport is the new truth
      if (run.current) { restoreLens(camera); unlock() }
      check.current = { armed: false, measure: null, canvas: null, errorPx: null, key: '' }
      run.current = {
        kind: 'entry', phase: 'settle', top: null, orbit: null, from: 0,
        startedAt: Number.POSITIVE_INFINITY, frames: 0, steady: 0, verified: 0,
        previous: null, reason: '',
      }
      invalidate()
      return
    }
    const active = run.current
    if (!active) return

    if (active.kind === 'entry' && active.phase === 'settle') {
      setGrowth166(0)
      // Die Szene und die Controls stellen verdeckt ihre Standardansicht ein.
      camera.updateMatrixWorld(true)
      const current = camera.matrixWorld.clone()
      const stable = active.previous !== null && active.previous.equals(current)
      active.steady = stable ? active.steady + 1 : 0
      active.previous = current
      active.frames++
      const grid = gridMatrix(state.scene)
      const waiting = active.steady < 3 || !grid || (!orbit() && active.frames < 24)
      if (waiting && active.frames < 90) { invalidate(); return }
      if (!cam) { run.current = null; notifyEnterFailed165('3D-Kamera ist keine Perspektivkamera.'); return }
      orbit()?.update?.()
      baseLens.current = { fov: cam.fov, near: cam.near, far: cam.far }
      active.orbit = captureOrbit(camera, grid)
      active.phase = 'prepare'
      active.frames = 0
      lock()
      invalidate()
      // no return: the first top view is drawn in this very frame
    }

    lock()
    const grid = gridMatrix(state.scene)
    const canvas = canvasRect(state.gl.domElement)

    if (active.kind === 'entry' && active.phase === 'prepare' && active.orbit) {
      active.frames++
      // Ergebnis der Messung nach dem zuletzt gezeichneten Bild.
      const last = check.current
      const solved = grid ? solveFromBlueprint(camera, canvas, grid) : null
      if (!solved || typeof solved.top === 'string' || !solved.measure || !grid) {
        active.reason = !grid ? '3D-Raster noch nicht aufgebaut' : String(solved?.top)
        active.verified = 0
      } else {
        const key = measureKey(solved.measure, canvas)
        const drawnExactly = last.errorPx !== null && last.key === key && active.top !== null
        if (drawnExactly && last.errorPx! <= TOLERANCE_PX165) active.verified++
        else {
          active.verified = 0
          if (last.errorPx !== null && last.key === key) active.reason = `Rasterabweichung ${last.errorPx.toFixed(2)} px`
          else active.reason = 'Blueprint oder 3D-Fenster noch in Bewegung'
        }
        active.top = solved.top
        place(camera, active.top, active.orbit, 0, grid)
        check.current.armed = true
        if (active.verified >= VERIFY_FRAMES165) {
          savedTop.current = active.top
          active.phase = 'fade'
          active.startedAt = now + ENTER_FADE150
          const position = camera.position
          console.info('[STROM165] Blueprint -> 3D: Raster deckungsgleich', report165('Blueprint -> 3D', {
            maxErrorCssPx: last.errorPx, toleranceCssPx: TOLERANCE_PX165,
            blueprint: solved.live ? 'live gemessen' : 'Klick-Schnappschuss',
            blueprintCenterM: active.top.planCenter, pixelsPerMetre: active.top.pixelsPerMetre,
            cameraXYZ: { x: position.x, y: position.z, z: position.y },
            fovDeg: cam?.fov, lensOffsetCssPx: { x: active.top.offset.x, y: active.top.offset.y },
            canvas, blueprintViewport: solved.measure.viewport, frames: active.frames,
          }))
          notifyEnterReady150()
          return
        }
      }
      if (active.frames > PREPARE_LIMIT165) {
        // Kein unbestaetigtes Ueberblenden und kein Dauer-Ladekreis.
        const record = report165('Blueprint -> 3D abgebrochen', {
          reason: active.reason, lastErrorCssPx: last.errorPx, toleranceCssPx: TOLERANCE_PX165, canvas,
          blueprint: solved?.measure || null,
        })
        console.error('[STROM165] Uebergang abgebrochen:', active.reason, record)
        finishOrbit(camera, active.orbit)
        run.current = null
        notifyEnterFailed165(`3D-Ansicht konnte nicht deckungsgleich ausgerichtet werden (${active.reason}). Bitte Ansicht erneut öffnen.`)
        return
      }
      invalidate()
      return
    }

    if (!active.top || !active.orbit) { run.current = null; unlock(); return }

    if (active.kind === 'entry' && active.phase === 'fade') {
      place(camera, active.top, active.orbit, 0, grid)
      if (now >= active.startedAt) active.phase = 'flight'
      return
    }

    if (active.kind === 'entry') {
      const t = clamp01((now - active.startedAt) / DURATION150)
      if (t < 1) { place(camera, active.top, active.orbit, t, grid); return }
      // STROM150N_NO_END_JUMP: genau die vorher gemerkte Standardansicht, danach uebernehmen die Controls.
      finishOrbit(camera, active.orbit)
      run.current = null
      return
    }

    // ---- Rueckweg ----
    // Sobald der Blueprint wieder im Browser steht, ist ER das Ziel (nicht ein altes Kamerabild).
    if (grid && measureBlueprint165()) {
      const solved = solveFromBlueprint(camera, canvas, grid)
      if (solved.live && typeof solved.top !== 'string') active.top = solved.top
    }
    if (active.phase === 'flight') {
      // Der Hinweg rueckwaerts in halber Zeit: aus Ease-out wird Ease-in in die Draufsicht.
      const duration = active.from * EXIT_FLIGHT159
      const tau = duration > 0 ? clamp01((now - active.startedAt) / duration) : 1
      place(camera, active.top, active.orbit, reverseTime166(active.from, tau), grid)
      if (tau >= 1) { active.phase = 'hold'; active.frames = 0; active.verified = 0 }
      else return
    }
    // hold / done: Draufsicht mit flachen Waenden steht still, bis 3D ausgeblendet und entfernt ist.
    place(camera, active.top, active.orbit, 0, grid)
    if (active.phase === 'done') return
    const last = check.current
    active.frames++
    if (last.errorPx !== null && last.errorPx <= TOLERANCE_PX165) active.verified++
    else active.verified = 0
    check.current.armed = true
    if (active.verified >= VERIFY_FRAMES165 || active.frames > HOLD_LIMIT165) {
      const position = camera.position
      const record = report165('3D -> Blueprint', {
        maxErrorCssPx: last.errorPx, toleranceCssPx: TOLERANCE_PX165, verified: active.verified >= VERIFY_FRAMES165,
        cameraXYZ: { x: position.x, y: position.z, z: position.y }, canvas, frames: active.frames,
      })
      if (active.verified >= VERIFY_FRAMES165) console.info('[STROM165] 3D -> Blueprint: Raster deckungsgleich', record)
      else console.warn('[STROM165] 3D -> Blueprint: Raster nicht bestaetigt', record)
      active.phase = 'done'
      check.current.armed = false
      active.finish?.()
    }
  })
  return null
}
STROM166_FLIGHT
cat > "$RESOURCE_DIR/test166.mjs" <<'STROM166_TEST'
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
STROM166_TEST
cat > "$RESOURCE_DIR/STROM_UPDATE_166.md" <<'STROM166_DOC'
# Strom 166: Rueckweg gespiegelt, Waende wachsen aus dem Blueprint

## Rueckweg (3D -> Blueprint)
- Genau der Hinweg rueckwaerts, doppelt so schnell:
  Kamerafahrt 1250 ms mit Ease-in in die Draufsicht (Hinweg 2500 ms Ease-out),
  danach Blende 375 ms (Hinblende 750 ms `ease`, rueckwaerts: `cubic-bezier(.75,0,.75,.9)`),
  danach Wechsel auf den an derselben Stelle liegenden Blueprint.
- Kamera und Wandhoehe haengen an einer Zeitachse t; der Rueckweg spielt t rueckwaerts ab.
  Wird mitten im Hinflug zurueckgeschaltet, kehrt der Rueckweg an genau dieser Stelle um.
- Vor der Blende wird wie in 165 nachgemessen (Raster <= 1 CSS-Pixel).

## Hinweg (Blueprint -> 3D)
- Die 3D-Szene startet mit Wandhoehe 0 (technisch 1 %: 2,6 m -> 2,6 cm, knapp ueber dem Boden),
  die Waende liegen in der Blende flach auf ihren Blueprint-Linien.
- Waehrend der Kamerafahrt wachsen Waende, Tueren, Treppen und Daecher mit Ease-in-out auf
  ihre volle Hoehe, genau bis zum Fahrtende. Boden, Deckenplatte und Raster bleiben unveraendert.
- Weitere Etagen ("Alle Etagen") sinken auf dem Rueckweg mit ab und werden dabei ausgeblendet,
  sodass die Draufsicht am Ende genau die aktive Ebene des Blueprints zeigt.

## Pruefung
- Vor Auslieferung im echten Browser (Chromium) gegen genau dieses Bundle gemessen.
- Das Skript vergleicht den Fingerabdruck des gebauten Bundles mit dem geprueften Bundle
  und bricht vor Git-Push und Deployment ab, wenn er abweicht.
- Nur Testumgebung `/strom-test/`; Produktion `/strom/` unveraendert.
STROM166_DOC
log "3) Quelltext patchen (Rueckweg gespiegelt, Wandwachstum) ..."
python3 -m py_compile "$RESOURCE_DIR/patch166.py" >>"$DIAG_LOG" 2>&1 || fail "166 Python patch syntax error"
STROM166_ROOT="$WORK_DIR" STROM166_RESOURCES="$RESOURCE_DIR" python3 "$RESOURCE_DIR/patch166.py" >>"$DIAG_LOG" 2>&1 || \
  fail "166 Ausgangsstand passt nicht; GitHub and Stage unchanged"
log "4) Full TypeScript/Vite build BEFORE committing ..."
( cd "$WORK_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || \
  fail "166 TypeScript/Vite build failed; GitHub and Stage unchanged"
log "5) Regression: 165-Pruefungen, Zeitverlauf, Wandhoehe, echte OrbitControls ..."
STROM166_SOURCE="$WORK_DIR/frontend/src" STROM166_MODULES="$DEPENDENCIES" \
  node "$RESOURCE_DIR/test166.mjs" >>"$DIAG_LOG" 2>&1 || \
  fail "166 Regression fehlgeschlagen; GitHub and Stage unchanged"
grep -F 'PASS 166' "$DIAG_LOG" | tail -n 2 || true
log "6) Bundle mit dem im Browser geprueften Bundle vergleichen ..."
check_bundle166 "$WORK_DIR/frontend/dist" "GitHub and Stage unchanged."
mkdir -p "$WORK_DIR/deploy/updates" "$WORK_DIR/docs"
cp -a "$RESOURCE_DIR/patch166.py" "$WORK_DIR/deploy/updates/${SCRIPT_NAME}_patch.py"
cp -a "$RESOURCE_DIR/STROM_UPDATE_166.md" "$WORK_DIR/docs/STROM_UPDATE_166.md"
rm -rf "$RESOURCE_DIR"
log "7) Synchronize verified source into Stage ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
  "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "166 Stage transfer failed; backup: $BACKUP_DIR"
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PASS PATCH_ONLY: no web deployment"
  exit 0
fi
log "8) Build Stage and deploy ONLY /strom-test/ ..."
( cd "$STAGE_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || \
  fail "166 Stage build failed; backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "166 frontend/dist missing"
check_bundle166 "$STAGE_DIR/frontend/dist" "Testseite unveraendert; Stage-Backup: $BACKUP_DIR."
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || \
  fail "166 test deployment failed; backup: $BACKUP_DIR"
log "SUCCESS: 166 deployed at https://home.moja.de/strom-test/"
log "Production /strom/ unchanged. Stage backup: $BACKUP_DIR"
log "Browser: Konsole [STROM165] bzw. localStorage['strom.camera165.check'] zeigt weiterhin die gemessene Rasterabweichung."
