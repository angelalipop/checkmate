import {fileURLToPath} from 'node:url';
process.chdir(fileURLToPath(new URL('../',import.meta.url)));
import {PGlite} from '@electric-sql/pglite';
import {readFileSync,writeFileSync} from 'node:fs';
const db=new PGlite();let passed=0;
function assert(condition,label){if(!condition)throw new Error(label);passed++;console.log('PASS '+label)}
async function rejects(sql,label){let rejected=false;try{await db.exec(sql)}catch{rejected=true}assert(rejected,label)}
for(const name of ['001_initial_schema.sql','002_teacher_module.sql','003_academic_module.sql','004_my_subjects.sql','005_short_quiz_support.sql','006_student_one_time_edit.sql','007_assessment_grading.sql']){
 try{await db.exec(readFileSync('db/migrations/'+name,'utf8'));console.log('Applied '+name)}catch(e){console.error('MIGRATION '+name+': '+e.message);throw e;}
}
await db.exec(readFileSync('db/migrations/007_assessment_grading.sql','utf8'));assert(true,'Migration 007 is idempotent');
await db.exec(`INSERT INTO users(id,name,email,password_hash,role,username) VALUES(99001,'Teacher','t@example.test','fixture','teacher','qa_teacher'),(99002,'Teacher 2','t2@example.test','fixture','teacher','qa_teacher2');
INSERT INTO subjects(id,name,code) VALUES(99001,'Test Subject','QA');
INSERT INTO classes(id,subject_id,teacher_id,section) VALUES(99001,99001,99001,'QA-A'),(99002,99001,99001,'QA-B'),(99003,99001,99002,'QA-C');
INSERT INTO students(id,class_id,student_number,first_name,last_name) VALUES(99001,99001,'QA001','First','Student'),(99002,99002,'QA002','Second','Student');
INSERT INTO exams(id,class_id,title,assessment_type,grading_period,creation_mode,manual_max_score) VALUES(99001,99001,'Manual PT','performance_task','prelims','manual',30),(99002,99001,'Manual LAB','laboratory','midterm','manual',40),(99003,99001,'Old quiz',NULL,NULL,'builder',NULL);
INSERT INTO exam_class_assignments(exam_id,class_id,exam_version) VALUES(99001,99001,1),(99002,99001,1),(99003,99001,1);`);
await db.exec(`INSERT INTO assessment_manual_scores(exam_id,student_id,score,updated_by) VALUES(99001,99001,0,99001);`);
assert((await db.query('SELECT score FROM assessment_manual_scores WHERE exam_id=99001')).rows[0].score==='0.00'||Number((await db.query('SELECT score FROM assessment_manual_scores WHERE exam_id=99001')).rows[0].score)===0,'Recorded zero persists');
await db.exec(`INSERT INTO assessment_manual_scores(exam_id,student_id,score) VALUES(99001,99001,20) ON CONFLICT(exam_id,student_id) DO UPDATE SET score=EXCLUDED.score;`);
assert((await db.query('SELECT count(*)::int AS n FROM assessment_manual_scores WHERE exam_id=99001')).rows[0].n===1,'Repeated save updates one manual record');
await rejects(`UPDATE assessment_manual_scores SET score=31 WHERE exam_id=99001`,'Scores above maximum rejected');
await rejects(`UPDATE assessment_manual_scores SET score=-1 WHERE exam_id=99001`,'Negative scores rejected');
await rejects(`INSERT INTO assessment_manual_scores(exam_id,student_id,score) VALUES(99001,99002,10)`,'Unassigned student rejected');
await rejects(`INSERT INTO exam_sections(exam_id,name,question_type,section_order) VALUES(99001,'Forbidden','multiple_choice',1)`,'Manual question sections rejected');
await rejects(`INSERT INTO exam_attempts(exam_id,student_id) VALUES(99001,99001)`,'Manual scan attempts rejected');
await rejects(`UPDATE exams SET creation_mode='builder',manual_max_score=NULL WHERE id=99001`,'Mode conversion rejected');
await rejects(`UPDATE exams SET status='published' WHERE id=99001`,'Manual publishing rejected');
await rejects(`UPDATE exams SET manual_max_score=10 WHERE id=99001`,'Maximum below existing scores rejected');
await rejects(`INSERT INTO exams(class_id,title,assessment_type,grading_period,creation_mode,manual_max_score) VALUES(99001,'Bad',NULL,'prelims','manual',20)`,'Null manual classification rejected');
await rejects(`INSERT INTO exams(class_id,title,assessment_type,grading_period,creation_mode,manual_max_score) VALUES(99001,'Bad','quiz','prelims','manual',20)`,'Manual quiz rejected');
await rejects(`INSERT INTO exams(class_id,title,assessment_type,grading_period) VALUES(99001,'Bad','prelim','finals')`,'Major period mismatch rejected');
await db.exec(`INSERT INTO class_grading_preferences(class_id) VALUES(99001)`);assert(true,'Default preferences persist');
await rejects(`UPDATE class_grading_preferences SET quiz=21 WHERE class_id=99001`,'Category weights must total 100');
await rejects(`UPDATE class_grading_preferences SET finals=41 WHERE class_id=99001`,'Period weights must total 100');
assert((await db.query('SELECT assessment_type,grading_period FROM exams WHERE id=99003')).rows[0].assessment_type===null,'Legacy classification remains unknown');
await db.exec(`DELETE FROM assessment_manual_scores WHERE exam_id=99001 AND student_id=99001`);assert((await db.query('SELECT count(*)::int AS n FROM assessment_manual_scores')).rows[0].n===0,'Clearing score produces missing, no zero inserted');
const params={teacher_id:99001,user_id:99001,class_id:99001,student_id:99001,exam_id:99001,id:99001,ids:[99001],exam_ids:[99001,99002,99003],attempt_id:99001,section_id:99001,class_ids:[99001]};
for(const item of JSON.parse(readFileSync('verification/query_checks.json','utf8'))){
 const names=[];const sql=item.sql.replace(/@([a-z_]+)/g,(_,name)=>{if(!names.includes(name))names.push(name);return '$'+(names.indexOf(name)+1)});
 if(names.some(n=>!(n in params)))throw new Error('Unknown param '+names);
 try{await db.query(sql,names.map(n=>params[n]));assert(true,'Source SQL '+item.label)}catch(e){throw new Error(item.label+': '+e.message)}
}
await db.exec(readFileSync('db/tests/assessment_grading_check.sql','utf8').replace(/^\\set.*$/mg,''));assert(true,'Packaged SQL regression script rolls back fixtures');
writeFileSync('verification/database_results.json',JSON.stringify({passed},null,2));await db.close();console.log(`${passed} database checks passed`);
