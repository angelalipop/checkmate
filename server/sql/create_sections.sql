-- Section catalog: one row per section (e.g. BSIT11D, ABM11-A) per
-- school year and semester. Programs / strands live in academic_programs.
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
