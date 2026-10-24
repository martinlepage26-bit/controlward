import { describe, expect, it } from 'vitest';
import { AGENT, MARTIN, core, load } from './helpers';

describe('audit trail is append-only at the DB level and hash-chained (criterion 2)', () => {
  it('raw UPDATE on pc_audit throws "pc_audit is append-only"', async () => {
    const { db, gate, contact, payload } = await core();
    gate.requestApproval(AGENT, 'contact.outreach', contact.id, payload);
    expect(() => db.prepare(`UPDATE pc_audit SET result = 'ok' WHERE seq = 1`).run()).toThrow(/pc_audit is append-only/);
  });

  it('raw DELETE on pc_audit throws "pc_audit is append-only"', async () => {
    const { db, gate, contact, payload } = await core();
    gate.requestApproval(AGENT, 'contact.outreach', contact.id, payload);
    expect(() => db.prepare('DELETE FROM pc_audit').run()).toThrow(/pc_audit is append-only/);
    expect((db.prepare('SELECT COUNT(*) AS n FROM pc_audit').get() as any).n).toBe(1);
  });

  it('chain verify passes on an untouched trail; first row links to 64 zeros', async () => {
    const { db, gate, contact, payload } = await core();
    const { verifyAudit } = await load.audit();
    const req = gate.requestApproval(AGENT, 'contact.outreach', contact.id, payload);
    gate.approve(req.id, { actor: MARTIN, payload_hash: req.payload_hash, presence_token: 'presence-ok' });
    gate.consume(req.id, payload, AGENT);
    const first = db.prepare('SELECT prev_hash FROM pc_audit WHERE seq = 1').get() as any;
    expect(first.prev_hash).toBe('0'.repeat(64));
    expect(verifyAudit(db)).toEqual({ ok: true, rows: 3 });
  });

  it('a tampered copy (triggers dropped in a scratch DB) fails verify at the tampered seq', async () => {
    const { db, gate, contact, payload } = await core();
    const { verifyAudit } = await load.audit();
    const req = gate.requestApproval(AGENT, 'contact.outreach', contact.id, payload);
    gate.approve(req.id, { actor: MARTIN, payload_hash: req.payload_hash, presence_token: 'presence-ok' });
    gate.consume(req.id, payload, AGENT);
    // scratch DB only: simulate an attacker who bypasses the triggers
    db.exec('DROP TRIGGER pc_audit_no_update');
    db.prepare(`UPDATE pc_audit SET result = 'refused:forged' WHERE seq = 2`).run();
    expect(verifyAudit(db)).toEqual({ ok: false, rows: 3, broken_at: 2 });
  });

  it('audit rows carry the payload hash only, never the payload body or contact PII', async () => {
    const { db, gate, contact, payload } = await core();
    gate.requestApproval(AGENT, 'contact.outreach', contact.id, payload);
    const dump = JSON.stringify(db.prepare('SELECT * FROM pc_audit').all());
    expect(dump).not.toContain(payload.body);
    expect(dump).not.toContain(contact.email!);
  });
});
