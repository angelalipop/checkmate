-- CheckMate: one-time student edit
-- File: db/migrations/006_student_one_time_edit.sql
--
-- Run AFTER 001 to 005. Non-destructive and safe to run twice.
--
-- students.edited_at is NULL until a teacher / admin uses the one-time Edit
-- (name, student number, email) from the student info. Once it is set, the
-- API refuses any further edit of that student. No existing row is changed.

BEGIN;

ALTER TABLE students
    ADD COLUMN IF NOT EXISTS edited_at TIMESTAMPTZ;

COMMIT;
