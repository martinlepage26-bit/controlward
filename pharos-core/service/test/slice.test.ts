import { describe, expect, it } from 'vitest';
import { AGENT, MARTIN, auditRows, core } from './helpers';

const DECISIONS = `SELECT * FROM pc_audit WHERE action IN ('approval.approve','approval.refuse') ORDER BY seq`;

describe('happy path: one contact, one approval, exactly one decision audit entry (criterion 3)', () => {
  it('Martin approves: state approved, exactly one approval.approve row, then one consume', async () => {
    const { db, gate, contact, payload } = await core();
    const req = gate.requestApproval(AGENT, 'contact.outreach', contact.id, payload);
    expect(auditRows(db, 'approval.request')).toHaveLength(1);
    const r = gate.approve(req.id, { actor: MARTIN, payload_hash: req.payload_hash, presence_token: 'presence-ok' });
    expect(r).toEqual({ ok: true });
    expect(gate.get(req.id)).toMatchObject({ state: 'approved', decided_by: MARTIN });
    const decisions = db.prepare(DECISIONS).all() as any[];
    expect(decisions).toHaveLength(1);
    expect(decisions[0]).toMatchObject({ actor: MARTIN, action: 'approval.approve', subject: req.id, payload_hash: req.payload_hash, result: 'ok' });
    expect(gate.consume(req.id, payload, AGENT)).toEqual({ ok: true });
    expect(gate.get(req.id)!.state).toBe('consumed');
    expect(auditRows(db, 'approval.consume')).toHaveLength(1);
    expect(auditRows(db, 'gate.refuse')).toHaveLength(0);
  });

  it('Martin refuses: state refused, exactly one approval.refuse row', async () => {
    const { db, gate, contact, payload } = await core();
    const req = gate.requestApproval(AGENT, 'contact.outreach', contact.id, payload);
    expect(gate.refuse(req.id, { actor: MARTIN, presence_token: 'presence-ok' })).toEqual({ ok: true });
    expect(gate.get(req.id)).toMatchObject({ state: 'refused', decided_by: MARTIN });
    const decisions = db.prepare(DECISIONS).all() as any[];
    expect(decisions).toHaveLength(1);
    expect(decisions[0]).toMatchObject({ action: 'approval.refuse', result: 'ok' });
  });

  it('the approval is bound to sha256 of the canonical payload (key order does not matter)', async () => {
    const { gate, contact, payload } = await core();
    const { canonicalJson, sha256Hex } = await import('../src/canonical');
    const req = gate.requestApproval(AGENT, 'contact.outreach', contact.id, payload);
    expect(req.payload_hash).toBe(sha256Hex(canonicalJson(payload)));
    expect(canonicalJson({ b: 1, a: { d: 2, c: 3 } })).toBe('{"a":{"c":3,"d":2},"b":1}');
  });

  it('a decision on an already-decided request is refused and the decision count stays at one', async () => {
    const { db, gate, contact, payload } = await core();
    const req = gate.requestApproval(AGENT, 'contact.outreach', contact.id, payload);
    gate.approve(req.id, { actor: MARTIN, payload_hash: req.payload_hash, presence_token: 'presence-ok' });
    expect(gate.refuse(req.id, { actor: MARTIN, presence_token: 'presence-ok' })).toEqual({ ok: false, code: 'refused:bad-transition' });
    expect((db.prepare(DECISIONS).all() as any[])).toHaveLength(1);
  });

  it('the loopback service runs the same path over HTTP and binds 127.0.0.1 only', async () => {
    const { db, gate, contact, payload } = await core();
    const { startServer } = await import('../src/server');
    const srv = await startServer(gate, { port: 0 });
    try {
      expect(srv.host).toBe('127.0.0.1');
      const base = `http://127.0.0.1:${srv.port}`;
      const post = (p: string, body: unknown, headers: Record<string, string> = {}) =>
        fetch(base + p, { method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body: JSON.stringify(body) }).then(async (r) => ({ status: r.status, json: await r.json() as any }));
      const created = await post('/approvals', { requested_by: AGENT, action: 'contact.outreach', contact_id: contact.id, payload });
      expect(created.status).toBe(201);
      expect(created.json.state).toBe('pending');
      const id = created.json.id;
      expect((await post(`/approvals/${id}/approve`, { actor: MARTIN, payload_hash: created.json.payload_hash })).status).toBe(403);
      const ok = await post(`/approvals/${id}/approve`, { actor: MARTIN, payload_hash: created.json.payload_hash }, { 'x-pharos-human-presence': 'presence-ok' });
      expect(ok.json).toEqual({ ok: true });
      expect((await post(`/approvals/${id}/consume`, { payload, executor: AGENT })).json).toEqual({ ok: true });
      expect((db.prepare(DECISIONS).all() as any[])).toHaveLength(1);
    } finally {
      await srv.close();
    }
  });
});
