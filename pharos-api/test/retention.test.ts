import { beforeEach, describe, expect, it } from "vitest";
import worker, { purgeLeadInbox, type Env } from "../src/index";
import { purgeIntake } from "../src/intake";
import { FakeD1 } from "./fake-d1";

/**
 * Retention runs from the daily cron, so nothing else exercises it. These tests
 * drive the real DELETE statements against the real migrations and a controlled
 * clock (rows are written with explicit created_at/acked_at values).
 */
let d1: FakeD1;
let env: Env;

beforeEach(() => {
  d1 = new FakeD1();
  env = { ENVIRONMENT: "test", DB: d1 as unknown as D1Database };
});

function intakeRow(id: string, ageDays: number, test: boolean) {
  d1.exec(
    `INSERT INTO intake_leads (id, created_at, source, route, project_id, name, email, test)
     VALUES ('${id}', datetime('now', '-${ageDays} days'), 'web', 'contextward', 'kpji3kub', 'Lead ${id}', '${id}@example.ca', ${test ? 1 : 0})`
  );
}

function inboxRow(sourceId: string, seq: number, ageDays: number, acked: boolean) {
  d1.exec(
    `INSERT INTO lead_inbox (source_id, content_hash, seq, payload_json, updated_at, acked_at)
     VALUES ('${sourceId}', 'hash-${sourceId}', ${seq}, '{"event_id":"${sourceId}"}', datetime('now', '-${ageDays} days'),
             ${acked ? `datetime('now', '-${ageDays} days')` : "NULL"})`
  );
}

function receiptRow(key: string, ageDays: number) {
  d1.exec(
    `INSERT INTO exchange_receipts (idempotency_key, receipt, payload_json, created_at)
     VALUES ('${key}', 'receipt-${key}', '{}', datetime('now', '-${ageDays} days'))`
  );
}

const intakeIds = () => d1.rows<{ id: string }>("SELECT id FROM intake_leads ORDER BY id").map((row) => row.id);
const inboxIds = () => d1.rows<{ source_id: string }>("SELECT source_id FROM lead_inbox ORDER BY seq").map((row) => row.source_id);

describe("purgeIntake", () => {
  it("drops test leads after 7 days and keeps younger ones", async () => {
    intakeRow("in_stale_test", 8, true);
    intakeRow("in_fresh_test", 6, true);
    await purgeIntake(env);
    expect(intakeIds()).toEqual(["in_fresh_test"]);
  });

  it("drops real leads after 400 days and keeps younger ones", async () => {
    intakeRow("in_stale_real", 401, false);
    intakeRow("in_fresh_real", 399, false);
    await purgeIntake(env);
    expect(intakeIds()).toEqual(["in_fresh_real"]);
  });

  it("does not apply the 7-day rule to real leads", async () => {
    intakeRow("in_real_10d", 10, false);
    await purgeIntake(env);
    expect(intakeIds()).toEqual(["in_real_10d"]);
  });

  it("is a no-op without storage", async () => {
    await expect(purgeIntake({ ...env, DB: undefined })).resolves.toBeUndefined();
  });
});

describe("purgeLeadInbox", () => {
  it("drops acked rows after 30 days and keeps younger ones", async () => {
    inboxRow("ld_old", 1, 31, true);
    inboxRow("ld_recent", 2, 29, true);
    await purgeLeadInbox(env);
    expect(inboxIds()).toEqual(["ld_recent"]);
  });

  it("never ages out unacked rows, however old", async () => {
    inboxRow("ld_unacked", 1, 400, false);
    await purgeLeadInbox(env);
    expect(inboxIds()).toEqual(["ld_unacked"]);
  });

  it("drops exchange receipts after 30 days", async () => {
    receiptRow("old", 31);
    receiptRow("recent", 29);
    await purgeLeadInbox(env);
    expect(d1.rows<{ idempotency_key: string }>("SELECT idempotency_key FROM exchange_receipts").map((row) => row.idempotency_key)).toEqual(["recent"]);
  });
});

describe("scheduled", () => {
  it("runs both retention sweeps", async () => {
    intakeRow("in_stale_test", 8, true);
    inboxRow("ld_old", 1, 31, true);
    await worker.scheduled!({} as ScheduledController, env, {} as ExecutionContext);
    expect(intakeIds()).toEqual([]);
    expect(inboxIds()).toEqual([]);
  });
});
