-- ============================================
-- Jungfruturer Booking System — Supabase Setup
-- ============================================
-- Run this in the Supabase SQL Editor (Dashboard → SQL Editor → New query)

-- 1. Tables
-- ---------

CREATE TABLE trips (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  date DATE NOT NULL,
  departure_time TIME NOT NULL,
  departure_location TEXT NOT NULL CHECK (departure_location IN ('Byxelkrok', 'Oskarshamn')),
  max_capacity INTEGER NOT NULL CHECK (max_capacity > 0)
);

CREATE TABLE bookings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  trip_id UUID NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  phone TEXT NOT NULL,
  num_people INTEGER NOT NULL CHECK (num_people > 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_bookings_trip_id ON bookings(trip_id);
CREATE INDEX idx_bookings_phone ON bookings(phone);
CREATE INDEX idx_trips_date ON trips(date);

-- 2. Capacity enforcement trigger
-- --------------------------------

CREATE OR REPLACE FUNCTION check_capacity()
RETURNS TRIGGER AS $$
BEGIN
  IF (
    SELECT COALESCE(SUM(num_people), 0) + NEW.num_people
    FROM bookings
    WHERE trip_id = NEW.trip_id
  ) > (
    SELECT max_capacity FROM trips WHERE id = NEW.trip_id
  ) THEN
    RAISE EXCEPTION 'Inte tillräckligt med platser kvar'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER enforce_capacity
BEFORE INSERT ON bookings
FOR EACH ROW
EXECUTE FUNCTION check_capacity();

-- 3. RPC functions (used by customers via anon key)
-- --------------------------------------------------

-- Get trips for a date with availability info
CREATE OR REPLACE FUNCTION get_trips_with_availability(target_date DATE)
RETURNS TABLE (
  id UUID,
  date DATE,
  departure_time TIME,
  departure_location TEXT,
  max_capacity INTEGER,
  booked BIGINT,
  spots_left BIGINT
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    t.id, t.date, t.departure_time, t.departure_location, t.max_capacity,
    COALESCE(SUM(b.num_people), 0) AS booked,
    (t.max_capacity - COALESCE(SUM(b.num_people), 0)) AS spots_left
  FROM trips t
  LEFT JOIN bookings b ON b.trip_id = t.id
  WHERE t.date = target_date
  GROUP BY t.id
  ORDER BY t.departure_time;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Get bookings for a phone number
CREATE OR REPLACE FUNCTION get_my_bookings(my_phone TEXT)
RETURNS TABLE (
  id UUID,
  trip_id UUID,
  name TEXT,
  phone TEXT,
  num_people INTEGER,
  created_at TIMESTAMPTZ,
  trip_date DATE,
  trip_time TIME,
  trip_location TEXT
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    b.id, b.trip_id, b.name, b.phone, b.num_people, b.created_at,
    t.date AS trip_date, t.departure_time AS trip_time, t.departure_location AS trip_location
  FROM bookings b
  JOIN trips t ON t.id = b.trip_id
  WHERE b.phone = my_phone
  ORDER BY t.date, t.departure_time;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Cancel a booking (requires matching phone)
CREATE OR REPLACE FUNCTION cancel_booking(booking_id UUID, booking_phone TEXT)
RETURNS BOOLEAN AS $$
DECLARE
  deleted_count INTEGER;
BEGIN
  DELETE FROM bookings WHERE id = booking_id AND phone = booking_phone;
  GET DIAGNOSTICS deleted_count = ROW_COUNT;
  RETURN deleted_count > 0;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 4. Row Level Security
-- ----------------------

ALTER TABLE trips ENABLE ROW LEVEL SECURITY;
ALTER TABLE bookings ENABLE ROW LEVEL SECURITY;

-- Trips: anyone can read, only authenticated (admin) can modify
CREATE POLICY "trips_select" ON trips FOR SELECT USING (true);
CREATE POLICY "trips_insert" ON trips FOR INSERT WITH CHECK (auth.role() = 'authenticated');
CREATE POLICY "trips_update" ON trips FOR UPDATE USING (auth.role() = 'authenticated');
CREATE POLICY "trips_delete" ON trips FOR DELETE USING (auth.role() = 'authenticated');

-- Bookings: anon can insert, only authenticated (admin) can read/delete
CREATE POLICY "bookings_insert" ON bookings FOR INSERT WITH CHECK (true);
CREATE POLICY "bookings_select" ON bookings FOR SELECT USING (auth.role() = 'authenticated');
CREATE POLICY "bookings_delete" ON bookings FOR DELETE USING (auth.role() = 'authenticated');
