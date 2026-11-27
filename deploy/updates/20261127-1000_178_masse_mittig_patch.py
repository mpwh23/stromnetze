#!/usr/bin/env python3
"""Update 178: Masse von Tueren und Fenstern mittig in der Oeffnung."""
import hashlib, os, pathlib

root = pathlib.Path(os.environ['STROM178_ROOT']) / 'frontend'
app_path = root / 'src/App.tsx'
have = hashlib.sha256(app_path.read_bytes()).hexdigest()
if have != 'ba3852faba4fad3bc6a69565279d4ec96caaaf3919d44c176f62c1b29e063cc7':
    raise RuntimeError(f'178: App.tsx entspricht nicht Stand 177 ({have})')
app = app_path.read_text(encoding='utf-8')
if 'STROM178_' in app:
    raise RuntimeError('178: bereits installiert')
old = "        const labelAt = { x: inner.x + nx * 0.2, y: inner.y + ny * 0.2 }\n"
new = ("        // STROM178_LABEL_CENTER: Masse mittig in der Tuer bzw. im Fenster (Mitte zwischen beiden Wandseiten).\n"
       "        void nx; void ny\n"
       "        const labelAt = mid(midA, midB)\n")
if app.count(old) != 1:
    raise RuntimeError('178: Beschriftungsposition nicht gefunden')
app_path.write_text(app.replace(old, new), encoding='utf-8')
print('178: Quelltext gepatcht')
