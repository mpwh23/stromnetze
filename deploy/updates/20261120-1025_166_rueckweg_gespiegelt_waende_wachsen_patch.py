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
