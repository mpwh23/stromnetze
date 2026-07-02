import type {
  AdminSettingsUpdate,
  AdminUserUpdate,
  AppSettings,
  AppUser,
  CreateOpeningRequest,
  CreateRoomRequest,
  Floor,
  Opening,
  Overview,
  Room,
  UpdateRoomRequest,
  UserObject,
  WallObject,
  CreateWallObjectRequest,
  UpdateWallObjectRequest,
} from './types'

const API_BASE = import.meta.env.VITE_API_BASE ?? '/strom/api'

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`${API_BASE}${path}`, {
    headers: { 'Content-Type': 'application/json', ...(init?.headers ?? {}) },
    ...init,
  })
  if (!response.ok) {
    throw new Error(await response.text())
  }
  return response.json() as Promise<T>
}

export function getUsers() {
  return request<AppUser[]>('/users')
}

export function getPublicSettings() {
  return request<AppSettings>('/settings/public')
}

export function findUserByName(name: string) {
  return request<AppUser>(`/users/by-name?name=${encodeURIComponent(name)}`)
}

export function createUser(name: string, password: string) {
  return request<AppUser>('/users', {
    method: 'POST',
    body: JSON.stringify({ name, password }),
  })
}

export function loginUser(userId: string, password: string) {
  return request<AppUser>('/users/login', {
    method: 'POST',
    body: JSON.stringify({ userId, password }),
  })
}

export function getAdminUsers(password: string) {
  return request<AppUser[]>(`/admin/users?password=${encodeURIComponent(password)}`)
}

export function updateAdminUser(userId: string, password: string, payload: AdminUserUpdate) {
  return request<AppUser>(`/admin/users?id=${encodeURIComponent(userId)}&password=${encodeURIComponent(password)}`, {
    method: 'PUT',
    body: JSON.stringify(payload),
  })
}

export function deleteAdminUser(userId: string, password: string) {
  return request<{ ok: boolean }>(`/admin/users?id=${encodeURIComponent(userId)}&password=${encodeURIComponent(password)}`, {
    method: 'DELETE',
  })
}

export function getAdminSettings(password: string) {
  return request<AppSettings>(`/admin/settings?password=${encodeURIComponent(password)}`)
}

export function updateAdminSettings(password: string, payload: AdminSettingsUpdate) {
  return request<AppSettings>(`/admin/settings?password=${encodeURIComponent(password)}`, {
    method: 'PUT',
    body: JSON.stringify(payload),
  })
}

export function changeAdminPassword(password: string, newPassword: string) {
  return request<{ ok: boolean }>(`/admin/password?password=${encodeURIComponent(password)}`, {
    method: 'PUT',
    body: JSON.stringify({ newPassword }),
  })
}

export function getObjects(userId: string) {
  return request<UserObject[]>(`/objects?userId=${encodeURIComponent(userId)}`)
}

export function createObject(userId: string, name: string) {
  return request<UserObject>('/objects', {
    method: 'POST',
    body: JSON.stringify({ userId, name }),
  })
}

export function deleteObject(objectId: string, userId: string) {
  return request<{ ok: boolean }>(`/objects?id=${encodeURIComponent(objectId)}&userId=${encodeURIComponent(userId)}`, {
    method: 'DELETE',
  })
}

export function getOverview(objectId?: string) {
  const query = objectId ? `?objectId=${encodeURIComponent(objectId)}` : ''
  return request<Overview>(`/overview${query}`)
}

export function getDefaultFloor(objectId?: string) {
  const query = objectId ? `?objectId=${encodeURIComponent(objectId)}` : ''
  return request<Floor>(`/floors/default${query}`)
}

export function getRooms(floorId: string) {
  return request<Room[]>(`/rooms?floorId=${encodeURIComponent(floorId)}`)
}

export function createRoom(payload: CreateRoomRequest) {
  return request<Room>('/rooms', {
    method: 'POST',
    body: JSON.stringify(payload),
  })
}

export function updateRoom(id: string, payload: UpdateRoomRequest) {
  return request<Room>(`/rooms?id=${encodeURIComponent(id)}`, {
    method: 'PUT',
    body: JSON.stringify(payload),
  })
}

export function deleteRoom(id: string) {
  return request<{ ok: boolean }>(`/rooms?id=${encodeURIComponent(id)}`, {
    method: 'DELETE',
  })
}

export function getOpenings(floorId: string) {
  return request<Opening[]>(`/openings?floorId=${encodeURIComponent(floorId)}`)
}

export function createOpening(payload: CreateOpeningRequest) {
  return request<Opening>('/openings', {
    method: 'POST',
    body: JSON.stringify(payload),
  })
}

export function deleteOpening(id: string) {
  return request<{ ok: boolean }>(`/openings?id=${encodeURIComponent(id)}`, {
    method: 'DELETE',
  })
}



export function getWallObjects(floorId: string) {
  return request<WallObject[]>(`/wall-objects?floorId=${encodeURIComponent(floorId)}`)
}

export function createWallObject(payload: CreateWallObjectRequest) {
  return request<WallObject>('/wall-objects', {
    method: 'POST',
    body: JSON.stringify(payload),
  })
}

export function updateWallObject(id: string, payload: UpdateWallObjectRequest) {
  return request<WallObject>(`/wall-objects?id=${encodeURIComponent(id)}`, {
    method: 'PUT',
    body: JSON.stringify(payload),
  })
}

export function deleteWallObject(id: string) {
  return request<{ ok: boolean }>(`/wall-objects?id=${encodeURIComponent(id)}`, {
    method: 'DELETE',
  })
}


