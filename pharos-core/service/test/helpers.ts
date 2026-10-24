// Modules are loaded lazily inside each test so that, before the implementation
// exists, every named test fails on its own line instead of the whole file erroring.
export const load = {
  db: () => import('../src/db'),
  gate: () => import('../src/gate'),
  audit: () => import('../src/audit'),
  contact: () => import('../src/contact'),
  canonical: () => import('../src/canonical'),
  adapter: () => import('../src/adapter'),
  server: () => import('../src/server'),
};

export const MARTIN = 'human:martin';
export const AGENT = 'agent:fire';
export const T0 = Date.parse('2026-10-24T20:00:00.000Z');

/** Builds a fresh in-memory core with a controllable clock and a stub human-presence check. */
export async function core(opts: { now?: () => number } = {}) {
  const { openDb } = await load.db();
  const { Gate } = await load.gate();
  const { createContact } = await load.contact();
  const db = openDb(':memory:');
  let now = T0;
  const clock = opts.now ?? (() => now);
  const presence = { verify: (token: string | undefined) => token === 'presence-ok' };
  const gate = new Gate(db, { now: clock, presence });
  const contact = createContact(db, {
    kind: 'company',
    display_name: 'Example Plumbing Inc.',
    email: 'info@example-plumbing.test',
    business_domain: 'example-plumbing.test',
    consent_basis: 'conspicuous_publication',
    consent_evidence_url: 'https://example-plumbing.test/contact',
    source: 'manual',
  }, clock);
  const payload = { channel: 'email', to: contact.email, subject: 'Hello', body: 'First contact.' };
  return { db, gate, contact, payload, advance: (ms: number) => { now += ms; } };
}

export function auditRows(db: any, action?: string) {
  const sql = action ? 'SELECT * FROM pc_audit WHERE action = ? ORDER BY seq' : 'SELECT * FROM pc_audit ORDER BY seq';
  return (action ? db.prepare(sql).all(action) : db.prepare(sql).all()) as any[];
}
