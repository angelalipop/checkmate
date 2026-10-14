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
