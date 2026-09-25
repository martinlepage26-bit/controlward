import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";

/**
 * Minimal D1 stand-in backed by node:sqlite, so the Worker runs its real SQL
 * against the real migrations. Covers prepare/bind/run/first/all and batch.
 */
type Value = string | number | null;

class FakeStatement {
  constructor(readonly db: DatabaseSync, readonly sql: string, readonly params: Value[] = []) {}
  bind(...params: Value[]) { return new FakeStatement(this.db, this.sql, params); }
  async run() {
    const result = this.db.prepare(this.sql).run(...this.params);
    return { success: true, meta: { changes: Number(result.changes) } };
  }
  async first<T>() { return (this.db.prepare(this.sql).get(...this.params) as T | undefined) ?? null; }
  async all<T>() { return { success: true, results: this.db.prepare(this.sql).all(...this.params) as T[] }; }
}

export class FakeD1 {
  readonly db = new DatabaseSync(":memory:");

  constructor(migrationsDir = join(__dirname, "..", "migrations")) {
    for (const file of readdirSync(migrationsDir).filter((name) => name.endsWith(".sql")).sort()) {
      this.db.exec(readFileSync(join(migrationsDir, file), "utf8"));
    }
  }

  prepare(sql: string) { return new FakeStatement(this.db, sql); }

  /** D1 runs a batch as one transaction. */
  async batch(statements: FakeStatement[]) {
    this.db.exec("BEGIN");
    try {
      const results = [];
      for (const statement of statements) results.push(await statement.run());
      this.db.exec("COMMIT");
      return results;
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
  }

  rows<T>(sql: string, ...params: Value[]) { return this.db.prepare(sql).all(...params) as T[]; }
  exec(sql: string) { this.db.exec(sql); }
}
