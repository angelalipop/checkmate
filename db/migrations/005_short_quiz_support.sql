-- CheckMate: Support Short Quiz, Other, and Assessment Type aliases
-- File: db/migrations/005_short_quiz_support.sql
--
-- Safe to run multiple times (idempotent).
-- Extends chk_exams_assessment_type on exams to allow 'short_quiz' and 'other'
-- alongside 'quiz', 'long_quiz', 'prelim', 'midterm', 'prefinal', 'final'.

BEGIN;

ALTER TABLE exams DROP CONSTRAINT IF EXISTS chk_exams_assessment_type;

ALTER TABLE exams
    ADD CONSTRAINT chk_exams_assessment_type CHECK (
        assessment_type IS NULL
        OR assessment_type IN (
            'quiz',
            'short_quiz',
            'long_quiz',
            'prelim',
            'midterm',
            'prefinal',
            'pre_finals',
            'final',
            'finals',
            'other'
        )
    );

COMMIT;
