-- CheckMate: Academic Management (programs, curricula, curriculum subjects, electives)
-- Migration: 006_academic_management.sql
--
-- Adds NEW tables only. The existing "subjects", "classes", "students" and
-- "exams" tables are not touched, so Teachers, Students, Classes and Exams
-- keep working exactly as before.
--
-- Deletion: every table carries is_deleted / deleted_at / deleted_by so the
-- backend can run in "soft" delete mode. Whether the API soft-deletes or
-- hard-deletes is chosen by the server (ACADEMIC_DELETE_MODE), not here.
-- All normal queries must filter on is_deleted = FALSE.

BEGIN;

-- ============================================================
-- PROGRAMS (college program or Senior High School strand)
-- ============================================================

CREATE TABLE IF NOT EXISTS academic_programs (
    id          BIGSERIAL PRIMARY KEY,
    code        VARCHAR(20)  NOT NULL,
    name        VARCHAR(200) NOT NULL,
    level       VARCHAR(10)  NOT NULL CHECK (level IN ('college', 'shs')),
    department  VARCHAR(120),
    is_deleted  BOOLEAN      NOT NULL DEFAULT FALSE,
    deleted_at  TIMESTAMPTZ,
    deleted_by  BIGINT REFERENCES users(id),
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_academic_programs_code
    ON academic_programs (UPPER(code))
    WHERE is_deleted = FALSE;


-- ============================================================
-- CURRICULA (a version of a program, e.g. BSIT 2401)
-- ============================================================

CREATE TABLE IF NOT EXISTS curricula (
    id              BIGSERIAL PRIMARY KEY,
    program_id      BIGINT      NOT NULL REFERENCES academic_programs(id),
    code            VARCHAR(20) NOT NULL,
    status          VARCHAR(12) NOT NULL DEFAULT 'draft'
                        CHECK (status IN ('draft', 'published')),
    copied_from_id  BIGINT REFERENCES curricula(id),
    published_at    TIMESTAMPTZ,
    published_by    BIGINT REFERENCES users(id),
    is_deleted      BOOLEAN     NOT NULL DEFAULT FALSE,
    deleted_at      TIMESTAMPTZ,
    deleted_by      BIGINT REFERENCES users(id),
    created_by      BIGINT REFERENCES users(id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_curricula_program_code
    ON curricula (program_id, UPPER(code))
    WHERE is_deleted = FALSE;

CREATE INDEX IF NOT EXISTS idx_curricula_program
    ON curricula (program_id)
    WHERE is_deleted = FALSE;


-- ============================================================
-- SUBJECT CATALOG (shared by every curriculum)
-- A subject lives here once and is linked into many curricula, so a shared
-- subject (e.g. GEDC1002) stays available in every other curriculum when it
-- is removed from one of them.
-- ============================================================

CREATE TABLE IF NOT EXISTS academic_subjects (
    id          BIGSERIAL PRIMARY KEY,
    code        VARCHAR(30),                       -- NULL for SHS subjects and unnumbered elective slots
    name        VARCHAR(250) NOT NULL,
    units       NUMERIC(4,1) CHECK (units IS NULL OR units >= 0),
    hours       INTEGER      CHECK (hours IS NULL OR hours >= 0),   -- SHS required duration
    is_deleted  BOOLEAN      NOT NULL DEFAULT FALSE,
    deleted_at  TIMESTAMPTZ,
    deleted_by  BIGINT REFERENCES users(id),
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_academic_subjects_code
    ON academic_subjects (LOWER(code))
    WHERE code IS NOT NULL AND is_deleted = FALSE;

CREATE UNIQUE INDEX IF NOT EXISTS uq_academic_subjects_name_nocode
    ON academic_subjects (LOWER(name))
    WHERE code IS NULL AND is_deleted = FALSE;


-- ============================================================
-- CURRICULUM SUBJECTS (which subject sits in which year level + term)
-- SHS strands use year_level 1 = Grade 11, 2 = Grade 12.
-- ============================================================

CREATE TABLE IF NOT EXISTS curriculum_subjects (
    id               BIGSERIAL PRIMARY KEY,
    curriculum_id    BIGINT   NOT NULL REFERENCES curricula(id),
    subject_id       BIGINT   NOT NULL REFERENCES academic_subjects(id),
    year_level       SMALLINT NOT NULL CHECK (year_level BETWEEN 1 AND 4),
    term             SMALLINT NOT NULL CHECK (term BETWEEN 1 AND 2),
    category         VARCHAR(12)
                         CHECK (category IS NULL OR category IN ('core', 'applied', 'specialized')),
    is_elective_slot BOOLEAN  NOT NULL DEFAULT FALSE,
    sort_order       INTEGER  NOT NULL DEFAULT 0,
    is_deleted       BOOLEAN  NOT NULL DEFAULT FALSE,
    deleted_at       TIMESTAMPTZ,
    deleted_by       BIGINT REFERENCES users(id),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_curriculum_subjects_slot
    ON curriculum_subjects (curriculum_id, year_level, term, subject_id)
    WHERE is_deleted = FALSE;

CREATE INDEX IF NOT EXISTS idx_curriculum_subjects_term
    ON curriculum_subjects (curriculum_id, year_level, term)
    WHERE is_deleted = FALSE;

CREATE INDEX IF NOT EXISTS idx_curriculum_subjects_subject
    ON curriculum_subjects (subject_id);


-- ============================================================
-- LIST OF ELECTIVES (per curriculum, shown separately from the term subjects)
-- ============================================================

CREATE TABLE IF NOT EXISTS curriculum_electives (
    id             BIGSERIAL PRIMARY KEY,
    curriculum_id  BIGINT       NOT NULL REFERENCES curricula(id),
    subject_id     BIGINT       NOT NULL REFERENCES academic_subjects(id),
    group_name     VARCHAR(120),
    sort_order     INTEGER      NOT NULL DEFAULT 0,
    is_deleted     BOOLEAN      NOT NULL DEFAULT FALSE,
    deleted_at     TIMESTAMPTZ,
    deleted_by     BIGINT REFERENCES users(id),
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_curriculum_electives_subject
    ON curriculum_electives (curriculum_id, subject_id)
    WHERE is_deleted = FALSE;

CREATE INDEX IF NOT EXISTS idx_curriculum_electives_curriculum
    ON curriculum_electives (curriculum_id)
    WHERE is_deleted = FALSE;


-- ============================================================
-- ELECTIVE SELECTIONS (the elective finalized for a slot in a school year)
-- Allowed on published curricula: choosing an elective does not change the
-- curriculum itself. A slot with no selection keeps showing as listed.
-- ============================================================

CREATE TABLE IF NOT EXISTS elective_selections (
    id                     BIGSERIAL PRIMARY KEY,
    curriculum_subject_id  BIGINT      NOT NULL REFERENCES curriculum_subjects(id),
    elective_id            BIGINT      NOT NULL REFERENCES curriculum_electives(id),
    school_year            VARCHAR(9)  NOT NULL CHECK (school_year ~ '^[0-9]{4}-[0-9]{4}$'),
    is_deleted             BOOLEAN     NOT NULL DEFAULT FALSE,
    deleted_at             TIMESTAMPTZ,
    deleted_by             BIGINT REFERENCES users(id),
    created_by             BIGINT REFERENCES users(id),
    created_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_elective_selection_slot_year
    ON elective_selections (curriculum_subject_id, school_year)
    WHERE is_deleted = FALSE;


-- ============================================================
-- INTEGRITY GUARDS
-- 1. A published curriculum's subjects and electives are locked.
-- 2. A published curriculum cannot go back to draft or be deleted.
-- ============================================================

CREATE OR REPLACE FUNCTION checkmate_curriculum_content_locked()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    cid BIGINT;
    st  TEXT;
BEGIN
    cid := COALESCE(NEW.curriculum_id, OLD.curriculum_id);
    SELECT status INTO st FROM curricula WHERE id = cid;
    IF st = 'published' THEN
        RAISE EXCEPTION 'Published curriculum is read-only. Copy it to a draft to make changes.';
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_curriculum_subjects_locked ON curriculum_subjects;
CREATE TRIGGER trg_curriculum_subjects_locked
BEFORE INSERT OR UPDATE OR DELETE ON curriculum_subjects
FOR EACH ROW EXECUTE FUNCTION checkmate_curriculum_content_locked();

DROP TRIGGER IF EXISTS trg_curriculum_electives_locked ON curriculum_electives;
CREATE TRIGGER trg_curriculum_electives_locked
BEFORE INSERT OR UPDATE OR DELETE ON curriculum_electives
FOR EACH ROW EXECUTE FUNCTION checkmate_curriculum_content_locked();

CREATE OR REPLACE FUNCTION checkmate_curriculum_status_guard()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.status = 'published' THEN
            RAISE EXCEPTION 'A published curriculum cannot be deleted.';
        END IF;
        RETURN OLD;
    END IF;

    IF OLD.status = 'published' AND NEW.status <> 'published' THEN
        RAISE EXCEPTION 'A published curriculum cannot be changed back to draft.';
    END IF;
    IF OLD.status = 'published' AND NEW.is_deleted = TRUE AND OLD.is_deleted = FALSE THEN
        RAISE EXCEPTION 'A published curriculum cannot be deleted.';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_curriculum_status_guard ON curricula;
CREATE TRIGGER trg_curriculum_status_guard
BEFORE UPDATE OR DELETE ON curricula
FOR EACH ROW EXECUTE FUNCTION checkmate_curriculum_status_guard();

COMMIT;
