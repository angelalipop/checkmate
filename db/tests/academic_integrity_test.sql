-- CheckMate: Academic Management database integrity test
-- Run AFTER 006 and 007:
--   docker exec -i <postgres-container> psql -U checkmate -d checkmate -v ON_ERROR_STOP=1 < db/tests/academic_integrity_test.sql
-- Everything runs inside a transaction that is rolled back, so no data changes.
-- Any failed check stops the script with a message starting with "FAIL".

BEGIN;

CREATE FUNCTION pg_temp.check_eq(label TEXT, actual BIGINT, expected BIGINT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'FAIL: % (got %, expected %)', label, actual, expected;
    END IF;
    RAISE NOTICE 'ok: %', label;
END;
$$;

-- Runs a statement that MUST be rejected by the database.
CREATE FUNCTION pg_temp.must_fail(label TEXT, stmt TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE stmt;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'ok: % (rejected: %)', label, SQLERRM;
        RETURN;
    END;
    RAISE EXCEPTION 'FAIL: % was allowed but must be rejected', label;
END;
$$;

CREATE FUNCTION pg_temp.cid(prog TEXT) RETURNS BIGINT LANGUAGE sql AS $$
    SELECT c.id FROM curricula c JOIN academic_programs p ON p.id = c.program_id
    WHERE p.code = prog AND c.is_deleted = FALSE ORDER BY c.id LIMIT 1
$$;

-- ---------- hierarchy ----------
SELECT pg_temp.check_eq('11 programs (9 college + 2 SHS)',
    (SELECT COUNT(*) FROM academic_programs WHERE is_deleted = FALSE), 11);
SELECT pg_temp.check_eq('9 college programs',
    (SELECT COUNT(*) FROM academic_programs WHERE level = 'college' AND is_deleted = FALSE), 9);
SELECT pg_temp.check_eq('2 SHS strands (STEM, ABM)',
    (SELECT COUNT(*) FROM academic_programs WHERE level = 'shs' AND code IN ('STEM','ABM') AND is_deleted = FALSE), 2);
SELECT pg_temp.check_eq('every program has exactly one published curriculum',
    (SELECT COUNT(*) FROM academic_programs p WHERE p.is_deleted = FALSE AND
        (SELECT COUNT(*) FROM curricula c WHERE c.program_id = p.id AND c.is_deleted = FALSE AND c.status = 'published') = 1), 11);
SELECT pg_temp.check_eq('2201 programs (BACOMM, BMMA, BSCpE, BSHM, BSTM)',
    (SELECT COUNT(*) FROM curricula c JOIN academic_programs p ON p.id = c.program_id
      WHERE c.code = '2201' AND p.code IN ('BACOMM','BMMA','BSCpE','BSHM','BSTM')), 5);
SELECT pg_temp.check_eq('2401 programs (BSA, BSAIS, BSBA, BSIT)',
    (SELECT COUNT(*) FROM curricula c JOIN academic_programs p ON p.id = c.program_id
      WHERE c.code = '2401' AND p.code IN ('BSA','BSAIS','BSBA','BSIT')), 4);

-- ---------- subject counts per curriculum ----------
SELECT pg_temp.check_eq('BSIT subjects', (SELECT COUNT(*) FROM curriculum_subjects WHERE curriculum_id = pg_temp.cid('BSIT') AND is_deleted = FALSE), 54);
SELECT pg_temp.check_eq('BSCpE subjects', (SELECT COUNT(*) FROM curriculum_subjects WHERE curriculum_id = pg_temp.cid('BSCpE') AND is_deleted = FALSE), 60);
SELECT pg_temp.check_eq('BMMA subjects', (SELECT COUNT(*) FROM curriculum_subjects WHERE curriculum_id = pg_temp.cid('BMMA') AND is_deleted = FALSE), 51);
SELECT pg_temp.check_eq('BSA subjects', (SELECT COUNT(*) FROM curriculum_subjects WHERE curriculum_id = pg_temp.cid('BSA') AND is_deleted = FALSE), 61);
SELECT pg_temp.check_eq('STEM subjects', (SELECT COUNT(*) FROM curriculum_subjects WHERE curriculum_id = pg_temp.cid('STEM') AND is_deleted = FALSE), 33);
SELECT pg_temp.check_eq('ABM subjects', (SELECT COUNT(*) FROM curriculum_subjects WHERE curriculum_id = pg_temp.cid('ABM') AND is_deleted = FALSE), 33);

-- ---------- exact filtering by program + curriculum + year + term ----------
SELECT pg_temp.check_eq('BSIT year 1 term 1 has 9 subjects',
    (SELECT COUNT(*) FROM curriculum_subjects WHERE curriculum_id = pg_temp.cid('BSIT') AND year_level = 1 AND term = 1 AND is_deleted = FALSE), 9);
SELECT pg_temp.check_eq('CITE1006 is not in BSIT year 1 term 1',
    (SELECT COUNT(*) FROM curriculum_subjects cs JOIN academic_subjects a ON a.id = cs.subject_id
      WHERE cs.curriculum_id = pg_temp.cid('BSIT') AND cs.year_level = 1 AND cs.term = 1 AND a.code = 'CITE1006'), 0);
SELECT pg_temp.check_eq('CITE1006 is in BSIT year 1 term 2',
    (SELECT COUNT(*) FROM curriculum_subjects cs JOIN academic_subjects a ON a.id = cs.subject_id
      WHERE cs.curriculum_id = pg_temp.cid('BSIT') AND cs.year_level = 1 AND cs.term = 2 AND a.code = 'CITE1006'), 1);
SELECT pg_temp.check_eq('SHS only uses Grade 11 and 12',
    (SELECT COUNT(*) FROM curriculum_subjects cs JOIN curricula c ON c.id = cs.curriculum_id
       JOIN academic_programs p ON p.id = c.program_id WHERE p.level = 'shs' AND cs.year_level > 2), 0);

-- ---------- no OJT / practicum / immersion ----------
SELECT pg_temp.check_eq('no OJT / practicum / internship / work immersion subjects',
    (SELECT COUNT(*) FROM academic_subjects
      WHERE code ~* '^OJTC' OR name ~* 'practicum|internship|on[- ]the[- ]job|\mOJT\M|work immersion'), 0);

-- ---------- shared subjects ----------
SELECT pg_temp.check_eq('GEDC1002 exists once in the catalog',
    (SELECT COUNT(*) FROM academic_subjects WHERE code = 'GEDC1002' AND is_deleted = FALSE), 1);
SELECT pg_temp.check_eq('GEDC1002 is used by more than one curriculum',
    (SELECT CASE WHEN COUNT(DISTINCT cs.curriculum_id) > 1 THEN 1 ELSE 0 END
       FROM curriculum_subjects cs JOIN academic_subjects a ON a.id = cs.subject_id WHERE a.code = 'GEDC1002'), 1);
SELECT pg_temp.check_eq('no duplicate course codes inside one curriculum',
    (SELECT COUNT(*) FROM (
        SELECT cs.curriculum_id, a.code FROM curriculum_subjects cs
        JOIN academic_subjects a ON a.id = cs.subject_id
        WHERE a.code IS NOT NULL AND cs.is_deleted = FALSE
        GROUP BY cs.curriculum_id, a.code HAVING COUNT(*) > 1) d), 0);

-- ---------- electives ----------
SELECT pg_temp.check_eq('BMMA list of electives', (SELECT COUNT(*) FROM curriculum_electives WHERE curriculum_id = pg_temp.cid('BMMA') AND is_deleted = FALSE), 6);
SELECT pg_temp.check_eq('BSCpE list of electives', (SELECT COUNT(*) FROM curriculum_electives WHERE curriculum_id = pg_temp.cid('BSCpE') AND is_deleted = FALSE), 9);
SELECT pg_temp.check_eq('BSIT list of electives', (SELECT COUNT(*) FROM curriculum_electives WHERE curriculum_id = pg_temp.cid('BSIT') AND is_deleted = FALSE), 12);
SELECT pg_temp.check_eq('programs without a list have no electives',
    (SELECT COUNT(*) FROM curriculum_electives ce JOIN curricula c ON c.id = ce.curriculum_id
       JOIN academic_programs p ON p.id = c.program_id WHERE p.code NOT IN ('BMMA','BSCpE','BSIT')), 0);
SELECT pg_temp.check_eq('BSIT elective slots', (SELECT COUNT(*) FROM curriculum_subjects WHERE curriculum_id = pg_temp.cid('BSIT') AND is_elective_slot), 4);
SELECT pg_temp.check_eq('BMMA elective slots', (SELECT COUNT(*) FROM curriculum_subjects WHERE curriculum_id = pg_temp.cid('BMMA') AND is_elective_slot), 5);
SELECT pg_temp.check_eq('BSCpE elective slots', (SELECT COUNT(*) FROM curriculum_subjects WHERE curriculum_id = pg_temp.cid('BSCpE') AND is_elective_slot), 3);
SELECT pg_temp.check_eq('BSA professional elective slots (no list, stay as listed)', (SELECT COUNT(*) FROM curriculum_subjects WHERE curriculum_id = pg_temp.cid('BSA') AND is_elective_slot), 4);

-- ---------- published curricula are locked ----------
SELECT pg_temp.must_fail('editing a published curriculum subject',
    format('UPDATE curriculum_subjects SET sort_order = 999 WHERE curriculum_id = %s', pg_temp.cid('BSIT')));
SELECT pg_temp.must_fail('deleting a published curriculum subject',
    format('DELETE FROM curriculum_subjects WHERE curriculum_id = %s', pg_temp.cid('BSIT')));
SELECT pg_temp.must_fail('deleting a published curriculum',
    format('DELETE FROM curricula WHERE id = %s', pg_temp.cid('BSIT')));
SELECT pg_temp.must_fail('soft-deleting a published curriculum',
    format('UPDATE curricula SET is_deleted = TRUE WHERE id = %s', pg_temp.cid('BSIT')));
SELECT pg_temp.must_fail('published curriculum back to draft',
    format('UPDATE curricula SET status = ''draft'' WHERE id = %s', pg_temp.cid('BSIT')));

-- ---------- uniqueness ----------
SELECT pg_temp.must_fail('duplicate program code',
    $$INSERT INTO academic_programs (code, name, level, department) VALUES ('bsit', 'Duplicate', 'college', 'X')$$);
SELECT pg_temp.must_fail('duplicate curriculum code for a program',
    format('INSERT INTO curricula (program_id, code, status) SELECT program_id, ''2401'', ''draft'' FROM curricula WHERE id = %s', pg_temp.cid('BSIT')));

-- ---------- copy to draft, edit the draft, then delete it ----------
DO $$
DECLARE
    src BIGINT := pg_temp.cid('BSIT');
    pid BIGINT;
    new_id BIGINT;
    n BIGINT;
BEGIN
    SELECT program_id INTO pid FROM curricula WHERE id = src;
    INSERT INTO curricula (program_id, code, status, copied_from_id) VALUES (pid, '2601', 'draft', src) RETURNING id INTO new_id;
    INSERT INTO curriculum_subjects (curriculum_id, subject_id, year_level, term, category, is_elective_slot, sort_order)
        SELECT new_id, subject_id, year_level, term, category, is_elective_slot, sort_order
        FROM curriculum_subjects WHERE curriculum_id = src AND is_deleted = FALSE;

    PERFORM pg_temp.check_eq('copy has the same subjects as the source',
        (SELECT COUNT(*) FROM curriculum_subjects WHERE curriculum_id = new_id), 54);

    -- a draft can be edited: remove one term, shared subjects stay in the source
    DELETE FROM curriculum_subjects WHERE curriculum_id = new_id AND year_level = 1 AND term = 1;
    PERFORM pg_temp.check_eq('draft term delete removes 9 rows',
        (SELECT COUNT(*) FROM curriculum_subjects WHERE curriculum_id = new_id), 45);
    PERFORM pg_temp.check_eq('source curriculum is untouched',
        (SELECT COUNT(*) FROM curriculum_subjects WHERE curriculum_id = src AND is_deleted = FALSE), 54);
    PERFORM pg_temp.check_eq('shared subject GEDC1002 still exists',
        (SELECT COUNT(*) FROM academic_subjects WHERE code = 'GEDC1002' AND is_deleted = FALSE), 1);

    -- soft delete keeps the row but hides it from normal queries
    UPDATE curriculum_subjects SET is_deleted = TRUE, deleted_at = NOW() WHERE curriculum_id = new_id AND year_level = 1 AND term = 2;
    PERFORM pg_temp.check_eq('soft-deleted rows are excluded by normal queries',
        (SELECT COUNT(*) FROM curriculum_subjects WHERE curriculum_id = new_id AND is_deleted = FALSE), 36);
    SELECT COUNT(*) INTO n FROM curriculum_subjects WHERE curriculum_id = new_id AND is_deleted = TRUE;
    PERFORM pg_temp.check_eq('soft-deleted rows remain stored in PostgreSQL', n, 9);

    -- publishing locks the copy
    UPDATE curricula SET status = 'published', published_at = NOW() WHERE id = new_id;
    PERFORM pg_temp.must_fail('editing the copy after it is published',
        format('UPDATE curriculum_subjects SET sort_order = 1 WHERE curriculum_id = %s', new_id));
END;
$$;

-- ---------- elective choice per school year ----------
DO $$
DECLARE
    cid BIGINT := pg_temp.cid('BSIT');
    slot BIGINT;
    el BIGINT;
BEGIN
    SELECT id INTO slot FROM curriculum_subjects WHERE curriculum_id = cid AND is_elective_slot ORDER BY id LIMIT 1;
    SELECT id INTO el FROM curriculum_electives WHERE curriculum_id = cid ORDER BY id LIMIT 1;

    -- allowed on a published curriculum
    INSERT INTO elective_selections (curriculum_subject_id, elective_id, school_year) VALUES (slot, el, '2026-2027');
    PERFORM pg_temp.check_eq('elective finalized on a published curriculum',
        (SELECT COUNT(*)
            FROM elective_selections
            WHERE curriculum_subject_id = slot
            AND school_year = '2026-2027'
            AND is_deleted = FALSE), 1);
    PERFORM pg_temp.must_fail('second choice for the same slot and school year',
        format('INSERT INTO elective_selections (curriculum_subject_id, elective_id, school_year) VALUES (%s, %s, ''2026-2027'')', slot, el));
    PERFORM pg_temp.must_fail('malformed school year',
        format('INSERT INTO elective_selections (curriculum_subject_id, elective_id, school_year) VALUES (%s, %s, ''2026'')', slot, el));
    -- a different school year is a separate choice
    INSERT INTO elective_selections (curriculum_subject_id, elective_id, school_year) VALUES (slot, el, '2027-2028');
    PERFORM pg_temp.check_eq('same slot can differ per school year',
        (SELECT COUNT(*)
            FROM elective_selections
            WHERE curriculum_subject_id = slot
            AND school_year IN ('2026-2027', '2027-2028')
            AND is_deleted = FALSE), 2);
END;
$$;

-- ---------- existing CheckMate tables are untouched ----------
SELECT pg_temp.check_eq('classes.subject_id still references subjects',
    (SELECT COUNT(*) FROM information_schema.table_constraints tc
       JOIN information_schema.constraint_column_usage ccu ON ccu.constraint_name = tc.constraint_name
      WHERE tc.table_name = 'classes' AND tc.constraint_type = 'FOREIGN KEY' AND ccu.table_name = 'subjects'), 1);

ROLLBACK;
\echo 'All Academic Management integrity checks passed (nothing was saved).'
