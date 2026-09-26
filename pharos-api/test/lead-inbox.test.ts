import { beforeEach, describe, expect, it } from "vitest";
import worker, { type Env } from "../src/index";
import { FakeD1 } from "./fake-d1";

const CONTEXTWARD_KEY = "cw-test-key-not-real";
const LEADGEN_KEY = "lg-test-key-not-real";
const BASE = "https://pharos-contextward-api.example.test";

let d1: FakeD1;
let env: Env;

beforeEach(() => {
  d1 = new FakeD1();
  env = { ENVIRONMENT: "test", PHAROS_API_KEY: CONTEXTWARD_KEY, LEADGEN_PUSH_KEY: LEADGEN_KEY, DB: d1 as unknown as D1Database };
});

function lead(sourceId: string, overrides: Record<string, unknown> = {}) {
  return {
    source_id: sourceId,
    event: {
      schema_version: "leadgen.event.v1",
      captured_at: "2026-09-25T12:00:00.000Z",
      raw_identity: { email: `${sourceId}@example.test`, first_name: "Test", last_name: "Lead", phone_raw: "+15145550100", company_name_raw: "Synthetic Co" },
      fit_score: 80,
      intent_score: 60,
      composite_score: 72,
      ...overrides,
    },
  };
}

async function call(method: string, path: string, key: string | null, body?: unknown) {
  const headers: Record<string, string> = {};
  if (key) headers.authorization = `Bearer ${key}`;
  if (body !== undefined) headers["content-type"] = "application/json";
  const response = await worker.fetch(new Request(`${BASE}${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) }), env);
  const text = await response.text();
  return { status: response.status, body: text ? JSON.parse(text) : null, headers: response.headers };
}

const push = (leads: unknown[], key: string | null = LEADGEN_KEY, retract?: string[]) =>
  call("POST", "/v1/leads/push", key, { schema_version: "leadgen.push.v1", leads, ...(retract ? { retract } : {}) });
const pull = (since = 0, key: string | null = CONTEXTWARD_KEY, limit?: number) =>
  call("GET", `/v1/leads?since=${since}${limit ? `&limit=${limit}` : ""}`, key);
const ack = (acks: unknown[], key: string | null = CONTEXTWARD_KEY) => call("POST", "/v1/leads/ack", key, { acks });

describe("authentication", () => {
  it("rejects push without a key or with a wrong key", async () => {
    expect((await push([lead("ld_1")], null)).status).toBe(401);
    expect((await push([lead("ld_1")], "wrong")).status).toBe(401);
  });

  it("the Contextward key cannot push", async () => {
    expect((await push([lead("ld_1")], CONTEXTWARD_KEY)).status).toBe(401);
    expect(d1.rows("SELECT * FROM lead_inbox")).toHaveLength(0);
  });

  it("the LeadGen key cannot read or ack", async () => {
    await push([lead("ld_1")]);
    const read = await pull(0, LEADGEN_KEY);
    expect(read.status).toBe(401);
    expect(JSON.stringify(read.body)).not.toContain("ld_1@example.test");
    expect((await ack([{ source_id: "ld_1", seq: 1 }], LEADGEN_KEY)).status).toBe(401);
  });

  it("the LeadGen key cannot use the Contextward key check or exchange push", async () => {
    expect((await call("GET", "/v1/auth/check", LEADGEN_KEY)).status).toBe(401);
    expect((await call("POST", "/v1/exchange/push", LEADGEN_KEY, { schemaVersion: "contextward.exchange.v1" })).status).toBe(401);
  });

  it("fails closed when the push key is not configured", async () => {
    env.LEADGEN_PUSH_KEY = undefined;
    expect((await push([lead("ld_1")], "")).status).toBe(401);
    expect((await push([lead("ld_1")], "Bearer ")).status).toBe(401);
  });
});

describe("push", () => {
  it("stores only the minimised fields", async () => {
    const extra = lead("ld_1", { notes: "should be dropped", ssn: "000-00-0000" });
    (extra.event.raw_identity as Record<string, unknown>).home_address = "1 Private Road";
    const response = await push([extra]);
    expect(response.status).toBe(200);
    expect(response.body).toMatchObject({ accepted: 1, created: 1, updated: 0, unchanged: 0 });
    const [row] = d1.rows<{ payload_json: string }>("SELECT payload_json FROM lead_inbox");
    expect(row.payload_json).not.toContain("should be dropped");
    expect(row.payload_json).not.toContain("000-00-0000");
    expect(row.payload_json).not.toContain("Private Road");
    expect(JSON.parse(row.payload_json).event_id).toBe("ld_1");
  });

  it("is idempotent per lead: same content is unchanged, new content is an update", async () => {
    expect((await push([lead("ld_1")])).body).toMatchObject({ created: 1 });
    expect((await push([lead("ld_1")])).body).toMatchObject({ created: 0, updated: 0, unchanged: 1 });
    expect(d1.rows("SELECT * FROM lead_inbox")).toHaveLength(1);
    const before = d1.rows<{ seq: number }>("SELECT seq FROM lead_inbox")[0].seq;
    expect((await push([lead("ld_1", { fit_score: 95 })])).body).toMatchObject({ updated: 1 });
    const after = d1.rows<{ seq: number }>("SELECT seq FROM lead_inbox")[0].seq;
    expect(after).toBeGreaterThan(before);
    expect(d1.rows("SELECT * FROM lead_inbox")).toHaveLength(1);
  });

  it("rejects invalid bodies and oversized batches", async () => {
    expect((await call("POST", "/v1/leads/push", LEADGEN_KEY, { schema_version: "other", leads: [] })).status).toBe(422);
    expect((await push([{ source_id: "bad id with spaces", event: lead("x").event }])).status).toBe(422);
    expect((await push([{ source_id: "ld_empty", event: { schema_version: "leadgen.event.v1", raw_identity: {} } }])).status).toBe(422);
    expect((await push(Array.from({ length: 101 }, (_, i) => lead(`ld_${i}`)))).status).toBe(413);
    expect(d1.rows("SELECT * FROM lead_inbox")).toHaveLength(0);
  });

  it("accepts an empty batch as a key check", async () => {
    expect((await push([])).body).toMatchObject({ accepted: 0 });
  });
});

describe("cursor", () => {
  it("returns leads after the cursor in order and pages with has_more", async () => {
    await push([lead("ld_1"), lead("ld_2"), lead("ld_3")]);
    const first = await pull(0, CONTEXTWARD_KEY, 2);
    expect(first.status).toBe(200);
    expect(first.headers.get("cache-control")).toBe("no-store");
    expect(first.body.leads.map((l: { source_id: string }) => l.source_id)).toEqual(["ld_1", "ld_2"]);
    expect(first.body.has_more).toBe(true);
    const second = await pull(first.body.cursor, CONTEXTWARD_KEY, 2);
    expect(second.body.leads.map((l: { source_id: string }) => l.source_id)).toEqual(["ld_3"]);
    expect(second.body.has_more).toBe(false);
    const empty = await pull(second.body.cursor);
    expect(empty.body.leads).toEqual([]);
    expect(empty.body.cursor).toBe(second.body.cursor);
  });

  it("an updated lead reappears after the cursor", async () => {
    await push([lead("ld_1")]);
    const { body } = await pull(0);
    await push([lead("ld_1", { intent_score: 99 })]);
    const again = await pull(body.cursor);
    expect(again.body.leads).toHaveLength(1);
    expect(again.body.leads[0].event.intent_score).toBe(99);
  });

  it("returns the leadgen.event.v1 shape Contextward decodes", async () => {
    await push([lead("ld_1")]);
    const [item] = (await pull(0)).body.leads;
    expect(item).toMatchObject({ source_id: "ld_1", seq: expect.any(Number), content_hash: expect.any(String) });
    expect(item.event).toMatchObject({ schema_version: "leadgen.event.v1", event_id: "ld_1", raw_identity: { email: "ld_1@example.test", first_name: "Test" }, fit_score: 80 });
  });

  it("rejects a malformed cursor", async () => {
    expect((await call("GET", "/v1/leads?since=abc", CONTEXTWARD_KEY)).status).toBe(400);
    expect((await call("GET", "/v1/leads?since=-1", CONTEXTWARD_KEY)).status).toBe(400);
  });
});

describe("ack", () => {
  it("marks leads received, redacts the payload, and hides them from later pulls", async () => {
    await push([lead("ld_1"), lead("ld_2")]);
    const { body } = await pull(0);
    const response = await ack(body.leads.map((l: { source_id: string; seq: number }) => ({ source_id: l.source_id, seq: l.seq })));
    expect(response.body).toMatchObject({ acked: 2, stale: 0 });
    expect((await pull(0)).body.leads).toEqual([]);
    const rows = d1.rows<{ payload_json: string | null; acked_at: string | null }>("SELECT payload_json, acked_at FROM lead_inbox");
    expect(rows.every((row) => row.payload_json === null && row.acked_at !== null)).toBe(true);
  });

  it("is idempotent and does not ack a newer version of the lead", async () => {
    await push([lead("ld_1")]);
    const { body } = await pull(0);
    const stale = { source_id: "ld_1", seq: body.leads[0].seq };
    await push([lead("ld_1", { fit_score: 10 })]);
    expect((await ack([stale])).body).toMatchObject({ acked: 0, stale: 1 });
    expect((await pull(0)).body.leads).toHaveLength(1);
    const fresh = (await pull(0)).body.leads[0];
    expect((await ack([{ source_id: "ld_1", seq: fresh.seq }])).body).toMatchObject({ acked: 1 });
    expect((await ack([{ source_id: "ld_1", seq: fresh.seq }])).body).toMatchObject({ acked: 1, stale: 0 });
  });

  it("an acked lead pushed again unchanged stays acked", async () => {
    await push([lead("ld_1")]);
    const [item] = (await pull(0)).body.leads;
    await ack([{ source_id: item.source_id, seq: item.seq }]);
    expect((await push([lead("ld_1")])).body).toMatchObject({ unchanged: 1 });
    expect((await pull(0)).body.leads).toEqual([]);
  });
});

describe("retraction", () => {
  it("a retracted lead reaches the next pull as a tombstone with no PII, then acks like any lead", async () => {
    await push([lead("ld_1"), lead("ld_2")]);
    const first = await pull(0);
    await ack(first.body.leads.map((l: { source_id: string; seq: number }) => ({ source_id: l.source_id, seq: l.seq })));
    const response = await push([], LEADGEN_KEY, ["ld_1"]);
    expect(response.body).toMatchObject({ retracted: 1 });
    const next = await pull(first.body.cursor);
    expect(next.body.leads).toEqual([{ source_id: "ld_1", seq: expect.any(Number), retracted: true }]);
    await ack([{ source_id: "ld_1", seq: next.body.leads[0].seq }]);
    expect((await pull(0)).body.leads).toEqual([]);
  });

  it("retracting an unknown or already-purged id still leaves a tombstone; retracting twice is a no-op", async () => {
    expect((await push([], LEADGEN_KEY, ["ld_gone"])).body).toMatchObject({ retracted: 1 });
    expect((await push([], LEADGEN_KEY, ["ld_gone"])).body).toMatchObject({ retracted: 0 });
    expect((await pull(0)).body.leads).toEqual([{ source_id: "ld_gone", seq: expect.any(Number), retracted: true }]);
  });

  it("a retracted lead that qualifies again comes back as a normal lead", async () => {
    await push([lead("ld_1")]);
    await push([], LEADGEN_KEY, ["ld_1"]);
    await push([lead("ld_1")]);
    const [item] = (await pull(0)).body.leads;
    expect(item.retracted).toBeUndefined();
    expect(item.event.event_id).toBe("ld_1");
  });

  it("the Contextward key cannot retract", async () => {
    await push([lead("ld_1")]);
    expect((await push([], CONTEXTWARD_KEY, ["ld_1"])).status).toBe(401);
  });

  it("rejects too many or malformed retractions", async () => {
    expect((await push([], LEADGEN_KEY, Array.from({ length: 101 }, (_, i) => `ld_${i}`))).status).toBe(413);
    expect((await push([], LEADGEN_KEY, ["bad id"])).status).toBe(422);
  });
});

describe("inbox epoch", () => {
  it("every pull reports a stable epoch so a client can detect a reset inbox", async () => {
    const a = await pull(0);
    const b = await pull(0);
    expect(typeof a.body.epoch).toBe("string");
    expect(a.body.epoch.length).toBeGreaterThan(8);
    expect(b.body.epoch).toBe(a.body.epoch);
  });
});

describe("retention", () => {
  it("deletes leads and tombstones acked more than 30 days ago, keeps unacked leads until pulled", async () => {
    await push([lead("ld_old_ack"), lead("ld_recent_ack"), lead("ld_unpulled"), lead("ld_fresh")]);
    d1.exec("UPDATE lead_inbox SET acked_at = datetime('now','-31 days'), payload_json = NULL WHERE source_id = 'ld_old_ack'");
    d1.exec("UPDATE lead_inbox SET acked_at = datetime('now','-5 days'), payload_json = NULL WHERE source_id = 'ld_recent_ack'");
    d1.exec("UPDATE lead_inbox SET updated_at = datetime('now','-200 days') WHERE source_id = 'ld_unpulled'");
    await worker.scheduled!({} as ScheduledController, env, {} as ExecutionContext);
    const left = d1.rows<{ source_id: string }>("SELECT source_id FROM lead_inbox ORDER BY source_id").map((row) => row.source_id);
    expect(left).toEqual(["ld_fresh", "ld_recent_ack", "ld_unpulled"]);
  });

  it("deletes exchange snapshots older than 30 days", async () => {
    d1.exec("INSERT INTO exchange_receipts (idempotency_key, receipt, payload_json, created_at) VALUES ('old', 'r1', '{}', datetime('now','-31 days')), ('new', 'r2', '{}', datetime('now'))");
    await worker.scheduled!({} as ScheduledController, env, {} as ExecutionContext);
    expect(d1.rows<{ idempotency_key: string }>("SELECT idempotency_key FROM exchange_receipts").map((r) => r.idempotency_key)).toEqual(["new"]);
  });
});
