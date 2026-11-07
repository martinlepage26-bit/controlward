import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { load } from './helpers';

const SCHEMA = join(__dirname, '..', '..', 'schema');
const files = () => readdirSync(SCHEMA).filter((f) => /^\d{4}_.+\.sql$/.test(f)).sort();
const strip = (sql: string) => sql.replace(/--.*$/gm, '');

describe('migrations are additive only (criterion 5)', () => {
  it('there are exactly the three slice-1 migrations, in order', () => {
    expect(files()).toEqual(['0001_contact.sql', '0002_approval.sql', '0003_audit.sql']);
  });

  it('scan: 0 DROP, 0 RENAME, 0 ALTER TABLE, 0 DELETE/UPDATE statements', () => {
    expect(files()).toHaveLength(3);
    const hits: string[] = [];
    for (const f of files()) {
      const sql = strip(readFileSync(join(SCHEMA, f), 'utf8'));
      // trigger bodies may contain SELECT RAISE; they may not contain data-changing statements
      for (const re of [/\bDROP\b/i, /\bRENAME\b/i, /\bALTER\s+TABLE\b/i, /^\s*(DELETE|UPDATE)\b/im, /\bREPLACE\s+INTO\b/i]) {
        if (re.test(sql)) hits.push(`${f}: ${re}`);
      }
    }
    expect(hits).toEqual([]);
  });

  it('every CREATE uses IF NOT EXISTS and every table is pc_-prefixed', () => {
    expect(files()).toHaveLength(3);
    for (const f of files()) {
      const sql = strip(readFileSync(join(SCHEMA, f), 'utf8'));
      const creates = sql.match(/CREATE\s+(TABLE|TRIGGER|INDEX|UNIQUE\s+INDEX)\s+[^(]*/gi) ?? [];
      expect(creates.length).toBeGreaterThan(0);
      for (const c of creates) {
        expect(c, `${f}: ${c}`).toMatch(/IF NOT EXISTS\s+pc_/i);
      }
    }
  });

  it('applying all migrations twice is idempotent and yields only pc_ objects', async () => {
    const { openDb, migrate } = await load.db();
    const db = openDb(':memory:');
    migrate(db);
    const names = (db.prepare(`SELECT name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY name`).all() as any[]).map((r) => r.name);
    expect(names.every((n: string) => n.startsWith('pc_'))).toBe(true);
    expect(names).toEqual(expect.arrayContaining(['pc_contact', 'pc_approval', 'pc_audit', 'pc_audit_no_update', 'pc_audit_no_delete']));
    const before = (db.prepare('SELECT COUNT(*) AS n FROM sqlite_master').get() as any).n;
    migrate(db);
    expect((db.prepare('SELECT COUNT(*) AS n FROM sqlite_master').get() as any).n).toBe(before);
  });
});
