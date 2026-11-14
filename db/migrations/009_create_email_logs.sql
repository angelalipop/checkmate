CREATE TABLE email_logs (
    id BIGSERIAL PRIMARY KEY,

    student_id BIGINT NOT NULL
        REFERENCES students(id) ON DELETE CASCADE,

    exam_id BIGINT NOT NULL
        REFERENCES exams(id) ON DELETE CASCADE,

    recipient_email VARCHAR(255) NOT NULL,

    status VARCHAR(20) NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'sent', 'failed')),

    sent_at TIMESTAMP WITH TIME ZONE,

    error_message TEXT,

    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_email_logs_student_id
    ON email_logs(student_id);

CREATE INDEX idx_email_logs_exam_id
    ON email_logs(exam_id);

CREATE INDEX idx_email_logs_status
    ON email_logs(status);
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'email_logs'
ORDER BY ordinal_position;
ALTER TABLE email_logs
ADD CONSTRAINT email_logs_student_exam_unique
UNIQUE (student_id, exam_id);