# strom

Browser-Anwendung zur Dokumentation und Darstellung des Stromnetzwerks eines Hauses.

Zielstruktur:

- Backend: Go API auf `127.0.0.1:8088`
- Frontend: React/Vite, gebaut fuer den Unterpfad `/strom/`
- Datenbank: PostgreSQL + PostGIS
- Reverse Proxy: nginx unter `https://home.moja.de/strom/`

## Ordner

```text
strom/
  backend/     Go API
  frontend/    React/Vite Browser-App
  db/          PostgreSQL/PostGIS Schema und Seed
  deploy/      nginx, systemd und Install-Skripte fuer den Pi
```

## Ziel-URL

```text
https://home.moja.de/strom/
https://home.moja.de/strom/api/health
```

## Lokale Entwicklung auf dem Pi

### 1. Datenbank vorbereiten

```bash
sudo -u postgres createdb strom
sudo -u postgres createuser strom_app
sudo -u postgres psql -d strom -c "ALTER USER strom_app WITH PASSWORD 'change_me';"
sudo -u postgres psql -d strom -c "GRANT ALL PRIVILEGES ON DATABASE strom TO strom_app;"
sudo -u postgres psql -d strom -f db/schema.sql
sudo -u postgres psql -d strom -f db/seed.sql
```

### 2. Backend starten

```bash
cd backend
cp ../.env.example .env
export $(grep -v '^#' .env | xargs)
go mod tidy
go run ./cmd/strom-server
```

Test:

```bash
curl http://127.0.0.1:8088/api/health
```

### 3. Frontend starten

```bash
cd frontend
npm install
npm run dev -- --host 0.0.0.0
```

### 4. Produktiv bauen

```bash
cd frontend
npm install
npm run build
sudo mkdir -p /var/www/strom
sudo rsync -a --delete dist/ /var/www/strom/
```

## Deployment auf home.moja.de/strom

1. Backend-Binary nach `/opt/strom/strom-api` kopieren.
2. Environment-Datei nach `/etc/strom/strom.env` legen.
3. systemd-Service aus `deploy/systemd/strom-api.service` installieren.
4. nginx-Snippet aus `deploy/nginx/strom.conf` in die bestehende nginx-Site von `home.moja.de` einbinden.
5. nginx neu laden: `sudo systemctl reload nginx`.

## Wichtig

Diese Anwendung ist fuer Dokumentation und Planung gedacht. Sie ersetzt keine Pruefung nach VDE/Normen und keine Arbeit durch eine Elektrofachkraft.
