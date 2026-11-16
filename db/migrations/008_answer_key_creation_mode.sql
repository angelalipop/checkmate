BEGIN;
ALTER TABLE exams DROP CONSTRAINT IF EXISTS chk_assessment_grading_metadata;
ALTER TABLE exams ADD CONSTRAINT chk_assessment_grading_metadata CHECK (
 (grading_period IS NULL OR grading_period IN ('prelims','midterm','pre_finals','finals'))
 AND creation_mode IN ('builder','manual','answer_key')
 AND (creation_mode IN ('builder','answer_key') AND manual_max_score IS NULL OR
      creation_mode = 'manual' AND assessment_type IS NOT NULL AND assessment_type IN ('performance_task','laboratory')
      AND grading_period IS NOT NULL AND manual_max_score IS NOT NULL
      AND manual_max_score > 0 AND manual_max_score <> 'NaN'::numeric)
 AND (grading_period IS NULL OR
      assessment_type NOT IN ('prelim','midterm','prefinal','pre_finals','final','finals') OR
      grading_period = CASE assessment_type WHEN 'prelim' THEN 'prelims'
       WHEN 'midterm' THEN 'midterm' WHEN 'prefinal' THEN 'pre_finals'
       WHEN 'pre_finals' THEN 'pre_finals' ELSE 'finals' END));
COMMIT;
