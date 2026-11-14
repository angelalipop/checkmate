
-- CheckMate
-- Migration: 011_email_logs_last_attempt_at.sql
-- Track when each email sending attempt begins.

BEGIN;

ALTER TABLE email_logs
ADD COLUMN last_attempt_at TIMESTAMPTZ;

-- Initialize existing records using their creation timestamps.
UPDATE email_logs
SET last_attempt_at = created_at
WHERE last_attempt_at IS NULL;

CREATE INDEX idx_email_logs_stale_pending
ON email_logs(last_attempt_at)
WHERE status = 'pending';

COMMIT;
