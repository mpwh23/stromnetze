-- strom database schema
-- PostgreSQL + PostGIS

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS projects (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS houses (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    address_note TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS floors (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    house_id UUID NOT NULL REFERENCES houses(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    level_index INTEGER NOT NULL,
    elevation_m NUMERIC(8,3) NOT NULL DEFAULT 0,
    height_m NUMERIC(8,3) NOT NULL DEFAULT 2.5,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(house_id, level_index)
);

CREATE TABLE IF NOT EXISTS rooms (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    floor_id UUID NOT NULL REFERENCES floors(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    room_type TEXT NOT NULL DEFAULT 'room',
    shape_type TEXT NOT NULL DEFAULT 'rectangle',
    wall_thickness_m NUMERIC(8,3) NOT NULL DEFAULT 0.115,
    polygon geometry(Polygon, 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS walls (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    floor_id UUID NOT NULL REFERENCES floors(id) ON DELETE CASCADE,
    room_id UUID REFERENCES rooms(id) ON DELETE SET NULL,
    name TEXT NOT NULL,
    centerline geometry(LineStringZ, 0),
    thickness_m NUMERIC(8,3) NOT NULL DEFAULT 0.115,
    height_m NUMERIC(8,3),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS distribution_boards (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    floor_id UUID NOT NULL REFERENCES floors(id) ON DELETE CASCADE,
    wall_id UUID REFERENCES walls(id) ON DELETE SET NULL,
    name TEXT NOT NULL,
    position geometry(PointZ, 0),
    rows_count INTEGER NOT NULL DEFAULT 1,
    modules_per_row INTEGER NOT NULL DEFAULT 12,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS protection_devices (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    board_id UUID NOT NULL REFERENCES distribution_boards(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    device_type TEXT NOT NULL CHECK (device_type IN ('main_switch','rcd','mcb','rcbo','fuse','surge_protection','meter','other')),
    row_no INTEGER NOT NULL DEFAULT 1,
    module_start INTEGER NOT NULL DEFAULT 1,
    module_width NUMERIC(6,2) NOT NULL DEFAULT 1,
    rating_a INTEGER,
    poles INTEGER NOT NULL DEFAULT 1,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS circuits (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    board_id UUID NOT NULL REFERENCES distribution_boards(id) ON DELETE CASCADE,
    protection_device_id UUID REFERENCES protection_devices(id) ON DELETE SET NULL,
    rcd_id UUID REFERENCES protection_devices(id) ON DELETE SET NULL,
    name TEXT NOT NULL,
    circuit_no TEXT NOT NULL DEFAULT '',
    phase TEXT CHECK (phase IN ('L1','L2','L3','L1L2L3','unknown')) DEFAULT 'unknown',
    voltage_v INTEGER NOT NULL DEFAULT 230,
    intended_use TEXT NOT NULL DEFAULT '',
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS devices (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    floor_id UUID NOT NULL REFERENCES floors(id) ON DELETE CASCADE,
    room_id UUID REFERENCES rooms(id) ON DELETE SET NULL,
    wall_id UUID REFERENCES walls(id) ON DELETE SET NULL,
    circuit_id UUID REFERENCES circuits(id) ON DELETE SET NULL,
    name TEXT NOT NULL,
    device_type TEXT NOT NULL CHECK (device_type IN ('switch','socket','light','consumer','junction_box','terminal_box','sensor','other')),
    position geometry(PointZ, 0),
    mount_height_m NUMERIC(8,3),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS terminals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id UUID REFERENCES devices(id) ON DELETE CASCADE,
    board_id UUID REFERENCES distribution_boards(id) ON DELETE CASCADE,
    protection_device_id UUID REFERENCES protection_devices(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    terminal_type TEXT NOT NULL CHECK (terminal_type IN ('L','N','PE','switched_L','data','control','unknown')) DEFAULT 'unknown',
    phase TEXT CHECK (phase IN ('L1','L2','L3','N','PE','unknown')) DEFAULT 'unknown',
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (
      (device_id IS NOT NULL)::integer +
      (board_id IS NOT NULL)::integer +
      (protection_device_id IS NOT NULL)::integer = 1
    )
);

CREATE TABLE IF NOT EXISTS cables (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    circuit_id UUID REFERENCES circuits(id) ON DELETE SET NULL,
    name TEXT NOT NULL,
    cable_type TEXT NOT NULL DEFAULT 'NYM-J',
    conductor_count INTEGER NOT NULL DEFAULT 3,
    cross_section_mm2 NUMERIC(8,2) NOT NULL DEFAULT 1.5,
    route geometry(LineStringZ, 0),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS cable_conductors (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cable_id UUID NOT NULL REFERENCES cables(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    color TEXT NOT NULL DEFAULT '',
    function TEXT NOT NULL CHECK (function IN ('L','N','PE','switched_L','traveller','control','data','spare','unknown')) DEFAULT 'unknown',
    phase TEXT CHECK (phase IN ('L1','L2','L3','N','PE','unknown')) DEFAULT 'unknown',
    from_terminal_id UUID REFERENCES terminals(id) ON DELETE SET NULL,
    to_terminal_id UUID REFERENCES terminals(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS electrical_connections (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    from_terminal_id UUID NOT NULL REFERENCES terminals(id) ON DELETE CASCADE,
    to_terminal_id UUID NOT NULL REFERENCES terminals(id) ON DELETE CASCADE,
    conductor_id UUID REFERENCES cable_conductors(id) ON DELETE SET NULL,
    circuit_id UUID REFERENCES circuits(id) ON DELETE SET NULL,
    connection_type TEXT NOT NULL CHECK (connection_type IN ('physical_wire','bridge','terminal_link','logical','unknown')) DEFAULT 'physical_wire',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);


CREATE TABLE IF NOT EXISTS room_openings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    floor_id UUID NOT NULL REFERENCES floors(id) ON DELETE CASCADE,
    room_id UUID REFERENCES rooms(id) ON DELETE SET NULL,
    name TEXT NOT NULL DEFAULT '',
    opening_type TEXT NOT NULL CHECK (opening_type IN ('door','window')),
    x_m NUMERIC(10,3) NOT NULL,
    y_m NUMERIC(10,3) NOT NULL,
    width_m NUMERIC(8,3) NOT NULL DEFAULT 0.9,
    angle_deg NUMERIC(8,2) NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_rooms_polygon ON rooms USING GIST (polygon);
CREATE INDEX IF NOT EXISTS idx_room_openings_floor ON room_openings(floor_id);
CREATE INDEX IF NOT EXISTS idx_room_openings_room ON room_openings(room_id);
CREATE INDEX IF NOT EXISTS idx_walls_centerline ON walls USING GIST (centerline);
CREATE INDEX IF NOT EXISTS idx_devices_position ON devices USING GIST (position);
CREATE INDEX IF NOT EXISTS idx_cables_route ON cables USING GIST (route);
CREATE INDEX IF NOT EXISTS idx_circuits_board ON circuits(board_id);
CREATE INDEX IF NOT EXISTS idx_devices_circuit ON devices(circuit_id);
CREATE INDEX IF NOT EXISTS idx_cables_circuit ON cables(circuit_id);
