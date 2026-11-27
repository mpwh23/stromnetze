#!/usr/bin/env python3
"""Update 177: Tueren und Fenster im Blueprint als Haarlinien, Masse dezent wie die Bemassung."""
import hashlib, os, pathlib

root = pathlib.Path(os.environ['STROM177_ROOT']) / 'frontend'
css_path = root / 'src/styles.css'
have = hashlib.sha256(css_path.read_bytes()).hexdigest()
if have != 'e04f4571253a72173a6212b89be034822b30d653c38a95cf7f4c2ae134868468':
    raise RuntimeError(f'177: styles.css entspricht nicht Stand 176 ({have})')
css = css_path.read_text(encoding='utf-8')
if 'STROM177_' in css:
    raise RuntimeError('177: bereits installiert')
CSS = """
/* STROM177_HAIRLINES: Tueren und Fenster als Haarlinien (wie Bemassungslinien, zoomunabhaengig),
   Masse dezent: kleiner, duenn, leicht transparent. */
.blueprint-openings176 .blueprint-door176 polygon.blueprint-wall-connection-door { fill: rgba(180, 83, 9, 0.07); stroke: #b45309; stroke-width: 0.75px; vector-effect: non-scaling-stroke; }
.blueprint-openings176 .blueprint-door176 .blueprint-wall-door-edge { stroke: #b45309; stroke-width: 0.75px; vector-effect: non-scaling-stroke; }
.blueprint-openings176 .blueprint-window176 line.blueprint-window-jamb176,
.blueprint-openings176 .blueprint-window176 line.blueprint-window-glass176 { stroke: #b45309; stroke-width: 0.75px; vector-effect: non-scaling-stroke; }
.blueprint-openings176 .blueprint-window176 polygon.blueprint-window-cut176 { fill: rgba(255, 250, 243, 0.9); }
.blueprint-openings176 .blueprint-opening-dims176 { fill: #b45309; opacity: 0.8; font-weight: 500;
  font-size: calc(var(--floorplan-small-text-size, 12.8px) * 0.9) !important; letter-spacing: 0.01em;
  stroke: rgba(255, 255, 255, 0.9); stroke-width: calc(var(--floorplan-label-stroke, 4.4px) * 0.45); }
"""
css_path.write_text(css.rstrip('\n') + '\n' + CSS, encoding='utf-8')
print('177: Quelltext gepatcht')
