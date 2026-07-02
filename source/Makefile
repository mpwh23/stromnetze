.PHONY: backend frontend db zip

backend:
	cd backend && go mod tidy && go run ./cmd/strom-server

frontend:
	cd frontend && npm install && npm run dev -- --host 0.0.0.0

db:
	sudo -u postgres psql -d strom -f db/schema.sql
	sudo -u postgres psql -d strom -f db/seed.sql

zip:
	cd .. && zip -r strom.zip strom
