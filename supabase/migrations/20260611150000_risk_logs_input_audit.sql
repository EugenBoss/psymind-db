-- PM-RISK-INPUT-AUDIT 2026-06-11
-- Store a minimal redacted excerpt for admin crisis-review traceability.
-- This does not change risk routing. Full raw input is not stored here.

alter table public.risk_logs
  add column if not exists input_excerpt text,
  add column if not exists input_char_count integer,
  add column if not exists input_hash text,
  add column if not exists input_redactions jsonb not null default '{}'::jsonb,
  add column if not exists input_audit_version text,
  add column if not exists admin_review_verdict text,
  add column if not exists admin_review_reason text,
  add column if not exists admin_review_notes text,
  add column if not exists admin_reviewed_at timestamptz,
  add column if not exists admin_reviewed_by_user_id uuid,
  add column if not exists admin_reviewed_by_email text,
  add column if not exists admin_review_version text,
  add column if not exists learning_signal jsonb not null default '{}'::jsonb;

comment on column public.risk_logs.input_excerpt is
  'Short server-redacted excerpt of the text that triggered risk routing. Admin-only traceability; not full raw input.';

comment on column public.risk_logs.input_char_count is
  'Original normalized input character count used for risk routing.';

comment on column public.risk_logs.input_hash is
  'SHA-256 hash of normalized raw risk input for correlation without storing full raw text.';

comment on column public.risk_logs.input_redactions is
  'PII redaction counts applied before storing input_excerpt.';

comment on column public.risk_logs.input_audit_version is
  'Risk input audit format version.';

comment on column public.risk_logs.admin_review_verdict is
  'Admin label for whether the risk trigger was correct: correct, incorrect, or uncertain. Feedback only; does not auto-change routing.';

comment on column public.risk_logs.admin_review_reason is
  'Short admin reason for the crisis/high-risk trigger review label.';

comment on column public.risk_logs.admin_review_notes is
  'Optional admin notes for future safety calibration review.';

comment on column public.risk_logs.admin_reviewed_at is
  'Timestamp when an admin reviewed the risk trigger.';

comment on column public.risk_logs.admin_reviewed_by_user_id is
  'Admin user id that reviewed the risk trigger.';

comment on column public.risk_logs.admin_reviewed_by_email is
  'Admin email snapshot that reviewed the risk trigger.';

comment on column public.risk_logs.admin_review_version is
  'Risk trigger review feedback format version.';

comment on column public.risk_logs.learning_signal is
  'Structured feedback signal for future offline calibration. It has no automatic live routing effect.';

create index if not exists risk_logs_admin_review_idx
  on public.risk_logs (admin_review_verdict, created_at desc);
