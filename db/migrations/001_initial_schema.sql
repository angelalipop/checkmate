-- CheckMate
-- Initial database schema
-- Migration: 001_initial_schema.sql

BEGIN;

-- ============================================================
-- USERS
-- ============================================================

CREATE TABLE users (
    id BIGSERIAL PRIMARY KEY,
    name VARCHAR(150) NOT NULL,
    email VARCHAR(255) NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    role VARCHAR(20) NOT NULL
        CHECK (role IN ('admin', 'teacher')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ============================================================
-- SUBJECTS
-- ============================================================

CREATE TABLE subjects (
    id BIGSERIAL PRIMARY KEY,
    name VARCHAR(150) NOT NULL,
    code VARCHAR(50),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_subject_name UNIQUE (name)
);


-- ============================================================
-- CLASSES
-- ============================================================

CREATE TABLE classes (
    id BIGSERIAL PRIMARY KEY,
    subject_id BIGINT NOT NULL REFERENCES subjects(id),
    teacher_id BIGINT NOT NULL REFERENCES users(id),
    section VARCHAR(100) NOT NULL,
    school_year VARCHAR(20),
    semester VARCHAR(50),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ============================================================
-- STUDENTS
-- ============================================================

CREATE TABLE students (
    id BIGSERIAL PRIMARY KEY,
    class_id BIGINT NOT NULL REFERENCES classes(id) ON DELETE CASCADE,
    student_number VARCHAR(100) NOT NULL,
    first_name VARCHAR(100) NOT NULL,
    last_name VARCHAR(100) NOT NULL,
    email VARCHAR(255),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_student_class_number
        UNIQUE (class_id, student_number)
);


-- ============================================================
-- EXAMS
-- ============================================================

CREATE TABLE exams (
    id BIGSERIAL PRIMARY KEY,
    class_id BIGINT NOT NULL REFERENCES classes(id) ON DELETE CASCADE,
    title VARCHAR(255) NOT NULL,
    description TEXT,
    instructions TEXT,
    status VARCHAR(20) NOT NULL DEFAULT 'draft'
        CHECK (status IN ('draft', 'published', 'archived')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ============================================================
-- EXAM SECTIONS
-- ============================================================

CREATE TABLE exam_sections (
    id BIGSERIAL PRIMARY KEY,
    exam_id BIGINT NOT NULL REFERENCES exams(id) ON DELETE CASCADE,
    name VARCHAR(150) NOT NULL,
    question_type VARCHAR(30) NOT NULL
        CHECK (
            question_type IN (
                'identification',
                'true_false',
                'multiple_choice'
            )
        ),
    section_order INTEGER NOT NULL,
    default_points NUMERIC(8,2) NOT NULL DEFAULT 1.00
        CHECK (default_points >= 0)
);


-- ============================================================
-- QUESTIONS
-- ============================================================

CREATE TABLE questions (
    id BIGSERIAL PRIMARY KEY,
    section_id BIGINT NOT NULL REFERENCES exam_sections(id)
        ON DELETE CASCADE,

    question_number INTEGER NOT NULL,
    question_text TEXT NOT NULL,

    points NUMERIC(8,2) NOT NULL
        CHECK (points >= 0),

    choices JSONB,
    correct_answer TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_question_number
        UNIQUE (section_id, question_number)
);


-- ============================================================
-- ACCEPTABLE ANSWERS
-- Used primarily for identification questions.
-- ============================================================

CREATE TABLE acceptable_answers (
    id BIGSERIAL PRIMARY KEY,
    question_id BIGINT NOT NULL REFERENCES questions(id)
        ON DELETE CASCADE,

    answer TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_acceptable_answer
        UNIQUE (question_id, answer)
);


-- ============================================================
-- EXAM ATTEMPTS
-- ============================================================

CREATE TABLE exam_attempts (
    id BIGSERIAL PRIMARY KEY,

    exam_id BIGINT NOT NULL REFERENCES exams(id),
    student_id BIGINT NOT NULL REFERENCES students(id),

    score NUMERIC(10,2) NOT NULL DEFAULT 0,
    max_score NUMERIC(10,2) NOT NULL DEFAULT 0,

    status VARCHAR(30) NOT NULL DEFAULT 'processing'
        CHECK (
            status IN (
                'processing',
                'pending_verification',
                'completed'
            )
        ),

    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ============================================================
-- STUDENT ANSWERS
-- ============================================================

CREATE TABLE student_answers (
    id BIGSERIAL PRIMARY KEY,

    attempt_id BIGINT NOT NULL REFERENCES exam_attempts(id)
        ON DELETE CASCADE,

    question_id BIGINT NOT NULL REFERENCES questions(id),

    raw_answer TEXT,
    recognized_answer TEXT,

    points_earned NUMERIC(8,2) NOT NULL DEFAULT 0,

    is_correct BOOLEAN,

    confidence NUMERIC(5,4)
        CHECK (
            confidence IS NULL
            OR (confidence >= 0 AND confidence <= 1)
        ),

    verification_status VARCHAR(30) NOT NULL DEFAULT 'automatic'
        CHECK (
            verification_status IN (
                'automatic',
                'needs_review',
                'verified'
            )
        ),

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_attempt_question
        UNIQUE (attempt_id, question_id)
);


-- ============================================================
-- INDEXES
-- ============================================================

CREATE INDEX idx_classes_teacher
    ON classes(teacher_id);

CREATE INDEX idx_classes_subject
    ON classes(subject_id);

CREATE INDEX idx_students_class
    ON students(class_id);

CREATE INDEX idx_exams_class
    ON exams(class_id);

CREATE INDEX idx_exam_sections_exam
    ON exam_sections(exam_id);

CREATE INDEX idx_questions_section
    ON questions(section_id);

CREATE INDEX idx_attempts_exam
    ON exam_attempts(exam_id);

CREATE INDEX idx_attempts_student
    ON exam_attempts(student_id);

CREATE INDEX idx_answers_attempt
    ON student_answers(attempt_id);

CREATE INDEX idx_answers_question
    ON student_answers(question_id);


COMMIT;
