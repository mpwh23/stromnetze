#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT_DIR="/home/mpwh/strom"
STAGE_DIR="/home/mpwh/strom_stage"
WEB_DIR="/var/www/strom"
STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="/home/mpwh/strom_backups/stage_promote_${STAMP}"
run_sudo() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi; }
[ -d "$STAGE_DIR/frontend" ] || { echo "Stage fehlt: $STAGE_DIR" >&2; exit 1; }
mkdir -p "$BACKUP_DIR"
rsync -a --delete --exclude 'frontend/node_modules' --exclude 'frontend/dist' "$PROJECT_DIR/" "$BACKUP_DIR/project/"
run_sudo rsync -a --delete "$WEB_DIR/" "$BACKUP_DIR/web/" || true
if [ ! -d "$STAGE_DIR/frontend/node_modules" ]; then
  if [ -d "$PROJECT_DIR/frontend/node_modules" ]; then ln -s "$PROJECT_DIR/frontend/node_modules" "$STAGE_DIR/frontend/node_modules"; else (cd "$STAGE_DIR/frontend" && npm ci --no-audit --no-fund); fi
fi
cd "$STAGE_DIR/frontend"
VITE_BASE=/strom/ npm run build
rsync -a --delete --exclude 'frontend/node_modules' --exclude 'frontend/dist' "$STAGE_DIR/" "$PROJECT_DIR/"
if [ -d "$PROJECT_DIR/frontend/node_modules" ] && [ ! -e "$STAGE_DIR/frontend/node_modules" ]; then ln -s "$PROJECT_DIR/frontend/node_modules" "$STAGE_DIR/frontend/node_modules"; fi
run_sudo mkdir -p "$WEB_DIR"
run_sudo rsync -a --delete "$STAGE_DIR/frontend/dist/" "$WEB_DIR/"
run_sudo nginx -t
run_sudo systemctl reload nginx || run_sudo nginx -s reload
curl -fsS http://127.0.0.1:8088/api/health >/dev/null || true
echo "Stage wurde nach Produktion uebernommen. Backup: $BACKUP_DIR"
