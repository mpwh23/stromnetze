package model

import "time"

type AppUser struct {
	ID                string    `json:"id"`
	Name              string    `json:"name"`
	IsAdmin           bool      `json:"isAdmin"`
	CanViewAllObjects bool      `json:"canViewAllObjects"`
	InList            bool      `json:"inList"`
	CreatedAt         time.Time `json:"createdAt"`
}

type CreateUserRequest struct {
	Name     string `json:"name"`
	Password string `json:"password"`
}

type LoginUserRequest struct {
	UserID   string `json:"userId"`
	Password string `json:"password"`
}

type AdminUserUpdateRequest struct {
	Name              *string `json:"name"`
	CanViewAllObjects *bool   `json:"canViewAllObjects"`
	InList            *bool   `json:"inList"`
}

type AppSettings struct {
	AcceptNewUser bool   `json:"acceptNewUser"`
	DebugMode     bool   `json:"debugMode"`
	DebugUserName string `json:"debugUserName"`
	DebugViewMode string `json:"debugViewMode"`
}

type AdminSettingsUpdateRequest struct {
	AcceptNewUser *bool   `json:"acceptNewUser"`
	DebugMode     *bool   `json:"debugMode"`
	DebugUserName *string `json:"debugUserName"`
	DebugViewMode *string `json:"debugViewMode"`
}

type AdminPasswordChangeRequest struct {
	NewPassword string `json:"newPassword"`
}

type UserObject struct {
	ID        string    `json:"id"`
	UserID    string    `json:"userId"`
	UserName  string    `json:"userName"`
	Name      string    `json:"name"`
	HasData   bool      `json:"hasData"`
	RoomCount int       `json:"roomCount"`
	CreatedAt time.Time `json:"createdAt"`
}

type CreateObjectRequest struct {
	UserID string `json:"userId"`
	Name   string `json:"name"`
}

type Floor struct {
	ID         string    `json:"id"`
	HouseID    string    `json:"houseId"`
	Name       string    `json:"name"`
	LevelIndex int       `json:"levelIndex"`
	ElevationM float64   `json:"elevationM"`
	HeightM    float64   `json:"heightM"`
	CreatedAt  time.Time `json:"createdAt"`
}

type PointM struct {
	X float64 `json:"x"`
	Y float64 `json:"y"`
}

type Room struct {
	ID             string    `json:"id"`
	FloorID        string    `json:"floorId"`
	Name           string    `json:"name"`
	ShapeType      string    `json:"shapeType"`
	RoomType       string    `json:"roomType,omitempty"`
	WallThicknessM float64   `json:"wallThicknessM"`
	Vertices       []PointM  `json:"vertices"`
	AreaM2         float64   `json:"areaM2"`
	CreatedAt      time.Time `json:"createdAt"`
}

type CreateRoomRequest struct {
	FloorID        string   `json:"floorId"`
	Name           string   `json:"name"`
	ShapeType      string   `json:"shapeType"`
	RoomType       string   `json:"roomType,omitempty"`
	WallThicknessM float64  `json:"wallThicknessM"`
	Vertices       []PointM `json:"vertices"`
}

type UpdateRoomRequest struct {
	Name           string   `json:"name"`
	ShapeType      string   `json:"shapeType"`
	RoomType       string   `json:"roomType,omitempty"`
	WallThicknessM float64  `json:"wallThicknessM"`
	Vertices       []PointM `json:"vertices"`
}

type Opening struct {
	ID          string    `json:"id"`
	FloorID     string    `json:"floorId"`
	RoomID      string    `json:"roomId"`
	Name        string    `json:"name"`
	OpeningType string    `json:"openingType"`
	X           float64   `json:"x"`
	Y           float64   `json:"y"`
	WidthM      float64   `json:"widthM"`
	AngleDeg    float64   `json:"angleDeg"`
	CreatedAt   time.Time `json:"createdAt"`
}

type CreateOpeningRequest struct {
	FloorID     string  `json:"floorId"`
	RoomID      string  `json:"roomId"`
	Name        string  `json:"name"`
	OpeningType string  `json:"openingType"`
	X           float64 `json:"x"`
	Y           float64 `json:"y"`
	WidthM      float64 `json:"widthM"`
	AngleDeg    float64 `json:"angleDeg"`
}

type WallObject struct {
	ID         string    `json:"id"`
	FloorID    string    `json:"floorId"`
	RoomID     string    `json:"roomId"`
	EdgeIndex  int       `json:"edgeIndex"`
	ObjectType string    `json:"objectType"`
	X          float64   `json:"x"`
	Y          float64   `json:"y"`
	W          float64   `json:"w"`
	H          float64   `json:"h"`
	GroupID    string    `json:"groupId"`
	CreatedAt  time.Time `json:"createdAt"`
}

type CreateWallObjectRequest struct {
	FloorID    string  `json:"floorId"`
	RoomID     string  `json:"roomId"`
	EdgeIndex  int     `json:"edgeIndex"`
	ObjectType string  `json:"objectType"`
	X          float64 `json:"x"`
	Y          float64 `json:"y"`
	W          float64 `json:"w"`
	H          float64 `json:"h"`
	GroupID    string  `json:"groupId"`
}

type UpdateWallObjectRequest struct {
	ObjectType string   `json:"objectType"`
	X          *float64 `json:"x"`
	Y          *float64 `json:"y"`
	W          *float64 `json:"w"`
	H          *float64 `json:"h"`
	GroupID    *string  `json:"groupId"`
}

type HealthResponse struct {
	OK      bool   `json:"ok"`
	Service string `json:"service"`
}

type AppOverview struct {
	Users    int `json:"users"`
	Objects  int `json:"objects"`
	Houses   int `json:"houses"`
	Floors   int `json:"floors"`
	Rooms    int `json:"rooms"`
	Devices  int `json:"devices"`
	Cables   int `json:"cables"`
	Circuits int `json:"circuits"`
}
