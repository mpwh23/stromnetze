#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../../frontend"
npm install
npm run build
sudo mkdir -p /var/www/strom
sudo rsync -a --delete dist/ /var/www/strom/
sudo chown -R www-data:www-data /var/www/strom
