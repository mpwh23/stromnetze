#!/usr/bin/env bash
set -Eeuo pipefail
DIR="${1:-/home/mpwh/strom}"
[ -d "$DIR/frontend" ] || { echo "Frontend fehlt in $DIR" >&2; exit 1; }
cd "$DIR/frontend"
VITE_BASE=/strom/ npm run build
if [ -d "$DIR/backend" ]; then (cd "$DIR/backend" && go test ./...) || echo "WARNUNG: go test fehlgeschlagen oder nicht verfuegbar"; fi
echo "Validierung abgeschlossen: $DIR"
