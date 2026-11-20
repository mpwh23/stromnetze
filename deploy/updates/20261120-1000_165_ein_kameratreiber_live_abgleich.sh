#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="20261120-1000_165_ein_kameratreiber_live_abgleich"
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
COMMIT_MESSAGE="Update 165: one camera owner, OrbitControls registered, live Blueprint verification"
SELF_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
MODE="${1:-}"
# STROM165: Fingerabdruck des Bundles, das vor der Auslieferung im echten Browser geprueft wurde.
EXPECTED_BUNDLE165="73d5359d3f8f8b697b52b74f1b0a2956ed76b5a67ce910f9da05a4550ead9985"
# Echte Produktionsquelle (nur lesend, fuer den Backend-Abgleich). PROD_DIR wird in der Git-Phase umgebogen.
REAL_PROD_DIR="${REAL_PROD_DIR:-/home/mpwh/strom}"
ALLOW_UNTESTED165="${STROM165_ALLOW_UNTESTED_BUNDLE:-0}"
if [ "${2:-}" = "allow-untested-bundle" ]; then ALLOW_UNTESTED165=1; fi
ALLOW_ARG165=""
if [ "$ALLOW_UNTESTED165" = "1" ]; then ALLOW_ARG165="allow-untested-bundle"; fi

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
  echo "2) Update 165 im isolierten Git-Checkout bauen, pruefen und nach GitHub pushen ..."
  ssh -t "${SSH_CONTROL_OPTS[@]}" "$REMOTE_HOST" "chmod +x '$REMOTE_TMP_SCRIPT' && '$REMOTE_TMP_SCRIPT' --git-phase $ALLOW_ARG165"

  echo ""
  echo "3) Git-Push erfolgreich. Update-Script jetzt nach ~/deploy kopieren ..."
  scp "${SSH_CONTROL_OPTS[@]}" "$SELF_PATH" "$REMOTE_HOST:$REMOTE_DEPLOY_SCRIPT"

  echo ""
  echo "4) Stage-Update auf dem Pi ausfuehren ..."
  ssh -t "${SSH_CONTROL_OPTS[@]}" "$REMOTE_HOST" "rm -f '$REMOTE_TMP_SCRIPT'; chmod +x '$REMOTE_DEPLOY_SCRIPT'; cd '$REMOTE_DEPLOY_DIR'; './$(basename "$SELF_PATH")' --stage-phase $ALLOW_ARG165"
  exit $?
fi

# -----------------------------------------------------------------------------
# Pi Git phase. Uses the already configured HomePi deploy key:
#   Host github-stromnetze -> /root/.ssh/.../github-stromnetze
# No Mac Git repository and no GitHub CLI are required.
# -----------------------------------------------------------------------------
if [ "$MODE" = "--git-phase" ]; then
  if [ "$(id -u)" -ne 0 ]; then
    exec sudo -H "$SELF_PATH" --git-phase-root $ALLOW_ARG165
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

  echo "1.3) Update 165 isoliert anwenden, TypeScript/Vite-Build, Tests und Bundle-Abgleich ..."
  PATCH_ONLY=1 \
    STAGE_DIR="$GIT_TMP" \
    PROD_DIR="$STAGE_DIR" \
    BACKUP_BASE=/tmp \
    "$SELF_PATH" --stage-phase $ALLOW_ARG165

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

# ----- 165: Hilfsfunktionen ----------------------------------------------------------------
run_as_postgres() {
  if [ "$(id -u)" -eq 0 ]; then
    if command -v runuser >/dev/null 2>&1; then runuser -u postgres -- "$@"; else sudo -n -u postgres "$@"; fi
  else
    sudo -u postgres "$@"
  fi
}
db_name165() {
  local name=""
  name="$(run_sudo sed -n 's/^DATABASE_URL=.*\/\([A-Za-z0-9_]*\)\(?.*\)\{0,1\}$/\1/p' /etc/strom/strom.env 2>/dev/null | head -n 1 || true)"
  case "$name" in ''|*[!A-Za-z0-9_]*) name="strom";; esac
  printf '%s' "$name"
}
dist_fingerprint165() {
  ( cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do sha256sum "$f"; done ) | sha256sum | cut -d' ' -f1
}
check_bundle165() {
  local have; have="$(dist_fingerprint165 "$1")"
  log "Bundle-Fingerabdruck: $have"
  if [ "$have" = "$EXPECTED_BUNDLE165" ]; then
    log "PASS: Bundle ist identisch mit dem im Browser geprueften Bundle."
  elif [ "$ALLOW_UNTESTED165" = "1" ]; then
    log "WARNUNG: Bundle weicht vom geprueften Bundle ab ($EXPECTED_BUNDLE165); ausdruecklich erlaubt."
  else
    ( cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do sha256sum "$f"; done ) >>"$DIAG_LOG" 2>&1 || true
    fail "165 Bundle weicht vom im Browser geprueften Bundle ab (erwartet $EXPECTED_BUNDLE165). $2 Bewusst trotzdem: STROM165_ALLOW_UNTESTED_BUNDLE=1 vor den Mac-Befehl setzen."
  fi
}

log "=== Update 165: ein Kameratreiber, Blueprint und 3D deckungsgleich ==="
log "Stage: $STAGE_DIR"
log "Diagnostics: $DIAG_LOG"
for file in frontend/src/App.tsx frontend/src/components/CameraFlight150.tsx frontend/src/components/cameraTransitions150.ts \
    frontend/src/components/Building3DWorkspace.tsx frontend/src/components/CanonicalGrid152.tsx; do
  [ -s "$STAGE_DIR/$file" ] || fail "165 Ausgangsdatei fehlt: $file"
done
if grep -Fq 'STROM165_ONE_CAMERA_OWNER' "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx"; then
  fail "165 ist bereits installiert; nichts veraendert"
fi
grep -Fq 'STROM164_ONE_EXACT_TRANSFORM' "$STAGE_DIR/frontend/src/components/CameraFlight150.tsx" || \
  fail "165 setzt den Stand 164b voraus (Marker STROM164_ONE_EXACT_TRANSFORM fehlt); nichts veraendert"
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
  # Datensicherung der Datenbank (nur lesen). Fehlschlag haelt das Update nicht auf.
  if [ "$(id -u)" -ne 0 ]; then log "   (sudo fragt ggf. nach dem Pi-Passwort: Datenbank-Sicherung und Test-Deployment)"; fi
  if command -v pg_dump >/dev/null 2>&1; then
    DB_NAME165="$(db_name165)"
    DB_BACKUP_DIR165="$BACKUP_BASE/strom_db_backups"
    DB_BACKUP_FILE165="$DB_BACKUP_DIR165/${DB_NAME165}_$(date +%Y%m%d-%H%M%S).pgcustom"
    if mkdir -p "$DB_BACKUP_DIR165" 2>>"$DIAG_LOG" && chmod 700 "$DB_BACKUP_DIR165" 2>>"$DIAG_LOG" && \
       ( umask 077; cd / && run_as_postgres pg_dump -Fc "$DB_NAME165" >"$DB_BACKUP_FILE165" ) 2>>"$DIAG_LOG" && \
       [ -s "$DB_BACKUP_FILE165" ]; then
      log "   Datenbank-Sicherung: $DB_BACKUP_FILE165 (enthaelt Nutzerdaten und Passwort-Hashes; vertraulich)"
    else
      rm -f "$DB_BACKUP_FILE165" 2>/dev/null || true
      log "   HINWEIS: Datenbank-Sicherung nicht moeglich (siehe Diagnose); Update laeuft weiter."
    fi
  else
    log "   HINWEIS: pg_dump nicht gefunden; keine Datenbank-Sicherung."
  fi
fi
log "2) Prepare isolated source ..."
rsync -a --exclude='/frontend/node_modules' --exclude='/frontend/dist' --exclude='/.git' \
  "$STAGE_DIR/" "$WORK_DIR/" >>"$DIAG_LOG" 2>&1 || fail "165 source copy failed"
DEPENDENCIES=""
for candidate in "$STAGE_DIR/frontend/node_modules" "$PROD_DIR/frontend/node_modules" /home/mpwh/strom_stage/frontend/node_modules; do
  if [ -f "$candidate/typescript/lib/typescript.js" ] && [ -d "$candidate/vite" ] && \
     [ -d "$candidate/three" ] && [ -d "$candidate/@react-three/fiber" ]; then
    DEPENDENCIES="$candidate";break
  fi
done
[ -n "$DEPENDENCIES" ] || fail "165 TypeScript/Vite/Three dependencies unavailable"
ln -s "$DEPENDENCIES" "$WORK_DIR/frontend/node_modules"
RESOURCE_DIR="$WORK_DIR/165_resources"
mkdir -p "$RESOURCE_DIR"
cat > "$RESOURCE_DIR/patch165.py" <<'STROM165_PATCH'
#!/usr/bin/env python3
"""Patch 165: ein Kameratreiber, Controls im R3F-Store, Live-Abgleich mit dem Blueprint.

Arbeitet nur auf einer isolierten Kopie. Jede Ausgangsdatei wird per SHA-256 mit dem
Stand 164b verglichen; bei Abweichung wird nichts veraendert.
"""
from pathlib import Path
import hashlib, os, shutil, sys

root = Path(os.environ['STROM165_ROOT'])
res = Path(os.environ['STROM165_RESOURCES'])
src = root / 'frontend/src'
comp = src / 'components'

BASE = {
    'frontend/src/App.tsx': 'f5379c0d562566d3f8eea9fcb7c0ebf9a2d97fa2b2f58c863e155f29b947f707',
    'frontend/src/components/Building3DWorkspace.tsx': '5a77950a3ff5fc9623cfd9c59bef3faebfa2056b64ee38ab7a8e46fc0a4b2057',
    'frontend/src/components/CameraFlight150.tsx': '62272df54793ae332cc6133f64946866468f7d001cd09ef0c8354c96befd0f80',
    'frontend/src/components/cameraTransitions150.ts': 'eb94fcce8089a61faebbfae04811e133af3f12f9f937bcd30a2bd8f583cf2603',
    'frontend/src/components/CanonicalGrid152.tsx': 'c8803f46ec0812065ef7c60a2cc29284e8701640aa2b779390d01556f7af6c2b',
    'frontend/package.json': '4fcbc0715a2558b0f8b70e1a5d538d6c8a0f0b2951ed446e772e289fa2de6a43',
    'frontend/package-lock.json': 'b911f7da72bd6725a94154746c2d2c90689f0544ff63992f3a15c6a726bf6967',
}
# Alte Kalibrierungen und Diagnosen: nach 165 von keiner Datei mehr importiert.
OBSOLETE = {
    'frontend/src/components/cameraBlueprintCenter156.ts': '915c5fa021fa79c9644db5aee3e317706f9322ccc5412dea97e6bb32c9278c3a',
    'frontend/src/components/cameraFloorMatch150r.ts': 'db8950c20a0b9d255bae8121cbc023cd0e12b781d4afd281f53efbc2b3d3f16e',
    'frontend/src/components/cameraGridAlignment154.ts': '728a137129f6037d507351814c5b918ccf4551f5c9c495499d00c576ac2d28d1',
    'frontend/src/components/cameraGridAnalytic164.ts': 'e38089123580d6e192ec27a387175a2f63f7e42cbc0f258448bbaa5af24ca98e',
    'frontend/src/components/cameraHandoffDiagnostics155.ts': 'bd72efc56bb95b051542571f980221b8b2b0adc5c3c7fe0c7627d1952131e9e9',
    'frontend/src/components/cameraViewportAlignment153.ts': 'f8ddb41e77f346dff36a5e71d615b92acb4285395c126a9bb2229ab4fd6548da',
    'frontend/src/components/cameraViewportExact163.ts': 'b9905eca57bea5bb4e3273e4f5f08207bf3a0f78c31b3097d39282251fb774e1',
    'frontend/src/components/threeFloorExtrema150q.ts': '26c97a4a0b6cff192355b7cbf06b62f00e0e75e88c7281da334043d90083e568',
}
PROMOTE_BASE = '71abd615549f18541fb747fa3e0882273e9fc96e99bcc9624aee4e9b7c2c6189'


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f'165: Textstelle "{label}" {count}x gefunden (erwartet: 1)')
    return text.replace(old, new)


flight = comp / 'CameraFlight150.tsx'
if not flight.is_file():
    raise RuntimeError('165: CameraFlight150.tsx fehlt')
if 'STROM165_ONE_CAMERA_OWNER' in flight.read_text(encoding='utf-8'):
    raise RuntimeError('165 ist bereits installiert; nichts veraendert')
for name, want in {**BASE, **OBSOLETE}.items():
    path = root / name
    if not path.is_file():
        raise RuntimeError(f'165: Ausgangsdatei fehlt: {name}')
    have = digest(path)
    if have != want:
        raise RuntimeError(f'165: {name} entspricht nicht dem Stand 164b (sha256 {have[:12]}...). '
                           'Der Patch wurde gegen genau diesen Stand im Browser geprueft; nichts veraendert.')
for name in ('cameraTop165.ts', 'cameraTransitions150.ts', 'CameraFlight150.tsx'):
    if not (res / name).is_file():
        raise RuntimeError(f'165: Ressource fehlt: {name}')

# 1) Neue Kameradateien, alte Kalibrierungen entfernen ------------------------------------
for name in ('cameraTop165.ts', 'cameraTransitions150.ts', 'CameraFlight150.tsx'):
    shutil.copyfile(res / name, comp / name)
for name in OBSOLETE:
    (root / name).unlink()

# 2) OrbitControls im R3F-Store anmelden (Ursache des Versatzes) --------------------------
workspace = comp / 'Building3DWorkspace.tsx'
text = workspace.read_text(encoding='utf-8')
text = once(text,
    "  const { camera, gl } = useThree()\n"
    "  const controls = useMemo(() => new OrbitControls(camera, gl.domElement), [camera, gl.domElement])\n",
    "  const { camera, gl } = useThree()\n"
    "  const controls = useMemo(() => new OrbitControls(camera, gl.domElement), [camera, gl.domElement])\n"
    "  // STROM165_ONE_CAMERA_OWNER: Controls im R3F-Store anmelden. Erst dadurch kann der\n"
    "  // Kameraflug (CameraFlight150) sie waehrend Blende und Flug wirklich sperren.\n"
    "  const setRootState165 = useThree((state) => state.set)\n"
    "  useEffect(() => {\n"
    "    setRootState165({ controls })\n"
    "    return () => setRootState165({ controls: null })\n"
    "  }, [controls, setRootState165])\n",
    'SceneControls')
workspace.write_text(text, encoding='utf-8')

# 3) App.tsx --------------------------------------------------------------------------------
app = src / 'App.tsx'
text = app.read_text(encoding='utf-8')
text = once(text,
    "import {queueEntry150,requestExit150,registerEnterReady150,ENTER_FADE150,EXIT_FADE158,currentFrame150} from './components/cameraTransitions150' // STROM150_CAMERA_BRIDGE\n",
    "import {queueEntry150,requestExit150,registerEnterReady150,registerEnterFailed165,notifyEnterFailed165,ENTER_FADE150,EXIT_FADE158,currentFrame150} from './components/cameraTransitions150' // STROM150_CAMERA_BRIDGE\n",
    'Import Kamerabruecke')
text = once(text,
    "import Building3DWorkspace from './components/Building3DWorkspace'\n",
    "import { lazy, Suspense, type ComponentProps } from 'react'\n"
    "// STROM165_LAZY_3D: Three.js und die 3D-Ansicht werden erst beim ersten Oeffnen geladen.\n"
    "function Building3DUnavailable165() {\n"
    "  useEffect(() => { notifyEnterFailed165('Das 3D-Modul konnte nicht geladen werden. Bitte die Seite neu laden.') }, [])\n"
    "  return <div className=\"hint-box standalone\">Das 3D-Modul konnte nicht geladen werden. Bitte die Seite neu laden.</div>\n"
    "}\n"
    "const Building3DWorkspaceLazy165 = lazy(() => import('./components/Building3DWorkspace').catch(() => ({\n"
    "  default: Building3DUnavailable165 as unknown as typeof import('./components/Building3DWorkspace').default,\n"
    "})))\n"
    "function Building3DWorkspace(props: ComponentProps<typeof Building3DWorkspaceLazy165>) {\n"
    "  return <Suspense fallback={null}><Building3DWorkspaceLazy165 {...props} /></Suspense>\n"
    "}\n",
    'Import Building3DWorkspace')
text = once(text,
    "  useEffect(() => () => {\n"
    "    if (enterPreviewTimer150.current !== null) window.clearTimeout(enterPreviewTimer150.current)\n"
    "  }, [])\n",
    "  // STROM165_FAIL_FAST: Abbruch sofort melden statt 30 s Ladekreis.\n"
    "  useEffect(() => registerEnterFailed165((reason) => {\n"
    "    if (enterPreviewTimer150.current !== null) {\n"
    "      window.clearTimeout(enterPreviewTimer150.current)\n"
    "      enterPreviewTimer150.current = null\n"
    "    }\n"
    "    setError(reason)\n"
    "    setEnterPreview150(null)\n"
    "    setViewMode('floorplan')\n"
    "  }), [])\n"
    "  useEffect(() => () => {\n"
    "    if (enterPreviewTimer150.current !== null) window.clearTimeout(enterPreviewTimer150.current)\n"
    "  }, [])\n",
    'Abbruch-Handler')
# Klassische Wandansicht verkleinert den gemeinsamen Zoom beim Einstieg auf 90 %. Bisher wurde
# beim Verlassen pauschal mit 1,1 multipliziert (0,9 x 1,1 = 0,99; ueber den 3D-Knopf gar nicht).
text = once(text,
    "    if(exitPreview158)return // prevent overlapping mode changes during reverse flight/fade\n"
    "    if (!canUseViewMode(mode)) return\n",
    "    if(exitPreview158)return // prevent overlapping mode changes during reverse flight/fade\n"
    "    if (!canUseViewMode(mode)) return\n"
    "    // STROM165_WALL_ZOOM_RESTORE: exakter Blueprint-Zoom nach der klassischen Wandansicht.\n"
    "    if (viewMode === 'wall' && mode !== 'wall' && floor) restoreBlueprintZoomAfterWall165(floor.id)\n",
    'Moduswechsel Anfang')
text = once(text,
    "    if (viewMode === 'wall' && mode === 'floorplan' && floor) {\n"
    "      const storedViewport = loadCanvasViewport(floor.id)\n"
    "      saveCanvasViewport(floor.id, {\n"
    "        ...storedViewport,\n"
    "        zoom: Math.min(10, Math.max(0.22, round2(storedViewport.zoom * 1.1))),\n"
    "      })\n"
    "    }\n"
    "    setViewMode(mode)\n",
    "    setViewMode(mode)\n",
    'Zoom x 1,1')
text = once(text,
    "onClick={() => setLegacyWallDetail(false)}>",
    "onClick={() => { if (floor) restoreBlueprintZoomAfterWall165(floor.id); setLegacyWallDetail(false) }}>",
    'Zurueck zu Echtes 3D')
text = once(text,
    "      saveCanvasViewport(floor.id, { zoom: targetZoom, left: entryViewport.left, top: entryViewport.top })\n",
    "      saveCanvasViewport(floor.id, { zoom: targetZoom, left: entryViewport.left, top: entryViewport.top })\n"
    "      wallIntroZoom165[floor.id] = { before: entryViewport.zoom, after: targetZoom } // STROM165_WALL_ZOOM_RESTORE\n",
    'Wandansicht Einstiegszoom')
text = once(text,
    "function loadWallCanvasRotation(floorId: string) {\n",
    "// STROM165_WALL_ZOOM_RESTORE: Zoom vor und nach dem Einstieg in die klassische Wandansicht.\n"
    "const wallIntroZoom165: Record<string, { before: number; after: number }> = {}\n"
    "function restoreBlueprintZoomAfterWall165(floorId: string) {\n"
    "  const record = wallIntroZoom165[floorId]\n"
    "  if (!record) return\n"
    "  delete wallIntroZoom165[floorId]\n"
    "  const stored = loadCanvasViewport(floorId)\n"
    "  // Unveraendert: exakt der alte Wert. In der Wandansicht gezoomt: gleiches Verhaeltnis.\n"
    "  const zoom = Math.abs(stored.zoom - record.after) < 0.005\n"
    "    ? record.before\n"
    "    : stored.zoom * record.before / Math.max(0.01, record.after)\n"
    "  saveCanvasViewport(floorId, { ...stored, zoom })\n"
    "}\n"
    "\n"
    "function loadWallCanvasRotation(floorId: string) {\n",
    'Hilfsfunktion Zoom')
app.write_text(text, encoding='utf-8')

# 4) Feste Versionen statt "latest" (identisch zu den bereits gesperrten Versionen) -------
PINS = {
    '"@vitejs/plugin-react": "latest"': '"@vitejs/plugin-react": "6.0.2"',
    '"typescript": "latest"': '"typescript": "6.0.3"',
    '"vite": "latest"': '"vite": "8.0.16"',
    '"@types/react": "latest"': '"@types/react": "19.2.17"',
    '"@types/react-dom": "latest"': '"@types/react-dom": "19.2.3"',
}
for name in ('frontend/package.json', 'frontend/package-lock.json'):
    path = root / name
    text = path.read_text(encoding='utf-8')
    for old, new in PINS.items():
        text = once(text, old, new, f'{name}: {old}')
    path.write_text(text, encoding='utf-8')

# 5) Promote-Skript: Backend der Produktion nie stillschweigend ueberschreiben -------------
promote = root / 'tools/strom_stage_promote_to_prod.sh'
if promote.is_file() and digest(promote) == PROMOTE_BASE:
    text = promote.read_text(encoding='utf-8')
    text = once(text,
        'mkdir -p "$BACKUP_DIR"\n',
        '# STROM165_BACKEND_GUARD: Stage darf ein abweichendes Produktions-Backend nicht stillschweigend ueberschreiben.\n'
        'backend_sums165() { ( cd "$1" 2>/dev/null && find . -type f \\( -name \'*.go\' -o -name go.mod -o -name go.sum \\) | LC_ALL=C sort | xargs -r sha256sum ); }\n'
        'if [ -d "$PROJECT_DIR/backend" ] && [ "${STROM_PROMOTE_BACKEND:-0}" != "1" ]; then\n'
        '  if [ "$(backend_sums165 "$PROJECT_DIR/backend")" != "$(backend_sums165 "$STAGE_DIR/backend")" ]; then\n'
        '    echo "ABBRUCH: Go-Quelltext in backend/ unterscheidet sich zwischen Produktion und Stage:" >&2\n'
        '    diff <(backend_sums165 "$PROJECT_DIR/backend") <(backend_sums165 "$STAGE_DIR/backend") >&2 || true\n'
        '    echo "Erst angleichen. Bewusst mit dem Stage-Stand ueberschreiben: STROM_PROMOTE_BACKEND=1 $0" >&2\n'
        '    exit 1\n'
        '  fi\n'
        'fi\n'
        'mkdir -p "$BACKUP_DIR"\n',
        'Promote-Skript')
    promote.write_text(text, encoding='utf-8')
    print('165: Promote-Skript mit Backend-Schutz versehen')
else:
    print('165: Promote-Skript nicht im erwarteten Stand; unveraendert gelassen')

print('165: Quelltext gepatcht')
STROM165_PATCH
cat > "$RESOURCE_DIR/cameraTop165.ts" <<'STROM165_TOP'
import * as THREE from 'three'

/** STROM165_ONE_CAMERA_OWNER
 * Reine Geometrie fuer den Uebergang Blueprint <-> 3D. Kein DOM, kein React,
 * keine Kamera wird hier veraendert. Architektur (X,Y,Z) == Three (X,Z,Y).
 *
 * Eine Draufsicht ist vollstaendig bestimmt durch
 *   - die Bildschirmmatrix des Blueprints (CSS-Pixel),
 *   - das sichtbare Blueprint-Rechteck,
 *   - das Rechteck des 3D-Canvas,
 *   - die Weltmatrix des tatsaechlich gezeichneten 3D-Rasters.
 * Daraus folgen Blickpunkt, Blickrichtung, Abstand und die Linsenverschiebung.
 */
export type BlueprintScreen165={x:number;y:number;ax:number;ay:number;bx:number;by:number}
export type Rect165={left:number;top:number;width:number;height:number}
export type ViewOffset165={x:number;y:number;width:number;height:number}
export type PlanPoint165={x:number;y:number}
/** Senkrechte Draufsicht. distanceBase gilt fuer den normalen Blickwinkel der 3D-Ansicht. */
export type TopView165={
  pivot:THREE.Vector3
  quaternion:THREE.Quaternion
  distanceBase:number
  offset:ViewOffset165
  pixelsPerMetre:number
  planCenter:PlanPoint165
}
/** Frei gedrehte 3D-Ansicht: Kamera schaut aus distance auf pivot. */
export type OrbitView165={pivot:THREE.Vector3;quaternion:THREE.Quaternion;distance:number}
export type Pose165={position:THREE.Vector3;quaternion:THREE.Quaternion;fov:number;offsetFactor:number;distance:number}

/** Hoehe der Rasterlinien innerhalb der Rastergruppe (CanonicalGrid152). */
export const GRID_PLANE_Y165=-0.018
const RADIANS165=Math.PI/180
const finite165=(...values:number[])=>values.every(Number.isFinite)

export function planToWorld165(grid:THREE.Matrix4,x:number,y:number):THREE.Vector3{
  return new THREE.Vector3(x,GRID_PLANE_Y165,y).applyMatrix4(grid)
}
export function blueprintPixel165(bp:BlueprintScreen165,x:number,y:number):PlanPoint165{
  return {x:bp.x+bp.ax*x+bp.bx*y,y:bp.y+bp.ay*x+bp.by*y}
}
export function pixelToPlan165(bp:BlueprintScreen165,px:number,py:number):PlanPoint165|null{
  const determinant=bp.ax*bp.by-bp.ay*bp.bx
  if(!finite165(determinant)||Math.abs(determinant)<1e-9)return null
  const dx=px-bp.x,dy=py-bp.y
  return {x:(bp.by*dx-bp.bx*dy)/determinant,y:(-bp.ay*dx+bp.ax*dy)/determinant}
}
/** Bildschirmposition (CSS-Pixel) eines Weltpunkts mit der uebergebenen Kamera. */
export function worldToPixel165(point:THREE.Vector3,camera:THREE.Camera,canvas:Rect165):PlanPoint165{
  const ndc=point.clone().project(camera)
  return {x:canvas.left+(ndc.x+1)*canvas.width/2,y:canvas.top+(1-ndc.y)*canvas.height/2}
}

/** Liefert die Draufsicht oder einen Klartext-Grund, warum keine exakte Loesung existiert. */
export function solveTopView165(bp:BlueprintScreen165,viewport:Rect165,canvas:Rect165,
  grid:THREE.Matrix4,baseFovDeg:number):TopView165|string{
  if(!finite165(bp.x,bp.y,bp.ax,bp.ay,bp.bx,bp.by))return 'Blueprint-Matrix unvollstaendig'
  if(!finite165(viewport.left,viewport.top,viewport.width,viewport.height)||viewport.width<20||viewport.height<20)
    return 'Blueprint-Viewport zu klein'
  if(!finite165(canvas.left,canvas.top,canvas.width,canvas.height)||canvas.width<20||canvas.height<20)
    return '3D-Canvas zu klein'
  if(!(baseFovDeg>1&&baseFovDeg<170))return 'Blickwinkel der 3D-Kamera ungueltig'
  const determinant=bp.ax*bp.by-bp.ay*bp.bx
  const pxX=Math.hypot(bp.ax,bp.ay),pxY=Math.hypot(bp.bx,bp.by)
  const skew=bp.ax*bp.bx+bp.ay*bp.by
  // Eine echte Kamera kann weder verzerrte noch gespiegelte Blueprint-Pixel abbilden.
  if(!(determinant>1e-8&&pxX>0.1&&pxY>0.1))return 'Blueprint-Matrix gespiegelt oder entartet'
  if(Math.abs(pxX-pxY)>Math.max(pxX,pxY)*1e-4||Math.abs(skew)>pxX*pxY*1e-4)
    return 'Blueprint-Matrix verzerrt'
  const pixelsPerMetre=(pxX+pxY)/2
  const pixelCenter={x:viewport.left+viewport.width/2,y:viewport.top+viewport.height/2}
  const planCenter=pixelToPlan165(bp,pixelCenter.x,pixelCenter.y)
  if(!planCenter)return 'Blueprint-Matrix nicht umkehrbar'

  const origin=planToWorld165(grid,0,0)
  const u=planToWorld165(grid,1,0).sub(origin),v=planToWorld165(grid,0,1).sub(origin)
  const lengthU=Math.hypot(u.x,u.z),lengthV=Math.hypot(v.x,v.z)
  if(!(lengthU>1e-5&&lengthV>1e-5)||Math.abs(lengthU-lengthV)>Math.max(lengthU,lengthV)*1e-4
      ||Math.abs(u.dot(v))>lengthU*lengthV*1e-4||Math.abs(u.y)>1e-6||Math.abs(v.y)>1e-6
      ||u.clone().cross(v).y>=0)
    return '3D-Raster ist kein waagerechtes, gleichmaessiges X/Y-Raster'
  const unitX=u.clone().divideScalar(lengthU),unitY=v.clone().divideScalar(lengthV)
  // Bildschirm rechts / oben, ausgedrueckt in Planrichtungen (auch bei gedrehtem SVG).
  const right=unitX.clone().multiplyScalar(bp.ax/pixelsPerMetre).addScaledVector(unitY,bp.bx/pixelsPerMetre).normalize()
  const up=unitX.clone().multiplyScalar(-bp.ay/pixelsPerMetre).addScaledVector(unitY,-bp.by/pixelsPerMetre).normalize()
  const back=new THREE.Vector3(0,1,0)
  if(right.clone().cross(up).distanceTo(back)>1e-4)return 'Blueprint und 3D-Raster haben verschiedene Drehsinne'
  const quaternion=new THREE.Quaternion().setFromRotationMatrix(new THREE.Matrix4().makeBasis(right,up,back))
  // Pixel je Welt-Einheit im Abstand d: H / (2 d tan(fov/2)). Gesucht: pixelsPerMetre / lengthU.
  const distanceBase=canvas.height*lengthU/(2*pixelsPerMetre*Math.tan(baseFovDeg*RADIANS165/2))
  if(!finite165(distanceBase)||distanceBase<=0.01)return 'Kameraabstand nicht berechenbar'
  // Die Kamera blickt genau auf pivot; ohne Verschiebung laege pivot in der Canvas-Mitte.
  // Die Linsenverschiebung legt ihn auf die Mitte des sichtbaren Blueprints.
  const offset:ViewOffset165={
    x:canvas.left+canvas.width/2-pixelCenter.x,
    y:canvas.top+canvas.height/2-pixelCenter.y,
    width:canvas.width,height:canvas.height,
  }
  return {pivot:planToWorld165(grid,planCenter.x,planCenter.y),quaternion,distanceBase,offset,pixelsPerMetre,planCenter}
}

/** Draufsicht ohne Blueprint-Daten (3D wurde ohne Uebergang geoeffnet). */
export function fallbackTopView165(bounds:{cx:number;cy:number;width:number;height:number},canvas:Rect165,
  grid:THREE.Matrix4,baseFovDeg:number):TopView165{
  const tangent=Math.max(0.02,Math.tan(baseFovDeg*RADIANS165/2))
  const aspect=Math.max(0.3,canvas.width/Math.max(1,canvas.height))
  const distanceBase=Math.max(3,1.14*Math.max(bounds.height/(2*tangent),bounds.width/(2*aspect*tangent)))
  const quaternion=new THREE.Quaternion().setFromRotationMatrix(new THREE.Matrix4().makeBasis(
    new THREE.Vector3(1,0,0),new THREE.Vector3(0,0,-1),new THREE.Vector3(0,1,0)))
  return {pivot:planToWorld165(grid,bounds.cx,bounds.cy),quaternion,distanceBase,
    offset:{x:0,y:0,width:canvas.width,height:canvas.height},
    pixelsPerMetre:canvas.height/(2*distanceBase*tangent),planCenter:{x:bounds.cx,y:bounds.cy}}
}

/** Mindestabstand der Kamera waehrend der Blende. Aus dieser Hoehe liegen auch 3 m hohe
 * Waende je 1000 px Abstand zur Bildmitte weniger als 3 CSS-Pixel neben ihrer Blueprint-Linie. */
export const MIN_START_DISTANCE165=1000

/** Blickwinkel am Anfang (s=0, fast parallel) bis zum normalen Blickwinkel (s=1).
 * Der Abstand waechst im selben Mass, sodass der Bildmassstab der Rasterebene gleich bleibt. */
export function lensAt165(baseFovDeg:number,startFovDeg:number,s:number,distanceBase=0):{fov:number;stretch:number}{
  const base=Math.tan(baseFovDeg*RADIANS165/2)
  let start=Math.tan(Math.min(baseFovDeg,Math.max(0.01,startFovDeg))*RADIANS165/2)
  // Stark hineingezoomt waere die Kamera sonst zu nah: Blickwinkel weiter verengen.
  if(distanceBase>0)start=Math.min(start,base*distanceBase/MIN_START_DISTANCE165)
  const k=Math.min(1,Math.max(0,s))
  const tangent=start+(base-start)*k
  return {fov:2*Math.atan(tangent)/RADIANS165,stretch:base/tangent}
}

/** Kamerapose zwischen Draufsicht (s=0) und freier 3D-Ansicht (s=1).
 * Die Kamera blickt in jedem Zwischenschritt genau auf den wandernden Blickpunkt. */
export function poseAt165(top:TopView165,orbit:OrbitView165,s:number,baseFovDeg:number,startFovDeg:number):Pose165{
  const k=Math.min(1,Math.max(0,s))
  const lens=lensAt165(baseFovDeg,startFovDeg,k,top.distanceBase)
  const pivot=top.pivot.clone().lerp(orbit.pivot,k)
  const quaternion=top.quaternion.clone().slerp(orbit.quaternion,k)
  const distance=(top.distanceBase+(orbit.distance-top.distanceBase)*k)*lens.stretch
  const forward=new THREE.Vector3(0,0,-1).applyQuaternion(quaternion)
  return {position:pivot.addScaledVector(forward,-distance),quaternion,fov:lens.fov,offsetFactor:1-k,distance}
}

/** Groesste Abweichung (CSS-Pixel) zwischen Blueprint und gezeichnetem 3D-Raster.
 * Geprueft werden Ursprung, 1 m, 5 m sowie Mitte und Ecken des sichtbaren Blueprints. */
export function gridErrorPx165(bp:BlueprintScreen165,viewport:Rect165,canvas:Rect165,
  grid:THREE.Matrix4,camera:THREE.Camera):{max:number;worst:PlanPoint165}|null{
  const samples:PlanPoint165[]=[{x:0,y:0},{x:1,y:0},{x:0,y:1},{x:5,y:0},{x:0,y:5}]
  for(const [fx,fy] of [[0.5,0.5],[0,0],[1,0],[0,1],[1,1]]){
    const plan=pixelToPlan165(bp,viewport.left+viewport.width*fx,viewport.top+viewport.height*fy)
    if(!plan)return null
    samples.push(plan)
  }
  let max=0,worst=samples[0]
  for(const sample of samples){
    const want=blueprintPixel165(bp,sample.x,sample.y)
    const have=worldToPixel165(planToWorld165(grid,sample.x,sample.y),camera,canvas)
    const error=Math.hypot(want.x-have.x,want.y-have.y)
    if(!Number.isFinite(error))return null
    if(error>max){max=error;worst=sample}
  }
  return {max,worst}
}
STROM165_TOP
cat > "$RESOURCE_DIR/cameraTransitions150.ts" <<'STROM165_BRIDGE'
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
/** STROM158_REVERSE_EXACT: fade starts after the reverse flight ends. */
export const EXIT_FADE158=500
/** STROM159_TIMINGS: reverse flight independently configurable from forward flight. */
export const EXIT_FLIGHT159=1000

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
STROM165_BRIDGE
cat > "$RESOURCE_DIR/CameraFlight150.tsx" <<'STROM165_FLIGHT'
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

/** STROM165_ONE_CAMERA_OWNER
 * Einziger Kameratreiber fuer Blueprint -> 3D -> Blueprint.
 *
 * Hinweg:  settle  (3D baut sich verdeckt auf, Standardansicht wird gemerkt)
 *          prepare (Draufsicht aus dem LIVE-Blueprint berechnen, zeichnen, nachmessen)
 *          fade    (Draufsicht steht still, Blueprint blendet aus)
 *          flight  (Flug zur Standardansicht, Ease-out)
 * Rueckweg: flight (Flug zur Draufsicht, Ease-out) -> hold (nachmessen, dann Blende)
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
const easeOut = (t: number) => 1 - (1 - t) ** 3

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
      // Laeuft der Hinflug noch, kehrt der Rueckflug an genau dieser Stelle um.
      let from = 1
      let target: OrbitState165 | null = null
      let top = savedTop.current
      if (active && active.kind === 'entry' && active.top && active.orbit && (active.phase === 'fade' || active.phase === 'flight')) {
        from = active.phase === 'fade' ? 0 : easeOut(clamp01((now - active.startedAt) / DURATION150))
        target = active.orbit
        top = active.top
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
        apply(camera, active.top, active.orbit, 0, grid)
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
      apply(camera, active.top, active.orbit, 0, grid)
      if (now >= active.startedAt) active.phase = 'flight'
      return
    }

    if (active.kind === 'entry') {
      const t = clamp01((now - active.startedAt) / DURATION150)
      if (t < 1) { apply(camera, active.top, active.orbit, easeOut(t), grid); return }
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
      const t = clamp01((now - active.startedAt) / EXIT_FLIGHT159)
      // Ease-out auch auf dem Rueckweg: schnell los, weich in die Draufsicht.
      apply(camera, active.top, active.orbit, active.from * (1 - easeOut(t)), grid)
      if (t >= 1) { active.phase = 'hold'; active.frames = 0; active.verified = 0 }
      else return
    }
    // hold / done: Draufsicht steht still, bis 3D ausgeblendet und entfernt ist.
    apply(camera, active.top, active.orbit, 0, grid)
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
STROM165_FLIGHT
cat > "$RESOURCE_DIR/test165.mjs" <<'STROM165_TEST'
// Regression 165. Laeuft mit dem echten three und den echten OrbitControls aus node_modules.
// Prueft (1) Quelltextstruktur, (2) die Geometrie der Draufsicht, (3) dass ungesperrte
// OrbitControls den Fehler erzeugen und gesperrte ihn beseitigen.
import fs from 'node:fs'
import path from 'node:path'
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'

const source = process.env.STROM165_SOURCE, modulesRaw = process.env.STROM165_MODULES
assert(source && modulesRaw, 'STROM165_SOURCE/STROM165_MODULES fehlen')
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
console.log('PASS 165: alle Pruefungen bestanden')
STROM165_TEST
cat > "$RESOURCE_DIR/STROM_UPDATE_165.md" <<'STROM165_DOC'
# Strom 165: ein Kameratreiber, Blueprint und 3D deckungsgleich

## Ursache des Versatzes (bis 164b)
`Building3DWorkspace.tsx` erzeugte die OrbitControls, meldete sie aber nie im
R3F-Store an. `CameraFlight150` fand sie deshalb nicht (`get().controls` war `null`)
und konnte sie nicht sperren. In jedem Frame lief nach dem Kameraflug noch
`controls.update()` und drehte die Kamera per `lookAt` auf die Hausmitte. Der Fehler
war null, wenn der Blueprint auf das Haus zentriert war, und wuchs mit Pan und Zoom.

## Aenderungen
- OrbitControls im R3F-Store angemeldet; waehrend Blende und Flug wirklich gesperrt.
- `CameraFlight150.tsx` neu: ein Treiber, ein `useFrame`, eine Kalibrierung.
  Die Kalibrierungen 150r, 154, 156, 164 und die Diagnosen 150q, 155, 158 sind entfernt,
  ebenso die unbenutzten Module 153 und 163.
- Die Draufsicht wird aus dem Blueprint berechnet, wie er im Moment der Blende im
  Browser steht (Live-Messung), nicht nur aus dem Schnappschuss beim Klick.
- Nachmessung nach dem Zeichnen (`scene.onAfterRender`) mit genau der Kamera, die
  gezeichnet hat. Die Blende startet erst nach zwei bestaetigten Bildern mit hoechstens
  1 CSS-Pixel Abweichung. Sonst Abbruch zurueck zum Blueprint mit Meldung (ca. 4 s statt 30 s).
- Blende mit fast parallelem Blickwinkel (hoechstens 2 Grad, mindestens 1000 m Abstand):
  auch Waende liegen auf ihren Blueprint-Linien. Im Flug oeffnet sich der Blickwinkel
  auf 48 Grad, der Bildmassstab der Rasterebene bleibt dabei stetig.
- Flug um einen wandernden Blickpunkt (Blueprint-Mitte -> Hausmitte), Ease-out.
  Rueckflug ebenfalls Ease-out, 1000 ms; Ziel ist der wieder eingeblendete Blueprint.
- Rueckweg mitten im Hinflug kehrt an der aktuellen Stelle um.
- Zeiten unveraendert: Hinblende 750 ms, Hinflug 2500 ms, Rueckflug 1000 ms, Rueckblende 500 ms.
- 3D-Ansicht und Three.js werden erst beim ersten Oeffnen geladen
  (Startpaket 435 kB statt 1470 kB).
- Klassische Wandansicht: der Blueprint-Zoom wird beim Verlassen exakt wiederhergestellt
  (vorher 0,9 x 1,1 = 0,99 je Durchgang, ueber "Zurueck zu Echtes 3D" blieb er bei 90 %).
- `package.json`: feste Versionen statt `latest` (identisch zu den gesperrten Versionen).
- `tools/strom_stage_promote_to_prod.sh`: bricht ab, wenn sich der Go-Quelltext in
  `backend/` zwischen Produktion und Stage unterscheidet.
- Backend-Quelltext der Produktion (u. a. `central_auth.go`) nach Stage und Git uebernommen,
  falls er dort fehlt. Es wird nichts gebaut und nichts an der Produktion veraendert.
- `db/live_schema_165.sql`: Schema der laufenden Datenbank (ohne Daten), falls lesbar.

## Pruefung
- Vor Auslieferung im echten Browser (Chromium) gegen genau dieses Bundle gemessen:
  Rasterabweichung 0 px auf Hin- und Rueckweg bei Zoom 22 % bis 1000 %, verschobenem
  Blueprint, Wanddetail, nach Drehen/Verschieben in 3D, DPR 1 / 1,25 / 2.
- Das Skript vergleicht den Fingerabdruck des gebauten Bundles mit dem geprueften Bundle
  und bricht vor Git-Push und Deployment ab, wenn er abweicht.
- Im Browser: Konsole `[STROM165]` bzw. `localStorage['strom.camera165.check']`.

## Nicht enthalten
Eigene Test-API und Test-Datenbank, Anmeldung an der API, Umzug der Browser-Speicher-Daten
in die Datenbank und das Aufteilen von `App.tsx`. Diese Punkte greifen in Produktion,
Datenbank oder nginx ein und gehoeren nicht in einen Frontend-Patch der Testumgebung.
Nur Testumgebung `/strom-test/`; Produktion `/strom/` unveraendert.
STROM165_DOC
log "3) Quelltext patchen (ein Kameratreiber, Controls angemeldet, Live-Abgleich) ..."
python3 -m py_compile "$RESOURCE_DIR/patch165.py" >>"$DIAG_LOG" 2>&1 || fail "165 Python patch syntax error"
STROM165_ROOT="$WORK_DIR" STROM165_RESOURCES="$RESOURCE_DIR" python3 "$RESOURCE_DIR/patch165.py" >>"$DIAG_LOG" 2>&1 || \
  fail "165 Ausgangsstand passt nicht; GitHub and Stage unchanged"
# Backend: die Produktion hat neueren Go-Quelltext (central_auth.go). Nur Quelltext, keine .env, kein Build.
if [ -f "$REAL_PROD_DIR/backend/internal/httpapi/central_auth.go" ] && [ -d "$WORK_DIR/backend" ] && \
   [ ! -f "$WORK_DIR/backend/internal/httpapi/central_auth.go" ]; then
  rsync -a -m --include='*/' --include='*.go' --include='go.mod' --include='go.sum' --exclude='*' \
    "$REAL_PROD_DIR/backend/" "$WORK_DIR/backend/" >>"$DIAG_LOG" 2>&1 || fail "165 Backend-Abgleich fehlgeschlagen"
  log "   Backend-Quelltext der Produktion nach Stage uebernommen (central_auth.go u. a.)."
else
  log "   Backend: kein Abgleich noetig."
fi
# Schema der laufenden Datenbank ins Repository (ohne Daten). Fehlschlag haelt das Update nicht auf.
if command -v pg_dump >/dev/null 2>&1 && [ -d "$WORK_DIR/db" ]; then
  SCHEMA_TMP165="$WORK_DIR/.schema165.tmp"
  if ( cd / && run_as_postgres pg_dump --schema-only --no-owner --no-privileges "$(db_name165)" ) >"$SCHEMA_TMP165" 2>>"$DIAG_LOG" && \
     [ -s "$SCHEMA_TMP165" ]; then
    {
      echo "-- STROM165: Schema der laufenden Datenbank (pg_dump --schema-only, ohne Daten)."
      echo "-- Enthaelt auch Tabellen und Spalten, die in schema.sql und migrations/ fehlen."
      grep -v -e '^\\restrict ' -e '^\\unrestrict ' -e '^-- Dumped ' "$SCHEMA_TMP165" || true
    } >"$WORK_DIR/db/live_schema_165.sql"
    log "   Datenbankschema gesichert: db/live_schema_165.sql"
  else
    log "   HINWEIS: Datenbankschema nicht lesbar; db/live_schema_165.sql wird nicht angelegt."
  fi
  rm -f "$SCHEMA_TMP165"
fi
log "4) Full TypeScript/Vite build BEFORE committing ..."
( cd "$WORK_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || \
  fail "165 TypeScript/Vite build failed; GitHub and Stage unchanged"
log "5) Regression: Quelltextstruktur, Geometrie, echte OrbitControls ..."
STROM165_SOURCE="$WORK_DIR/frontend/src" STROM165_MODULES="$DEPENDENCIES" \
  node "$RESOURCE_DIR/test165.mjs" >>"$DIAG_LOG" 2>&1 || \
  fail "165 Regression fehlgeschlagen; GitHub and Stage unchanged"
grep -F 'PASS 165' "$DIAG_LOG" | tail -n 3 || true
log "6) Bundle mit dem im Browser geprueften Bundle vergleichen ..."
check_bundle165 "$WORK_DIR/frontend/dist" "GitHub and Stage unchanged."
mkdir -p "$WORK_DIR/deploy/updates" "$WORK_DIR/docs"
cp -a "$RESOURCE_DIR/patch165.py" "$WORK_DIR/deploy/updates/${SCRIPT_NAME}_patch.py"
cp -a "$RESOURCE_DIR/STROM_UPDATE_165.md" "$WORK_DIR/docs/STROM_UPDATE_165.md"
rm -rf "$RESOURCE_DIR"
log "7) Synchronize verified source into Stage ..."
rsync -a --delete --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='.git' \
  "$WORK_DIR/" "$STAGE_DIR/" >>"$DIAG_LOG" 2>&1 || fail "165 Stage transfer failed; backup: $BACKUP_DIR"
if [ "${PATCH_ONLY:-0}" = "1" ]; then
  log "PASS PATCH_ONLY: no web deployment"
  exit 0
fi
log "8) Build Stage and deploy ONLY /strom-test/ ..."
( cd "$STAGE_DIR/frontend" && VITE_BASE=/strom-test/ npm run build ) >>"$DIAG_LOG" 2>&1 || \
  fail "165 Stage build failed; backup: $BACKUP_DIR"
[ -d "$STAGE_DIR/frontend/dist" ] || fail "165 frontend/dist missing"
check_bundle165 "$STAGE_DIR/frontend/dist" "Testseite unveraendert; Stage-Backup: $BACKUP_DIR."
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/" >>"$DIAG_LOG" 2>&1 || \
  fail "165 test deployment failed; backup: $BACKUP_DIR"
# Das Promote-Skript wird laut REFERENCE_MAP aus ~/deploy gestartet: dortige Kopie mit schuetzen.
PROMOTE_OLD165="71abd615549f18541fb747fa3e0882273e9fc96e99bcc9624aee4e9b7c2c6189"
if [ -f "$DEPLOY_DIR/strom_stage_promote_to_prod.sh" ] && [ -f "$STAGE_DIR/tools/strom_stage_promote_to_prod.sh" ]; then
  if [ "$(sha256sum "$DEPLOY_DIR/strom_stage_promote_to_prod.sh" | cut -d' ' -f1)" = "$PROMOTE_OLD165" ] && \
     grep -Fq 'STROM165_BACKEND_GUARD' "$STAGE_DIR/tools/strom_stage_promote_to_prod.sh"; then
    cp -p "$STAGE_DIR/tools/strom_stage_promote_to_prod.sh" "$DEPLOY_DIR/strom_stage_promote_to_prod.sh" 2>>"$DIAG_LOG" && \
      log "   ~/deploy/strom_stage_promote_to_prod.sh: Backend-Schutz eingebaut." || \
      log "   HINWEIS: ~/deploy/strom_stage_promote_to_prod.sh konnte nicht aktualisiert werden."
  else
    log "   HINWEIS: ~/deploy/strom_stage_promote_to_prod.sh weicht vom bekannten Stand ab; nicht angefasst."
  fi
fi
log "SUCCESS: 165 deployed at https://home.moja.de/strom-test/"
log "Production /strom/ unchanged. Stage backup: $BACKUP_DIR"
log "Browser: Konsole [STROM165] bzw. localStorage['strom.camera165.check'] zeigt die gemessene Rasterabweichung."
