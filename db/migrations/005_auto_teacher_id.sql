-- CheckMate: automatically allocated, immutable Teacher IDs.
-- Run ONCE after migration 004 and BEFORE deploying the matching backend.
BEGIN;

CREATE TABLE IF NOT EXISTS teacher_id_counters (
  year INTEGER PRIMARY KEY CHECK (year BETWEEN 2000 AND 9999),
  last_number INTEGER NOT NULL CHECK (last_number BETWEEN 1 AND 9999)
);

-- Resume after any already-issued formatted IDs; never reset a year's counter.
INSERT INTO teacher_id_counters (year, last_number)
SELECT substring(teacher_id_no FROM 4 FOR 4)::INTEGER,
       MAX(substring(teacher_id_no FROM 9 FOR 4)::INTEGER)
FROM users
WHERE teacher_id_no ~ '^CM-[0-9]{4}-[0-9]{4}$'
GROUP BY substring(teacher_id_no FROM 4 FOR 4)::INTEGER
ON CONFLICT (year) DO UPDATE
  SET last_number = GREATEST(teacher_id_counters.last_number, EXCLUDED.last_number);

-- Existing numeric IDs are retained for backwards compatibility.
ALTER TABLE users DROP CONSTRAINT IF EXISTS chk_users_teacher_id_format;
ALTER TABLE users ADD CONSTRAINT chk_users_teacher_id_format CHECK (
  teacher_id_no IS NULL OR
  teacher_id_no ~ '^(CM-[0-9]{4}-(000[1-9]|00[1-9][0-9]|0[1-9][0-9]{2}|[1-9][0-9]{3})|[0-9]{3,20})$'
);

-- Enforce immutability even if a future API mistakenly tries to change an ID.
CREATE OR REPLACE FUNCTION checkmate_teacher_id_immutable()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.teacher_id_no IS NOT NULL
     AND NEW.teacher_id_no IS DISTINCT FROM OLD.teacher_id_no THEN
    RAISE EXCEPTION 'Teacher ID cannot be changed once assigned.';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_teacher_id_immutable ON users;
CREATE TRIGGER trg_teacher_id_immutable
BEFORE UPDATE OF teacher_id_no ON users
FOR EACH ROW EXECUTE FUNCTION checkmate_teacher_id_immutable();

COMMIT;
