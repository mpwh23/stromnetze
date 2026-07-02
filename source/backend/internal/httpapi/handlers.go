package httpapi

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"strconv"
	"strings"

	"strom/backend/internal/model"
)

func (api *API) health(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, model.HealthResponse{OK: true, Service: "strom-api"})
}

func (api *API) overview(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	objectID := strings.TrimSpace(r.URL.Query().Get("objectId"))
	overview := model.AppOverview{}

	if err := api.db.Pool.QueryRow(ctx, "SELECT count(*) FROM app_users").Scan(&overview.Users); err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	if err := api.db.Pool.QueryRow(ctx, "SELECT count(*) FROM user_objects").Scan(&overview.Objects); err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}

	if objectID == "" {
		counts := []struct {
			table string
			dest  *int
		}{
			{"houses", &overview.Houses},
			{"floors", &overview.Floors},
			{"rooms", &overview.Rooms},
			{"devices", &overview.Devices},
			{"cables", &overview.Cables},
			{"circuits", &overview.Circuits},
		}
		for _, item := range counts {
			if err := api.db.Pool.QueryRow(ctx, "SELECT count(*) FROM "+item.table).Scan(item.dest); err != nil {
				writeError(w, http.StatusInternalServerError, err)
				return
			}
		}
		writeJSON(w, http.StatusOK, overview)
		return
	}

	queries := []struct {
		sql  string
		dest *int
	}{
		{"SELECT count(*) FROM houses h JOIN projects p ON p.id = h.project_id WHERE p.object_id = $1", &overview.Houses},
		{"SELECT count(*) FROM floors f JOIN houses h ON h.id = f.house_id JOIN projects p ON p.id = h.project_id WHERE p.object_id = $1", &overview.Floors},
		{"SELECT count(*) FROM rooms r JOIN floors f ON f.id = r.floor_id JOIN houses h ON h.id = f.house_id JOIN projects p ON p.id = h.project_id WHERE p.object_id = $1", &overview.Rooms},
		{"SELECT count(*) FROM devices d JOIN floors f ON f.id = d.floor_id JOIN houses h ON h.id = f.house_id JOIN projects p ON p.id = h.project_id WHERE p.object_id = $1", &overview.Devices},
		{"SELECT count(*) FROM cables c JOIN projects p ON p.id = c.project_id WHERE p.object_id = $1", &overview.Cables},
		{"SELECT count(*) FROM circuits c JOIN distribution_boards b ON b.id = c.board_id JOIN floors f ON f.id = b.floor_id JOIN houses h ON h.id = f.house_id JOIN projects p ON p.id = h.project_id WHERE p.object_id = $1", &overview.Circuits},
	}
	for _, query := range queries {
		if err := api.db.Pool.QueryRow(ctx, query.sql, objectID).Scan(query.dest); err != nil {
			writeError(w, http.StatusInternalServerError, err)
			return
		}
	}
	writeJSON(w, http.StatusOK, overview)
}

func (api *API) users(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		api.listUsers(w, r)
	case http.MethodPost:
		api.createUser(w, r)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (api *API) listUsers(w http.ResponseWriter, r *http.Request) {
    if api.adminpanel != nil {
        if err := api.syncCentralUsersForList(r.Context()); err != nil {
            writeError(w, http.StatusInternalServerError, err)
            return
        }
    }

    rows, err := api.db.Pool.Query(r.Context(), `
        SELECT id::text, name, COALESCE(is_admin, false), COALESCE(can_view_all_objects, false), COALESCE(in_list, false), created_at
        FROM app_users
        WHERE COALESCE(in_list, false) = true
        ORDER BY lower(name), created_at
    `)
    if err != nil {
        writeError(w, http.StatusInternalServerError, err)
        return
    }
    defer rows.Close()

    users := []model.AppUser{}
    for rows.Next() {
        var user model.AppUser
        if err := rows.Scan(&user.ID, &user.Name, &user.IsAdmin, &user.CanViewAllObjects, &user.InList, &user.CreatedAt); err != nil {
            writeError(w, http.StatusInternalServerError, err)
            return
        }
        users = append(users, user)
    }
    if err := rows.Err(); err != nil {
        writeError(w, http.StatusInternalServerError, err)
        return
    }
    writeJSON(w, http.StatusOK, users)
}


func (api *API) createUser(w http.ResponseWriter, r *http.Request) {
    if !api.getBoolSetting(r.Context(), "accept_new_user", true) {
        writeError(w, http.StatusForbidden, errors.New("new users are currently disabled"))
        return
    }
    var req model.CreateUserRequest
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        writeError(w, http.StatusBadRequest, err)
        return
    }
    req.Name = strings.TrimSpace(req.Name)
    if req.Name == "" {
        writeError(w, http.StatusBadRequest, errors.New("user name is required"))
        return
    }
    if strings.TrimSpace(req.Password) == "" {
        writeError(w, http.StatusBadRequest, errors.New("password is required"))
        return
    }

    if api.adminpanel != nil {
        ident, err := api.createCentralUserWithAccess(r.Context(), req.Name, req.Password)
        if err != nil {
            writeError(w, http.StatusConflict, err)
            return
        }
        user, err := api.ensureLocalUserForCentral(r.Context(), ident, true)
        if err != nil {
            writeError(w, http.StatusInternalServerError, err)
            return
        }
        writeJSON(w, http.StatusCreated, user)
        return
    }

    var user model.AppUser
    err := api.db.Pool.QueryRow(r.Context(), `
        INSERT INTO app_users (name, password_hash, in_list)
        VALUES ($1, crypt($2, gen_salt('bf')), true)
        RETURNING id::text, name, COALESCE(is_admin, false), COALESCE(can_view_all_objects, false), COALESCE(in_list, false), created_at
    `, req.Name, req.Password).Scan(&user.ID, &user.Name, &user.IsAdmin, &user.CanViewAllObjects, &user.InList, &user.CreatedAt)
    if err != nil {
        writeError(w, http.StatusInternalServerError, err)
        return
    }
    writeJSON(w, http.StatusCreated, user)
}


func (api *API) userLogin(w http.ResponseWriter, r *http.Request) {
    var req model.LoginUserRequest
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        writeError(w, http.StatusBadRequest, err)
        return
    }
    req.UserID = strings.TrimSpace(req.UserID)
    if req.UserID == "" {
        writeError(w, http.StatusBadRequest, errors.New("userId is required"))
        return
    }

    if api.adminpanel != nil {
        centralID, localName, err := api.localUserCentralID(r.Context(), req.UserID)
        if err != nil {
            if isNoRows(err) {
                writeError(w, http.StatusUnauthorized, errors.New("invalid login"))
                return
            }
            writeError(w, http.StatusInternalServerError, err)
            return
        }

        var ident centralIdentity
        var found bool
        if centralID > 0 {
            ident, found, err = api.fetchCentralIdentityByID(r.Context(), centralID)
        } else {
            ident, found, err = api.fetchCentralIdentityByUsername(r.Context(), localName)
        }
        if err != nil {
            writeError(w, http.StatusInternalServerError, err)
            return
        }
        if !found || !ident.HasAccess || !verifyCentralPassword(ident.PasswordHash, req.Password) {
            writeError(w, http.StatusUnauthorized, errors.New("invalid central login or missing strom access"))
            return
        }

        user, err := api.ensureLocalUserForCentral(r.Context(), ident, true)
        if err != nil {
            writeError(w, http.StatusInternalServerError, err)
            return
        }
        writeJSON(w, http.StatusOK, user)
        return
    }

    var user model.AppUser
    var ok bool
    err := api.db.Pool.QueryRow(r.Context(), `
        SELECT id::text, name, COALESCE(is_admin, false), COALESCE(can_view_all_objects, false), COALESCE(in_list, false), created_at,
               CASE WHEN password_hash IS NULL OR password_hash = '' THEN true ELSE password_hash = crypt($2, password_hash) END AS ok
        FROM app_users
        WHERE id = $1
    `, req.UserID, req.Password).Scan(&user.ID, &user.Name, &user.IsAdmin, &user.CanViewAllObjects, &user.InList, &user.CreatedAt, &ok)
    if err != nil {
        if isNoRows(err) {
            writeError(w, http.StatusUnauthorized, errors.New("invalid login"))
            return
        }
        writeError(w, http.StatusInternalServerError, err)
        return
    }
    if !ok {
        writeError(w, http.StatusUnauthorized, errors.New("invalid password"))
        return
    }
    writeJSON(w, http.StatusOK, user)
}


func (api *API) userByName(w http.ResponseWriter, r *http.Request) {
    name := strings.TrimSpace(r.URL.Query().Get("name"))
    if name == "" {
        writeError(w, http.StatusBadRequest, errors.New("name query parameter is required"))
        return
    }

    if api.adminpanel != nil {
        ident, found, err := api.fetchCentralIdentityByUsername(r.Context(), name)
        if err != nil {
            writeError(w, http.StatusInternalServerError, err)
            return
        }
        if !found || !ident.HasAccess {
            writeError(w, http.StatusNotFound, errors.New("central user not found or not allowed for strom"))
            return
        }
        user, err := api.ensureLocalUserForCentral(r.Context(), ident, true)
        if err != nil {
            writeError(w, http.StatusInternalServerError, err)
            return
        }
        writeJSON(w, http.StatusOK, user)
        return
    }

    var user model.AppUser
    err := api.db.Pool.QueryRow(r.Context(), `
        SELECT id::text, name, COALESCE(is_admin, false), COALESCE(can_view_all_objects, false), COALESCE(in_list, false), created_at
        FROM app_users
        WHERE lower(name) = lower($1)
        ORDER BY created_at
        LIMIT 1
    `, name).Scan(&user.ID, &user.Name, &user.IsAdmin, &user.CanViewAllObjects, &user.InList, &user.CreatedAt)
    if err != nil {
        if isNoRows(err) {
            writeError(w, http.StatusNotFound, errors.New("user not found"))
            return
        }
        writeError(w, http.StatusInternalServerError, err)
        return
    }
    writeJSON(w, http.StatusOK, user)
}


func (api *API) adminUsers(w http.ResponseWriter, r *http.Request) {
	if !api.validateAdminPassword(r.Context(), r.URL.Query().Get("password")) {
		writeError(w, http.StatusUnauthorized, errors.New("invalid admin password"))
		return
	}
	switch r.Method {
	case http.MethodGet:
		api.listAdminUsers(w, r)
	case http.MethodPut:
		api.updateAdminUser(w, r)
	case http.MethodDelete:
		api.deleteAdminUser(w, r)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}


func (api *API) listAdminUsers(w http.ResponseWriter, r *http.Request) {
    if api.adminpanel != nil {
        identities, err := api.fetchCentralUsers(r.Context(), false)
        if err != nil {
            writeError(w, http.StatusInternalServerError, err)
            return
        }
        users := []model.AppUser{}
        for _, ident := range identities {
            user, err := api.ensureLocalUserForCentral(r.Context(), ident, ident.HasAccess)
            if err != nil {
                writeError(w, http.StatusInternalServerError, err)
                return
            }
            users = append(users, user)
        }
        writeJSON(w, http.StatusOK, users)
        return
    }

    rows, err := api.db.Pool.Query(r.Context(), `
        SELECT id::text, name, COALESCE(is_admin, false), COALESCE(can_view_all_objects, false), COALESCE(in_list, false), created_at
        FROM app_users
        ORDER BY lower(name), created_at
    `)
    if err != nil {
        writeError(w, http.StatusInternalServerError, err)
        return
    }
    defer rows.Close()
    users := []model.AppUser{}
    for rows.Next() {
        var user model.AppUser
        if err := rows.Scan(&user.ID, &user.Name, &user.IsAdmin, &user.CanViewAllObjects, &user.InList, &user.CreatedAt); err != nil {
            writeError(w, http.StatusInternalServerError, err)
            return
        }
        users = append(users, user)
    }
    if err := rows.Err(); err != nil {
        writeError(w, http.StatusInternalServerError, err)
        return
    }
    writeJSON(w, http.StatusOK, users)
}


func (api *API) updateAdminUser(w http.ResponseWriter, r *http.Request) {
    id := strings.TrimSpace(r.URL.Query().Get("id"))
    if id == "" {
        writeError(w, http.StatusBadRequest, errors.New("id query parameter is required"))
        return
    }
    var req model.AdminUserUpdateRequest
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        writeError(w, http.StatusBadRequest, err)
        return
    }

    if api.adminpanel != nil {
        centralID, localName, err := api.localUserCentralID(r.Context(), id)
        if err != nil {
            if isNoRows(err) {
                writeError(w, http.StatusNotFound, errors.New("user not found"))
                return
            }
            writeError(w, http.StatusInternalServerError, err)
            return
        }
        if centralID <= 0 {
            ident, found, err := api.fetchCentralIdentityByUsername(r.Context(), localName)
            if err != nil {
                writeError(w, http.StatusInternalServerError, err)
                return
            }
            if !found {
                writeError(w, http.StatusBadRequest, errors.New("local user has no central mapping"))
                return
            }
            centralID = ident.AdminUserID
        }

        if req.Name != nil && strings.TrimSpace(*req.Name) != "" {
            _, err = api.adminpanel.ExecContext(r.Context(), "UPDATE admin_users SET username = ?, display_name = ? WHERE id = ?", strings.TrimSpace(*req.Name), strings.TrimSpace(*req.Name), centralID)
            if err != nil {
                writeError(w, http.StatusInternalServerError, err)
                return
            }
        }

        roleKey := "user"
        canViewAll := false
        if req.CanViewAllObjects != nil {
            canViewAll = *req.CanViewAllObjects
        } else {
            _ = api.db.Pool.QueryRow(r.Context(), "SELECT COALESCE(can_view_all_objects,false) FROM app_users WHERE id = $1", id).Scan(&canViewAll)
        }
        if canViewAll {
            roleKey = "admin"
        }
        canAccess := true
        if req.InList != nil {
            canAccess = *req.InList
        } else {
            _ = api.db.Pool.QueryRow(r.Context(), "SELECT COALESCE(in_list,false) FROM app_users WHERE id = $1", id).Scan(&canAccess)
        }
        if err := api.setCentralAccess(r.Context(), centralID, canAccess, roleKey); err != nil {
            writeError(w, http.StatusInternalServerError, err)
            return
        }

        ident, found, err := api.fetchCentralIdentityByID(r.Context(), centralID)
        if err != nil || !found {
            writeError(w, http.StatusInternalServerError, errors.New("central user not readable after update"))
            return
        }
        user, err := api.ensureLocalUserForCentral(r.Context(), ident, canAccess)
        if err != nil {
            writeError(w, http.StatusInternalServerError, err)
            return
        }
        writeJSON(w, http.StatusOK, user)
        return
    }

    var user model.AppUser
    err := api.db.Pool.QueryRow(r.Context(), `
        UPDATE app_users
        SET name = CASE WHEN $2::text IS NULL OR btrim($2::text) = '' THEN name ELSE btrim($2::text) END,
            can_view_all_objects = COALESCE($3, can_view_all_objects),
            in_list = COALESCE($4, in_list)
        WHERE id = $1
        RETURNING id::text, name, COALESCE(is_admin, false), COALESCE(can_view_all_objects, false), COALESCE(in_list, false), created_at
    `, id, req.Name, req.CanViewAllObjects, req.InList).Scan(&user.ID, &user.Name, &user.IsAdmin, &user.CanViewAllObjects, &user.InList, &user.CreatedAt)
    if err != nil {
        if isNoRows(err) {
            writeError(w, http.StatusNotFound, errors.New("user not found"))
            return
        }
        writeError(w, http.StatusInternalServerError, err)
        return
    }
    writeJSON(w, http.StatusOK, user)
}


func (api *API) deleteAdminUser(w http.ResponseWriter, r *http.Request) {
    id := strings.TrimSpace(r.URL.Query().Get("id"))
    if id == "" {
        writeError(w, http.StatusBadRequest, errors.New("id query parameter is required"))
        return
    }

    if api.adminpanel != nil {
        centralID, _, err := api.localUserCentralID(r.Context(), id)
        if err != nil {
            if isNoRows(err) {
                writeError(w, http.StatusNotFound, errors.New("user not found"))
                return
            }
            writeError(w, http.StatusInternalServerError, err)
            return
        }
        if centralID > 0 {
            if err := api.setCentralAccess(r.Context(), centralID, false, "user"); err != nil {
                writeError(w, http.StatusInternalServerError, err)
                return
            }
        }
        if _, err := api.db.Pool.Exec(r.Context(), "UPDATE app_users SET in_list = false, is_admin = false, can_view_all_objects = false WHERE id = $1", id); err != nil {
            writeError(w, http.StatusInternalServerError, err)
            return
        }
        writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
        return
    }

    var isAdmin bool
    if err := api.db.Pool.QueryRow(r.Context(), "SELECT COALESCE(is_admin, false) FROM app_users WHERE id = $1", id).Scan(&isAdmin); err != nil {
        if isNoRows(err) {
            writeError(w, http.StatusNotFound, errors.New("user not found"))
            return
        }
        writeError(w, http.StatusInternalServerError, err)
        return
    }
    if isAdmin {
        var adminCount int
        if err := api.db.Pool.QueryRow(r.Context(), "SELECT count(*) FROM app_users WHERE COALESCE(is_admin, false) = true").Scan(&adminCount); err != nil {
            writeError(w, http.StatusInternalServerError, err)
            return
        }
        if adminCount <= 1 {
            writeError(w, http.StatusBadRequest, errors.New("last admin user cannot be deleted"))
            return
        }
    }
    if _, err := api.db.Pool.Exec(r.Context(), "DELETE FROM app_users WHERE id = $1", id); err != nil {
        writeError(w, http.StatusInternalServerError, err)
        return
    }
    writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}


func (api *API) publicSettings(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, api.readAppSettings(r.Context()))
}

func (api *API) adminSettings(w http.ResponseWriter, r *http.Request) {
	if !api.validateAdminPassword(r.Context(), r.URL.Query().Get("password")) {
		writeError(w, http.StatusUnauthorized, errors.New("invalid admin password"))
		return
	}
	switch r.Method {
	case http.MethodGet:
		writeJSON(w, http.StatusOK, api.readAppSettings(r.Context()))
	case http.MethodPut:
		var req model.AdminSettingsUpdateRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, err)
			return
		}
		if req.AcceptNewUser != nil {
			api.setSetting(r.Context(), "accept_new_user", strconv.FormatBool(*req.AcceptNewUser))
		}
		if req.DebugMode != nil {
			api.setSetting(r.Context(), "debug_mode", strconv.FormatBool(*req.DebugMode))
		}
		if req.DebugUserName != nil {
			api.setSetting(r.Context(), "debug_user_name", strings.TrimSpace(*req.DebugUserName))
		}
		if req.DebugViewMode != nil {
			mode := strings.TrimSpace(*req.DebugViewMode)
			if mode == "" {
				mode = "floorplan"
			}
			api.setSetting(r.Context(), "debug_view_mode", mode)
		}
		writeJSON(w, http.StatusOK, api.readAppSettings(r.Context()))
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (api *API) adminPassword(w http.ResponseWriter, r *http.Request) {
    if api.adminpanel != nil {
        writeError(w, http.StatusBadRequest, errors.New("Passwortaenderungen werden zentral im Adminpanel vorgenommen"))
        return
    }

    if !api.validateAdminPassword(r.Context(), r.URL.Query().Get("password")) {
        writeError(w, http.StatusUnauthorized, errors.New("invalid admin password"))
        return
    }
    var req model.AdminPasswordChangeRequest
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        writeError(w, http.StatusBadRequest, err)
        return
    }
    if strings.TrimSpace(req.NewPassword) == "" {
        writeError(w, http.StatusBadRequest, errors.New("new password is required"))
        return
    }
    if _, err := api.db.Pool.Exec(r.Context(), "UPDATE app_users SET password_hash = crypt($1, gen_salt('bf')) WHERE COALESCE(is_admin, false) = true", req.NewPassword); err != nil {
        writeError(w, http.StatusInternalServerError, err)
        return
    }
    writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}


func (api *API) readAppSettings(ctx context.Context) model.AppSettings {
	return model.AppSettings{
		AcceptNewUser: api.getBoolSetting(ctx, "accept_new_user", true),
		DebugMode:     api.getBoolSetting(ctx, "debug_mode", false),
		DebugUserName: api.getStringSetting(ctx, "debug_user_name", ""),
		DebugViewMode: api.getStringSetting(ctx, "debug_view_mode", "floorplan"),
	}
}

func (api *API) getStringSetting(ctx context.Context, key string, fallback string) string {
	var value string
	err := api.db.Pool.QueryRow(ctx, "SELECT value FROM app_settings WHERE key = $1", key).Scan(&value)
	if err != nil || strings.TrimSpace(value) == "" {
		return fallback
	}
	return value
}

func (api *API) getBoolSetting(ctx context.Context, key string, fallback bool) bool {
	value := strings.ToLower(strings.TrimSpace(api.getStringSetting(ctx, key, strconv.FormatBool(fallback))))
	return value == "true" || value == "1" || value == "yes" || value == "on"
}

func (api *API) setSetting(ctx context.Context, key string, value string) {
	_, _ = api.db.Pool.Exec(ctx, `
        INSERT INTO app_settings (key, value)
        VALUES ($1, $2)
        ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value
    `, key, value)
}

func (api *API) userObjects(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		api.listUserObjects(w, r)
	case http.MethodPost:
		api.createUserObject(w, r)
	case http.MethodDelete:
		api.deleteUserObject(w, r)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (api *API) listUserObjects(w http.ResponseWriter, r *http.Request) {
	userID := strings.TrimSpace(r.URL.Query().Get("userId"))
	if userID == "" {
		writeError(w, http.StatusBadRequest, errors.New("userId query parameter is required"))
		return
	}

	var canViewAll bool
	if err := api.db.Pool.QueryRow(r.Context(), "SELECT COALESCE(can_view_all_objects, false) FROM app_users WHERE id = $1", userID).Scan(&canViewAll); err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}

	query := `
        SELECT o.id::text, o.user_id::text, u.name, o.name, o.created_at,
               COALESCE(count(r.id), 0)::int AS room_count
        FROM user_objects o
        JOIN app_users u ON u.id = o.user_id
        LEFT JOIN projects p ON p.object_id = o.id
        LEFT JOIN houses h ON h.project_id = p.id
        LEFT JOIN floors f ON f.house_id = h.id
        LEFT JOIN rooms r ON r.floor_id = f.id
    `
	args := []any{}
	if !canViewAll {
		query += " WHERE o.user_id = $1"
		args = append(args, userID)
	}
	query += " GROUP BY o.id, o.user_id, u.name, o.name, o.created_at ORDER BY lower(o.name), o.created_at"

	rows, err := api.db.Pool.Query(r.Context(), query, args...)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	defer rows.Close()

	objects := []model.UserObject{}
	for rows.Next() {
		var object model.UserObject
		if err := rows.Scan(&object.ID, &object.UserID, &object.UserName, &object.Name, &object.CreatedAt, &object.RoomCount); err != nil {
			writeError(w, http.StatusInternalServerError, err)
			return
		}
		object.HasData = object.RoomCount > 0
		objects = append(objects, object)
	}
	if err := rows.Err(); err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, objects)
}

func (api *API) createUserObject(w http.ResponseWriter, r *http.Request) {
	var req model.CreateObjectRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	req.UserID = strings.TrimSpace(req.UserID)
	req.Name = strings.TrimSpace(req.Name)
	if req.UserID == "" {
		writeError(w, http.StatusBadRequest, errors.New("userId is required"))
		return
	}
	if req.Name == "" {
		writeError(w, http.StatusBadRequest, errors.New("object name is required"))
		return
	}

	tx, err := api.db.Pool.Begin(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	defer tx.Rollback(r.Context())

	var object model.UserObject
	err = tx.QueryRow(r.Context(), `
        INSERT INTO user_objects (user_id, name)
        VALUES ($1, $2)
        RETURNING id::text, user_id::text, name, created_at
    `, req.UserID, req.Name).Scan(&object.ID, &object.UserID, &object.Name, &object.CreatedAt)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	_ = tx.QueryRow(r.Context(), "SELECT name FROM app_users WHERE id = $1", object.UserID).Scan(&object.UserName)

	var projectID string
	err = tx.QueryRow(r.Context(), `
        INSERT INTO projects (object_id, name, description)
        VALUES ($1, $2, $3)
        RETURNING id::text
    `, object.ID, object.Name+" intern", "Interne technische Zuordnung").Scan(&projectID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	var houseID string
	err = tx.QueryRow(r.Context(), `
        INSERT INTO houses (project_id, name)
        VALUES ($1, 'Wohnhaus')
        RETURNING id::text
    `, projectID).Scan(&houseID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	if _, err := tx.Exec(r.Context(), `
        INSERT INTO floors (house_id, name, level_index, elevation_m, height_m)
        VALUES ($1, 'EG', 0, 0, 2.5)
    `, houseID); err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusCreated, object)
}

func (api *API) deleteUserObject(w http.ResponseWriter, r *http.Request) {
	objectID := strings.TrimSpace(r.URL.Query().Get("id"))
	userID := strings.TrimSpace(r.URL.Query().Get("userId"))
	if objectID == "" {
		writeError(w, http.StatusBadRequest, errors.New("id query parameter is required"))
		return
	}
	if userID == "" {
		writeError(w, http.StatusBadRequest, errors.New("userId query parameter is required"))
		return
	}

	var allowed bool
	err := api.db.Pool.QueryRow(r.Context(), `
        SELECT EXISTS (
            SELECT 1
            FROM user_objects o
            JOIN app_users u ON u.id = $2
            WHERE o.id = $1 AND (o.user_id = $2 OR COALESCE(u.can_view_all_objects, false) = true)
        )
    `, objectID, userID).Scan(&allowed)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	if !allowed {
		writeError(w, http.StatusForbidden, errors.New("not allowed to delete object"))
		return
	}
	_, err = api.db.Pool.Exec(r.Context(), "DELETE FROM user_objects WHERE id = $1", objectID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (api *API) defaultFloor(w http.ResponseWriter, r *http.Request) {
	objectID := strings.TrimSpace(r.URL.Query().Get("objectId"))
	floor, err := api.findDefaultFloor(r.Context(), objectID)
	if err != nil {
		if objectID != "" && isNoRows(err) {
			floor, err = api.ensureDefaultStructureForObject(r.Context(), objectID)
		}
		if err != nil {
			if isNoRows(err) {
				writeError(w, http.StatusNotFound, errors.New("no floor found"))
				return
			}
			writeError(w, http.StatusInternalServerError, err)
			return
		}
	}
	writeJSON(w, http.StatusOK, floor)
}

func (api *API) findDefaultFloor(ctx context.Context, objectID string) (model.Floor, error) {
	var floor model.Floor
	query := `
        SELECT f.id::text, f.house_id::text, f.name, f.level_index, f.elevation_m::float8, f.height_m::float8, f.created_at
        FROM floors f
        JOIN houses h ON h.id = f.house_id
        JOIN projects p ON p.id = h.project_id
    `
	args := []any{}
	if objectID != "" {
		query += " WHERE p.object_id = $1"
		args = append(args, objectID)
	}
	query += " ORDER BY f.level_index, f.created_at LIMIT 1"
	err := api.db.Pool.QueryRow(ctx, query, args...).Scan(&floor.ID, &floor.HouseID, &floor.Name, &floor.LevelIndex, &floor.ElevationM, &floor.HeightM, &floor.CreatedAt)
	return floor, err
}

func (api *API) ensureDefaultStructureForObject(ctx context.Context, objectID string) (model.Floor, error) {
	tx, err := api.db.Pool.Begin(ctx)
	if err != nil {
		return model.Floor{}, err
	}
	defer tx.Rollback(ctx)

	var objectName string
	if err := tx.QueryRow(ctx, "SELECT name FROM user_objects WHERE id = $1", objectID).Scan(&objectName); err != nil {
		return model.Floor{}, err
	}

	var projectID string
	err = tx.QueryRow(ctx, "SELECT id::text FROM projects WHERE object_id = $1 ORDER BY created_at LIMIT 1", objectID).Scan(&projectID)
	if isNoRows(err) {
		err = tx.QueryRow(ctx, `
            INSERT INTO projects (object_id, name, description)
            VALUES ($1, $2, $3)
            RETURNING id::text
        `, objectID, objectName+" intern", "Interne technische Zuordnung").Scan(&projectID)
	}
	if err != nil {
		return model.Floor{}, err
	}

	var houseID string
	err = tx.QueryRow(ctx, "SELECT id::text FROM houses WHERE project_id = $1 ORDER BY created_at LIMIT 1", projectID).Scan(&houseID)
	if isNoRows(err) {
		err = tx.QueryRow(ctx, "INSERT INTO houses (project_id, name) VALUES ($1, 'Wohnhaus') RETURNING id::text", projectID).Scan(&houseID)
	}
	if err != nil {
		return model.Floor{}, err
	}

	var floor model.Floor
	err = tx.QueryRow(ctx, `
        SELECT id::text, house_id::text, name, level_index, elevation_m::float8, height_m::float8, created_at
        FROM floors
        WHERE house_id = $1
        ORDER BY level_index, created_at
        LIMIT 1
    `, houseID).Scan(&floor.ID, &floor.HouseID, &floor.Name, &floor.LevelIndex, &floor.ElevationM, &floor.HeightM, &floor.CreatedAt)
	if isNoRows(err) {
		err = tx.QueryRow(ctx, `
            INSERT INTO floors (house_id, name, level_index, elevation_m, height_m)
            VALUES ($1, 'EG', 0, 0, 2.5)
            RETURNING id::text, house_id::text, name, level_index, elevation_m::float8, height_m::float8, created_at
        `, houseID).Scan(&floor.ID, &floor.HouseID, &floor.Name, &floor.LevelIndex, &floor.ElevationM, &floor.HeightM, &floor.CreatedAt)
	}
	if err != nil {
		return model.Floor{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return model.Floor{}, err
	}
	return floor, nil
}

func (api *API) rooms(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		api.listRooms(w, r)
	case http.MethodPost:
		api.createRoom(w, r)
	case http.MethodPut:
		api.updateRoom(w, r)
	case http.MethodDelete:
		api.deleteRoom(w, r)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (api *API) listRooms(w http.ResponseWriter, r *http.Request) {
	floorID := strings.TrimSpace(r.URL.Query().Get("floorId"))
	if floorID == "" {
		var err error
		floorID, err = api.getDefaultFloorID(r)
		if err != nil {
			writeError(w, http.StatusInternalServerError, err)
			return
		}
	}

	rows, err := api.db.Pool.Query(r.Context(), `
        SELECT id::text, floor_id::text, name, shape_type, COALESCE(room_type, 'room'), wall_thickness_m::float8,
               COALESCE(ST_AsGeoJSON(polygon), '') AS geojson,
               COALESCE(ST_Area(polygon), 0)::float8 AS area_m2,
               created_at
        FROM rooms
        WHERE floor_id = $1
        ORDER BY created_at, name
    `, floorID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	defer rows.Close()

	rooms := []model.Room{}
	for rows.Next() {
		var room model.Room
		var geoJSON string
		if err := rows.Scan(&room.ID, &room.FloorID, &room.Name, &room.ShapeType, &room.RoomType, &room.WallThicknessM, &geoJSON, &room.AreaM2, &room.CreatedAt); err != nil {
			writeError(w, http.StatusInternalServerError, err)
			return
		}
		vertices, err := verticesFromGeoJSON(geoJSON)
		if err != nil {
			writeError(w, http.StatusInternalServerError, err)
			return
		}
		room.Vertices = vertices
		rooms = append(rooms, room)
	}
	if err := rows.Err(); err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, rooms)
}

func (api *API) createRoom(w http.ResponseWriter, r *http.Request) {
	var req model.CreateRoomRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}

	req.Name = strings.TrimSpace(req.Name)
	req.ShapeType = strings.TrimSpace(req.ShapeType)
	if req.Name == "" {
		writeError(w, http.StatusBadRequest, errors.New("room name is required"))
		return
	}
	if req.FloorID == "" {
		var err error
		req.FloorID, err = api.getDefaultFloorID(r)
		if err != nil {
			writeError(w, http.StatusInternalServerError, err)
			return
		}
	}
	if req.ShapeType == "" {
		req.ShapeType = "rectangle"
	}
	req.RoomType = strings.TrimSpace(req.RoomType)
	if req.RoomType == "" {
		req.RoomType = "room"
	}
	if req.RoomType != "room" && req.RoomType != "stair" {
		writeError(w, http.StatusBadRequest, errors.New("roomType must be room or stair"))
		return
	}
	if req.ShapeType != "rectangle" && req.ShapeType != "polygon" {
		writeError(w, http.StatusBadRequest, errors.New("shapeType must be rectangle or polygon"))
		return
	}
	if req.WallThicknessM <= 0 {
		req.WallThicknessM = 0.115
	}
	if len(req.Vertices) < 3 {
		writeError(w, http.StatusBadRequest, errors.New("at least 3 vertices are required"))
		return
	}

	wkt, err := polygonWKT(req.Vertices)
	if err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}

	var room model.Room
	var geoJSON string
	err = api.db.Pool.QueryRow(r.Context(), `
        INSERT INTO rooms (floor_id, name, shape_type, room_type, wall_thickness_m, polygon)
        VALUES ($1, $2, $3, $4, $5, ST_GeomFromText($6, 0))
        RETURNING id::text, floor_id::text, name, shape_type, COALESCE(room_type, 'room'), wall_thickness_m::float8,
                  COALESCE(ST_AsGeoJSON(polygon), '') AS geojson,
                  COALESCE(ST_Area(polygon), 0)::float8 AS area_m2,
                  created_at
    `, req.FloorID, req.Name, req.ShapeType, req.RoomType, req.WallThicknessM, wkt).Scan(
		&room.ID, &room.FloorID, &room.Name, &room.ShapeType, &room.RoomType, &room.WallThicknessM, &geoJSON, &room.AreaM2, &room.CreatedAt,
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	room.Vertices, err = verticesFromGeoJSON(geoJSON)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusCreated, room)
}

func (api *API) updateRoom(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimSpace(r.URL.Query().Get("id"))
	if id == "" {
		writeError(w, http.StatusBadRequest, errors.New("id query parameter is required"))
		return
	}

	var req model.UpdateRoomRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}

	req.Name = strings.TrimSpace(req.Name)
	req.ShapeType = strings.TrimSpace(req.ShapeType)
	if req.Name == "" {
		writeError(w, http.StatusBadRequest, errors.New("room name is required"))
		return
	}
	if req.ShapeType == "" {
		req.ShapeType = "rectangle"
	}
	req.RoomType = strings.TrimSpace(req.RoomType)
	if req.RoomType == "" {
		req.RoomType = "room"
	}
	if req.RoomType != "room" && req.RoomType != "stair" {
		writeError(w, http.StatusBadRequest, errors.New("roomType must be room or stair"))
		return
	}
	if req.ShapeType != "rectangle" && req.ShapeType != "polygon" {
		writeError(w, http.StatusBadRequest, errors.New("shapeType must be rectangle or polygon"))
		return
	}
	if req.WallThicknessM <= 0 {
		req.WallThicknessM = 0.115
	}
	if len(req.Vertices) < 3 {
		writeError(w, http.StatusBadRequest, errors.New("at least 3 vertices are required"))
		return
	}

	wkt, err := polygonWKT(req.Vertices)
	if err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}

	var room model.Room
	var geoJSON string
	err = api.db.Pool.QueryRow(r.Context(), `
        UPDATE rooms
        SET name = $2,
            shape_type = $3,
            room_type = $4,
            wall_thickness_m = $5,
            polygon = ST_GeomFromText($6, 0)
        WHERE id = $1
        RETURNING id::text, floor_id::text, name, shape_type, COALESCE(room_type, 'room'), wall_thickness_m::float8,
                  COALESCE(ST_AsGeoJSON(polygon), '') AS geojson,
                  COALESCE(ST_Area(polygon), 0)::float8 AS area_m2,
                  created_at
    `, id, req.Name, req.ShapeType, req.RoomType, req.WallThicknessM, wkt).Scan(
		&room.ID, &room.FloorID, &room.Name, &room.ShapeType, &room.RoomType, &room.WallThicknessM, &geoJSON, &room.AreaM2, &room.CreatedAt,
	)
	if err != nil {
		if isNoRows(err) {
			writeError(w, http.StatusNotFound, errors.New("room not found"))
			return
		}
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	room.Vertices, err = verticesFromGeoJSON(geoJSON)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, room)
}

func (api *API) deleteRoom(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimSpace(r.URL.Query().Get("id"))
	if id == "" {
		writeError(w, http.StatusBadRequest, errors.New("id query parameter is required"))
		return
	}
	_, err := api.db.Pool.Exec(r.Context(), "DELETE FROM rooms WHERE id = $1", id)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (api *API) wallObjects(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		api.listWallObjects(w, r)
	case http.MethodPost:
		api.createWallObject(w, r)
	case http.MethodPut:
		api.updateWallObject(w, r)
	case http.MethodDelete:
		api.deleteWallObject(w, r)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (api *API) listWallObjects(w http.ResponseWriter, r *http.Request) {
	floorID := strings.TrimSpace(r.URL.Query().Get("floorId"))
	if floorID == "" {
		var err error
		floorID, err = api.getDefaultFloorID(r)
		if err != nil {
			writeError(w, http.StatusInternalServerError, err)
			return
		}
	}
	rows, err := api.db.Pool.Query(r.Context(), `
        SELECT id::text, floor_id::text, room_id::text, edge_index, object_type,
               x::float8, y::float8, w::float8, h::float8, COALESCE(group_id, ''), created_at
        FROM wall_objects
        WHERE floor_id = $1
        ORDER BY created_at, id
    `, floorID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	defer rows.Close()
	objects := []model.WallObject{}
	for rows.Next() {
		var item model.WallObject
		if err := rows.Scan(&item.ID, &item.FloorID, &item.RoomID, &item.EdgeIndex, &item.ObjectType, &item.X, &item.Y, &item.W, &item.H, &item.GroupID, &item.CreatedAt); err != nil {
			writeError(w, http.StatusInternalServerError, err)
			return
		}
		objects = append(objects, item)
	}
	if err := rows.Err(); err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, objects)
}

func (api *API) createWallObject(w http.ResponseWriter, r *http.Request) {
	var req model.CreateWallObjectRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	req.FloorID = strings.TrimSpace(req.FloorID)
	req.RoomID = strings.TrimSpace(req.RoomID)
	req.ObjectType = strings.TrimSpace(req.ObjectType)
	req.GroupID = strings.TrimSpace(req.GroupID)
	if req.FloorID == "" || req.RoomID == "" {
		writeError(w, http.StatusBadRequest, errors.New("floorId and roomId are required"))
		return
	}
	if req.ObjectType != "door" && req.ObjectType != "window" && req.ObjectType != "socket" {
		writeError(w, http.StatusBadRequest, errors.New("objectType must be door, window or socket"))
		return
	}
	if req.EdgeIndex < 0 {
		writeError(w, http.StatusBadRequest, errors.New("edgeIndex must be >= 0"))
		return
	}
	req.X = math.Max(0, math.Min(1, req.X))
	req.Y = math.Max(0, math.Min(1, req.Y))
	req.W = math.Max(0.01, math.Min(1, req.W))
	req.H = math.Max(0.01, math.Min(1, req.H))
	var item model.WallObject
	err := api.db.Pool.QueryRow(r.Context(), `
        INSERT INTO wall_objects (floor_id, room_id, edge_index, object_type, x, y, w, h, group_id)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, NULLIF($9, ''))
        RETURNING id::text, floor_id::text, room_id::text, edge_index, object_type,
                  x::float8, y::float8, w::float8, h::float8, COALESCE(group_id, ''), created_at
    `, req.FloorID, req.RoomID, req.EdgeIndex, req.ObjectType, req.X, req.Y, req.W, req.H, req.GroupID).Scan(
		&item.ID, &item.FloorID, &item.RoomID, &item.EdgeIndex, &item.ObjectType, &item.X, &item.Y, &item.W, &item.H, &item.GroupID, &item.CreatedAt,
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusCreated, item)
}

func (api *API) updateWallObject(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimSpace(r.URL.Query().Get("id"))
	if id == "" {
		writeError(w, http.StatusBadRequest, errors.New("id query parameter is required"))
		return
	}
	var req model.UpdateWallObjectRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	var item model.WallObject
	err := api.db.Pool.QueryRow(r.Context(), `
        UPDATE wall_objects
        SET object_type = CASE WHEN $2 <> '' THEN $2 ELSE object_type END,
            x = COALESCE($3, x),
            y = COALESCE($4, y),
            w = COALESCE($5, w),
            h = COALESCE($6, h),
            group_id = COALESCE(NULLIF($7, ''), group_id)
        WHERE id = $1
        RETURNING id::text, floor_id::text, room_id::text, edge_index, object_type,
                  x::float8, y::float8, w::float8, h::float8, COALESCE(group_id, ''), created_at
    `, id, strings.TrimSpace(req.ObjectType), req.X, req.Y, req.W, req.H, req.GroupID).Scan(
		&item.ID, &item.FloorID, &item.RoomID, &item.EdgeIndex, &item.ObjectType, &item.X, &item.Y, &item.W, &item.H, &item.GroupID, &item.CreatedAt,
	)
	if err != nil {
		if isNoRows(err) {
			writeError(w, http.StatusNotFound, errors.New("wall object not found"))
			return
		}
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, item)
}

func (api *API) deleteWallObject(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimSpace(r.URL.Query().Get("id"))
	if id == "" {
		writeError(w, http.StatusBadRequest, errors.New("id query parameter is required"))
		return
	}
	_, err := api.db.Pool.Exec(r.Context(), "DELETE FROM wall_objects WHERE id = $1", id)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (api *API) openings(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		api.listOpenings(w, r)
	case http.MethodPost:
		api.createOpening(w, r)
	case http.MethodDelete:
		api.deleteOpening(w, r)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (api *API) listOpenings(w http.ResponseWriter, r *http.Request) {
	floorID := strings.TrimSpace(r.URL.Query().Get("floorId"))
	if floorID == "" {
		var err error
		floorID, err = api.getDefaultFloorID(r)
		if err != nil {
			writeError(w, http.StatusInternalServerError, err)
			return
		}
	}

	rows, err := api.db.Pool.Query(r.Context(), `
        SELECT id::text, floor_id::text, COALESCE(room_id::text, ''), name, opening_type,
               x_m::float8, y_m::float8, width_m::float8, angle_deg::float8, created_at
        FROM room_openings
        WHERE floor_id = $1
        ORDER BY created_at
    `, floorID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	defer rows.Close()

	openings := []model.Opening{}
	for rows.Next() {
		var opening model.Opening
		if err := rows.Scan(&opening.ID, &opening.FloorID, &opening.RoomID, &opening.Name, &opening.OpeningType, &opening.X, &opening.Y, &opening.WidthM, &opening.AngleDeg, &opening.CreatedAt); err != nil {
			writeError(w, http.StatusInternalServerError, err)
			return
		}
		openings = append(openings, opening)
	}
	if err := rows.Err(); err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, openings)
}

func (api *API) createOpening(w http.ResponseWriter, r *http.Request) {
	var req model.CreateOpeningRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}

	req.Name = strings.TrimSpace(req.Name)
	req.OpeningType = strings.TrimSpace(req.OpeningType)
	if req.FloorID == "" {
		var err error
		req.FloorID, err = api.getDefaultFloorID(r)
		if err != nil {
			writeError(w, http.StatusInternalServerError, err)
			return
		}
	}
	if req.OpeningType != "door" && req.OpeningType != "window" {
		writeError(w, http.StatusBadRequest, errors.New("openingType must be door or window"))
		return
	}
	if req.WidthM <= 0 {
		req.WidthM = 0.9
	}

	var opening model.Opening
	var roomID sql.NullString
	err := api.db.Pool.QueryRow(r.Context(), `
        INSERT INTO room_openings (floor_id, room_id, name, opening_type, x_m, y_m, width_m, angle_deg)
        VALUES ($1, NULLIF($2, '')::uuid, $3, $4, $5, $6, $7, $8)
        RETURNING id::text, floor_id::text, room_id::text, name, opening_type,
                  x_m::float8, y_m::float8, width_m::float8, angle_deg::float8, created_at
    `, req.FloorID, req.RoomID, req.Name, req.OpeningType, req.X, req.Y, req.WidthM, req.AngleDeg).Scan(
		&opening.ID, &opening.FloorID, &roomID, &opening.Name, &opening.OpeningType, &opening.X, &opening.Y, &opening.WidthM, &opening.AngleDeg, &opening.CreatedAt,
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	if roomID.Valid {
		opening.RoomID = roomID.String
	}
	writeJSON(w, http.StatusCreated, opening)
}

func (api *API) deleteOpening(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimSpace(r.URL.Query().Get("id"))
	if id == "" {
		writeError(w, http.StatusBadRequest, errors.New("id query parameter is required"))
		return
	}
	_, err := api.db.Pool.Exec(r.Context(), "DELETE FROM room_openings WHERE id = $1", id)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (api *API) getDefaultFloorID(r *http.Request) (string, error) {
	var id string
	err := api.db.Pool.QueryRow(r.Context(), "SELECT id::text FROM floors ORDER BY level_index, created_at LIMIT 1").Scan(&id)
	return id, err
}

func polygonWKT(vertices []model.PointM) (string, error) {
	clean := make([]model.PointM, 0, len(vertices)+1)
	for _, point := range vertices {
		if math.IsNaN(point.X) || math.IsNaN(point.Y) || math.IsInf(point.X, 0) || math.IsInf(point.Y, 0) {
			return "", errors.New("vertices must be finite numbers")
		}
		clean = append(clean, model.PointM{X: round3(point.X), Y: round3(point.Y)})
	}
	if len(clean) < 3 {
		return "", errors.New("at least 3 vertices are required")
	}
	if clean[0] != clean[len(clean)-1] {
		clean = append(clean, clean[0])
	}

	parts := make([]string, 0, len(clean))
	for _, point := range clean {
		parts = append(parts, fmt.Sprintf("%s %s", formatFloat(point.X), formatFloat(point.Y)))
	}
	return "POLYGON((" + strings.Join(parts, ", ") + "))", nil
}

func round3(value float64) float64 {
	return math.Round(value*1000) / 1000
}

func formatFloat(value float64) string {
	return strconv.FormatFloat(value, 'f', 3, 64)
}

type polygonGeoJSON struct {
	Type        string        `json:"type"`
	Coordinates [][][]float64 `json:"coordinates"`
}

func verticesFromGeoJSON(raw string) ([]model.PointM, error) {
	if strings.TrimSpace(raw) == "" {
		return []model.PointM{}, nil
	}
	var polygon polygonGeoJSON
	if err := json.Unmarshal([]byte(raw), &polygon); err != nil {
		return nil, err
	}
	if len(polygon.Coordinates) == 0 || len(polygon.Coordinates[0]) == 0 {
		return []model.PointM{}, nil
	}

	points := polygon.Coordinates[0]
	vertices := make([]model.PointM, 0, len(points))
	for index, point := range points {
		if len(point) < 2 {
			continue
		}
		if index == len(points)-1 && len(points) > 1 {
			first := points[0]
			if len(first) >= 2 && point[0] == first[0] && point[1] == first[1] {
				continue
			}
		}
		vertices = append(vertices, model.PointM{X: point[0], Y: point[1]})
	}
	return vertices, nil
}

func isNoRows(err error) bool {
	if err == nil {
		return false
	}
	return errors.Is(err, sql.ErrNoRows) || strings.Contains(err.Error(), "no rows in result set")
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeError(w http.ResponseWriter, status int, err error) {
	writeJSON(w, status, map[string]string{"error": err.Error()})
}
