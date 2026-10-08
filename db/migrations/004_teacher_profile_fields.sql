-- CheckMate
-- Teacher profile fields: structured name, Teacher ID No., department,
-- institutional email rules
-- Migration: 004_teacher_profile_fields.sql
--
-- Requires 002 and 003 to be applied already. Does not touch them.
--
-- Existing teachers are NOT given invented values: their new columns stay
-- NULL until an administrator completes their profile in the Teachers screen
-- (Edit). Their current email/username keep working until then.

BEGIN;

-- ============================================================
-- 1. NEW COLUMNS (users.name stays as the full display name)
-- ============================================================

ALTER TABLE users
    ADD COLUMN IF NOT EXISTS first_name    VARCHAR(100),
    ADD COLUMN IF NOT EXISTS middle_name   VARCHAR(100),
    ADD COLUMN IF NOT EXISTS last_name     VARCHAR(100),
    ADD COLUMN IF NOT EXISTS teacher_id_no VARCHAR(30),
    ADD COLUMN IF NOT EXISTS department    VARCHAR(100);


-- ============================================================
-- 2. UNIQUENESS (case-insensitive)
-- ============================================================

-- Refuse loudly instead of failing half-way if two accounts already differ
-- only by upper/lower case in their email.
DO $$
DECLARE
    dup TEXT;
BEGIN
    SELECT string_agg(e, ', ')
    INTO dup
    FROM (
        SELECT LOWER(email) AS e
        FROM users
        GROUP BY LOWER(email)
        HAVING COUNT(*) > 1
    ) d;

    IF dup IS NOT NULL THEN
        RAISE EXCEPTION
            'Accounts with the same email (ignoring upper/lower case) exist: %. Fix them, then run this migration again.',
            dup;
    END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_users_email_lower
    ON users (LOWER(email));

-- Admins and not-yet-completed legacy teachers have NULL and are ignored.
CREATE UNIQUE INDEX IF NOT EXISTS uq_users_teacher_id_no_lower
    ON users (LOWER(teacher_id_no))
    WHERE teacher_id_no IS NOT NULL;


-- ============================================================
-- 3. RULES THE DATABASE ENFORCES BY ITSELF
-- ============================================================

ALTER TABLE users
    DROP CONSTRAINT IF EXISTS chk_users_teacher_id_not_blank;

ALTER TABLE users
    ADD CONSTRAINT chk_users_teacher_id_not_blank
    CHECK (teacher_id_no IS NULL OR BTRIM(teacher_id_no) <> '');

-- Any account that has a Teacher ID must use the institutional domain.
ALTER TABLE users
    DROP CONSTRAINT IF EXISTS chk_users_teacher_email_domain;

ALTER TABLE users
    ADD CONSTRAINT chk_users_teacher_email_domain
    CHECK (
        teacher_id_no IS NULL
        OR LOWER(email) LIKE '%@sti.checkmate.com'
    );

COMMIT;