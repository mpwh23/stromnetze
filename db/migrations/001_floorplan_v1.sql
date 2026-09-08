-- Floorplan V1: room drawing metadata and doors/windows

ALTER TABLE rooms
    ADD COLUMN IF NOT EXISTS shape_type TEXT NOT NULL DEFAULT 'rectangle';

ALTER TABLE rooms
    ADD COLUMN IF NOT EXISTS wall_thickness_m NUMERIC(8,3) NOT NULL DEFAULT 0.115;

UPDATE rooms
SET shape_type = 'rectangle'
WHERE shape_type IS NULL OR shape_type = '';

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

CREATE INDEX IF NOT EXISTS idx_room_openings_floor ON room_openings(floor_id);
CREATE INDEX IF NOT EXISTS idx_room_openings_room ON room_openings(room_id);
