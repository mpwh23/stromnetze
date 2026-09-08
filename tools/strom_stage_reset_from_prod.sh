#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT_DIR="/home/mpwh/strom"
STAGE_DIR="/home/mpwh/strom_stage"
WEB_TEST_DIR="/var/www/strom-test"
STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="/home/mpwh/strom_backups/stage_reset_${STAMP}"
run_sudo() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi; }
mkdir -p "$BACKUP_DIR"
[ -d "$STAGE_DIR" ] && rsync -a --delete --exclude 'frontend/node_modules' --exclude 'frontend/dist' "$STAGE_DIR/" "$BACKUP_DIR/stage/" || true
rsync -a --delete --exclude 'frontend/node_modules' --exclude 'frontend/dist' "$PROJECT_DIR/" "$STAGE_DIR/"
if [ -d "$PROJECT_DIR/frontend/node_modules" ] && [ ! -e "$STAGE_DIR/frontend/node_modules" ]; then ln -s "$PROJECT_DIR/frontend/node_modules" "$STAGE_DIR/frontend/node_modules"; fi
cd "$STAGE_DIR/frontend"
if [ ! -d node_modules ]; then npm ci --no-audit --no-fund; fi
VITE_BASE=/strom-test/ npm run build
run_sudo mkdir -p "$WEB_TEST_DIR"
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_TEST_DIR/"
echo "Stage wurde aus Produktion neu aufgebaut und nach /strom-test/ deployed. Backup: $BACKUP_DIR"
