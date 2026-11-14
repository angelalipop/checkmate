-- CheckMate
-- Migration: 010_email_logs_needs_review.sql
-- Add a status for uncertain email deliveries.

BEGIN;

ALTER TABLE email_logs
DROP CONSTRAINT IF EXISTS email_logs_status_check;

ALTER TABLE email_logs
ADD CONSTRAINT email_logs_status_check
CHECK (
    status IN ('pending', 'sent', 'failed', 'needs_review')
);

COMMIT;