-- STROM165: Schema der laufenden Datenbank (pg_dump --schema-only, ohne Daten).
-- Enthaelt auch Tabellen und Spalten, die in schema.sql und migrations/ fehlen.
--
-- PostgreSQL database dump
--



SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: postgis; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA public;


--
-- Name: EXTENSION postgis; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION postgis IS 'PostGIS geometry and geography spatial types and functions';


--
-- Name: update_app_settings_timestamp(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_app_settings_timestamp() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: app_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_settings (
    key text NOT NULL,
    value text DEFAULT ''::text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: app_users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_users (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    password_hash text,
    is_admin boolean DEFAULT false NOT NULL,
    can_view_all_objects boolean DEFAULT false NOT NULL,
    in_list boolean DEFAULT false NOT NULL,
    central_admin_user_id bigint
);


--
-- Name: cable_conductors; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cable_conductors (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    cable_id uuid NOT NULL,
    name text NOT NULL,
    color text DEFAULT ''::text NOT NULL,
    function text DEFAULT 'unknown'::text NOT NULL,
    phase text DEFAULT 'unknown'::text,
    from_terminal_id uuid,
    to_terminal_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT cable_conductors_function_check CHECK ((function = ANY (ARRAY['L'::text, 'N'::text, 'PE'::text, 'switched_L'::text, 'traveller'::text, 'control'::text, 'data'::text, 'spare'::text, 'unknown'::text]))),
    CONSTRAINT cable_conductors_phase_check CHECK ((phase = ANY (ARRAY['L1'::text, 'L2'::text, 'L3'::text, 'N'::text, 'PE'::text, 'unknown'::text])))
);


--
-- Name: cables; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cables (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    project_id uuid NOT NULL,
    circuit_id uuid,
    name text NOT NULL,
    cable_type text DEFAULT 'NYM-J'::text NOT NULL,
    conductor_count integer DEFAULT 3 NOT NULL,
    cross_section_mm2 numeric(8,2) DEFAULT 1.5 NOT NULL,
    route public.geometry(LineStringZ),
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: circuits; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.circuits (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    board_id uuid NOT NULL,
    protection_device_id uuid,
    rcd_id uuid,
    name text NOT NULL,
    circuit_no text DEFAULT ''::text NOT NULL,
    phase text DEFAULT 'unknown'::text,
    voltage_v integer DEFAULT 230 NOT NULL,
    intended_use text DEFAULT ''::text NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT circuits_phase_check CHECK ((phase = ANY (ARRAY['L1'::text, 'L2'::text, 'L3'::text, 'L1L2L3'::text, 'unknown'::text])))
);


--
-- Name: devices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.devices (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    floor_id uuid NOT NULL,
    room_id uuid,
    wall_id uuid,
    circuit_id uuid,
    name text NOT NULL,
    device_type text NOT NULL,
    "position" public.geometry(PointZ),
    mount_height_m numeric(8,3),
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT devices_device_type_check CHECK ((device_type = ANY (ARRAY['switch'::text, 'socket'::text, 'light'::text, 'consumer'::text, 'junction_box'::text, 'terminal_box'::text, 'sensor'::text, 'other'::text])))
);


--
-- Name: distribution_boards; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.distribution_boards (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    floor_id uuid NOT NULL,
    wall_id uuid,
    name text NOT NULL,
    "position" public.geometry(PointZ),
    rows_count integer DEFAULT 1 NOT NULL,
    modules_per_row integer DEFAULT 12 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: electrical_connections; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.electrical_connections (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    from_terminal_id uuid NOT NULL,
    to_terminal_id uuid NOT NULL,
    conductor_id uuid,
    circuit_id uuid,
    connection_type text DEFAULT 'physical_wire'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT electrical_connections_connection_type_check CHECK ((connection_type = ANY (ARRAY['physical_wire'::text, 'bridge'::text, 'terminal_link'::text, 'logical'::text, 'unknown'::text])))
);


--
-- Name: floors; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.floors (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    house_id uuid NOT NULL,
    name text NOT NULL,
    level_index integer NOT NULL,
    elevation_m numeric(8,3) DEFAULT 0 NOT NULL,
    height_m numeric(8,3) DEFAULT 2.5 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: houses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.houses (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    project_id uuid NOT NULL,
    name text NOT NULL,
    address_note text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: projects; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.projects (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    object_id uuid NOT NULL
);


--
-- Name: protection_devices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.protection_devices (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    board_id uuid NOT NULL,
    name text NOT NULL,
    device_type text NOT NULL,
    row_no integer DEFAULT 1 NOT NULL,
    module_start integer DEFAULT 1 NOT NULL,
    module_width numeric(6,2) DEFAULT 1 NOT NULL,
    rating_a integer,
    poles integer DEFAULT 1 NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT protection_devices_device_type_check CHECK ((device_type = ANY (ARRAY['main_switch'::text, 'rcd'::text, 'mcb'::text, 'rcbo'::text, 'fuse'::text, 'surge_protection'::text, 'meter'::text, 'other'::text])))
);


--
-- Name: room_openings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.room_openings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    floor_id uuid NOT NULL,
    room_id uuid,
    name text DEFAULT ''::text NOT NULL,
    opening_type text NOT NULL,
    x_m numeric(10,3) NOT NULL,
    y_m numeric(10,3) NOT NULL,
    width_m numeric(8,3) DEFAULT 0.9 NOT NULL,
    angle_deg numeric(8,2) DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT room_openings_opening_type_check CHECK ((opening_type = ANY (ARRAY['door'::text, 'window'::text])))
);


--
-- Name: rooms; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rooms (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    floor_id uuid NOT NULL,
    name text NOT NULL,
    room_type text DEFAULT 'room'::text NOT NULL,
    shape_type text DEFAULT 'rectangle'::text NOT NULL,
    wall_thickness_m numeric(8,3) DEFAULT 0.115 NOT NULL,
    polygon public.geometry(Polygon),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT rooms_room_type_check CHECK ((room_type = ANY (ARRAY['room'::text, 'stair'::text])))
);


--
-- Name: terminals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.terminals (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    device_id uuid,
    board_id uuid,
    protection_device_id uuid,
    name text NOT NULL,
    terminal_type text DEFAULT 'unknown'::text NOT NULL,
    phase text DEFAULT 'unknown'::text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT terminals_check CHECK ((((((device_id IS NOT NULL))::integer + ((board_id IS NOT NULL))::integer) + ((protection_device_id IS NOT NULL))::integer) = 1)),
    CONSTRAINT terminals_phase_check CHECK ((phase = ANY (ARRAY['L1'::text, 'L2'::text, 'L3'::text, 'N'::text, 'PE'::text, 'unknown'::text]))),
    CONSTRAINT terminals_terminal_type_check CHECK ((terminal_type = ANY (ARRAY['L'::text, 'N'::text, 'PE'::text, 'switched_L'::text, 'data'::text, 'control'::text, 'unknown'::text])))
);


--
-- Name: user_objects; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_objects (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    name text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: wall_objects; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.wall_objects (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    floor_id uuid NOT NULL,
    room_id uuid NOT NULL,
    edge_index integer NOT NULL,
    object_type text NOT NULL,
    x double precision NOT NULL,
    y double precision NOT NULL,
    w double precision NOT NULL,
    h double precision NOT NULL,
    group_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT wall_objects_edge_index_check CHECK ((edge_index >= 0)),
    CONSTRAINT wall_objects_h_check CHECK (((h > (0)::double precision) AND (h <= (1)::double precision))),
    CONSTRAINT wall_objects_object_type_check CHECK ((object_type = ANY (ARRAY['door'::text, 'window'::text, 'socket'::text]))),
    CONSTRAINT wall_objects_w_check CHECK (((w > (0)::double precision) AND (w <= (1)::double precision))),
    CONSTRAINT wall_objects_x_check CHECK (((x >= (0)::double precision) AND (x <= (1)::double precision))),
    CONSTRAINT wall_objects_y_check CHECK (((y >= (0)::double precision) AND (y <= (1)::double precision)))
);


--
-- Name: walls; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.walls (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    floor_id uuid NOT NULL,
    room_id uuid,
    name text NOT NULL,
    centerline public.geometry(LineStringZ),
    thickness_m numeric(8,3) DEFAULT 0.115 NOT NULL,
    height_m numeric(8,3),
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: app_settings app_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_settings
    ADD CONSTRAINT app_settings_pkey PRIMARY KEY (key);


--
-- Name: app_users app_users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_users
    ADD CONSTRAINT app_users_pkey PRIMARY KEY (id);


--
-- Name: cable_conductors cable_conductors_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_conductors
    ADD CONSTRAINT cable_conductors_pkey PRIMARY KEY (id);


--
-- Name: cables cables_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cables
    ADD CONSTRAINT cables_pkey PRIMARY KEY (id);


--
-- Name: circuits circuits_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.circuits
    ADD CONSTRAINT circuits_pkey PRIMARY KEY (id);


--
-- Name: devices devices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.devices
    ADD CONSTRAINT devices_pkey PRIMARY KEY (id);


--
-- Name: distribution_boards distribution_boards_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.distribution_boards
    ADD CONSTRAINT distribution_boards_pkey PRIMARY KEY (id);


--
-- Name: electrical_connections electrical_connections_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.electrical_connections
    ADD CONSTRAINT electrical_connections_pkey PRIMARY KEY (id);


--
-- Name: floors floors_house_id_level_index_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.floors
    ADD CONSTRAINT floors_house_id_level_index_key UNIQUE (house_id, level_index);


--
-- Name: floors floors_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.floors
    ADD CONSTRAINT floors_pkey PRIMARY KEY (id);


--
-- Name: houses houses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.houses
    ADD CONSTRAINT houses_pkey PRIMARY KEY (id);


--
-- Name: projects projects_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.projects
    ADD CONSTRAINT projects_pkey PRIMARY KEY (id);


--
-- Name: protection_devices protection_devices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.protection_devices
    ADD CONSTRAINT protection_devices_pkey PRIMARY KEY (id);


--
-- Name: room_openings room_openings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.room_openings
    ADD CONSTRAINT room_openings_pkey PRIMARY KEY (id);


--
-- Name: rooms rooms_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rooms
    ADD CONSTRAINT rooms_pkey PRIMARY KEY (id);


--
-- Name: terminals terminals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.terminals
    ADD CONSTRAINT terminals_pkey PRIMARY KEY (id);


--
-- Name: user_objects user_objects_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_objects
    ADD CONSTRAINT user_objects_pkey PRIMARY KEY (id);


--
-- Name: wall_objects wall_objects_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wall_objects
    ADD CONSTRAINT wall_objects_pkey PRIMARY KEY (id);


--
-- Name: walls walls_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.walls
    ADD CONSTRAINT walls_pkey PRIMARY KEY (id);


--
-- Name: idx_app_users_central_admin_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_app_users_central_admin_user_id ON public.app_users USING btree (central_admin_user_id) WHERE (central_admin_user_id IS NOT NULL);


--
-- Name: idx_app_users_name_lower; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_app_users_name_lower ON public.app_users USING btree (lower(name));


--
-- Name: idx_cables_circuit; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cables_circuit ON public.cables USING btree (circuit_id);


--
-- Name: idx_cables_route; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cables_route ON public.cables USING gist (route);


--
-- Name: idx_circuits_board; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_circuits_board ON public.circuits USING btree (board_id);


--
-- Name: idx_devices_circuit; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_devices_circuit ON public.devices USING btree (circuit_id);


--
-- Name: idx_devices_position; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_devices_position ON public.devices USING gist ("position");


--
-- Name: idx_projects_object; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_projects_object ON public.projects USING btree (object_id);


--
-- Name: idx_room_openings_floor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_room_openings_floor ON public.room_openings USING btree (floor_id);


--
-- Name: idx_room_openings_room; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_room_openings_room ON public.room_openings USING btree (room_id);


--
-- Name: idx_rooms_polygon; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rooms_polygon ON public.rooms USING gist (polygon);


--
-- Name: idx_user_objects_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_objects_user ON public.user_objects USING btree (user_id);


--
-- Name: idx_wall_objects_floor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_wall_objects_floor_id ON public.wall_objects USING btree (floor_id);


--
-- Name: idx_wall_objects_group_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_wall_objects_group_id ON public.wall_objects USING btree (group_id);


--
-- Name: idx_wall_objects_wall; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_wall_objects_wall ON public.wall_objects USING btree (floor_id, room_id, edge_index);


--
-- Name: idx_walls_centerline; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_walls_centerline ON public.walls USING gist (centerline);


--
-- Name: app_settings app_settings_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER app_settings_updated_at BEFORE UPDATE ON public.app_settings FOR EACH ROW EXECUTE FUNCTION public.update_app_settings_timestamp();


--
-- Name: cable_conductors cable_conductors_cable_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_conductors
    ADD CONSTRAINT cable_conductors_cable_id_fkey FOREIGN KEY (cable_id) REFERENCES public.cables(id) ON DELETE CASCADE;


--
-- Name: cable_conductors cable_conductors_from_terminal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_conductors
    ADD CONSTRAINT cable_conductors_from_terminal_id_fkey FOREIGN KEY (from_terminal_id) REFERENCES public.terminals(id) ON DELETE SET NULL;


--
-- Name: cable_conductors cable_conductors_to_terminal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cable_conductors
    ADD CONSTRAINT cable_conductors_to_terminal_id_fkey FOREIGN KEY (to_terminal_id) REFERENCES public.terminals(id) ON DELETE SET NULL;


--
-- Name: cables cables_circuit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cables
    ADD CONSTRAINT cables_circuit_id_fkey FOREIGN KEY (circuit_id) REFERENCES public.circuits(id) ON DELETE SET NULL;


--
-- Name: cables cables_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cables
    ADD CONSTRAINT cables_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: circuits circuits_board_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.circuits
    ADD CONSTRAINT circuits_board_id_fkey FOREIGN KEY (board_id) REFERENCES public.distribution_boards(id) ON DELETE CASCADE;


--
-- Name: circuits circuits_protection_device_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.circuits
    ADD CONSTRAINT circuits_protection_device_id_fkey FOREIGN KEY (protection_device_id) REFERENCES public.protection_devices(id) ON DELETE SET NULL;


--
-- Name: circuits circuits_rcd_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.circuits
    ADD CONSTRAINT circuits_rcd_id_fkey FOREIGN KEY (rcd_id) REFERENCES public.protection_devices(id) ON DELETE SET NULL;


--
-- Name: devices devices_circuit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.devices
    ADD CONSTRAINT devices_circuit_id_fkey FOREIGN KEY (circuit_id) REFERENCES public.circuits(id) ON DELETE SET NULL;


--
-- Name: devices devices_floor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.devices
    ADD CONSTRAINT devices_floor_id_fkey FOREIGN KEY (floor_id) REFERENCES public.floors(id) ON DELETE CASCADE;


--
-- Name: devices devices_room_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.devices
    ADD CONSTRAINT devices_room_id_fkey FOREIGN KEY (room_id) REFERENCES public.rooms(id) ON DELETE SET NULL;


--
-- Name: devices devices_wall_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.devices
    ADD CONSTRAINT devices_wall_id_fkey FOREIGN KEY (wall_id) REFERENCES public.walls(id) ON DELETE SET NULL;


--
-- Name: distribution_boards distribution_boards_floor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.distribution_boards
    ADD CONSTRAINT distribution_boards_floor_id_fkey FOREIGN KEY (floor_id) REFERENCES public.floors(id) ON DELETE CASCADE;


--
-- Name: distribution_boards distribution_boards_wall_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.distribution_boards
    ADD CONSTRAINT distribution_boards_wall_id_fkey FOREIGN KEY (wall_id) REFERENCES public.walls(id) ON DELETE SET NULL;


--
-- Name: electrical_connections electrical_connections_circuit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.electrical_connections
    ADD CONSTRAINT electrical_connections_circuit_id_fkey FOREIGN KEY (circuit_id) REFERENCES public.circuits(id) ON DELETE SET NULL;


--
-- Name: electrical_connections electrical_connections_conductor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.electrical_connections
    ADD CONSTRAINT electrical_connections_conductor_id_fkey FOREIGN KEY (conductor_id) REFERENCES public.cable_conductors(id) ON DELETE SET NULL;


--
-- Name: electrical_connections electrical_connections_from_terminal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.electrical_connections
    ADD CONSTRAINT electrical_connections_from_terminal_id_fkey FOREIGN KEY (from_terminal_id) REFERENCES public.terminals(id) ON DELETE CASCADE;


--
-- Name: electrical_connections electrical_connections_to_terminal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.electrical_connections
    ADD CONSTRAINT electrical_connections_to_terminal_id_fkey FOREIGN KEY (to_terminal_id) REFERENCES public.terminals(id) ON DELETE CASCADE;


--
-- Name: floors floors_house_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.floors
    ADD CONSTRAINT floors_house_id_fkey FOREIGN KEY (house_id) REFERENCES public.houses(id) ON DELETE CASCADE;


--
-- Name: houses houses_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.houses
    ADD CONSTRAINT houses_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: projects projects_object_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.projects
    ADD CONSTRAINT projects_object_id_fkey FOREIGN KEY (object_id) REFERENCES public.user_objects(id) ON DELETE CASCADE;


--
-- Name: protection_devices protection_devices_board_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.protection_devices
    ADD CONSTRAINT protection_devices_board_id_fkey FOREIGN KEY (board_id) REFERENCES public.distribution_boards(id) ON DELETE CASCADE;


--
-- Name: room_openings room_openings_floor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.room_openings
    ADD CONSTRAINT room_openings_floor_id_fkey FOREIGN KEY (floor_id) REFERENCES public.floors(id) ON DELETE CASCADE;


--
-- Name: room_openings room_openings_room_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.room_openings
    ADD CONSTRAINT room_openings_room_id_fkey FOREIGN KEY (room_id) REFERENCES public.rooms(id) ON DELETE SET NULL;


--
-- Name: rooms rooms_floor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rooms
    ADD CONSTRAINT rooms_floor_id_fkey FOREIGN KEY (floor_id) REFERENCES public.floors(id) ON DELETE CASCADE;


--
-- Name: terminals terminals_board_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.terminals
    ADD CONSTRAINT terminals_board_id_fkey FOREIGN KEY (board_id) REFERENCES public.distribution_boards(id) ON DELETE CASCADE;


--
-- Name: terminals terminals_device_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.terminals
    ADD CONSTRAINT terminals_device_id_fkey FOREIGN KEY (device_id) REFERENCES public.devices(id) ON DELETE CASCADE;


--
-- Name: terminals terminals_protection_device_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.terminals
    ADD CONSTRAINT terminals_protection_device_id_fkey FOREIGN KEY (protection_device_id) REFERENCES public.protection_devices(id) ON DELETE CASCADE;


--
-- Name: user_objects user_objects_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_objects
    ADD CONSTRAINT user_objects_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.app_users(id) ON DELETE CASCADE;


--
-- Name: wall_objects wall_objects_floor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wall_objects
    ADD CONSTRAINT wall_objects_floor_id_fkey FOREIGN KEY (floor_id) REFERENCES public.floors(id) ON DELETE CASCADE;


--
-- Name: wall_objects wall_objects_room_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wall_objects
    ADD CONSTRAINT wall_objects_room_id_fkey FOREIGN KEY (room_id) REFERENCES public.rooms(id) ON DELETE CASCADE;


--
-- Name: walls walls_floor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.walls
    ADD CONSTRAINT walls_floor_id_fkey FOREIGN KEY (floor_id) REFERENCES public.floors(id) ON DELETE CASCADE;


--
-- Name: walls walls_room_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.walls
    ADD CONSTRAINT walls_room_id_fkey FOREIGN KEY (room_id) REFERENCES public.rooms(id) ON DELETE SET NULL;


--
-- PostgreSQL database dump complete
--


