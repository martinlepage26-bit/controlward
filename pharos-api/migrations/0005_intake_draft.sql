-- DRAFT follow-up for a KAIROS trial signup. Never a sent message.
-- Nullable so every other intake row is unchanged. A missing draft is not a lost lead.
ALTER TABLE intake_leads ADD COLUMN draft_subject TEXT;
ALTER TABLE intake_leads ADD COLUMN draft_body TEXT;
ALTER TABLE intake_leads ADD COLUMN draft_html TEXT;
ALTER TABLE intake_leads ADD COLUMN draft_status TEXT;
