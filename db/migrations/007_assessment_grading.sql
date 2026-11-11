-- Apply after 006. No historical scores, types, or periods are rewritten.
BEGIN;
ALTER TABLE exams
 ADD COLUMN IF NOT EXISTS grading_period VARCHAR(20),
 ADD COLUMN IF NOT EXISTS creation_mode VARCHAR(16) NOT NULL DEFAULT 'builder',
 ADD COLUMN IF NOT EXISTS manual_max_score NUMERIC(12,2);
ALTER TABLE exams DROP CONSTRAINT IF EXISTS chk_exams_assessment_type;
ALTER TABLE exams ADD CONSTRAINT chk_exams_assessment_type CHECK (
 assessment_type IS NULL OR assessment_type IN
 ('quiz','short_quiz','long_quiz','performance_task','laboratory','prelim','midterm','prefinal','pre_finals','final','finals','other'));
ALTER TABLE exams DROP CONSTRAINT IF EXISTS chk_assessment_grading_metadata;
ALTER TABLE exams ADD CONSTRAINT chk_assessment_grading_metadata CHECK (
 (grading_period IS NULL OR grading_period IN ('prelims','midterm','pre_finals','finals'))
 AND creation_mode IN ('builder','manual')
 AND (creation_mode = 'builder' AND manual_max_score IS NULL OR
      creation_mode = 'manual' AND assessment_type IS NOT NULL AND assessment_type IN ('performance_task','laboratory')
      AND grading_period IS NOT NULL AND manual_max_score IS NOT NULL
      AND manual_max_score > 0 AND manual_max_score <> 'NaN'::numeric)
 AND (grading_period IS NULL OR
      assessment_type NOT IN ('prelim','midterm','prefinal','pre_finals','final','finals') OR
      grading_period = CASE assessment_type WHEN 'prelim' THEN 'prelims'
       WHEN 'midterm' THEN 'midterm' WHEN 'prefinal' THEN 'pre_finals'
       WHEN 'pre_finals' THEN 'pre_finals' ELSE 'finals' END));
CREATE TABLE IF NOT EXISTS assessment_manual_scores (
 exam_id BIGINT NOT NULL REFERENCES exams(id) ON DELETE CASCADE,
 student_id BIGINT NOT NULL REFERENCES students(id) ON DELETE CASCADE,
 score NUMERIC(12,2) NOT NULL CHECK (score >= 0 AND score <> 'NaN'::numeric),
 updated_by BIGINT REFERENCES users(id) ON DELETE SET NULL,
 updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
 PRIMARY KEY (exam_id, student_id)
);
CREATE TABLE IF NOT EXISTS class_grading_preferences (
 class_id BIGINT PRIMARY KEY REFERENCES classes(id) ON DELETE CASCADE,
 pt NUMERIC(5,2) NOT NULL DEFAULT 30 CHECK (pt BETWEEN 0 AND 100),
 quiz NUMERIC(5,2) NOT NULL DEFAULT 20 CHECK (quiz BETWEEN 0 AND 100),
 exam NUMERIC(5,2) NOT NULL DEFAULT 50 CHECK (exam BETWEEN 0 AND 100),
 prelims NUMERIC(5,2) NOT NULL DEFAULT 20 CHECK (prelims BETWEEN 0 AND 100),
 midterm NUMERIC(5,2) NOT NULL DEFAULT 20 CHECK (midterm BETWEEN 0 AND 100),
 pre_finals NUMERIC(5,2) NOT NULL DEFAULT 20 CHECK (pre_finals BETWEEN 0 AND 100),
 finals NUMERIC(5,2) NOT NULL DEFAULT 40 CHECK (finals BETWEEN 0 AND 100),
 updated_by BIGINT REFERENCES users(id) ON DELETE SET NULL,
 updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
 CHECK (pt + quiz + exam = 100),
 CHECK (prelims + midterm + pre_finals + finals = 100)
);
-- Boundary protection: manual records cannot acquire builder/scanner data.
CREATE OR REPLACE FUNCTION checkmate_builder_only() RETURNS TRIGGER AS $$
BEGIN
 IF EXISTS (SELECT 1 FROM exams WHERE id = NEW.exam_id AND creation_mode = 'manual') THEN
  RAISE EXCEPTION 'Manual-only assessments cannot have question sections or scan attempts';
 END IF;
 RETURN NEW;
END; $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS checkmate_section_builder_only ON exam_sections;
CREATE TRIGGER checkmate_section_builder_only BEFORE INSERT OR UPDATE ON exam_sections
 FOR EACH ROW EXECUTE FUNCTION checkmate_builder_only();
DROP TRIGGER IF EXISTS checkmate_attempt_builder_only ON exam_attempts;
CREATE TRIGGER checkmate_attempt_builder_only BEFORE INSERT OR UPDATE ON exam_attempts
 FOR EACH ROW EXECUTE FUNCTION checkmate_builder_only();
CREATE OR REPLACE FUNCTION checkmate_manual_score_bounds() RETURNS TRIGGER AS $$
DECLARE mx NUMERIC; mode TEXT; cid BIGINT;
BEGIN
 SELECT creation_mode, manual_max_score INTO mode, mx FROM exams WHERE id = NEW.exam_id FOR UPDATE;
 IF mode IS DISTINCT FROM 'manual' OR NEW.score > mx THEN RAISE EXCEPTION 'Invalid manual assessment score'; END IF;
 SELECT class_id INTO cid FROM students WHERE id = NEW.student_id;
 IF NOT EXISTS (SELECT 1 FROM exams WHERE id = NEW.exam_id AND class_id = cid)
 AND NOT EXISTS (SELECT 1 FROM exam_class_assignments WHERE exam_id = NEW.exam_id AND class_id = cid) THEN
  RAISE EXCEPTION 'Student does not belong to an assigned section';
 END IF;
 RETURN NEW;
END; $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS checkmate_manual_score_bounds ON assessment_manual_scores;
CREATE TRIGGER checkmate_manual_score_bounds BEFORE INSERT OR UPDATE ON assessment_manual_scores
 FOR EACH ROW EXECUTE FUNCTION checkmate_manual_score_bounds();
CREATE OR REPLACE FUNCTION checkmate_preserve_assessment_mode() RETURNS TRIGGER AS $$
BEGIN
 IF NEW.creation_mode IS DISTINCT FROM OLD.creation_mode THEN RAISE EXCEPTION 'Assessment creation mode cannot be changed'; END IF;
 IF NEW.creation_mode = 'manual' THEN
  IF NEW.status IS DISTINCT FROM OLD.status THEN RAISE EXCEPTION 'Manual-only assessments do not use publishing'; END IF;
  IF EXISTS (SELECT 1 FROM assessment_manual_scores WHERE exam_id = NEW.id AND score > NEW.manual_max_score) THEN
   RAISE EXCEPTION 'Maximum score cannot be lower than an existing score';
  END IF;
 END IF;
 RETURN NEW;
END; $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS checkmate_preserve_assessment_mode ON exams;
CREATE TRIGGER checkmate_preserve_assessment_mode BEFORE UPDATE ON exams
 FOR EACH ROW EXECUTE FUNCTION checkmate_preserve_assessment_mode();
COMMIT;
