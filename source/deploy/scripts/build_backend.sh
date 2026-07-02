#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../../backend"
go mod tidy
go build -o /tmp/strom-api ./cmd/strom-server
sudo install -o strom -g strom -m 0755 /tmp/strom-api /opt/strom/strom-api
sudo install -o root -g root -m 0644 ../deploy/systemd/strom-api.service /etc/systemd/system/strom-api.service
sudo systemctl daemon-reload
sudo systemctl enable --now strom-api.service
sudo systemctl status strom-api.service --no-pager
