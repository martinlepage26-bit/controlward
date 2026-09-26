-- Retractions: LeadGen OS withdraws a lead (deletion request, consent withdrawn,
-- no longer qualified). The row becomes a PII-free tombstone that Contextward pulls
-- and acks like any lead, then removes the lead locally.
ALTER TABLE lead_inbox ADD COLUMN retracted INTEGER NOT NULL DEFAULT 0;

-- Inbox epoch: changes only if the inbox is recreated, so a client holding a cursor
-- from an older inbox resets it instead of skipping every new lead.
ALTER TABLE lead_inbox_counter ADD COLUMN epoch TEXT;
UPDATE lead_inbox_counter SET epoch = lower(hex(randomblob(12))) WHERE epoch IS NULL;
