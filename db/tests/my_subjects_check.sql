-- READ-ONLY checks for the My Subjects migration. Inserts nothing.
-- Run:  psql -U checkmate -d checkmate -f db/tests/my_subjects_check.sql

-- 1. New columns on exams (expect 2 rows)
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_name = 'exams' AND column_name IN ('assessment_type', 'version')
ORDER BY column_name;

-- 2. New tables (expect 2 rows)
SELECT table_name FROM information_schema.tables
WHERE table_name IN ('exam_class_assignments', 'assessment_absences')
ORDER BY table_name;

-- 3. Every existing exam is linked to its own class (expect 0)
SELECT COUNT(*) AS exams_without_assignment
FROM exams e
WHERE NOT EXISTS (
  SELECT 1 FROM exam_class_assignments a
  WHERE a.exam_id = e.id AND a.class_id = e.class_id
);

-- 4. An assessment must only be given to ONE subject (expect 0 rows)
SELECT a.exam_id, COUNT(DISTINCT c.subject_id) AS subjects
FROM exam_class_assignments a
JOIN classes c ON c.id = a.class_id
GROUP BY a.exam_id
HAVING COUNT(DISTINCT c.subject_id) > 1;

-- 5. Each teacher's assigned classes (what My Subjects is built from)
SELECT u.name AS teacher, s.code, s.name AS subject, c.section,
       c.school_year, c.semester
FROM classes c
JOIN users u ON u.id = c.teacher_id
JOIN subjects s ON s.id = c.subject_id
ORDER BY u.name, s.name, c.section;
