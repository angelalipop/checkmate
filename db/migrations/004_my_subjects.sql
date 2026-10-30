-- CheckMate: My Subjects module
-- File: db/migrations/004_my_subjects.sql
--
-- Run AFTER 001, 002 and 003. Non-destructive and safe to run twice:
--   * no table or column is dropped, no row is deleted or rewritten;
--   * no sample / test data is inserted.
--
-- What it adds
--   1. exams.assessment_type  quiz | long_quiz | prelim | midterm | prefinal | final
--                             (NULL for exams created before this migration:
--                              their type is unknown, so none is invented)
--   2. exams.version          the version number of the assessment (starts at 1)
--   3. exam_class_assignments which classes (Subject + Section) an assessment
--                             is given to, and WHICH VERSION each one got
--   4. assessment_absences    a teacher's explicit "Absent" confirmation
--
-- Backfill: every existing exam is linked to the class it already belongs to
-- (exams.class_id), at its current version. That copies real relationships
-- only; nothing is made up.

BEGIN;

-- ------------------------------------------------------------
-- 1 + 2. Assessment type and version on exams
-- ------------------------------------------------------------

ALTER TABLE exams
    ADD COLUMN IF NOT EXISTS assessment_type VARCHAR(20),
    ADD COLUMN IF NOT EXISTS version INTEGER NOT NULL DEFAULT 1;

ALTER TABLE exams DROP CONSTRAINT IF EXISTS chk_exams_assessment_type;
ALTER TABLE exams
    ADD CONSTRAINT chk_exams_assessment_type CHECK (
        assessment_type IS NULL
        OR assessment_type IN (
            'quiz', 'long_quiz', 'prelim', 'midterm', 'prefinal', 'final'
        )
    );

ALTER TABLE exams DROP CONSTRAINT IF EXISTS chk_exams_version_positive;
ALTER TABLE exams
    ADD CONSTRAINT chk_exams_version_positive CHECK (version >= 1);

-- ------------------------------------------------------------
-- 3. One assessment -> many classes, with the version each one got
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS exam_class_assignments (
    id           BIGSERIAL PRIMARY KEY,
    exam_id      BIGINT NOT NULL REFERENCES exams(id)   ON DELETE CASCADE,
    class_id     BIGINT NOT NULL REFERENCES classes(id) ON DELETE CASCADE,
    exam_version INTEGER NOT NULL CHECK (exam_version >= 1),
    assigned_by  BIGINT REFERENCES users(id) ON DELETE SET NULL,
    assigned_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_exam_class_assignment UNIQUE (exam_id, class_id)
);

CREATE INDEX IF NOT EXISTS idx_exam_class_assignments_class
    ON exam_class_assignments (class_id);

INSERT INTO exam_class_assignments (exam_id, class_id, exam_version)
SELECT e.id, e.class_id, e.version
FROM exams e
ON CONFLICT (exam_id, class_id) DO NOTHING;

-- ------------------------------------------------------------
-- 4. Explicit absence (never inferred from a missing scan)
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS assessment_absences (
    exam_id    BIGINT NOT NULL REFERENCES exams(id)    ON DELETE CASCADE,
    student_id BIGINT NOT NULL REFERENCES students(id) ON DELETE CASCADE,
    marked_by  BIGINT REFERENCES users(id) ON DELETE SET NULL,
    marked_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (exam_id, student_id)
);

COMMIT;
