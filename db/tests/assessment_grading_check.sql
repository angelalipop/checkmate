-- Run after 007 in a test database. Fixtures roll back.
\set ON_ERROR_STOP on
BEGIN;
DO $$
DECLARE teacher BIGINT; subject BIGINT; class BIGINT; student BIGINT;
 assessment BIGINT; n INTEGER; rejected BOOLEAN;
 marker TEXT := md5(random()::text || clock_timestamp()::text);
BEGIN
 INSERT INTO users(name,email,username,password_hash,role) VALUES('Grading Test','grading-'||marker||'@example.invalid','grading_'||marker,'fixture','teacher') RETURNING id INTO teacher;
 INSERT INTO subjects(name,code) VALUES('Grading Test '||marker,'QA') RETURNING id INTO subject;
 INSERT INTO classes(subject_id,teacher_id,section) VALUES(subject,teacher,'QA-'||marker) RETURNING id INTO class;
 INSERT INTO students(class_id,student_number,first_name,last_name) VALUES(class,marker,'Test','Student') RETURNING id INTO student;
 INSERT INTO exams(class_id,title,assessment_type,grading_period,creation_mode,manual_max_score) VALUES(class,'Manual Test','performance_task','prelims','manual',30) RETURNING id INTO assessment;
 INSERT INTO assessment_manual_scores(exam_id,student_id,score) VALUES(assessment,student,0);
 IF (SELECT score FROM assessment_manual_scores WHERE exam_id=assessment AND student_id=student) <> 0 THEN RAISE EXCEPTION 'Zero did not persist'; END IF;
 INSERT INTO assessment_manual_scores(exam_id,student_id,score) VALUES(assessment,student,20) ON CONFLICT(exam_id,student_id) DO UPDATE SET score=EXCLUDED.score;
 SELECT count(*) INTO n FROM assessment_manual_scores WHERE exam_id=assessment AND student_id=student;
 IF n<>1 THEN RAISE EXCEPTION 'Duplicate score'; END IF;
 rejected:=false;
 BEGIN UPDATE assessment_manual_scores SET score=31 WHERE exam_id=assessment AND student_id=student; EXCEPTION WHEN OTHERS THEN rejected:=true; END;
 IF NOT rejected THEN RAISE EXCEPTION 'Out-of-range score accepted'; END IF;
 rejected:=false;
 BEGIN INSERT INTO exam_sections(exam_id,name,question_type,section_order) VALUES(assessment,'Forbidden','multiple_choice',1); EXCEPTION WHEN OTHERS THEN rejected:=true; END;
 IF NOT rejected THEN RAISE EXCEPTION 'Manual question section accepted'; END IF;
 rejected:=false;
 BEGIN INSERT INTO exam_attempts(exam_id,student_id) VALUES(assessment,student); EXCEPTION WHEN OTHERS THEN rejected:=true; END;
 IF NOT rejected THEN RAISE EXCEPTION 'Manual scan attempt accepted'; END IF;
 rejected:=false;
 BEGIN UPDATE exams SET status='published' WHERE id=assessment; EXCEPTION WHEN OTHERS THEN rejected:=true; END;
 IF NOT rejected THEN RAISE EXCEPTION 'Manual publishing accepted'; END IF;
 INSERT INTO class_grading_preferences(class_id) VALUES(class);
 rejected:=false;
 BEGIN UPDATE class_grading_preferences SET quiz=21 WHERE class_id=class; EXCEPTION WHEN OTHERS THEN rejected:=true; END;
 IF NOT rejected THEN RAISE EXCEPTION 'Invalid weight total accepted'; END IF;
 DELETE FROM assessment_manual_scores WHERE exam_id=assessment AND student_id=student;
 IF EXISTS(SELECT 1 FROM assessment_manual_scores WHERE exam_id=assessment AND student_id=student) THEN RAISE EXCEPTION 'Score did not clear'; END IF;
 RAISE NOTICE 'Assessment grading checks passed; fixtures will roll back.';
END $$;
ROLLBACK;
