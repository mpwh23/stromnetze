export type AppUser = {
  id: string
  name: string
  createdAt: string
  isAdmin?: boolean
  canViewAllObjects?: boolean
  inList?: boolean
}

export type UserObject = {
  id: string
  userId: string
  userName?: string
  name: string
  createdAt: string
  hasData?: boolean
  roomCount?: number
}

export type AdminUserUpdate = {
  name?: string
  canViewAllObjects?: boolean
  inList?: boolean
}

export type AppSettings = {
  acceptNewUser: boolean
  debugMode: boolean
  debugUserName: string
  debugViewMode: ViewMode
}

export type AdminSettingsUpdate = {
  acceptNewUser?: boolean
  debugMode?: boolean
  debugUserName?: string
  debugViewMode?: ViewMode
}

export type Floor = {
  id: string
  houseId: string
  name: string
  levelIndex: number
  elevationM: number
  heightM: number
  createdAt: string
}

export type PointM = {
  x: number
  y: number
}

export type RoomShapeType = 'rectangle' | 'polygon'
export type RoomType = 'room' | 'stair'

export type Room = {
  id: string
  floorId: string
  name: string
  shapeType: RoomShapeType
  roomType?: RoomType
  wallThicknessM: number
  vertices: PointM[]
  areaM2: number
  createdAt: string
}

export type OpeningType = 'door' | 'window'

export type Opening = {
  id: string
  floorId: string
  roomId: string
  name: string
  openingType: OpeningType
  x: number
  y: number
  widthM: number
  angleDeg: number
  createdAt: string
}

export type CreateRoomRequest = {
  floorId: string
  name: string
  shapeType: RoomShapeType
  roomType?: RoomType
  wallThicknessM: number
  vertices: PointM[]
}

export type UpdateRoomRequest = {
  name: string
  shapeType: RoomShapeType
  roomType?: RoomType
  wallThicknessM: number
  vertices: PointM[]
}

export type CreateOpeningRequest = {
  floorId: string
  roomId?: string
  name: string
  openingType: OpeningType
  x: number
  y: number
  widthM: number
  angleDeg: number
}



export type WallObjectType = 'door' | 'window' | 'socket'

export type WallObject = {
  id: string
  floorId: string
  roomId: string
  edgeIndex: number
  objectType: WallObjectType
  x: number
  y: number
  w: number
  h: number
  groupId: string
  createdAt: string
}

export type CreateWallObjectRequest = {
  floorId: string
  roomId: string
  edgeIndex: number
  objectType: WallObjectType
  x: number
  y: number
  w: number
  h: number
  groupId?: string
}

export type UpdateWallObjectRequest = Partial<Pick<CreateWallObjectRequest, 'objectType' | 'x' | 'y' | 'w' | 'h' | 'groupId'>>

export type Overview = {
  users: number
  objects: number
  houses: number
  floors: number
  rooms: number
  devices: number
  cables: number
  circuits: number
}

export type ViewMode = 'floorplan' | 'wall' | 'board' | 'threeD'



