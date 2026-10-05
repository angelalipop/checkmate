-- CheckMate
-- Teaching assignments (Subject + Section) and year levels
-- Migration: 003_teaching_assignments.sql
--
-- A row in "classes" is already one Subject + Section offering (students and
-- exams hang off it), so it IS the teaching assignment:
--     classes.teacher_id  = the teacher who teaches that subject in that section
-- This migration adds (1) a year level and (2) a database-level guarantee that
-- the same Subject + Section can never exist twice, so it can never belong to
-- two teachers.

BEGIN;

-- ============================================================
-- 1. YEAR LEVEL
-- ============================================================

ALTER TABLE classes
    ADD COLUMN IF NOT EXISTS year_level SMALLINT
        CHECK (year_level BETWEEN 1 AND 6);

-- Best-effort backfill from the first digit in the section name
-- ("BSIT 1-A" -> 1, "BSIT-3A" -> 3). Sections with no digit stay NULL.
UPDATE classes
SET year_level = substring(section from '[0-9]')::smallint
WHERE year_level IS NULL
  AND substring(section from '[0-9]') ~ '^[1-6]$';


-- ============================================================
-- 2. ONE OFFERING PER SUBJECT + SECTION
-- Refuse loudly if duplicates already exist, instead of guessing
-- which row to keep.
-- ============================================================

DO $$
DECLARE
    dup TEXT;
BEGIN
    SELECT string_agg(
               format('subject_id %s / "%s" (%s rows)', subject_id, sec, n),
               '; '
           )
    INTO dup
    FROM (
        SELECT subject_id,
               LOWER(section) AS sec,
               COUNT(*) AS n
        FROM classes
        GROUP BY subject_id,
                 LOWER(section),
                 COALESCE(school_year, ''),
                 COALESCE(semester, '')
        HAVING COUNT(*) > 1
    ) d;

    IF dup IS NOT NULL THEN
        RAISE EXCEPTION
            'Duplicate Subject + Section classes exist: %. Merge or delete the duplicates in the Classes screen/database, then run this migration again.',
            dup;
    END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_classes_subject_section
    ON classes (
        subject_id,
        LOWER(section),
        COALESCE(school_year, ''),
        COALESCE(semester, '')
    );

COMMIT;
