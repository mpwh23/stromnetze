#!/usr/bin/env bash
set -euo pipefail

APP_USER="strom"
APP_DIR="/opt/strom"
WEB_DIR="/var/www/strom"
ENV_DIR="/etc/strom"
DB_NAME="strom"
DB_USER="strom_app"
DB_PASS="${DB_PASS:-$(openssl rand -hex 24)}"

sudo apt update
sudo apt install -y nginx postgresql postgresql-contrib postgis golang-go nodejs npm rsync curl ca-certificates build-essential

POSTGIS_PKG=""
for candidate in postgresql-17-postgis-3 postgresql-16-postgis-3 postgresql-15-postgis-3 postgresql-14-postgis-3; do
  if apt-cache show "$candidate" >/dev/null 2>&1; then
    POSTGIS_PKG="$candidate"
    break
  fi
done
if [ -n "$POSTGIS_PKG" ]; then
  sudo apt install -y "$POSTGIS_PKG"
fi

if ! id "${APP_USER}" >/dev/null 2>&1; then
  sudo useradd --system --home "${APP_DIR}" --shell /usr/sbin/nologin "${APP_USER}"
fi

sudo mkdir -p "${APP_DIR}" "${WEB_DIR}" "${ENV_DIR}" /var/lib/strom
sudo chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}" /var/lib/strom
sudo chown -R www-data:www-data "${WEB_DIR}"

sudo -u postgres psql <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_USER}') THEN
    CREATE ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASS}';
  ELSE
    ALTER ROLE ${DB_USER} WITH PASSWORD '${DB_PASS}';
  END IF;
END
\$\$;
SQL

sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1 || sudo -u postgres createdb "${DB_NAME}"
sudo -u postgres psql -d "${DB_NAME}" -c "GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};"
sudo -u postgres psql -d "${DB_NAME}" -c "GRANT USAGE, CREATE ON SCHEMA public TO ${DB_USER};"

sudo tee "${ENV_DIR}/strom.env" >/dev/null <<ENV
STROM_ADDR=127.0.0.1:8088
STROM_PUBLIC_BASE_PATH=/strom
DATABASE_URL=postgres://${DB_USER}:${DB_PASS}@127.0.0.1:5432/${DB_NAME}?sslmode=disable
ENV
sudo chmod 640 "${ENV_DIR}/strom.env"
sudo chown root:"${APP_USER}" "${ENV_DIR}/strom.env"

echo "Installation vorbereitet. Passwort wurde in ${ENV_DIR}/strom.env gespeichert."
echo "Naechster Schritt: bash deploy/scripts/apply_db.sh"
