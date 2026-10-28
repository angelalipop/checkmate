-- CheckMate: Academic Management (combined migration)
-- File: 003_academic_module.sql
--
-- PARTS 1 to 4 are the old 006, 007, 008 and 009 joined together, in the same
-- order and with the same SQL. PART 5 links teaching subjects to Academic
-- Management subjects. PART 6 is the section catalog (it was the separate
-- server/sql/create_sections.sql). Each part keeps its own BEGIN/COMMIT.
--
-- Run it once, after 001_initial_schema.sql and 002_teacher_module.sql.
-- It can be run again without errors, but a second run would put back any
-- seeded program, curriculum or subject that you deleted in the meantime.
-- Do NOT keep the four old files next to this one in a folder that is run
-- automatically.


-- ============================================================
-- PART 1 of 6: tables, indexes and integrity guards (was 006_academic_management.sql)
-- ============================================================

-- CheckMate: Academic Management (programs, curricula, curriculum subjects, electives)
-- Migration: 006_academic_management.sql
--
-- Parts 1 to 4 add NEW tables only. The existing "subjects", "classes",
-- "students" and "exams" tables are not touched by them, so Teachers,
-- Students, Classes and Exams keep working exactly as before. (PART 5 adds
-- one optional column to "subjects"; PART 6 adds the "sections" table.)
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


-- ============================================================
-- PART 2 of 6: STI programs, curricula, subjects and electives (was 007_academic_seed.sql)
-- ============================================================

-- CheckMate: Academic Management seed data
-- Migration: 007_academic_seed.sql   (run after 006_academic_management.sql)
--
-- Source: STI program guides (BSIT, BSCpE, BSBA, BSAIS, BSA, BSHM, BSTM, BMMA,
-- BACOMM) and the STI Senior High School STEM and ABM strand sheets.
--   * Term unit totals were checked against the printed TOTAL of every term.
--   * OJT / practicum / internship / work immersion subjects are NOT included.
--   * Electives are stored in the program's LIST OF ELECTIVES; the elective
--     slots inside the terms (e.g. "IT Elective 1") stay as listed until an
--     elective is finalized for a school year.
-- Safe to run twice: existing rows are skipped.

BEGIN;

CREATE TEMP TABLE seed_programs (
    code TEXT, name TEXT, level TEXT, department TEXT, curriculum_code TEXT
) ON COMMIT DROP;

CREATE TEMP TABLE seed_rows (
    program_code TEXT, kind TEXT, year_level INT, term INT, group_name TEXT,
    category TEXT, is_slot BOOLEAN, code TEXT, name TEXT, units NUMERIC, hours INT, sort_order INT
) ON COMMIT DROP;

INSERT INTO seed_programs (code, name, level, department, curriculum_code) VALUES
  ('BACOMM', 'Bachelor of Arts in Communication', 'college', 'Arts and Communication Department', '2201'),
  ('BMMA', 'Bachelor of Multimedia Arts', 'college', 'Arts and Communication Department', '2201'),
  ('BSCpE', 'Bachelor of Science in Computer Engineering', 'college', 'Computing Department', '2201'),
  ('BSHM', 'Bachelor of Science in Hospitality Management', 'college', 'Hospitality and Tourism Department', '2201'),
  ('BSTM', 'Bachelor of Science in Tourism Management', 'college', 'Hospitality and Tourism Department', '2201'),
  ('BSA', 'Bachelor of Science in Accountancy', 'college', 'Business Department', '2401'),
  ('BSAIS', 'Bachelor of Science in Accounting Information System', 'college', 'Business Department', '2401'),
  ('BSBA', 'Bachelor of Science in Business Administration', 'college', 'Business Department', '2401'),
  ('BSIT', 'Bachelor of Science in Information Technology', 'college', 'Computing Department', '2401'),
  ('STEM', 'Science, Technology, Engineering, and Mathematics', 'shs', NULL, 'SHS'),
  ('ABM', 'Accountancy, Business, and Management', 'shs', NULL, 'SHS');

INSERT INTO seed_rows (program_code, kind, year_level, term, group_name, category, is_slot, code, name, units, hours, sort_order) VALUES
  ('BACOMM', 'subject', 1, 1, NULL, NULL, FALSE, 'ACOM1001', 'Introduction to Communication Media', '3', NULL, 1),
  ('BACOMM', 'subject', 1, 1, NULL, NULL, FALSE, 'STIC1002', 'Euthenics 1', '1', NULL, 2),
  ('BACOMM', 'subject', 1, 1, NULL, NULL, FALSE, 'GEDC1005', 'Mathematics in the Modern World', '3', NULL, 3),
  ('BACOMM', 'subject', 1, 1, NULL, NULL, FALSE, 'NSTP1008', 'National Service Training Program 1', '3', NULL, 4),
  ('BACOMM', 'subject', 1, 1, NULL, NULL, FALSE, 'PHED1005', 'P.E./PATHFIT 1: Movement Competency Training', '2', NULL, 5),
  ('BACOMM', 'subject', 1, 1, NULL, NULL, FALSE, 'GEDC1006', 'Readings in Philippine History', '3', NULL, 6),
  ('BACOMM', 'subject', 1, 1, NULL, NULL, FALSE, 'GEDC1008', 'Understanding the Self', '3', NULL, 7),
  ('BACOMM', 'subject', 1, 2, NULL, NULL, FALSE, 'ACOM1002', 'Communication, Culture, and Society', '3', NULL, 8),
  ('BACOMM', 'subject', 1, 2, NULL, NULL, FALSE, 'GEDC1009', 'Ethics', '3', NULL, 9),
  ('BACOMM', 'subject', 1, 2, NULL, NULL, FALSE, 'NSTP1010', 'National Service Training Program 2', '3', NULL, 10),
  ('BACOMM', 'subject', 1, 2, NULL, NULL, FALSE, 'PHED1006', 'P.E./PATHFIT 2: Exercise-based Fitness Activities', '2', NULL, 11),
  ('BACOMM', 'subject', 1, 2, NULL, NULL, FALSE, 'GEDC1016', 'Purposive Communication', '3', NULL, 12),
  ('BACOMM', 'subject', 1, 2, NULL, NULL, FALSE, 'STIC1003', 'Computer Productivity Tools', '1', NULL, 13),
  ('BACOMM', 'subject', 1, 2, NULL, NULL, FALSE, 'CASC1001', 'Digital Photography', '3', NULL, 14),
  ('BACOMM', 'subject', 2, 1, NULL, NULL, FALSE, 'GEDC1002', 'The Contemporary World', '3', NULL, 15),
  ('BACOMM', 'subject', 2, 1, NULL, NULL, FALSE, 'GEDC1003', 'The Entrepreneurial Mind', '3', NULL, 16),
  ('BACOMM', 'subject', 2, 1, NULL, NULL, FALSE, 'GEDC1014', 'Rizal''s Life and Works', '3', NULL, 17),
  ('BACOMM', 'subject', 2, 1, NULL, NULL, FALSE, 'PHED1007', 'P.E./PATHFIT 3: Individual-Dual Sports', '2', NULL, 18),
  ('BACOMM', 'subject', 2, 1, NULL, NULL, FALSE, 'ACOM1003', 'Broadcasting Principles and Practices', '3', NULL, 19),
  ('BACOMM', 'subject', 2, 1, NULL, NULL, FALSE, 'ACOM1004', 'Journalism Principles and Practices', '3', NULL, 20),
  ('BACOMM', 'subject', 2, 2, NULL, NULL, FALSE, 'ACOM1005', 'Communication Theory', '3', NULL, 21),
  ('BACOMM', 'subject', 2, 2, NULL, NULL, FALSE, 'ACOM1006', 'Development Communication', '3', NULL, 22),
  ('BACOMM', 'subject', 2, 2, NULL, NULL, FALSE, 'GEDC1010', 'Art Appreciation', '3', NULL, 23),
  ('BACOMM', 'subject', 2, 2, NULL, NULL, FALSE, 'PHED1008', 'P.E./PATHFIT 4: Team Sports', '2', NULL, 24),
  ('BACOMM', 'subject', 2, 2, NULL, NULL, FALSE, 'GEDC1013', 'Science, Technology, and Society', '3', NULL, 25),
  ('BACOMM', 'subject', 2, 2, NULL, NULL, FALSE, 'CASC1002', 'Brand Communication and Design', '3', NULL, 26),
  ('BACOMM', 'subject', 3, 1, NULL, NULL, FALSE, 'ACOM1007', 'Communication Media Laws and Ethics', '3', NULL, 27),
  ('BACOMM', 'subject', 3, 1, NULL, NULL, FALSE, 'ACOM1008', 'Risk, Disaster, and Humanitarian Communication', '3', NULL, 28),
  ('BACOMM', 'subject', 3, 1, NULL, NULL, FALSE, 'GEDC1045', 'Great Books', '3', NULL, 29),
  ('BACOMM', 'subject', 3, 1, NULL, NULL, FALSE, 'ACOM1009', 'Social Media Principles and Practices', '3', NULL, 30),
  ('BACOMM', 'subject', 3, 1, NULL, NULL, FALSE, 'ACOM1010', 'Advertising Principles and Practices', '3', NULL, 31),
  ('BACOMM', 'subject', 3, 1, NULL, NULL, FALSE, 'ACOM1011', 'Multimedia Journalism', '3', NULL, 32),
  ('BACOMM', 'subject', 3, 2, NULL, NULL, FALSE, 'ACOM1012', 'Communication Research', '3', NULL, 33),
  ('BACOMM', 'subject', 3, 2, NULL, NULL, FALSE, 'GEDC1041', 'Philippine Popular Culture', '3', NULL, 34),
  ('BACOMM', 'subject', 3, 2, NULL, NULL, FALSE, 'STIC1007', 'Euthenics 2', '1', NULL, 35),
  ('BACOMM', 'subject', 3, 2, NULL, NULL, FALSE, 'GEDC1007', 'Panitikang Pilipino', '3', NULL, 36),
  ('BACOMM', 'subject', 3, 2, NULL, NULL, FALSE, 'CASC1003', 'Writing for New Media', '3', NULL, 37),
  ('BACOMM', 'subject', 3, 2, NULL, NULL, FALSE, 'ACOM1013', 'Digital Learning Materials Development', '3', NULL, 38),
  ('BACOMM', 'subject', 3, 2, NULL, NULL, FALSE, 'ACOM1014', 'Social Media and Mobile Technology for Communication Campaigns', '3', NULL, 39),
  ('BACOMM', 'subject', 4, 1, NULL, NULL, FALSE, 'ACOM1015', 'Communication Planning', '3', NULL, 40),
  ('BACOMM', 'subject', 4, 1, NULL, NULL, FALSE, 'ACOM1016', 'Digital Publishing', '3', NULL, 41),
  ('BACOMM', 'subject', 4, 1, NULL, NULL, FALSE, 'ACOM1017', 'Web Content Management', '3', NULL, 42),
  ('BACOMM', 'subject', 4, 1, NULL, NULL, FALSE, 'ACOM1018', 'Thesis/Special Project 1', '3', NULL, 43),
  ('BACOMM', 'subject', 4, 1, NULL, NULL, FALSE, 'GEDC1035', 'World Literature', '3', NULL, 44),
  ('BACOMM', 'subject', 4, 2, NULL, NULL, FALSE, 'ACOM1019', 'Communication Management', '3', NULL, 45),
  ('BACOMM', 'subject', 4, 2, NULL, NULL, FALSE, 'ACOM1020', 'Knowledge Management', '3', NULL, 46),
  ('BACOMM', 'subject', 4, 2, NULL, NULL, FALSE, 'ACOM1021', 'Thesis/Special Project 2', '3', NULL, 47),
  ('BMMA', 'subject', 1, 1, NULL, NULL, FALSE, 'GEDC1002', 'The Contemporary World', '3', NULL, 1),
  ('BMMA', 'subject', 1, 1, NULL, NULL, FALSE, 'STIC1002', 'Euthenics 1', '1', NULL, 2),
  ('BMMA', 'subject', 1, 1, NULL, NULL, FALSE, 'GEDC1005', 'Mathematics in the Modern World', '3', NULL, 3),
  ('BMMA', 'subject', 1, 1, NULL, NULL, FALSE, 'NSTP1008', 'National Service Training Program 1', '3', NULL, 4),
  ('BMMA', 'subject', 1, 1, NULL, NULL, FALSE, 'PHED1005', 'P.E./PATHFIT 1: Movement Competency Training', '2', NULL, 5),
  ('BMMA', 'subject', 1, 1, NULL, NULL, FALSE, 'GEDC1006', 'Readings in Philippine History', '3', NULL, 6),
  ('BMMA', 'subject', 1, 1, NULL, NULL, FALSE, 'GEDC1008', 'Understanding the Self', '3', NULL, 7),
  ('BMMA', 'subject', 1, 1, NULL, NULL, FALSE, 'MMAR1001', 'Drawing 1', '2', NULL, 8),
  ('BMMA', 'subject', 1, 1, NULL, NULL, FALSE, 'MMAR1002', 'Introduction to Multimedia Arts', '3', NULL, 9),
  ('BMMA', 'subject', 1, 2, NULL, NULL, FALSE, 'GEDC1009', 'Ethics', '3', NULL, 10),
  ('BMMA', 'subject', 1, 2, NULL, NULL, FALSE, 'NSTP1010', 'National Service Training Program 2', '3', NULL, 11),
  ('BMMA', 'subject', 1, 2, NULL, NULL, FALSE, 'PHED1006', 'P.E./PATHFIT 2: Exercise-based Fitness Activities', '2', NULL, 12),
  ('BMMA', 'subject', 1, 2, NULL, NULL, FALSE, 'GEDC1016', 'Purposive Communication', '3', NULL, 13),
  ('BMMA', 'subject', 1, 2, NULL, NULL, FALSE, 'GEDC1013', 'Science, Technology, and Society', '3', NULL, 14),
  ('BMMA', 'subject', 1, 2, NULL, NULL, FALSE, 'STIC1003', 'Computer Productivity Tools', '1', NULL, 15),
  ('BMMA', 'subject', 1, 2, NULL, NULL, FALSE, 'MMAR1003', 'Drawing 2', '2', NULL, 16),
  ('BMMA', 'subject', 1, 2, NULL, NULL, FALSE, 'MMAR1004', 'Elements and Principles of Design', '3', NULL, 17),
  ('BMMA', 'subject', 1, 2, NULL, NULL, FALSE, 'MMAR1005', 'History of Graphic Design', '3', NULL, 18),
  ('BMMA', 'subject', 2, 1, NULL, NULL, FALSE, 'GEDC1003', 'The Entrepreneurial Mind', '3', NULL, 19),
  ('BMMA', 'subject', 2, 1, NULL, NULL, FALSE, 'GEDC1014', 'Rizal''s Life and Works', '3', NULL, 20),
  ('BMMA', 'subject', 2, 1, NULL, NULL, FALSE, 'PHED1007', 'P.E./PATHFIT 3: Individual-Dual Sports', '2', NULL, 21),
  ('BMMA', 'subject', 2, 1, NULL, NULL, FALSE, 'MMAR1006', '2D Animation', '3', NULL, 22),
  ('BMMA', 'subject', 2, 1, NULL, NULL, FALSE, 'MMAR1007', '3D Modeling', '3', NULL, 23),
  ('BMMA', 'subject', 2, 1, NULL, NULL, FALSE, 'MMAR1008', 'Color Theory', '3', NULL, 24),
  ('BMMA', 'subject', 2, 2, NULL, NULL, FALSE, 'GEDC1010', 'Art Appreciation', '3', NULL, 25),
  ('BMMA', 'subject', 2, 2, NULL, NULL, FALSE, 'GEDC1041', 'Philippine Popular Culture', '3', NULL, 26),
  ('BMMA', 'subject', 2, 2, NULL, NULL, FALSE, 'PHED1008', 'P.E./PATHFIT 4: Team Sports', '2', NULL, 27),
  ('BMMA', 'subject', 2, 2, NULL, NULL, FALSE, 'MMAR1009', '3D Animation', '3', NULL, 28),
  ('BMMA', 'subject', 2, 2, NULL, NULL, TRUE, 'MMAR1010', 'MMA Elective 1', '3', NULL, 29),
  ('BMMA', 'subject', 2, 2, NULL, NULL, FALSE, 'CASC1003', 'Writing for New Media', '3', NULL, 30),
  ('BMMA', 'subject', 3, 1, NULL, NULL, FALSE, 'GEDC1045', 'Great Books', '3', NULL, 31),
  ('BMMA', 'subject', 3, 1, NULL, NULL, FALSE, 'MMAR1011', 'Business Ventures in Multimedia', '3', NULL, 32),
  ('BMMA', 'subject', 3, 1, NULL, NULL, FALSE, 'CASC1004', 'Digital Photography', '3', NULL, 33),
  ('BMMA', 'subject', 3, 1, NULL, NULL, TRUE, 'MMAR1012', 'MMA Elective 2', '3', NULL, 34),
  ('BMMA', 'subject', 3, 1, NULL, NULL, TRUE, 'MMAR1013', 'MMA Free Elective 1', '3', NULL, 35),
  ('BMMA', 'subject', 3, 1, NULL, NULL, FALSE, 'MMAR1014', 'Typography and Layout', '3', NULL, 36),
  ('BMMA', 'subject', 3, 2, NULL, NULL, FALSE, 'GEDC1007', 'Panitikang Pilipino', '3', NULL, 37),
  ('BMMA', 'subject', 3, 2, NULL, NULL, FALSE, 'STIC1007', 'Euthenics 2', '1', NULL, 38),
  ('BMMA', 'subject', 3, 2, NULL, NULL, TRUE, 'MMAR1015', 'MMA Elective 3', '3', NULL, 39),
  ('BMMA', 'subject', 3, 2, NULL, NULL, TRUE, 'MMAR1016', 'MMA Free Elective 2', '3', NULL, 40),
  ('BMMA', 'subject', 3, 2, NULL, NULL, FALSE, 'MMAR1017', 'Fundamentals in Film and Video Production', '3', NULL, 41),
  ('BMMA', 'subject', 3, 2, NULL, NULL, FALSE, 'MMAR1018', 'Multimedia Publishing', '3', NULL, 42),
  ('BMMA', 'subject', 3, 2, NULL, NULL, FALSE, 'MMAR1031', 'Methods of Research', '3', NULL, 43),
  ('BMMA', 'subject', 4, 1, NULL, NULL, FALSE, 'MMAR1019', 'Capstone Project 1', '3', NULL, 44),
  ('BMMA', 'subject', 4, 1, NULL, NULL, FALSE, 'MMAR1020', 'Interactive Media Design', '3', NULL, 45),
  ('BMMA', 'subject', 4, 1, NULL, NULL, FALSE, 'MMAR1021', 'Multimedia Seminars', '3', NULL, 46),
  ('BMMA', 'subject', 4, 1, NULL, NULL, FALSE, 'MMAR1022', 'Digital Sound Production', '3', NULL, 47),
  ('BMMA', 'subject', 4, 1, NULL, NULL, FALSE, 'GEDC1035', 'World Literature', '3', NULL, 48),
  ('BMMA', 'subject', 4, 2, NULL, NULL, FALSE, 'MMAR1023', 'Capstone Project 2', '3', NULL, 49),
  ('BMMA', 'subject', 4, 2, NULL, NULL, FALSE, 'MMAR1024', 'Portfolio Preparation and Exhibit Design', '3', NULL, 50),
  ('BMMA', 'subject', 4, 2, NULL, NULL, FALSE, 'MMAR1025', 'Post-Production Techniques', '3', NULL, 51),
  ('BMMA', 'elective', NULL, NULL, 'Free Electives', NULL, FALSE, 'MMAR1026', 'Web Programming', '3', NULL, 52),
  ('BMMA', 'elective', NULL, NULL, 'Free Electives', NULL, FALSE, 'MMAR1027', 'Advanced Web Design', '3', NULL, 53),
  ('BMMA', 'elective', NULL, NULL, 'Graphic Design Electives', NULL, FALSE, 'MMAR1028', 'Advertising Creatives', '3', NULL, 54),
  ('BMMA', 'elective', NULL, NULL, 'Graphic Design Electives', NULL, FALSE, 'CASC1005', 'Brand Communication and Design', '3', NULL, 55),
  ('BMMA', 'elective', NULL, NULL, 'Graphic Design Electives', NULL, FALSE, 'MMAR1029', 'Motion Graphics Design', '3', NULL, 56),
  ('BMMA', 'elective', NULL, NULL, 'Graphic Design Electives', NULL, FALSE, 'MMAR1030', 'Fundamentals of Web Design', '3', NULL, 57),
  ('BSCpE', 'subject', 1, 1, NULL, NULL, FALSE, 'ENGR1001', 'Programming Logic and Design', '2', NULL, 1),
  ('BSCpE', 'subject', 1, 1, NULL, NULL, FALSE, 'GEDC1002', 'The Contemporary World', '3', NULL, 2),
  ('BSCpE', 'subject', 1, 1, NULL, NULL, FALSE, 'STIC1002', 'Euthenics 1', '1', NULL, 3),
  ('BSCpE', 'subject', 1, 1, NULL, NULL, FALSE, 'GEDC1005', 'Mathematics in the Modern World', '3', NULL, 4),
  ('BSCpE', 'subject', 1, 1, NULL, NULL, FALSE, 'NSTP1008', 'National Service Training Program 1', '3', NULL, 5),
  ('BSCpE', 'subject', 1, 1, NULL, NULL, FALSE, 'PHED1005', 'P.E./PATHFIT 1: Movement Competency Training', '2', NULL, 6),
  ('BSCpE', 'subject', 1, 1, NULL, NULL, FALSE, 'GEDC1008', 'Understanding the Self', '3', NULL, 7),
  ('BSCpE', 'subject', 1, 1, NULL, NULL, FALSE, 'ENGR1002', 'College Calculus (Differential)', '3', NULL, 8),
  ('BSCpE', 'subject', 1, 1, NULL, NULL, FALSE, 'ENGR1003', 'Chemistry for Engineers', '3', NULL, 9),
  ('BSCpE', 'subject', 1, 1, NULL, NULL, FALSE, 'ENGR1004', 'Computer Engineering as a Discipline', '1', NULL, 10),
  ('BSCpE', 'subject', 1, 2, NULL, NULL, FALSE, 'INTE1001', 'Object-Oriented Programming', '2', NULL, 11),
  ('BSCpE', 'subject', 1, 2, NULL, NULL, FALSE, 'ENGR1048', 'Discrete Mathematics', '3', NULL, 12),
  ('BSCpE', 'subject', 1, 2, NULL, NULL, FALSE, 'GEDC1010', 'Art Appreciation', '3', NULL, 13),
  ('BSCpE', 'subject', 1, 2, NULL, NULL, FALSE, 'NSTP1010', 'National Service Training Program 2', '3', NULL, 14),
  ('BSCpE', 'subject', 1, 2, NULL, NULL, FALSE, 'PHED1006', 'P.E./PATHFIT 2: Exercise-based Fitness Activities', '2', NULL, 15),
  ('BSCpE', 'subject', 1, 2, NULL, NULL, FALSE, 'GEDC1016', 'Purposive Communication', '3', NULL, 16),
  ('BSCpE', 'subject', 1, 2, NULL, NULL, FALSE, 'GEDC1013', 'Science, Technology, and Society', '3', NULL, 17),
  ('BSCpE', 'subject', 1, 2, NULL, NULL, FALSE, 'ENGR1005', 'College Calculus (Integral)', '3', NULL, 18),
  ('BSCpE', 'subject', 1, 2, NULL, NULL, FALSE, 'ENGR1007', 'Physics for Engineers', '3', NULL, 19),
  ('BSCpE', 'subject', 2, 1, NULL, NULL, FALSE, 'ENGR1008', 'Fundamentals of Electrical Circuits', '4', NULL, 20),
  ('BSCpE', 'subject', 2, 1, NULL, NULL, FALSE, 'ENGR1009', 'Operating Systems', '3', NULL, 21),
  ('BSCpE', 'subject', 2, 1, NULL, NULL, FALSE, 'COSC1004', 'Data Structures and Algorithms', '2', NULL, 22),
  ('BSCpE', 'subject', 2, 1, NULL, NULL, FALSE, 'ENGR1010', 'Emerging Technologies in CpE', '3', NULL, 23),
  ('BSCpE', 'subject', 2, 1, NULL, NULL, FALSE, 'GEDC1003', 'The Entrepreneurial Mind', '3', NULL, 24),
  ('BSCpE', 'subject', 2, 1, NULL, NULL, FALSE, 'GEDC1014', 'Rizal''s Life and Works', '3', NULL, 25),
  ('BSCpE', 'subject', 2, 1, NULL, NULL, FALSE, 'PHED1007', 'P.E./PATHFIT 3: Individual-Dual Sports', '2', NULL, 26),
  ('BSCpE', 'subject', 2, 1, NULL, NULL, FALSE, 'GEDC1006', 'Readings in Philippine History', '3', NULL, 27),
  ('BSCpE', 'subject', 2, 1, NULL, NULL, FALSE, 'ENGR1011', 'Differential Equations', '3', NULL, 28),
  ('BSCpE', 'subject', 2, 2, NULL, NULL, FALSE, 'ENGR1012', 'Numerical Methods', '3', NULL, 29),
  ('BSCpE', 'subject', 2, 2, NULL, NULL, FALSE, 'ENGR1013', 'Fundamentals of Electronic Circuits', '4', NULL, 30),
  ('BSCpE', 'subject', 2, 2, NULL, NULL, FALSE, 'ENGR1014', 'Software Design', '4', NULL, 31),
  ('BSCpE', 'subject', 2, 2, NULL, NULL, FALSE, 'GEDC1041', 'Philippine Popular Culture', '3', NULL, 32),
  ('BSCpE', 'subject', 2, 2, NULL, NULL, FALSE, 'GEDC1009', 'Ethics', '3', NULL, 33),
  ('BSCpE', 'subject', 2, 2, NULL, NULL, FALSE, 'PHED1008', 'P.E./PATHFIT 4: Team Sports', '2', NULL, 34),
  ('BSCpE', 'subject', 2, 2, NULL, NULL, FALSE, 'GEDC1045', 'Great Books', '3', NULL, 35),
  ('BSCpE', 'subject', 2, 2, NULL, NULL, FALSE, 'BUSS1013', 'Technopreneurship', '3', NULL, 36),
  ('BSCpE', 'subject', 2, 2, NULL, NULL, FALSE, 'ENGR1049', 'Engineering Data Analysis', '3', NULL, 37),
  ('BSCpE', 'subject', 3, 1, NULL, NULL, FALSE, 'ENGR1015', 'Fundamentals of Mixed Signals and Sensors', '3', NULL, 38),
  ('BSCpE', 'subject', 3, 1, NULL, NULL, TRUE, NULL, 'CpE Elective 1', '3', NULL, 39),
  ('BSCpE', 'subject', 3, 1, NULL, NULL, FALSE, 'ENGR1017', 'Logic Circuits and Design', '4', NULL, 40),
  ('BSCpE', 'subject', 3, 1, NULL, NULL, FALSE, 'INTE1026', 'Data and Digital Communications (Data Communications)', '3', NULL, 41),
  ('BSCpE', 'subject', 3, 1, NULL, NULL, FALSE, 'ENGR1018', 'Computer-Aided Drafting', '1', NULL, 42),
  ('BSCpE', 'subject', 3, 1, NULL, NULL, FALSE, 'ENGR1019', 'Computer Engineering Drafting and Design', '1', NULL, 43),
  ('BSCpE', 'subject', 3, 1, NULL, NULL, FALSE, 'ENGR1020', 'Engineering Economics', '3', NULL, 44),
  ('BSCpE', 'subject', 3, 1, NULL, NULL, FALSE, 'ENGR1021', 'Feedback and Control Systems', '3', NULL, 45),
  ('BSCpE', 'subject', 3, 1, NULL, NULL, FALSE, 'ENGR1051', 'Methods of Research', '2', NULL, 46),
  ('BSCpE', 'subject', 3, 2, NULL, NULL, FALSE, 'ENGR1022', 'Basic Occupational Health and Safety', '3', NULL, 47),
  ('BSCpE', 'subject', 3, 2, NULL, NULL, FALSE, 'ENGR1023', 'Microprocessors', '4', NULL, 48),
  ('BSCpE', 'subject', 3, 2, NULL, NULL, TRUE, NULL, 'CpE Elective 2', '3', NULL, 49),
  ('BSCpE', 'subject', 3, 2, NULL, NULL, FALSE, 'ENGR1025', 'Introduction to HDL', '1', NULL, 50),
  ('BSCpE', 'subject', 3, 2, NULL, NULL, FALSE, 'ENGR1026', 'Digital Signal Processing', '4', NULL, 51),
  ('BSCpE', 'subject', 3, 2, NULL, NULL, FALSE, 'ENGR1052', 'Capstone Design 1', '1', NULL, 52),
  ('BSCpE', 'subject', 4, 1, NULL, NULL, FALSE, 'ENGR1050', 'Computer Architecture and Organization', '4', NULL, 53),
  ('BSCpE', 'subject', 4, 1, NULL, NULL, FALSE, 'INTE1038', 'Computer Network and Security', '4', NULL, 54),
  ('BSCpE', 'subject', 4, 1, NULL, NULL, FALSE, 'ENGR1029', 'CpE Laws and Professional Practice', '2', NULL, 55),
  ('BSCpE', 'subject', 4, 1, NULL, NULL, TRUE, NULL, 'CpE Elective 3', '3', NULL, 56),
  ('BSCpE', 'subject', 4, 1, NULL, NULL, FALSE, 'ENGR1031', 'Embedded Systems', '4', NULL, 57),
  ('BSCpE', 'subject', 4, 1, NULL, NULL, FALSE, 'STIC1007', 'Euthenics 2', '1', NULL, 58),
  ('BSCpE', 'subject', 4, 1, NULL, NULL, FALSE, 'ENGR1053', 'Capstone Design 2', '2', NULL, 59),
  ('BSCpE', 'subject', 4, 1, NULL, NULL, FALSE, 'ENGR1033', 'Seminars and Fieldtrips', '1', NULL, 60),
  ('BSCpE', 'elective', NULL, NULL, 'Robotics Systems', NULL, FALSE, 'ENGR1046', 'Computer Systems Architecture', '3', NULL, 61),
  ('BSCpE', 'elective', NULL, NULL, 'Robotics Systems', NULL, FALSE, 'ENGR1036', 'Robot Dynamics Fundamentals', '3', NULL, 62),
  ('BSCpE', 'elective', NULL, NULL, 'Robotics Systems', NULL, FALSE, 'ENGR1038', 'Robot Assembly and Programming', '3', NULL, 63),
  ('BSCpE', 'elective', NULL, NULL, 'Systems and Network Administration', NULL, FALSE, 'ENGR1034', 'Systems Administration', '3', NULL, 64),
  ('BSCpE', 'elective', NULL, NULL, 'Systems and Network Administration', NULL, FALSE, 'INTE1045', 'Network Technology 1', '3', NULL, 65),
  ('BSCpE', 'elective', NULL, NULL, 'Systems and Network Administration', NULL, FALSE, 'INTE1046', 'Network Technology 2', '3', NULL, 66),
  ('BSCpE', 'elective', NULL, NULL, 'Software Development', NULL, FALSE, 'INSY1012', 'Advanced Database Systems', '3', NULL, 67),
  ('BSCpE', 'elective', NULL, NULL, 'Software Development', NULL, FALSE, 'INSY1028', 'Software Quality Assurance', '3', NULL, 68),
  ('BSCpE', 'elective', NULL, NULL, 'Software Development', NULL, FALSE, 'INSY1008', 'Management Information Systems', '3', NULL, 69),
  ('BSHM', 'subject', 1, 1, NULL, NULL, FALSE, 'STIC1002', 'Euthenics 1', '1', NULL, 1),
  ('BSHM', 'subject', 1, 1, NULL, NULL, FALSE, 'GEDC1005', 'Mathematics in the Modern World', '3', NULL, 2),
  ('BSHM', 'subject', 1, 1, NULL, NULL, FALSE, 'NSTP1008', 'National Service Training Program 1', '3', NULL, 3),
  ('BSHM', 'subject', 1, 1, NULL, NULL, FALSE, 'PHED1005', 'P.E./PATHFIT 1: Movement Competency Training', '2', NULL, 4),
  ('BSHM', 'subject', 1, 1, NULL, NULL, FALSE, 'GEDC1006', 'Readings in Philippine History', '3', NULL, 5),
  ('BSHM', 'subject', 1, 1, NULL, NULL, FALSE, 'GEDC1008', 'Understanding the Self', '3', NULL, 6),
  ('BSHM', 'subject', 1, 1, NULL, NULL, FALSE, 'CTHC1003', 'Macro Perspective of Tourism and Hospitality', '3', NULL, 7),
  ('BSHM', 'subject', 1, 1, NULL, NULL, FALSE, 'CTHC1004', 'Risk Management as Applied to Safety, Security, and Sanitation', '3', NULL, 8),
  ('BSHM', 'subject', 1, 2, NULL, NULL, FALSE, 'NSTP1010', 'National Service Training Program 2', '3', NULL, 9),
  ('BSHM', 'subject', 1, 2, NULL, NULL, FALSE, 'PHED1006', 'P.E./PATHFIT 2: Exercise-based Fitness Activities', '2', NULL, 10),
  ('BSHM', 'subject', 1, 2, NULL, NULL, FALSE, 'GEDC1016', 'Purposive Communication', '3', NULL, 11),
  ('BSHM', 'subject', 1, 2, NULL, NULL, FALSE, 'HOSP1002', 'Kitchen Essentials and Basic Food Preparation', '3', NULL, 12),
  ('BSHM', 'subject', 1, 2, NULL, NULL, FALSE, 'STIC1003', 'Computer Productivity Tools', '1', NULL, 13),
  ('BSHM', 'subject', 1, 2, NULL, NULL, FALSE, 'CTHC1006', 'Philippine Culture and Tourism Geography', '3', NULL, 14),
  ('BSHM', 'subject', 1, 2, NULL, NULL, FALSE, 'CTHC1007', 'Micro Perspective of Tourism and Hospitality', '3', NULL, 15),
  ('BSHM', 'subject', 2, 1, NULL, NULL, FALSE, 'GEDC1010', 'Art Appreciation', '3', NULL, 16),
  ('BSHM', 'subject', 2, 1, NULL, NULL, FALSE, 'PHED1007', 'P.E./PATHFIT 3: Individual-Dual Sports', '2', NULL, 17),
  ('BSHM', 'subject', 2, 1, NULL, NULL, FALSE, 'HOSP1007', 'Hotel Front Office Operations Management', '3', NULL, 18),
  ('BSHM', 'subject', 2, 1, NULL, NULL, FALSE, 'HOSP1005', 'Philippine Regional Cuisines with Food Styling and Design', '2', NULL, 19),
  ('BSHM', 'subject', 2, 1, NULL, NULL, FALSE, 'HOSP1008', 'Fundamentals in Lodging Operations', '3', NULL, 20),
  ('BSHM', 'subject', 2, 1, NULL, NULL, FALSE, 'CTHC1010', 'Foreign Language 1', '3', NULL, 21),
  ('BSHM', 'subject', 2, 1, NULL, NULL, FALSE, 'CTHC1008', 'Quality Service Management in Tourism and Hospitality', '3', NULL, 22),
  ('BSHM', 'subject', 2, 2, NULL, NULL, FALSE, 'GEDC1009', 'Ethics', '3', NULL, 23),
  ('BSHM', 'subject', 2, 2, NULL, NULL, FALSE, 'PHED1008', 'P.E./PATHFIT 4: Team Sports', '2', NULL, 24),
  ('BSHM', 'subject', 2, 2, NULL, NULL, FALSE, 'GEDC1013', 'Science, Technology, and Society', '3', NULL, 25),
  ('BSHM', 'subject', 2, 2, NULL, NULL, FALSE, 'HOSP1009', 'International Cuisines with Food Styling and Design', '2', NULL, 26),
  ('BSHM', 'subject', 2, 2, NULL, NULL, FALSE, 'HOSP1013', 'Supply Chain Management in Hospitality Industry', '3', NULL, 27),
  ('BSHM', 'subject', 2, 2, NULL, NULL, FALSE, 'HOSP1014', 'Fundamentals in Food Service Operations', '3', NULL, 28),
  ('BSHM', 'subject', 2, 2, NULL, NULL, FALSE, 'CTHC1011', 'Introduction to Meetings, Incentives, Conferences, and Events Management (MICE)', '3', NULL, 29),
  ('BSHM', 'subject', 2, 2, NULL, NULL, FALSE, 'CTHC1012', 'Foreign Language 2', '3', NULL, 30),
  ('BSHM', 'subject', 3, 1, NULL, NULL, FALSE, 'CBMC1001', 'Operations Management (TQM)', '3', NULL, 31),
  ('BSHM', 'subject', 3, 1, NULL, NULL, FALSE, 'GEDC1003', 'The Entrepreneurial Mind', '3', NULL, 32),
  ('BSHM', 'subject', 3, 1, NULL, NULL, FALSE, 'GEDC1045', 'Great Books', '3', NULL, 33),
  ('BSHM', 'subject', 3, 1, NULL, NULL, FALSE, 'HOSP1016', 'Pastry Arts and Bakery Management', '2', NULL, 34),
  ('BSHM', 'subject', 3, 1, NULL, NULL, FALSE, 'HOSP1019', 'Applied Business Tools and Technologies in Hospitality', '3', NULL, 35),
  ('BSHM', 'subject', 3, 1, NULL, NULL, FALSE, 'CTHC1013', 'Professional Development and Applied Ethics', '3', NULL, 36),
  ('BSHM', 'subject', 3, 1, NULL, NULL, FALSE, 'CTHC1014', 'Tourism and Hospitality Marketing', '3', NULL, 37),
  ('BSHM', 'subject', 3, 1, NULL, NULL, FALSE, 'CTHC1015', 'Multicultural Diversity in Workplace for the Tourism Professional', '3', NULL, 38),
  ('BSHM', 'subject', 3, 2, NULL, NULL, FALSE, 'CBMC1003', 'Strategic Management', '3', NULL, 39),
  ('BSHM', 'subject', 3, 2, NULL, NULL, FALSE, 'GEDC1041', 'Philippine Popular Culture', '3', NULL, 40),
  ('BSHM', 'subject', 3, 2, NULL, NULL, FALSE, 'HOSP1021', 'Catering Operations Management', '2', NULL, 41),
  ('BSHM', 'subject', 3, 2, NULL, NULL, FALSE, 'HOSP1022', 'Modern Gastronomy with Fusion of Cuisines', '2', NULL, 42),
  ('BSHM', 'subject', 3, 2, NULL, NULL, FALSE, 'HOSP1023', 'Ergonomics and Facilities Planning for the Hospitality Industry', '3', NULL, 43),
  ('BSHM', 'subject', 3, 2, NULL, NULL, FALSE, 'CTHC1016', 'Legal Aspects in Tourism and Hospitality', '3', NULL, 44),
  ('BSHM', 'subject', 3, 2, NULL, NULL, FALSE, 'CTHC1017', 'Entrepreneurship in Tourism and Hospitality', '3', NULL, 45),
  ('BSHM', 'subject', 4, 1, NULL, NULL, FALSE, 'GEDC1002', 'The Contemporary World', '3', NULL, 46),
  ('BSHM', 'subject', 4, 1, NULL, NULL, FALSE, 'STIC1007', 'Euthenics 2', '1', NULL, 47),
  ('BSHM', 'subject', 4, 1, NULL, NULL, FALSE, 'GEDC1014', 'Rizal''s Life and Works', '3', NULL, 48),
  ('BSHM', 'subject', 4, 1, NULL, NULL, FALSE, 'HOSP1024', 'Specialty Cuisine with Food Exhibit', '2', NULL, 49),
  ('BSHM', 'subject', 4, 1, NULL, NULL, FALSE, 'HOSP1025', 'Research in Hospitality', '3', NULL, 50),
  ('BSTM', 'subject', 1, 1, NULL, NULL, FALSE, 'STIC1002', 'Euthenics 1', '1', NULL, 1),
  ('BSTM', 'subject', 1, 1, NULL, NULL, FALSE, 'GEDC1005', 'Mathematics in the Modern World', '3', NULL, 2),
  ('BSTM', 'subject', 1, 1, NULL, NULL, FALSE, 'NSTP1008', 'National Service Training Program 1', '3', NULL, 3),
  ('BSTM', 'subject', 1, 1, NULL, NULL, FALSE, 'PHED1005', 'P.E./PATHFIT 1: Movement Competency Training', '2', NULL, 4),
  ('BSTM', 'subject', 1, 1, NULL, NULL, FALSE, 'GEDC1006', 'Readings in Philippine History', '3', NULL, 5),
  ('BSTM', 'subject', 1, 1, NULL, NULL, FALSE, 'GEDC1008', 'Understanding the Self', '3', NULL, 6),
  ('BSTM', 'subject', 1, 1, NULL, NULL, FALSE, 'CTHC1003', 'Macro Perspective of Tourism and Hospitality', '3', NULL, 7),
  ('BSTM', 'subject', 1, 1, NULL, NULL, FALSE, 'CTHC1004', 'Risk Management as Applied to Safety, Security, and Sanitation', '3', NULL, 8),
  ('BSTM', 'subject', 1, 2, NULL, NULL, FALSE, 'NSTP1010', 'National Service Training Program 2', '3', NULL, 9),
  ('BSTM', 'subject', 1, 2, NULL, NULL, FALSE, 'PHED1006', 'P.E./PATHFIT 2: Exercise-based Fitness Activities', '2', NULL, 10),
  ('BSTM', 'subject', 1, 2, NULL, NULL, FALSE, 'GEDC1016', 'Purposive Communication', '3', NULL, 11),
  ('BSTM', 'subject', 1, 2, NULL, NULL, FALSE, 'STIC1003', 'Computer Productivity Tools', '1', NULL, 12),
  ('BSTM', 'subject', 1, 2, NULL, NULL, FALSE, 'CTHC1006', 'Philippine Culture and Tourism Geography', '3', NULL, 13),
  ('BSTM', 'subject', 1, 2, NULL, NULL, FALSE, 'CTHC1007', 'Micro Perspective of Tourism and Hospitality', '3', NULL, 14),
  ('BSTM', 'subject', 1, 2, NULL, NULL, FALSE, 'TOUR1003', 'Global Culture and Tourism Geography', '3', NULL, 15),
  ('BSTM', 'subject', 2, 1, NULL, NULL, FALSE, 'GEDC1010', 'Art Appreciation', '3', NULL, 16),
  ('BSTM', 'subject', 2, 1, NULL, NULL, FALSE, 'PHED1007', 'P.E./PATHFIT 3: Individual-Dual Sports', '2', NULL, 17),
  ('BSTM', 'subject', 2, 1, NULL, NULL, FALSE, 'CTHC1008', 'Quality Service Management in Tourism and Hospitality', '3', NULL, 18),
  ('BSTM', 'subject', 2, 1, NULL, NULL, FALSE, 'TOUR1007', 'Accommodation Operations and Management', '3', NULL, 19),
  ('BSTM', 'subject', 2, 1, NULL, NULL, FALSE, 'TOUR1008', 'Tour and Travel Management', '3', NULL, 20),
  ('BSTM', 'subject', 2, 1, NULL, NULL, FALSE, 'CTHC1010', 'Foreign Language 1', '3', NULL, 21),
  ('BSTM', 'subject', 2, 1, NULL, NULL, FALSE, 'TOUR1009', 'Sustainable Tourism', '3', NULL, 22),
  ('BSTM', 'subject', 2, 2, NULL, NULL, FALSE, 'GEDC1009', 'Ethics', '3', NULL, 23),
  ('BSTM', 'subject', 2, 2, NULL, NULL, FALSE, 'PHED1008', 'P.E./PATHFIT 4: Team Sports', '2', NULL, 24),
  ('BSTM', 'subject', 2, 2, NULL, NULL, FALSE, 'GEDC1013', 'Science, Technology, and Society', '3', NULL, 25),
  ('BSTM', 'subject', 2, 2, NULL, NULL, FALSE, 'TOUR1012', 'Tour Planning, Packaging, and Pricing', '3', NULL, 26),
  ('BSTM', 'subject', 2, 2, NULL, NULL, FALSE, 'TOUR1014', 'Tourism Policy Planning and Development', '3', NULL, 27),
  ('BSTM', 'subject', 2, 2, NULL, NULL, FALSE, 'CTHC1011', 'Introduction to Meetings, Incentives, Conferences, and Events Management (MICE)', '3', NULL, 28),
  ('BSTM', 'subject', 2, 2, NULL, NULL, FALSE, 'CTHC1012', 'Foreign Language 2', '3', NULL, 29),
  ('BSTM', 'subject', 3, 1, NULL, NULL, FALSE, 'CBMC1001', 'Operations Management (TQM)', '3', NULL, 30),
  ('BSTM', 'subject', 3, 1, NULL, NULL, FALSE, 'GEDC1003', 'The Entrepreneurial Mind', '3', NULL, 31),
  ('BSTM', 'subject', 3, 1, NULL, NULL, FALSE, 'GEDC1045', 'Great Books', '3', NULL, 32),
  ('BSTM', 'subject', 3, 1, NULL, NULL, FALSE, 'CTHC1013', 'Professional Development and Applied Ethics', '3', NULL, 33),
  ('BSTM', 'subject', 3, 1, NULL, NULL, FALSE, 'CTHC1014', 'Tourism and Hospitality Marketing', '3', NULL, 34),
  ('BSTM', 'subject', 3, 1, NULL, NULL, FALSE, 'CTHC1015', 'Multicultural Diversity in Workplace for the Tourism Professional', '3', NULL, 35),
  ('BSTM', 'subject', 3, 1, NULL, NULL, FALSE, 'TOUR1016', 'Applied Business Tools and Technologies in Tourism', '3', NULL, 36),
  ('BSTM', 'subject', 3, 2, NULL, NULL, FALSE, 'CBMC1003', 'Strategic Management', '3', NULL, 37),
  ('BSTM', 'subject', 3, 2, NULL, NULL, FALSE, 'GEDC1041', 'Philippine Popular Culture', '3', NULL, 38),
  ('BSTM', 'subject', 3, 2, NULL, NULL, FALSE, 'CTHC1016', 'Legal Aspects in Tourism and Hospitality', '3', NULL, 39),
  ('BSTM', 'subject', 3, 2, NULL, NULL, FALSE, 'CTHC1017', 'Entrepreneurship in Tourism and Hospitality', '3', NULL, 40),
  ('BSTM', 'subject', 3, 2, NULL, NULL, FALSE, 'TOUR1022', 'Travel Writing and Photography', '3', NULL, 41),
  ('BSTM', 'subject', 3, 2, NULL, NULL, FALSE, 'TOUR1018', 'Professional Tour Guiding', '3', NULL, 42),
  ('BSTM', 'subject', 3, 2, NULL, NULL, FALSE, 'TOUR1019', 'Transportation Management', '3', NULL, 43),
  ('BSTM', 'subject', 4, 1, NULL, NULL, FALSE, 'GEDC1002', 'The Contemporary World', '3', NULL, 44),
  ('BSTM', 'subject', 4, 1, NULL, NULL, FALSE, 'STIC1007', 'Euthenics 2', '1', NULL, 45),
  ('BSTM', 'subject', 4, 1, NULL, NULL, FALSE, 'GEDC1014', 'Rizal''s Life and Works', '3', NULL, 46),
  ('BSTM', 'subject', 4, 1, NULL, NULL, FALSE, 'TOUR1020', 'Airline/Flight Operations Management', '3', NULL, 47),
  ('BSTM', 'subject', 4, 1, NULL, NULL, FALSE, 'TOUR1021', 'Research in Tourism', '3', NULL, 48),
  ('BSA', 'subject', 1, 1, NULL, NULL, FALSE, 'ACCT1001', 'Basic Accounting', '6', NULL, 1),
  ('BSA', 'subject', 1, 1, NULL, NULL, FALSE, 'GEDC1002', 'The Contemporary World', '3', NULL, 2),
  ('BSA', 'subject', 1, 1, NULL, NULL, FALSE, 'STIC1002', 'Euthenics 1', '1', NULL, 3),
  ('BSA', 'subject', 1, 1, NULL, NULL, FALSE, 'GEDC1041', 'Philippine Popular Culture', '3', NULL, 4),
  ('BSA', 'subject', 1, 1, NULL, NULL, FALSE, 'NSTP1008', 'National Service Training Program 1', '3', NULL, 5),
  ('BSA', 'subject', 1, 1, NULL, NULL, FALSE, 'PHED1005', 'P.E./PATHFIT 1: Movement Competency Training', '2', NULL, 6),
  ('BSA', 'subject', 1, 1, NULL, NULL, FALSE, 'GEDC1006', 'Readings in Philippine History', '3', NULL, 7),
  ('BSA', 'subject', 1, 1, NULL, NULL, FALSE, 'GEDC1013', 'Science, Technology, and Society', '3', NULL, 8),
  ('BSA', 'subject', 1, 1, NULL, NULL, FALSE, 'GEDC1008', 'Understanding the Self', '3', NULL, 9),
  ('BSA', 'subject', 1, 2, NULL, NULL, FALSE, 'ACCT1002', 'Conceptual Framework and Accounting Standards', '3', NULL, 10),
  ('BSA', 'subject', 1, 2, NULL, NULL, FALSE, 'ACCT1003', 'Financial Accounting and Reporting', '3', NULL, 11),
  ('BSA', 'subject', 1, 2, NULL, NULL, FALSE, 'BUSS1002', 'Income Taxation', '3', NULL, 12),
  ('BSA', 'subject', 1, 2, NULL, NULL, FALSE, 'BUSS1003', 'Law on Obligations and Contracts', '3', NULL, 13),
  ('BSA', 'subject', 1, 2, NULL, NULL, FALSE, 'CBMC1001', 'Operations Management (TQM)', '3', NULL, 14),
  ('BSA', 'subject', 1, 2, NULL, NULL, FALSE, 'GEDC1009', 'Ethics', '3', NULL, 15),
  ('BSA', 'subject', 1, 2, NULL, NULL, FALSE, 'NSTP1010', 'National Service Training Program 2', '3', NULL, 16),
  ('BSA', 'subject', 1, 2, NULL, NULL, FALSE, 'PHED1006', 'P.E./PATHFIT 2: Exercise-based Fitness Activities', '2', NULL, 17),
  ('BSA', 'subject', 1, 2, NULL, NULL, FALSE, 'GEDC1005', 'Mathematics in the Modern World', '3', NULL, 18),
  ('BSA', 'subject', 1, 2, NULL, NULL, FALSE, 'STIC1003', 'Computer Productivity Tools', '1', NULL, 19),
  ('BSA', 'subject', 2, 1, NULL, NULL, FALSE, 'ACCT1004', 'Business Laws and Regulations', '3', NULL, 20),
  ('BSA', 'subject', 2, 1, NULL, NULL, FALSE, 'GEDC1045', 'Great Books', '3', NULL, 21),
  ('BSA', 'subject', 2, 1, NULL, NULL, FALSE, 'ACCT1005', 'Intermediate Accounting 1', '3', NULL, 22),
  ('BSA', 'subject', 2, 1, NULL, NULL, FALSE, 'INTE1011', 'IT Application Tools in Business', '3', NULL, 23),
  ('BSA', 'subject', 2, 1, NULL, NULL, FALSE, 'ACCT1006', 'Managerial Economics', '3', NULL, 24),
  ('BSA', 'subject', 2, 1, NULL, NULL, FALSE, 'CBMC1002', 'Strategic Management', '3', NULL, 25),
  ('BSA', 'subject', 2, 1, NULL, NULL, FALSE, 'GEDC1014', 'Rizal''s Life and Works', '3', NULL, 26),
  ('BSA', 'subject', 2, 1, NULL, NULL, FALSE, 'GEDC1016', 'Purposive Communication', '3', NULL, 27),
  ('BSA', 'subject', 2, 1, NULL, NULL, FALSE, 'PHED1007', 'P.E./PATHFIT 3: Individual-Dual Sports', '2', NULL, 28),
  ('BSA', 'subject', 2, 2, NULL, NULL, FALSE, 'ACCT1007', 'Accounting Information System', '3', NULL, 29),
  ('BSA', 'subject', 2, 2, NULL, NULL, FALSE, 'ACCT1008', 'Business Taxation', '3', NULL, 30),
  ('BSA', 'subject', 2, 2, NULL, NULL, FALSE, 'BUSS1012', 'Financial Management', '3', NULL, 31),
  ('BSA', 'subject', 2, 2, NULL, NULL, FALSE, 'ACCT1009', 'Intermediate Accounting 2', '3', NULL, 32),
  ('BSA', 'subject', 2, 2, NULL, NULL, FALSE, 'ACCT1010', 'Regulatory Framework and Legal Issues in Business', '3', NULL, 33),
  ('BSA', 'subject', 2, 2, NULL, NULL, FALSE, 'GEDC1003', 'The Entrepreneurial Mind', '3', NULL, 34),
  ('BSA', 'subject', 2, 2, NULL, NULL, FALSE, 'GEDC1010', 'Art Appreciation', '3', NULL, 35),
  ('BSA', 'subject', 2, 2, NULL, NULL, FALSE, 'PHED1008', 'P.E./PATHFIT 4: Team Sports', '2', NULL, 36),
  ('BSA', 'subject', 2, 2, NULL, NULL, FALSE, 'ACCT1011', 'Auditing and Assurance Principles', '3', NULL, 37),
  ('BSA', 'subject', 3, 1, NULL, NULL, FALSE, 'ACCT1013', 'Cost Accounting and Control', '3', NULL, 38),
  ('BSA', 'subject', 3, 1, NULL, NULL, FALSE, 'ACCT1014', 'Economic Development', '3', NULL, 39),
  ('BSA', 'subject', 3, 1, NULL, NULL, FALSE, 'ACCT1015', 'Financial Markets', '3', NULL, 40),
  ('BSA', 'subject', 3, 1, NULL, NULL, FALSE, 'ACCT1016', 'Governance, Business Ethics, Risk Management, and Internal Control', '3', NULL, 41),
  ('BSA', 'subject', 3, 1, NULL, NULL, FALSE, 'ACCT1017', 'Intermediate Accounting 3', '3', NULL, 42),
  ('BSA', 'subject', 3, 1, NULL, NULL, FALSE, 'BUSS1017', 'International Business and Trade', '3', NULL, 43),
  ('BSA', 'subject', 3, 1, NULL, NULL, FALSE, 'ACCT1018', 'Statistical Analysis with Software Application', '3', NULL, 44),
  ('BSA', 'subject', 3, 1, NULL, NULL, FALSE, 'ACCT1019', 'Auditing and Assurance: Concepts and Applications 1', '3', NULL, 45),
  ('BSA', 'subject', 3, 2, NULL, NULL, FALSE, 'ACCT1021', 'Accounting Research Methods', '3', NULL, 46),
  ('BSA', 'subject', 3, 2, NULL, NULL, FALSE, 'ACCT1022', 'Strategic Cost Management', '3', NULL, 47),
  ('BSA', 'subject', 3, 2, NULL, NULL, FALSE, 'ACCT1023', 'Accounting for Business Combinations', '3', NULL, 48),
  ('BSA', 'subject', 3, 2, NULL, NULL, FALSE, 'ACCT1024', 'Auditing in a CIS Environment', '3', NULL, 49),
  ('BSA', 'subject', 3, 2, NULL, NULL, FALSE, 'ACCT1025', 'Accounting for Government and Non-profit Organizations', '3', NULL, 50),
  ('BSA', 'subject', 3, 2, NULL, NULL, FALSE, 'ACCT1026', 'Accounting for Special Transactions', '3', NULL, 51),
  ('BSA', 'subject', 3, 2, NULL, NULL, FALSE, 'ACCT1027', 'Auditing and Assurance: Concepts and Applications 2', '3', NULL, 52),
  ('BSA', 'subject', 4, 1, NULL, NULL, FALSE, 'ACCT1030', 'Management Science', '3', NULL, 53),
  ('BSA', 'subject', 4, 1, NULL, NULL, FALSE, 'ACCT1031', 'Strategic Business Analysis', '3', NULL, 54),
  ('BSA', 'subject', 4, 1, NULL, NULL, TRUE, 'ACCT1042', 'Professional Elective 1', '3', NULL, 55),
  ('BSA', 'subject', 4, 1, NULL, NULL, TRUE, 'ACCT1043', 'Professional Elective 2', '3', NULL, 56),
  ('BSA', 'subject', 4, 1, NULL, NULL, TRUE, 'ACCT1044', 'Professional Elective 3', '3', NULL, 57),
  ('BSA', 'subject', 4, 1, NULL, NULL, TRUE, 'ACCT1045', 'Professional Elective 4', '3', NULL, 58),
  ('BSA', 'subject', 4, 1, NULL, NULL, FALSE, 'STIC1007', 'Euthenics 2', '1', NULL, 59),
  ('BSA', 'subject', 4, 1, NULL, NULL, FALSE, 'ACCT1035', 'Auditing and Assurance: Specialized Industries', '3', NULL, 60),
  ('BSA', 'subject', 4, 2, NULL, NULL, FALSE, 'ACCT1037', 'Accounting Research', '3', NULL, 61),
  ('BSAIS', 'subject', 1, 1, NULL, NULL, FALSE, 'ACCT1001', 'Basic Accounting', '6', NULL, 1),
  ('BSAIS', 'subject', 1, 1, NULL, NULL, FALSE, 'GEDC1002', 'The Contemporary World', '3', NULL, 2),
  ('BSAIS', 'subject', 1, 1, NULL, NULL, FALSE, 'STIC1002', 'Euthenics 1', '1', NULL, 3),
  ('BSAIS', 'subject', 1, 1, NULL, NULL, FALSE, 'GEDC1041', 'Philippine Popular Culture', '3', NULL, 4),
  ('BSAIS', 'subject', 1, 1, NULL, NULL, FALSE, 'NSTP1008', 'National Service Training Program 1', '3', NULL, 5),
  ('BSAIS', 'subject', 1, 1, NULL, NULL, FALSE, 'PHED1005', 'P.E./PATHFIT 1: Movement Competency Training', '2', NULL, 6),
  ('BSAIS', 'subject', 1, 1, NULL, NULL, FALSE, 'GEDC1006', 'Readings in Philippine History', '3', NULL, 7),
  ('BSAIS', 'subject', 1, 1, NULL, NULL, FALSE, 'GEDC1013', 'Science, Technology, and Society', '3', NULL, 8),
  ('BSAIS', 'subject', 1, 1, NULL, NULL, FALSE, 'GEDC1008', 'Understanding the Self', '3', NULL, 9),
  ('BSAIS', 'subject', 1, 2, NULL, NULL, FALSE, 'ACCT1002', 'Conceptual Framework and Accounting Standards', '3', NULL, 10),
  ('BSAIS', 'subject', 1, 2, NULL, NULL, FALSE, 'ACCT1003', 'Financial Accounting and Reporting', '3', NULL, 11),
  ('BSAIS', 'subject', 1, 2, NULL, NULL, FALSE, 'BUSS1002', 'Income Taxation', '3', NULL, 12),
  ('BSAIS', 'subject', 1, 2, NULL, NULL, FALSE, 'BUSS1003', 'Law on Obligations and Contracts', '3', NULL, 13),
  ('BSAIS', 'subject', 1, 2, NULL, NULL, FALSE, 'CBMC1001', 'Operations Management (TQM)', '3', NULL, 14),
  ('BSAIS', 'subject', 1, 2, NULL, NULL, FALSE, 'GEDC1009', 'Ethics', '3', NULL, 15),
  ('BSAIS', 'subject', 1, 2, NULL, NULL, FALSE, 'NSTP1010', 'National Service Training Program 2', '3', NULL, 16),
  ('BSAIS', 'subject', 1, 2, NULL, NULL, FALSE, 'PHED1006', 'P.E./PATHFIT 2: Exercise-based Fitness Activities', '2', NULL, 17),
  ('BSAIS', 'subject', 1, 2, NULL, NULL, FALSE, 'GEDC1005', 'Mathematics in the Modern World', '3', NULL, 18),
  ('BSAIS', 'subject', 1, 2, NULL, NULL, FALSE, 'STIC1003', 'Computer Productivity Tools', '1', NULL, 19),
  ('BSAIS', 'subject', 2, 1, NULL, NULL, FALSE, 'ACCT1004', 'Business Laws and Regulations', '3', NULL, 20),
  ('BSAIS', 'subject', 2, 1, NULL, NULL, FALSE, 'GEDC1045', 'Great Books', '3', NULL, 21),
  ('BSAIS', 'subject', 2, 1, NULL, NULL, FALSE, 'ACCT1005', 'Intermediate Accounting 1', '3', NULL, 22),
  ('BSAIS', 'subject', 2, 1, NULL, NULL, FALSE, 'INTE1011', 'IT Application Tools in Business', '3', NULL, 23),
  ('BSAIS', 'subject', 2, 1, NULL, NULL, FALSE, 'ACCT1006', 'Managerial Economics', '3', NULL, 24),
  ('BSAIS', 'subject', 2, 1, NULL, NULL, FALSE, 'CBMC1002', 'Strategic Management', '3', NULL, 25),
  ('BSAIS', 'subject', 2, 1, NULL, NULL, FALSE, 'GEDC1014', 'Rizal''s Life and Works', '3', NULL, 26),
  ('BSAIS', 'subject', 2, 1, NULL, NULL, FALSE, 'GEDC1016', 'Purposive Communication', '3', NULL, 27),
  ('BSAIS', 'subject', 2, 1, NULL, NULL, FALSE, 'PHED1007', 'P.E./PATHFIT 3: Individual-Dual Sports', '2', NULL, 28),
  ('BSAIS', 'subject', 2, 2, NULL, NULL, FALSE, 'ACCT1007', 'Accounting Information System', '3', NULL, 29),
  ('BSAIS', 'subject', 2, 2, NULL, NULL, FALSE, 'ACCT1008', 'Business Taxation', '3', NULL, 30),
  ('BSAIS', 'subject', 2, 2, NULL, NULL, FALSE, 'BUSS1012', 'Financial Management', '3', NULL, 31),
  ('BSAIS', 'subject', 2, 2, NULL, NULL, FALSE, 'ACCT1009', 'Intermediate Accounting 2', '3', NULL, 32),
  ('BSAIS', 'subject', 2, 2, NULL, NULL, FALSE, 'ACCT1010', 'Regulatory Framework and Legal Issues in Business', '3', NULL, 33),
  ('BSAIS', 'subject', 2, 2, NULL, NULL, FALSE, 'GEDC1003', 'The Entrepreneurial Mind', '3', NULL, 34),
  ('BSAIS', 'subject', 2, 2, NULL, NULL, FALSE, 'GEDC1010', 'Art Appreciation', '3', NULL, 35),
  ('BSAIS', 'subject', 2, 2, NULL, NULL, FALSE, 'PHED1008', 'P.E./PATHFIT 4: Team Sports', '2', NULL, 36),
  ('BSAIS', 'subject', 2, 2, NULL, NULL, FALSE, 'INTE1022', 'Managing Information and Technology', '3', NULL, 37),
  ('BSAIS', 'subject', 3, 1, NULL, NULL, FALSE, 'ACCT1013', 'Cost Accounting and Control', '3', NULL, 38),
  ('BSAIS', 'subject', 3, 1, NULL, NULL, FALSE, 'ACCT1014', 'Economic Development', '3', NULL, 39),
  ('BSAIS', 'subject', 3, 1, NULL, NULL, FALSE, 'ACCT1015', 'Financial Markets', '3', NULL, 40),
  ('BSAIS', 'subject', 3, 1, NULL, NULL, FALSE, 'ACCT1016', 'Governance, Business Ethics, Risk Management, and Internal Control', '3', NULL, 41),
  ('BSAIS', 'subject', 3, 1, NULL, NULL, FALSE, 'ACCT1017', 'Intermediate Accounting 3', '3', NULL, 42),
  ('BSAIS', 'subject', 3, 1, NULL, NULL, FALSE, 'BUSS1017', 'International Business and Trade', '3', NULL, 43),
  ('BSAIS', 'subject', 3, 1, NULL, NULL, FALSE, 'ACCT1018', 'Statistical Analysis with Software Application', '3', NULL, 44),
  ('BSAIS', 'subject', 3, 1, NULL, NULL, FALSE, 'INTE1028', 'Information Systems Analysis and Design', '3', NULL, 45),
  ('BSAIS', 'subject', 3, 2, NULL, NULL, FALSE, 'ACCT1021', 'Accounting Research Methods', '3', NULL, 46),
  ('BSAIS', 'subject', 3, 2, NULL, NULL, FALSE, 'ACCT1022', 'Strategic Cost Management', '3', NULL, 47),
  ('BSAIS', 'subject', 3, 2, NULL, NULL, FALSE, 'INTE1032', 'Data Warehousing and Management', '3', NULL, 48),
  ('BSAIS', 'subject', 3, 2, NULL, NULL, FALSE, 'INTE1033', 'Enterprise Resource Planning and Management', '3', NULL, 49),
  ('BSAIS', 'subject', 3, 2, NULL, NULL, FALSE, 'INTE1036', 'Information Systems Operations and Maintenance', '3', NULL, 50),
  ('BSAIS', 'subject', 3, 2, NULL, NULL, FALSE, 'INSY1007', 'Management Information System', '3', NULL, 51),
  ('BSAIS', 'subject', 3, 2, NULL, NULL, FALSE, 'INTE1035', 'Project Management', '3', NULL, 52),
  ('BSAIS', 'subject', 4, 1, NULL, NULL, FALSE, 'ACCT1030', 'Management Science', '3', NULL, 53),
  ('BSAIS', 'subject', 4, 1, NULL, NULL, FALSE, 'ACCT1031', 'Strategic Business Analysis', '3', NULL, 54),
  ('BSAIS', 'subject', 4, 1, NULL, NULL, FALSE, 'ACCT1032', 'Business Analytics', '3', NULL, 55),
  ('BSAIS', 'subject', 4, 1, NULL, NULL, FALSE, 'ACCT1033', 'Financial Modeling', '3', NULL, 56),
  ('BSAIS', 'subject', 4, 1, NULL, NULL, FALSE, 'BUSS1009', 'Human Resource Management', '3', NULL, 57),
  ('BSAIS', 'subject', 4, 1, NULL, NULL, FALSE, 'ACCT1034', 'Management Reporting', '3', NULL, 58),
  ('BSAIS', 'subject', 4, 1, NULL, NULL, FALSE, 'STIC1007', 'Euthenics 2', '1', NULL, 59),
  ('BSAIS', 'subject', 4, 1, NULL, NULL, FALSE, 'INTE1042', 'Information Security and Management', '3', NULL, 60),
  ('BSAIS', 'subject', 4, 2, NULL, NULL, FALSE, 'ACCT1037', 'Accounting Research', '3', NULL, 61),
  ('BSBA', 'subject', 1, 1, NULL, NULL, FALSE, 'BUSS1001', 'Basic Microeconomics', '3', NULL, 1),
  ('BSBA', 'subject', 1, 1, NULL, NULL, FALSE, 'GEDC1002', 'The Contemporary World', '3', NULL, 2),
  ('BSBA', 'subject', 1, 1, NULL, NULL, FALSE, 'STIC1002', 'Euthenics 1', '1', NULL, 3),
  ('BSBA', 'subject', 1, 1, NULL, NULL, FALSE, 'NSTP1008', 'National Service Training Program 1', '3', NULL, 4),
  ('BSBA', 'subject', 1, 1, NULL, NULL, FALSE, 'PHED1005', 'P.E./PATHFIT 1: Movement Competency Training', '2', NULL, 5),
  ('BSBA', 'subject', 1, 1, NULL, NULL, FALSE, 'GEDC1006', 'Readings in Philippine History', '3', NULL, 6),
  ('BSBA', 'subject', 1, 1, NULL, NULL, FALSE, 'GEDC1008', 'Understanding the Self', '3', NULL, 7),
  ('BSBA', 'subject', 1, 2, NULL, NULL, FALSE, 'GEDC1009', 'Ethics', '3', NULL, 8),
  ('BSBA', 'subject', 1, 2, NULL, NULL, FALSE, 'NSTP1010', 'National Service Training Program 2', '3', NULL, 9),
  ('BSBA', 'subject', 1, 2, NULL, NULL, FALSE, 'PHED1006', 'P.E./PATHFIT 2: Exercise-based Fitness Activities', '2', NULL, 10),
  ('BSBA', 'subject', 1, 2, NULL, NULL, FALSE, 'GEDC1005', 'Mathematics in the Modern World', '3', NULL, 11),
  ('BSBA', 'subject', 1, 2, NULL, NULL, FALSE, 'GEDC1013', 'Science, Technology, and Society', '3', NULL, 12),
  ('BSBA', 'subject', 1, 2, NULL, NULL, FALSE, 'STIC1003', 'Computer Productivity Tools', '1', NULL, 13),
  ('BSBA', 'subject', 1, 2, NULL, NULL, FALSE, 'BUSS1004', 'Productivity and Quality Tools', '3', NULL, 14),
  ('BSBA', 'subject', 2, 1, NULL, NULL, FALSE, 'GEDC1041', 'Philippine Popular Culture', '3', NULL, 15),
  ('BSBA', 'subject', 2, 1, NULL, NULL, FALSE, 'GEDC1014', 'Rizal''s Life and Works', '3', NULL, 16),
  ('BSBA', 'subject', 2, 1, NULL, NULL, FALSE, 'GEDC1016', 'Purposive Communication', '3', NULL, 17),
  ('BSBA', 'subject', 2, 1, NULL, NULL, FALSE, 'PHED1007', 'P.E./PATHFIT 3: Individual-Dual Sports', '2', NULL, 18),
  ('BSBA', 'subject', 2, 1, NULL, NULL, FALSE, 'BUSS1005', 'Costing and Pricing', '3', NULL, 19),
  ('BSBA', 'subject', 2, 1, NULL, NULL, FALSE, 'BUSS1007', 'Facilities Management', '3', NULL, 20),
  ('BSBA', 'subject', 2, 2, NULL, NULL, FALSE, 'BUSS1008', 'Business Law (Obligations and Contracts)', '3', NULL, 21),
  ('BSBA', 'subject', 2, 2, NULL, NULL, FALSE, 'BUSS1011', 'Taxation (Income Taxation)', '3', NULL, 22),
  ('BSBA', 'subject', 2, 2, NULL, NULL, FALSE, 'GEDC1003', 'The Entrepreneurial Mind', '3', NULL, 23),
  ('BSBA', 'subject', 2, 2, NULL, NULL, FALSE, 'GEDC1010', 'Art Appreciation', '3', NULL, 24),
  ('BSBA', 'subject', 2, 2, NULL, NULL, FALSE, 'PHED1008', 'P.E./PATHFIT 4: Team Sports', '2', NULL, 25),
  ('BSBA', 'subject', 2, 2, NULL, NULL, FALSE, 'BUSS1014', 'Logistics Management', '3', NULL, 26),
  ('BSBA', 'subject', 3, 1, NULL, NULL, FALSE, 'BUSS1015', 'Business Research', '3', NULL, 27),
  ('BSBA', 'subject', 3, 1, NULL, NULL, FALSE, 'BUSS1016', 'Good Governance and Social Responsibility', '3', NULL, 28),
  ('BSBA', 'subject', 3, 1, NULL, NULL, FALSE, 'BUSS1017', 'International Business and Trade', '3', NULL, 29),
  ('BSBA', 'subject', 3, 1, NULL, NULL, FALSE, 'CBMC1001', 'Operations Management (TQM)', '3', NULL, 30),
  ('BSBA', 'subject', 3, 1, NULL, NULL, FALSE, 'BUSS1019', 'Managerial Accounting', '3', NULL, 31),
  ('BSBA', 'subject', 3, 1, NULL, NULL, FALSE, 'GEDC1045', 'Great Books', '3', NULL, 32),
  ('BSBA', 'subject', 3, 2, NULL, NULL, FALSE, 'BUSS1009', 'Human Resource Management', '3', NULL, 33),
  ('BSBA', 'subject', 3, 2, NULL, NULL, FALSE, 'CBMC1002', 'Strategic Management', '3', NULL, 34),
  ('BSBA', 'subject', 3, 2, NULL, NULL, FALSE, 'INSY1007', 'Management Information System', '3', NULL, 35),
  ('BSBA', 'subject', 3, 2, NULL, NULL, FALSE, 'BUSS1021', 'Environmental Management System', '3', NULL, 36),
  ('BSBA', 'subject', 3, 2, NULL, NULL, FALSE, 'BUSS1022', 'Inventory Management and Control', '3', NULL, 37),
  ('BSBA', 'subject', 3, 2, NULL, NULL, FALSE, 'INTE1035', 'Project Management', '3', NULL, 38),
  ('BSBA', 'subject', 4, 1, NULL, NULL, FALSE, 'BUSS1024', 'Feasibility Study', '3', NULL, 39),
  ('BSBA', 'subject', 4, 1, NULL, NULL, FALSE, 'BUSS1025', 'Entrepreneurial Management', '3', NULL, 40),
  ('BSBA', 'subject', 4, 1, NULL, NULL, FALSE, 'BUSS1020', 'Financial Management', '3', NULL, 41),
  ('BSBA', 'subject', 4, 1, NULL, NULL, FALSE, 'BUSS1026', 'Marketing Management', '3', NULL, 42),
  ('BSBA', 'subject', 4, 1, NULL, NULL, FALSE, 'STIC1007', 'Euthenics 2', '1', NULL, 43),
  ('BSBA', 'subject', 4, 1, NULL, NULL, FALSE, 'BUSS1027', 'Special Topics in Operations Management', '3', NULL, 44),
  ('BSIT', 'subject', 1, 1, NULL, NULL, FALSE, 'CITE1004', 'Introduction to Computing', '3', NULL, 1),
  ('BSIT', 'subject', 1, 1, NULL, NULL, FALSE, 'CITE1003', 'Computer Programming 1', '3', NULL, 2),
  ('BSIT', 'subject', 1, 1, NULL, NULL, FALSE, 'GEDC1002', 'The Contemporary World', '3', NULL, 3),
  ('BSIT', 'subject', 1, 1, NULL, NULL, FALSE, 'STIC1002', 'Euthenics 1', '1', NULL, 4),
  ('BSIT', 'subject', 1, 1, NULL, NULL, FALSE, 'GEDC1016', 'Purposive Communication', '3', NULL, 5),
  ('BSIT', 'subject', 1, 1, NULL, NULL, FALSE, 'NSTP1008', 'National Service Training Program 1', '3', NULL, 6),
  ('BSIT', 'subject', 1, 1, NULL, NULL, FALSE, 'PHED1005', 'P.E./PATHFIT 1: Movement Competency Training', '2', NULL, 7),
  ('BSIT', 'subject', 1, 1, NULL, NULL, FALSE, 'GEDC1041', 'Philippine Popular Culture', '3', NULL, 8),
  ('BSIT', 'subject', 1, 1, NULL, NULL, FALSE, 'GEDC1008', 'Understanding the Self', '3', NULL, 9),
  ('BSIT', 'subject', 1, 2, NULL, NULL, FALSE, 'CITE1006', 'Computer Programming 2', '3', NULL, 10),
  ('BSIT', 'subject', 1, 2, NULL, NULL, FALSE, 'COSC1002', 'Discrete Structures 1 (Discrete Mathematics)', '3', NULL, 11),
  ('BSIT', 'subject', 1, 2, NULL, NULL, FALSE, 'GEDC1010', 'Art Appreciation', '3', NULL, 12),
  ('BSIT', 'subject', 1, 2, NULL, NULL, FALSE, 'NSTP1010', 'National Service Training Program 2', '3', NULL, 13),
  ('BSIT', 'subject', 1, 2, NULL, NULL, FALSE, 'PHED1006', 'P.E./PATHFIT 2: Exercise-based Fitness Activities', '2', NULL, 14),
  ('BSIT', 'subject', 1, 2, NULL, NULL, FALSE, 'GEDC1005', 'Mathematics in the Modern World', '3', NULL, 15),
  ('BSIT', 'subject', 1, 2, NULL, NULL, FALSE, 'GEDC1013', 'Science, Technology, and Society', '3', NULL, 16),
  ('BSIT', 'subject', 1, 2, NULL, NULL, FALSE, 'GEDC1009', 'Ethics', '3', NULL, 17),
  ('BSIT', 'subject', 1, 2, NULL, NULL, FALSE, 'INTE1006', 'Systems Administration and Maintenance', '3', NULL, 18),
  ('BSIT', 'subject', 2, 1, NULL, NULL, FALSE, 'COSC1003', 'Data Structures and Algorithms', '3', NULL, 19),
  ('BSIT', 'subject', 2, 1, NULL, NULL, FALSE, 'GEDC1006', 'Readings in Philippine History', '3', NULL, 20),
  ('BSIT', 'subject', 2, 1, NULL, NULL, FALSE, 'PHED1007', 'P.E./PATHFIT 3: Individual-Dual Sports', '2', NULL, 21),
  ('BSIT', 'subject', 2, 1, NULL, NULL, FALSE, 'GEDC1014', 'Rizal''s Life and Works', '3', NULL, 22),
  ('BSIT', 'subject', 2, 1, NULL, NULL, FALSE, 'COSC1007', 'Human-Computer Interaction', '3', NULL, 23),
  ('BSIT', 'subject', 2, 1, NULL, NULL, TRUE, 'INTE1015', 'IT Elective 1', '3', NULL, 24),
  ('BSIT', 'subject', 2, 1, NULL, NULL, FALSE, 'COSC1001', 'Principles of Communication', '3', NULL, 25),
  ('BSIT', 'subject', 2, 1, NULL, NULL, FALSE, 'COSC1008', 'Platform Technology (Operating Systems)', '3', NULL, 26),
  ('BSIT', 'subject', 2, 2, NULL, NULL, FALSE, 'CITE1011', 'Information Management', '3', NULL, 27),
  ('BSIT', 'subject', 2, 2, NULL, NULL, FALSE, 'GEDC1003', 'The Entrepreneurial Mind', '3', NULL, 28),
  ('BSIT', 'subject', 2, 2, NULL, NULL, FALSE, 'PHED1008', 'P.E./PATHFIT 4: Team Sports', '2', NULL, 29),
  ('BSIT', 'subject', 2, 2, NULL, NULL, FALSE, 'INTE1005', 'Network Technology 1', '3', NULL, 30),
  ('BSIT', 'subject', 2, 2, NULL, NULL, FALSE, 'INTE1020', 'Quantitative Methods', '3', NULL, 31),
  ('BSIT', 'subject', 2, 2, NULL, NULL, FALSE, 'INTE1021', 'Systems Integration and Architecture', '3', NULL, 32),
  ('BSIT', 'subject', 2, 2, NULL, NULL, FALSE, 'INTE1010', 'Integrative Programming', '3', NULL, 33),
  ('BSIT', 'subject', 3, 1, NULL, NULL, FALSE, 'CITE1008', 'Application Development and Emerging Technologies', '3', NULL, 34),
  ('BSIT', 'subject', 3, 1, NULL, NULL, FALSE, 'INSY1011', 'Advanced Database Systems', '3', NULL, 35),
  ('BSIT', 'subject', 3, 1, NULL, NULL, FALSE, 'INTE1024', 'Event-Driven Programming', '3', NULL, 36),
  ('BSIT', 'subject', 3, 1, NULL, NULL, FALSE, 'INTE1025', 'Data and Digital Communications (Data Communications)', '3', NULL, 37),
  ('BSIT', 'subject', 3, 1, NULL, NULL, FALSE, 'INSY1003', 'Professional Issues in Information Systems and Technology', '3', NULL, 38),
  ('BSIT', 'subject', 3, 1, NULL, NULL, TRUE, NULL, 'IT Elective 2', '3', NULL, 39),
  ('BSIT', 'subject', 3, 1, NULL, NULL, FALSE, 'INTE1056', 'Advanced Systems Integration and Architecture', '3', NULL, 40),
  ('BSIT', 'subject', 3, 2, NULL, NULL, FALSE, 'INTE1083', 'Web Systems and Technologies', '3', NULL, 41),
  ('BSIT', 'subject', 3, 2, NULL, NULL, FALSE, 'INSY1007', 'Management Information Systems', '3', NULL, 42),
  ('BSIT', 'subject', 3, 2, NULL, NULL, FALSE, 'INTE1031', 'IT Capstone Project 1', '3', NULL, 43),
  ('BSIT', 'subject', 3, 2, NULL, NULL, FALSE, 'GEDC1045', 'Great Books', '3', NULL, 44),
  ('BSIT', 'subject', 3, 2, NULL, NULL, TRUE, 'INTE1027', 'IT Elective 3', '3', NULL, 45),
  ('BSIT', 'subject', 3, 2, NULL, NULL, FALSE, 'INTE1084', 'Mobile Systems and Technologies', '3', NULL, 46),
  ('BSIT', 'subject', 3, 2, NULL, NULL, FALSE, 'INSY1010', 'Information Assurance and Security (Cybersecurity Fundamentals)', '3', NULL, 47),
  ('BSIT', 'subject', 4, 1, NULL, NULL, FALSE, 'STIC1007', 'Euthenics 2', '1', NULL, 48),
  ('BSIT', 'subject', 4, 1, NULL, NULL, FALSE, 'INTE1039', 'IT Capstone Project 2', '3', NULL, 49),
  ('BSIT', 'subject', 4, 1, NULL, NULL, TRUE, 'INTE1040', 'IT Elective 4', '3', NULL, 50),
  ('BSIT', 'subject', 4, 1, NULL, NULL, FALSE, 'INTE1041', 'Computer Graphics Programming', '3', NULL, 51),
  ('BSIT', 'subject', 4, 1, NULL, NULL, FALSE, 'INTE1013', 'IT Service Management', '3', NULL, 52),
  ('BSIT', 'subject', 4, 1, NULL, NULL, FALSE, 'INSY1005', 'Information Assurance and Security (Data Privacy)', '3', NULL, 53),
  ('BSIT', 'subject', 4, 1, NULL, NULL, FALSE, 'INTE1030', 'Network Technology 2', '3', NULL, 54),
  ('BSIT', 'elective', NULL, NULL, 'Application Development', NULL, FALSE, 'INTE1044', 'Object-Oriented Programming', '3', NULL, 55),
  ('BSIT', 'elective', NULL, NULL, 'Application Development', NULL, FALSE, 'INTE1086', 'Enterprise Architecture', '3', NULL, 56),
  ('BSIT', 'elective', NULL, NULL, 'Application Development', NULL, FALSE, 'INTE1085', 'Programming Languages', '3', NULL, 57),
  ('BSIT', 'elective', NULL, NULL, 'Application Development', NULL, FALSE, 'INTE1050', 'Game Development', '3', NULL, 58),
  ('BSIT', 'elective', NULL, NULL, 'Graphics Technology', NULL, FALSE, 'INTE1047', 'Introduction to Digital Graphics Design', '3', NULL, 59),
  ('BSIT', 'elective', NULL, NULL, 'Graphics Technology', NULL, FALSE, 'INTE1048', 'Introduction to Computer Animation', '3', NULL, 60),
  ('BSIT', 'elective', NULL, NULL, 'Graphics Technology', NULL, FALSE, 'INTE1054', 'Advanced Digital Graphics Design', '3', NULL, 61),
  ('BSIT', 'elective', NULL, NULL, 'Graphics Technology', NULL, FALSE, 'INTE1055', 'Advanced Computer Animation', '3', NULL, 62),
  ('BSIT', 'elective', NULL, NULL, 'Platform Integration', NULL, FALSE, 'INTE1051', 'Computer Systems Architecture', '3', NULL, 63),
  ('BSIT', 'elective', NULL, NULL, 'Platform Integration', NULL, FALSE, 'ENGR1035', 'Robot Dynamics Fundamentals', '3', NULL, 64),
  ('BSIT', 'elective', NULL, NULL, 'Platform Integration', NULL, FALSE, 'INTE1049', 'Intermediate Human-Computer Interaction', '3', NULL, 65),
  ('BSIT', 'elective', NULL, NULL, 'Platform Integration', NULL, FALSE, 'ENGR1037', 'Robot Assembly and Programming', '3', NULL, 66),
  ('STEM', 'subject', 1, 1, NULL, 'core', FALSE, NULL, 'Oral Communication', NULL, '80', 1),
  ('STEM', 'subject', 1, 1, NULL, 'core', FALSE, NULL, 'General Mathematics', NULL, '80', 2),
  ('STEM', 'subject', 1, 1, NULL, 'core', FALSE, NULL, '21st Century Literature from the Philippines and the World', NULL, '80', 3),
  ('STEM', 'subject', 1, 1, NULL, 'core', FALSE, NULL, 'Media and Information Literacy', NULL, '80', 4),
  ('STEM', 'subject', 1, 1, NULL, 'core', FALSE, NULL, 'Introduction to the Philosophy of the Human Person', NULL, '80', 5),
  ('STEM', 'subject', 1, 1, NULL, 'core', FALSE, NULL, 'Physical Education and Health 1', NULL, '20', 6),
  ('STEM', 'subject', 1, 1, NULL, 'specialized', FALSE, NULL, 'Pre-Calculus', NULL, '80', 7),
  ('STEM', 'subject', 1, 1, NULL, 'specialized', FALSE, NULL, 'General Biology 1', NULL, '80', 8),
  ('STEM', 'subject', 1, 2, NULL, 'core', FALSE, NULL, 'Reading and Writing', NULL, '80', 9),
  ('STEM', 'subject', 1, 2, NULL, 'core', FALSE, NULL, 'Statistics and Probability', NULL, '80', 10),
  ('STEM', 'subject', 1, 2, NULL, 'core', FALSE, NULL, 'Understanding Culture, Society and Politics', NULL, '80', 11),
  ('STEM', 'subject', 1, 2, NULL, 'core', FALSE, NULL, 'Earth Science', NULL, '80', 12),
  ('STEM', 'subject', 1, 2, NULL, 'core', FALSE, NULL, 'Komunikasyon at Pananaliksik sa Wika at Kulturang Pilipino', NULL, '80', 13),
  ('STEM', 'subject', 1, 2, NULL, 'core', FALSE, NULL, 'Physical Education and Health 2', NULL, '20', 14),
  ('STEM', 'subject', 1, 2, NULL, 'applied', FALSE, NULL, 'Practical Research 1', NULL, '80', 15),
  ('STEM', 'subject', 1, 2, NULL, 'specialized', FALSE, NULL, 'Basic Calculus', NULL, '80', 16),
  ('STEM', 'subject', 1, 2, NULL, 'specialized', FALSE, NULL, 'General Biology 2', NULL, '80', 17),
  ('STEM', 'subject', 2, 1, NULL, 'core', FALSE, NULL, 'Personal Development', NULL, '80', 18),
  ('STEM', 'subject', 2, 1, NULL, 'core', FALSE, NULL, 'Pagbasa at Pagsusuri ng Iba''t Ibang Teksto Tungo sa Pananaliksik', NULL, '80', 19),
  ('STEM', 'subject', 2, 1, NULL, 'core', FALSE, NULL, 'Disaster Readiness and Risk Reduction', NULL, '80', 20),
  ('STEM', 'subject', 2, 1, NULL, 'core', FALSE, NULL, 'Physical Education and Health 3', NULL, '20', 21),
  ('STEM', 'subject', 2, 1, NULL, 'applied', FALSE, NULL, 'Practical Research 2', NULL, '80', 22),
  ('STEM', 'subject', 2, 1, NULL, 'applied', FALSE, NULL, 'Filipino sa Piling Larangan', NULL, '80', 23),
  ('STEM', 'subject', 2, 1, NULL, 'applied', FALSE, NULL, 'English for Academic and Professional Purposes', NULL, '80', 24),
  ('STEM', 'subject', 2, 1, NULL, 'specialized', FALSE, NULL, 'General Physics 1', NULL, '80', 25),
  ('STEM', 'subject', 2, 1, NULL, 'specialized', FALSE, NULL, 'General Chemistry 1', NULL, '80', 26),
  ('STEM', 'subject', 2, 2, NULL, 'core', FALSE, NULL, 'Contemporary Philippine Arts from the Regions', NULL, '80', 27),
  ('STEM', 'subject', 2, 2, NULL, 'core', FALSE, NULL, 'Physical Education and Health 4', NULL, '20', 28),
  ('STEM', 'subject', 2, 2, NULL, 'applied', FALSE, NULL, 'Empowerment Technologies', NULL, '80', 29),
  ('STEM', 'subject', 2, 2, NULL, 'applied', FALSE, NULL, 'Entrepreneurship', NULL, '80', 30),
  ('STEM', 'subject', 2, 2, NULL, 'applied', FALSE, NULL, 'Inquiries, Investigations and Immersion', NULL, '80', 31),
  ('STEM', 'subject', 2, 2, NULL, 'specialized', FALSE, NULL, 'General Physics 2', NULL, '80', 32),
  ('STEM', 'subject', 2, 2, NULL, 'specialized', FALSE, NULL, 'General Chemistry 2', NULL, '80', 33),
  ('ABM', 'subject', 1, 1, NULL, 'core', FALSE, NULL, 'Oral Communication', NULL, '80', 1),
  ('ABM', 'subject', 1, 1, NULL, 'core', FALSE, NULL, 'General Mathematics', NULL, '80', 2),
  ('ABM', 'subject', 1, 1, NULL, 'core', FALSE, NULL, '21st Century Literature from the Philippines and the World', NULL, '80', 3),
  ('ABM', 'subject', 1, 1, NULL, 'core', FALSE, NULL, 'Media and Information Literacy', NULL, '80', 4),
  ('ABM', 'subject', 1, 1, NULL, 'core', FALSE, NULL, 'Introduction to the Philosophy of the Human Person', NULL, '80', 5),
  ('ABM', 'subject', 1, 1, NULL, 'core', FALSE, NULL, 'Physical Education and Health 1', NULL, '20', 6),
  ('ABM', 'subject', 1, 1, NULL, 'specialized', FALSE, NULL, 'Organization & Management', NULL, '80', 7),
  ('ABM', 'subject', 1, 1, NULL, 'specialized', FALSE, NULL, 'Business Mathematics', NULL, '80', 8),
  ('ABM', 'subject', 1, 2, NULL, 'core', FALSE, NULL, 'Reading and Writing', NULL, '80', 9),
  ('ABM', 'subject', 1, 2, NULL, 'core', FALSE, NULL, 'Statistics and Probability', NULL, '80', 10),
  ('ABM', 'subject', 1, 2, NULL, 'core', FALSE, NULL, 'Understanding Culture, Society and Politics', NULL, '80', 11),
  ('ABM', 'subject', 1, 2, NULL, 'core', FALSE, NULL, 'Earth and Life Science', NULL, '80', 12),
  ('ABM', 'subject', 1, 2, NULL, 'core', FALSE, NULL, 'Komunikasyon at Pananaliksik sa Wika at Kulturang Pilipino', NULL, '80', 13),
  ('ABM', 'subject', 1, 2, NULL, 'core', FALSE, NULL, 'Physical Education and Health 2', NULL, '20', 14),
  ('ABM', 'subject', 1, 2, NULL, 'applied', FALSE, NULL, 'Practical Research 1', NULL, '80', 15),
  ('ABM', 'subject', 1, 2, NULL, 'specialized', FALSE, NULL, 'Principles of Marketing', NULL, '80', 16),
  ('ABM', 'subject', 1, 2, NULL, 'specialized', FALSE, NULL, 'Fundamentals of Accountancy, Business & Management 1', NULL, '80', 17),
  ('ABM', 'subject', 2, 1, NULL, 'core', FALSE, NULL, 'Personal Development', NULL, '80', 18),
  ('ABM', 'subject', 2, 1, NULL, 'core', FALSE, NULL, 'Pagbasa at Pagsusuri ng Iba''t Ibang Teksto Tungo sa Pananaliksik', NULL, '80', 19),
  ('ABM', 'subject', 2, 1, NULL, 'core', FALSE, NULL, 'Physical Science', NULL, '80', 20),
  ('ABM', 'subject', 2, 1, NULL, 'core', FALSE, NULL, 'Physical Education and Health 3', NULL, '20', 21),
  ('ABM', 'subject', 2, 1, NULL, 'applied', FALSE, NULL, 'Practical Research 2', NULL, '80', 22),
  ('ABM', 'subject', 2, 1, NULL, 'applied', FALSE, NULL, 'Filipino sa Piling Larangan', NULL, '80', 23),
  ('ABM', 'subject', 2, 1, NULL, 'applied', FALSE, NULL, 'English for Academic and Professional Purposes', NULL, '80', 24),
  ('ABM', 'subject', 2, 1, NULL, 'specialized', FALSE, NULL, 'Business Finance', NULL, '80', 25),
  ('ABM', 'subject', 2, 1, NULL, 'specialized', FALSE, NULL, 'Fundamentals of Accountancy, Business & Management 2', NULL, '80', 26),
  ('ABM', 'subject', 2, 2, NULL, 'core', FALSE, NULL, 'Contemporary Philippine Arts from the Regions', NULL, '80', 27),
  ('ABM', 'subject', 2, 2, NULL, 'core', FALSE, NULL, 'Physical Education and Health 4', NULL, '20', 28),
  ('ABM', 'subject', 2, 2, NULL, 'applied', FALSE, NULL, 'Empowerment Technologies', NULL, '80', 29),
  ('ABM', 'subject', 2, 2, NULL, 'applied', FALSE, NULL, 'Entrepreneurship', NULL, '80', 30),
  ('ABM', 'subject', 2, 2, NULL, 'applied', FALSE, NULL, 'Inquiries, Investigations and Immersion', NULL, '80', 31),
  ('ABM', 'subject', 2, 2, NULL, 'specialized', FALSE, NULL, 'Applied Economics', NULL, '80', 32),
  ('ABM', 'subject', 2, 2, NULL, 'specialized', FALSE, NULL, 'Business Ethics & Social Responsibility', NULL, '80', 33);


-- 1. Programs
INSERT INTO academic_programs (code, name, level, department)
SELECT sp.code, sp.name, sp.level, sp.department
FROM seed_programs sp
WHERE NOT EXISTS (
    SELECT 1 FROM academic_programs ap
    WHERE UPPER(ap.code) = UPPER(sp.code) AND ap.is_deleted = FALSE
);

-- 2. Curricula (created as draft so subjects can be linked, published below)
INSERT INTO curricula (program_id, code, status)
SELECT ap.id, sp.curriculum_code, 'draft'
FROM seed_programs sp
JOIN academic_programs ap ON UPPER(ap.code) = UPPER(sp.code) AND ap.is_deleted = FALSE
WHERE NOT EXISTS (
    SELECT 1 FROM curricula c
    WHERE c.program_id = ap.id AND UPPER(c.code) = UPPER(sp.curriculum_code) AND c.is_deleted = FALSE
);

-- 3. Shared subject catalog (one row per course code; unnumbered subjects by name)
INSERT INTO academic_subjects (code, name, units, hours)
SELECT DISTINCT ON (LOWER(s.code)) s.code, s.name, s.units, s.hours
FROM seed_rows s
WHERE s.code IS NOT NULL
  AND NOT EXISTS (
      SELECT 1 FROM academic_subjects a
      WHERE LOWER(a.code) = LOWER(s.code) AND a.is_deleted = FALSE
  )
ORDER BY LOWER(s.code), s.program_code, s.sort_order;

INSERT INTO academic_subjects (code, name, units, hours)
SELECT DISTINCT ON (LOWER(s.name)) NULL, s.name, s.units, s.hours
FROM seed_rows s
WHERE s.code IS NULL
  AND NOT EXISTS (
      SELECT 1 FROM academic_subjects a
      WHERE a.code IS NULL AND LOWER(a.name) = LOWER(s.name) AND a.is_deleted = FALSE
  )
ORDER BY LOWER(s.name), s.program_code, s.sort_order;

-- 4. Term subjects
INSERT INTO curriculum_subjects
    (curriculum_id, subject_id, year_level, term, category, is_elective_slot, sort_order)
SELECT c.id, a.id, s.year_level, s.term, s.category, s.is_slot, s.sort_order
FROM seed_rows s
JOIN academic_programs ap ON UPPER(ap.code) = UPPER(s.program_code) AND ap.is_deleted = FALSE
JOIN seed_programs sp ON sp.code = s.program_code
JOIN curricula c ON c.program_id = ap.id AND UPPER(c.code) = UPPER(sp.curriculum_code) AND c.is_deleted = FALSE
JOIN academic_subjects a
  ON a.is_deleted = FALSE
 AND ((s.code IS NOT NULL AND LOWER(a.code) = LOWER(s.code))
   OR (s.code IS NULL AND a.code IS NULL AND LOWER(a.name) = LOWER(s.name)))
WHERE s.kind = 'subject'
  AND c.status = 'draft'
  AND NOT EXISTS (
      SELECT 1 FROM curriculum_subjects cs
      WHERE cs.curriculum_id = c.id AND cs.year_level = s.year_level
        AND cs.term = s.term AND cs.subject_id = a.id AND cs.is_deleted = FALSE
  );

-- 5. Lists of electives
INSERT INTO curriculum_electives (curriculum_id, subject_id, group_name, sort_order)
SELECT c.id, a.id, s.group_name, s.sort_order
FROM seed_rows s
JOIN academic_programs ap ON UPPER(ap.code) = UPPER(s.program_code) AND ap.is_deleted = FALSE
JOIN seed_programs sp ON sp.code = s.program_code
JOIN curricula c ON c.program_id = ap.id AND UPPER(c.code) = UPPER(sp.curriculum_code) AND c.is_deleted = FALSE
JOIN academic_subjects a ON a.is_deleted = FALSE AND LOWER(a.code) = LOWER(s.code)
WHERE s.kind = 'elective'
  AND c.status = 'draft'
  AND NOT EXISTS (
      SELECT 1 FROM curriculum_electives ce
      WHERE ce.curriculum_id = c.id AND ce.subject_id = a.id AND ce.is_deleted = FALSE
  );

-- 6. Publish the seeded curricula (they are the current, official ones)
UPDATE curricula c
SET status = 'published', published_at = NOW(), updated_at = NOW()
FROM seed_programs sp
JOIN academic_programs ap ON UPPER(ap.code) = UPPER(sp.code) AND ap.is_deleted = FALSE
WHERE c.program_id = ap.id
  AND UPPER(c.code) = UPPER(sp.curriculum_code)
  AND c.status = 'draft';

COMMIT;


-- ============================================================
-- PART 3 of 6: department names (was 008_academic_departments.sql)
-- ============================================================

-- CheckMate: Academic Management department names
-- Migration: 008_academic_departments.sql   (run after 007_academic_seed.sql)
--
-- Puts every college program under its correct department. Safe to run twice.

BEGIN;

UPDATE academic_programs SET department = CASE code
    WHEN 'BSIT'   THEN 'Information Technology Department'
    WHEN 'BSCpE'  THEN 'Engineering Department'
    WHEN 'BSBA'   THEN 'Business & Management Department'
    WHEN 'BSAIS'  THEN 'Business & Management Department'
    WHEN 'BSA'    THEN 'Business & Management Department'
    WHEN 'BSHM'   THEN 'Hospitality Management Department'
    WHEN 'BMMA'   THEN 'Arts & Sciences Department'
    WHEN 'BACOMM' THEN 'Arts & Sciences Department'
    WHEN 'BSTM'   THEN 'Tourism Management Department'
END,
updated_at = NOW()
WHERE level = 'college'
  AND is_deleted = FALSE
  AND code IN ('BSIT','BSCpE','BSBA','BSAIS','BSA','BSHM','BMMA','BACOMM','BSTM');

COMMIT;


-- ============================================================
-- PART 4 of 6: required hours per curriculum subject (was 009_curriculum_subject_hours.sql)
-- ============================================================

-- CheckMate: required hours belong to the curriculum, not the shared subject
-- Migration: 009_curriculum_subject_hours.sql   (run after 008)
--
-- Senior High School subjects can keep the same name but change their
-- Core/Applied/Specialized group or required hours in a new curriculum.
-- The group already lives on curriculum_subjects; this adds the hours there too.

BEGIN;

ALTER TABLE curriculum_subjects
    ADD COLUMN IF NOT EXISTS hours INTEGER CHECK (hours IS NULL OR hours >= 0);

-- Copy the hours seeded on the shared subject into the curriculum rows.
-- The published-curriculum lock is switched off only for this one backfill.
ALTER TABLE curriculum_subjects DISABLE TRIGGER trg_curriculum_subjects_locked;

UPDATE curriculum_subjects cs
SET hours = a.hours
FROM academic_subjects a
WHERE a.id = cs.subject_id
  AND cs.hours IS NULL
  AND a.hours IS NOT NULL;

ALTER TABLE curriculum_subjects ENABLE TRIGGER trg_curriculum_subjects_locked;

COMMIT;

-- ============================================================
-- PART 5 of 6: link teaching subjects to Academic Management subjects
-- (Section Assignments pick subjects from Academic Management; the server
-- links an existing subjects row or creates one the first time a subject is
-- assigned.) Idempotent: safe to run more than once.
-- ============================================================

BEGIN;

ALTER TABLE subjects
    ADD COLUMN IF NOT EXISTS academic_subject_id BIGINT
        REFERENCES academic_subjects(id) ON DELETE SET NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_subjects_academic_subject
    ON subjects (academic_subject_id)
    WHERE academic_subject_id IS NOT NULL;

COMMIT;

-- ============================================================
-- PART 6 of 6: section catalog (was server/sql/create_sections.sql)
-- ============================================================

-- Section catalog: one row per section (e.g. BSIT11D, ABM11-A) per
-- school year and semester. Programs / strands live in academic_programs.
-- Idempotent: safe to run more than once.

BEGIN;

CREATE TABLE IF NOT EXISTS sections (
  id          SERIAL PRIMARY KEY,
  program_id  INT NOT NULL REFERENCES academic_programs(id),
  name        VARCHAR(40) NOT NULL,
  year_level  INT NOT NULL CHECK (year_level BETWEEN 1 AND 4),
  school_year VARCHAR(9) NOT NULL,
  semester    INT NOT NULL CHECK (semester IN (1, 2)),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (school_year, semester, name)
);

CREATE INDEX IF NOT EXISTS sections_program_idx ON sections (program_id);

COMMIT;
