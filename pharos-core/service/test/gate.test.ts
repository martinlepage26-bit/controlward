import { describe, expect, it } from 'vitest';
import { AGENT, MARTIN, auditRows, core } from './helpers';

const H = 24 * 3600 * 1000;

describe('gate refuses without Martin\'s OK, and every refusal is audited (criterion 1)', () => {
  it('consume on a pending request is refused:not-approved and audited', async () => {
    const { db, gate, contact, payload } = await core();
    const req = gate.requestApproval(AGENT, 'contact.outreach', contact.id, payload);
    expect(req.state).toBe('pending');
    expect(gate.consume(req.id, payload, AGENT)).toEqual({ ok: false, code: 'refused:not-approved' });
    const refusals = auditRows(db, 'gate.refuse');
    expect(refusals).toHaveLength(1);
    expect(refusals[0].result).toBe('refused:not-approved');
  });

  it('approve by an agent id is refused:not-human and audited', async () => {
    const { db, gate, contact, payload } = await core();
    const req = gate.requestApproval(AGENT, 'contact.outreach', contact.id, payload);
    const r = gate.approve(req.id, { actor: AGENT, payload_hash: req.payload_hash, presence_token: 'presence-ok' });
    expect(r).toEqual({ ok: false, code: 'refused:not-human' });
    expect(gate.get(req.id)!.state).toBe('pending');
    expect(auditRows(db, 'gate.refuse').map((a) => a.result)).toEqual(['refused:not-human']);
  });

  it('approve as human:martin without a human-presence token is refused:not-human', async () => {
    const { db, gate, contact, payload } = await core();
    const req = gate.requestApproval(AGENT, 'contact.outreach', contact.id, payload);
    expect(gate.approve(req.id, { actor: MARTIN, payload_hash: req.payload_hash })).toEqual({ ok: false, code: 'refused:not-human' });
    expect(auditRows(db, 'gate.refuse')).toHaveLength(1);
  });

  it('agents can only create pending requests; the DB rejects a non-pending insert and a non-Martin decider', async () => {
    const { db, gate, contact, payload } = await core();
    const req = gate.requestApproval(AGENT, 'contact.outreach', contact.id, payload);
    expect(req.state).toBe('pending');
    expect(() => db.prepare(
      `INSERT INTO pc_approval (id, action, contact_id, payload_json, payload_hash, requested_by, state, expires_at, created_at)
       VALUES ('x', 'contact.outreach', ?, '{}', 'h', 'agent:fire', 'approved', '2099-01-01', '2026-01-01')`,
    ).run(contact.id)).toThrow();
    expect(() => db.prepare(`UPDATE pc_approval SET decided_by = 'agent:fire' WHERE id = ?`).run(req.id)).toThrow();
  });

  it('consume with an edited payload is refused:hash-mismatch and audited', async () => {
    const { db, gate, contact, payload } = await core();
    const req = gate.requestApproval(AGENT, 'contact.outreach', contact.id, payload);
    expect(gate.approve(req.id, { actor: MARTIN, payload_hash: req.payload_hash, presence_token: 'presence-ok' }).ok).toBe(true);
    const r = gate.consume(req.id, { ...payload, body: 'Edited after approval.' }, AGENT);
    expect(r).toEqual({ ok: false, code: 'refused:hash-mismatch' });
    expect(auditRows(db, 'gate.refuse').map((a) => a.result)).toEqual(['refused:hash-mismatch']);
  });

  it('approve with a hash that does not match the stored payload is refused:hash-mismatch', async () => {
    const { db, gate, contact, payload } = await core();
    const req = gate.requestApproval(AGENT, 'contact.outreach', contact.id, payload);
    expect(gate.approve(req.id, { actor: MARTIN, payload_hash: '0'.repeat(64), presence_token: 'presence-ok' })).toEqual({ ok: false, code: 'refused:hash-mismatch' });
    expect(auditRows(db, 'gate.refuse')).toHaveLength(1);
  });

  it('consume after expiry is refused:expired and audited', async () => {
    const { db, gate, contact, payload, advance } = await core();
    const req = gate.requestApproval(AGENT, 'contact.outreach', contact.id, payload);
    gate.approve(req.id, { actor: MARTIN, payload_hash: req.payload_hash, presence_token: 'presence-ok' });
    advance(24 * H + 1);
    expect(gate.consume(req.id, payload, AGENT)).toEqual({ ok: false, code: 'refused:expired' });
    expect(gate.get(req.id)!.state).toBe('expired');
    expect(auditRows(db, 'gate.refuse').map((a) => a.result)).toEqual(['refused:expired']);
  });

  it('a second consume is refused:already-consumed (single use) and audited', async () => {
    const { db, gate, contact, payload } = await core();
    const req = gate.requestApproval(AGENT, 'contact.outreach', contact.id, payload);
    gate.approve(req.id, { actor: MARTIN, payload_hash: req.payload_hash, presence_token: 'presence-ok' });
    expect(gate.consume(req.id, payload, AGENT)).toEqual({ ok: true });
    expect(gate.consume(req.id, payload, AGENT)).toEqual({ ok: false, code: 'refused:already-consumed' });
    expect(auditRows(db, 'gate.refuse').map((a) => a.result)).toEqual(['refused:already-consumed']);
  });

  it('consume of a refused request is refused:not-approved', async () => {
    const { gate, contact, payload } = await core();
    const req = gate.requestApproval(AGENT, 'contact.outreach', contact.id, payload);
    gate.refuse(req.id, { actor: MARTIN, presence_token: 'presence-ok' });
    expect(gate.consume(req.id, payload, AGENT)).toEqual({ ok: false, code: 'refused:not-approved' });
  });

  it('contact consent evidence off the business domain is rejected', async () => {
    const { openDb } = await import('../src/db');
    const { createContact } = await import('../src/contact');
    const db = openDb(':memory:');
    expect(() => createContact(db, {
      kind: 'company', display_name: 'X', business_domain: 'example-plumbing.test',
      consent_basis: 'conspicuous_publication', consent_evidence_url: 'https://directory.test/listing', source: 'manual',
    })).toThrow(/off-domain/);
  });
});
