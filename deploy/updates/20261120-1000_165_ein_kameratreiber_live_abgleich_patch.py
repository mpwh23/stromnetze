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
