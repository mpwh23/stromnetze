package httpapi

import (
    "context"
    "database/sql"
    "errors"
    "strings"

    "golang.org/x/crypto/bcrypt"

    "strom/backend/internal/model"
)

type centralIdentity struct {
    AdminUserID  int64
    Username     string
    DisplayName  string
    PasswordHash string
    RoleKey      string
    IsAdmin      bool
    HasAccess    bool
}

func normalizeBcryptHash(hash string) string {
    hash = strings.TrimSpace(hash)
    if strings.HasPrefix(hash, "$2y$") {
        return "$2a$" + strings.TrimPrefix(hash, "$2y$")
    }
    return hash
}

func verifyCentralPassword(hash string, password string) bool {
    hash = normalizeBcryptHash(hash)
    if hash == "" || password == "" {
        return false
    }
    return bcrypt.CompareHashAndPassword([]byte(hash), []byte(password)) == nil
}

func (api *API) centralRoleIsAdmin(ident centralIdentity) bool {
    return ident.IsAdmin || strings.EqualFold(ident.RoleKey, "admin") || strings.EqualFold(ident.RoleKey, "owner")
}

func (api *API) fetchCentralIdentityByUsername(ctx context.Context, username string) (centralIdentity, bool, error) {
    if api.adminpanel == nil {
        return centralIdentity{}, false, nil
    }

    username = strings.TrimSpace(username)
    if username == "" {
        return centralIdentity{}, false, nil
    }

    var ident centralIdentity
    var hasAccess int
    err := api.adminpanel.QueryRowContext(ctx, `
        SELECT
            u.id,
            u.username,
            COALESCE(NULLIF(u.display_name, ''), u.username) AS display_name,
            u.password_hash,
            COALESCE(a.role_key, '') AS role_key,
            COALESCE(u.is_admin, 0) AS is_admin,
            CASE WHEN a.id IS NULL THEN 0 ELSE 1 END AS has_access
        FROM admin_users u
        LEFT JOIN admin_user_project_access a
            ON a.user_id = u.id
           AND a.can_access = 1
           AND a.project_id = (
                SELECT id FROM admin_projects WHERE project_key = 'strom' AND is_active = 1 LIMIT 1
           )
        WHERE u.is_active = 1
          AND (LOWER(u.username) = LOWER(?) OR LOWER(u.display_name) = LOWER(?))
        ORDER BY CASE WHEN LOWER(u.username) = LOWER(?) THEN 0 ELSE 1 END
        LIMIT 1
    `, username, username, username).Scan(&ident.AdminUserID, &ident.Username, &ident.DisplayName, &ident.PasswordHash, &ident.RoleKey, &ident.IsAdmin, &hasAccess)
    if err != nil {
        if errors.Is(err, sql.ErrNoRows) {
            return centralIdentity{}, false, nil
        }
        return centralIdentity{}, false, err
    }
    ident.HasAccess = hasAccess == 1
    return ident, true, nil
}

func (api *API) fetchCentralIdentityByID(ctx context.Context, adminUserID int64) (centralIdentity, bool, error) {
    if api.adminpanel == nil || adminUserID <= 0 {
        return centralIdentity{}, false, nil
    }

    var ident centralIdentity
    var hasAccess int
    err := api.adminpanel.QueryRowContext(ctx, `
        SELECT
            u.id,
            u.username,
            COALESCE(NULLIF(u.display_name, ''), u.username) AS display_name,
            u.password_hash,
            COALESCE(a.role_key, '') AS role_key,
            COALESCE(u.is_admin, 0) AS is_admin,
            CASE WHEN a.id IS NULL THEN 0 ELSE 1 END AS has_access
        FROM admin_users u
        LEFT JOIN admin_user_project_access a
            ON a.user_id = u.id
           AND a.can_access = 1
           AND a.project_id = (
                SELECT id FROM admin_projects WHERE project_key = 'strom' AND is_active = 1 LIMIT 1
           )
        WHERE u.is_active = 1
          AND u.id = ?
        LIMIT 1
    `, adminUserID).Scan(&ident.AdminUserID, &ident.Username, &ident.DisplayName, &ident.PasswordHash, &ident.RoleKey, &ident.IsAdmin, &hasAccess)
    if err != nil {
        if errors.Is(err, sql.ErrNoRows) {
            return centralIdentity{}, false, nil
        }
        return centralIdentity{}, false, err
    }
    ident.HasAccess = hasAccess == 1
    return ident, true, nil
}

func (api *API) fetchCentralUsers(ctx context.Context, onlyWithAccess bool) ([]centralIdentity, error) {
    if api.adminpanel == nil {
        return nil, nil
    }

    whereAccess := ""
    if onlyWithAccess {
        whereAccess = "AND a.id IS NOT NULL"
    }

    rows, err := api.adminpanel.QueryContext(ctx, `
        SELECT
            u.id,
            u.username,
            COALESCE(NULLIF(u.display_name, ''), u.username) AS display_name,
            u.password_hash,
            COALESCE(a.role_key, 'user') AS role_key,
            COALESCE(u.is_admin, 0) AS is_admin,
            CASE WHEN a.id IS NULL THEN 0 ELSE 1 END AS has_access
        FROM admin_users u
        LEFT JOIN admin_user_project_access a
            ON a.user_id = u.id
           AND a.can_access = 1
           AND a.project_id = (
                SELECT id FROM admin_projects WHERE project_key = 'strom' AND is_active = 1 LIMIT 1
           )
        WHERE u.is_active = 1
    `+whereAccess+`
        ORDER BY lower(u.username)
    `)
    if err != nil {
        return nil, err
    }
    defer rows.Close()

    out := []centralIdentity{}
    for rows.Next() {
        var ident centralIdentity
        var hasAccess int
        if err := rows.Scan(&ident.AdminUserID, &ident.Username, &ident.DisplayName, &ident.PasswordHash, &ident.RoleKey, &ident.IsAdmin, &hasAccess); err != nil {
            return nil, err
        }
        ident.HasAccess = hasAccess == 1
        out = append(out, ident)
    }
    return out, rows.Err()
}

func (api *API) syncCentralUsersForList(ctx context.Context) error {
    identities, err := api.fetchCentralUsers(ctx, true)
    if err != nil {
        return err
    }
    for _, ident := range identities {
        _, _ = api.ensureLocalUserForCentral(ctx, ident, true)
    }
    return nil
}

func (api *API) ensureLocalUserForCentral(ctx context.Context, ident centralIdentity, inList bool) (model.AppUser, error) {
    var user model.AppUser
    isProjectAdmin := api.centralRoleIsAdmin(ident)
    displayName := strings.TrimSpace(ident.DisplayName)
    if displayName == "" {
        displayName = ident.Username
    }

    err := api.db.Pool.QueryRow(ctx, `
        SELECT id::text, name, COALESCE(is_admin, false), COALESCE(can_view_all_objects, false), COALESCE(in_list, false), created_at
        FROM app_users
        WHERE central_admin_user_id = $1
        LIMIT 1
    `, ident.AdminUserID).Scan(&user.ID, &user.Name, &user.IsAdmin, &user.CanViewAllObjects, &user.InList, &user.CreatedAt)
    if err == nil {
        err = api.db.Pool.QueryRow(ctx, `
            UPDATE app_users
            SET name = $2,
                is_admin = $3,
                can_view_all_objects = $4,
                in_list = $5
            WHERE id = $1
            RETURNING id::text, name, COALESCE(is_admin, false), COALESCE(can_view_all_objects, false), COALESCE(in_list, false), created_at
        `, user.ID, displayName, isProjectAdmin, isProjectAdmin, inList).Scan(&user.ID, &user.Name, &user.IsAdmin, &user.CanViewAllObjects, &user.InList, &user.CreatedAt)
        return user, err
    }
    if !isNoRows(err) {
        return user, err
    }

    err = api.db.Pool.QueryRow(ctx, `
        SELECT id::text, name, COALESCE(is_admin, false), COALESCE(can_view_all_objects, false), COALESCE(in_list, false), created_at
        FROM app_users
        WHERE central_admin_user_id IS NULL
          AND lower(name) IN (lower($1), lower($2))
        ORDER BY created_at
        LIMIT 1
    `, ident.Username, displayName).Scan(&user.ID, &user.Name, &user.IsAdmin, &user.CanViewAllObjects, &user.InList, &user.CreatedAt)
    if err == nil {
        err = api.db.Pool.QueryRow(ctx, `
            UPDATE app_users
            SET central_admin_user_id = $2,
                name = $3,
                is_admin = $4,
                can_view_all_objects = $5,
                in_list = $6
            WHERE id = $1
            RETURNING id::text, name, COALESCE(is_admin, false), COALESCE(can_view_all_objects, false), COALESCE(in_list, false), created_at
        `, user.ID, ident.AdminUserID, displayName, isProjectAdmin, isProjectAdmin, inList).Scan(&user.ID, &user.Name, &user.IsAdmin, &user.CanViewAllObjects, &user.InList, &user.CreatedAt)
        return user, err
    }
    if !isNoRows(err) {
        return user, err
    }

    err = api.db.Pool.QueryRow(ctx, `
        INSERT INTO app_users (name, password_hash, is_admin, can_view_all_objects, in_list, central_admin_user_id)
        VALUES ($1, crypt(gen_random_uuid()::text, gen_salt('bf')), $2, $3, $4, $5)
        RETURNING id::text, name, COALESCE(is_admin, false), COALESCE(can_view_all_objects, false), COALESCE(in_list, false), created_at
    `, displayName, isProjectAdmin, isProjectAdmin, inList, ident.AdminUserID).Scan(&user.ID, &user.Name, &user.IsAdmin, &user.CanViewAllObjects, &user.InList, &user.CreatedAt)
    return user, err
}

func (api *API) localUserCentralID(ctx context.Context, localUserID string) (int64, string, error) {
    var centralID sql.NullInt64
    var name string
    err := api.db.Pool.QueryRow(ctx, "SELECT central_admin_user_id, name FROM app_users WHERE id = $1", localUserID).Scan(&centralID, &name)
    if err != nil {
        return 0, "", err
    }
    if centralID.Valid {
        return centralID.Int64, name, nil
    }
    return 0, name, nil
}

func (api *API) validateAdminPassword(ctx context.Context, password string) bool {
    if api.adminpanel != nil {
        identities, err := api.fetchCentralUsers(ctx, true)
        if err != nil {
            return false
        }
        for _, ident := range identities {
            if api.centralRoleIsAdmin(ident) && verifyCentralPassword(ident.PasswordHash, password) {
                return true
            }
        }
        return false
    }

    var ok bool
    err := api.db.Pool.QueryRow(ctx, `
        SELECT COALESCE(bool_or(password_hash = crypt($1, password_hash)), false)
        FROM app_users
        WHERE COALESCE(is_admin, false) = true AND password_hash IS NOT NULL AND password_hash <> ''
    `, password).Scan(&ok)
    return err == nil && ok
}

func (api *API) createCentralUserWithAccess(ctx context.Context, username string, password string) (centralIdentity, error) {
    if api.adminpanel == nil {
        return centralIdentity{}, errors.New("central adminpanel database is not configured")
    }

    username = strings.TrimSpace(username)
    if username == "" || strings.TrimSpace(password) == "" {
        return centralIdentity{}, errors.New("username and password required")
    }

    if _, found, err := api.fetchCentralIdentityByUsername(ctx, username); err != nil {
        return centralIdentity{}, err
    } else if found {
        return centralIdentity{}, errors.New("central user already exists")
    }

    hashBytes, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
    if err != nil {
        return centralIdentity{}, err
    }

    tx, err := api.adminpanel.BeginTx(ctx, nil)
    if err != nil {
        return centralIdentity{}, err
    }
    defer func() { _ = tx.Rollback() }()

    result, err := tx.ExecContext(ctx, `
        INSERT INTO admin_users (username, display_name, password_hash, is_active, is_admin)
        VALUES (?, ?, ?, 1, 0)
    `, username, username, string(hashBytes))
    if err != nil {
        return centralIdentity{}, err
    }

    userID, err := result.LastInsertId()
    if err != nil {
        return centralIdentity{}, err
    }

    var projectID int64
    if err := tx.QueryRowContext(ctx, "SELECT id FROM admin_projects WHERE project_key = 'strom' AND is_active = 1 LIMIT 1").Scan(&projectID); err != nil {
        return centralIdentity{}, err
    }

    _, err = tx.ExecContext(ctx, `
        INSERT INTO admin_user_project_access (user_id, project_id, role_key, can_access)
        VALUES (?, ?, 'user', 1)
        ON DUPLICATE KEY UPDATE can_access = 1, role_key = VALUES(role_key)
    `, userID, projectID)
    if err != nil {
        return centralIdentity{}, err
    }

    if err := tx.Commit(); err != nil {
        return centralIdentity{}, err
    }

    ident, found, err := api.fetchCentralIdentityByID(ctx, userID)
    if err != nil {
        return centralIdentity{}, err
    }
    if !found {
        return centralIdentity{}, errors.New("central user created but not readable")
    }
    return ident, nil
}

func (api *API) setCentralAccess(ctx context.Context, adminUserID int64, canAccess bool, roleKey string) error {
    if api.adminpanel == nil || adminUserID <= 0 {
        return nil
    }
    if roleKey == "" {
        roleKey = "user"
    }

    _, err := api.adminpanel.ExecContext(ctx, `
        INSERT INTO admin_user_project_access (user_id, project_id, role_key, can_access)
        VALUES (?, (SELECT id FROM admin_projects WHERE project_key = 'strom' LIMIT 1), ?, ?)
        ON DUPLICATE KEY UPDATE role_key = VALUES(role_key), can_access = VALUES(can_access)
    `, adminUserID, roleKey, canAccess)
    return err
}
