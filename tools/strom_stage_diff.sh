#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT_DIR="/home/mpwh/strom"
STAGE_DIR="/home/mpwh/strom_stage"
OUT="/home/mpwh/deploy/strom_stage_diff_$(date +%Y%m%d_%H%M%S).diff"
diff -ruN --exclude node_modules --exclude dist --exclude .git "$PROJECT_DIR" "$STAGE_DIR" > "$OUT" || true
echo "Diff gespeichert: $OUT"
