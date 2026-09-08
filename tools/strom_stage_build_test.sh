#!/usr/bin/env bash
set -Eeuo pipefail
STAGE_DIR="/home/mpwh/strom_stage"
WEB_TEST_DIR="/var/www/strom-test"
run_sudo() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi; }
[ -d "$STAGE_DIR/frontend" ] || { echo "Stage fehlt: $STAGE_DIR" >&2; exit 1; }
if [ ! -d "$STAGE_DIR/frontend/node_modules" ]; then
  if [ -d /home/mpwh/strom/frontend/node_modules ]; then ln -s /home/mpwh/strom/frontend/node_modules "$STAGE_DIR/frontend/node_modules"; else (cd "$STAGE_DIR/frontend" && npm ci --no-audit --no-fund); fi
fi
cd "$STAGE_DIR/frontend"
VITE_BASE=/strom-test/ npm run build
run_sudo mkdir -p "$WEB_TEST_DIR"
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/"
echo "Stage-Build erfolgreich: /strom-test/"
