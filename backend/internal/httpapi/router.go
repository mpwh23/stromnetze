package httpapi

import (
	"net/http"

	"strom/backend/internal/database"
)

type API struct {
	db *database.DB
}

func New(db *database.DB) *API {
	return &API{db: db}
}

func (api *API) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/health", method(http.MethodGet, api.health))
	mux.HandleFunc("/api/overview", method(http.MethodGet, api.overview))
	mux.HandleFunc("/api/users", api.users)
	mux.HandleFunc("/api/users/login", method(http.MethodPost, api.userLogin))
	mux.HandleFunc("/api/users/by-name", method(http.MethodGet, api.userByName))
	mux.HandleFunc("/api/settings/public", method(http.MethodGet, api.publicSettings))
	mux.HandleFunc("/api/admin/users", api.adminUsers)
	mux.HandleFunc("/api/admin/settings", api.adminSettings)
	mux.HandleFunc("/api/admin/password", method(http.MethodPut, api.adminPassword))
	mux.HandleFunc("/api/objects", api.userObjects)
	mux.HandleFunc("/api/floors/default", method(http.MethodGet, api.defaultFloor))
	mux.HandleFunc("/api/rooms", api.rooms)
	mux.HandleFunc("/api/openings", api.openings)
	mux.HandleFunc("/api/wall-objects", api.wallObjects)
	return cors(jsonContentType(mux))
}

func method(allowed string, handler http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != allowed {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		handler(w, r)
	}
}

func jsonContentType(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if len(r.URL.Path) >= 5 && r.URL.Path[:5] == "/api/" {
			w.Header().Set("Content-Type", "application/json; charset=utf-8")
		}
		next.ServeHTTP(w, r)
	})
}

func cors(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
		w.Header().Set("Access-Control-Allow-Methods", "GET,POST,PUT,PATCH,DELETE,OPTIONS")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

