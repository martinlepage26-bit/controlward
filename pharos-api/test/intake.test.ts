import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker, { type Env } from "../src/index";
import { maskEmail, isTestLead } from "../src/intake";
import { FakeD1 } from "./fake-d1";

const CONTEXTWARD_KEY = "cw-test-key-not-real";
const INTAKE_KEY = "intake-test-key-not-real";
const BASE = "https://pharos-contextward-api.example.test";

let d1: FakeD1;
let env: Env;
let pcCalls: { url: string; body: Record<string, unknown> }[];

beforeEach(() => {
  d1 = new FakeD1();
  env = { ENVIRONMENT: "test", PHAROS_API_KEY: CONTEXTWARD_KEY, LEADGEN_PUSH_KEY: "lg", INTAKE_KEY, PC_FEED_TOKEN: "pc-feed-not-real", DB: d1 as unknown as D1Database };
  pcCalls = [];
  vi.stubGlobal("fetch", async (url: string, init: RequestInit) => {
    pcCalls.push({ url, body: JSON.parse(String(init.body)) });
    return new Response(JSON.stringify({ id: "pcitem1" }), { status: 201 });
  });
});
afterEach(() => vi.unstubAllGlobals());

async function post(body: unknown, headers: Record<string, string> = {}) {
  const response = await worker.fetch(new Request(`${BASE}/v1/intake`, {
    method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body),
  }), env);
  return { status: response.status, body: await response.json().catch(() => null), headers: response.headers };
}

const lead = { name: "TEST Pipeline", email: "test.pipeline@example.test", interest: "quickscan", source: "kairos" };

describe("intake", () => {
  it("refuses browser posts from unknown origins", async () => {
    expect((await post(lead, { origin: "https://evil.example" })).status).toBe(403);
    expect((await post(lead)).status).toBe(403);
  });

  it("accepts a server post, routes it, fills the inbox and files a Project Control item", async () => {
    const r = await post(lead, { authorization: `Bearer ${INTAKE_KEY}` });
    expect(r.status).toBe(201);
    expect(r.body.route).toBe("quickscan");
    expect(r.body.project_id).toBe("kpji3kub");
    expect(r.body.test).toBe(true);
    expect(r.body.project_control).toEqual({ filed: true, item_id: "pcitem1", status: 201 });
    expect(pcCalls).toHaveLength(1);
    expect(String(pcCalls[0].body.summary)).toContain("[TEST]");
    expect(String(pcCalls[0].body.summary)).not.toContain("test.pipeline@");
    const pulled = await worker.fetch(new Request(`${BASE}/v1/leads?since=0`, { headers: { authorization: `Bearer ${CONTEXTWARD_KEY}` } }), env);
    const inbox = await pulled.json() as { leads: { source_id: string; event: { raw_identity: { email: string } } }[] };
    expect(inbox.leads[0].source_id).toBe(`intake:${r.body.id}`);
    expect(inbox.leads[0].event.raw_identity.email).toBe("test.pipeline@example.test");
  });

  it("accepts an allowed-origin browser post, hides routing detail and sets CORS", async () => {
    const r = await post({ ...lead, interest: "fba" }, { origin: "https://kairos-dashboard-dy4.pages.dev" });
    expect(r.status).toBe(201);
    expect(Object.keys(r.body).sort()).toEqual(["accepted", "id"]);
    expect(r.headers.get("access-control-allow-origin")).toBe("https://kairos-dashboard-dy4.pages.dev");
  });

  it("falls back to the ContextWard route for unknown interests", async () => {
    const r = await post({ ...lead, interest: "nope" }, { authorization: `Bearer ${INTAKE_KEY}` });
    expect(r.body.route).toBe("contextward");
  });

  it("validates name and email", async () => {
    expect((await post({ name: "", email: "x@y.ca" }, { authorization: `Bearer ${INTAKE_KEY}` })).status).toBe(422);
    expect((await post({ name: "A", email: "bad" }, { authorization: `Bearer ${INTAKE_KEY}` })).status).toBe(422);
  });

  it("drops honeypot submissions without storing", async () => {
    const r = await post({ ...lead, website: "http://spam" }, { origin: "https://pharos-ai.ca" });
    expect(r.status).toBe(202);
    expect(pcCalls).toHaveLength(0);
  });

  it("rate limits browser posts per IP", async () => {
    for (let i = 0; i < 5; i += 1) expect((await post(lead, { origin: "https://pharos-ai.ca", "cf-connecting-ip": "1.2.3.4" })).status).toBe(201);
    expect((await post(lead, { origin: "https://pharos-ai.ca", "cf-connecting-ip": "1.2.3.4" })).status).toBe(429);
  });

  it("lists intake only with the Contextward key", async () => {
    await post(lead, { authorization: `Bearer ${INTAKE_KEY}` });
    const denied = await worker.fetch(new Request(`${BASE}/v1/intake`), env);
    expect(denied.status).toBe(401);
    const ok = await worker.fetch(new Request(`${BASE}/v1/intake`, { headers: { authorization: `Bearer ${CONTEXTWARD_KEY}` } }), env);
    expect(((await ok.json()) as { leads: unknown[] }).leads).toHaveLength(1);
  });

  it("still stores the lead when Project Control is unreachable", async () => {
    vi.stubGlobal("fetch", async () => { throw new Error("down"); });
    const r = await post(lead, { authorization: `Bearer ${INTAKE_KEY}` });
    expect(r.status).toBe(201);
    expect(r.body.project_control.filed).toBe(false);
  });

  it("helpers", () => {
    expect(maskEmail("martin@example.ca")).toBe("m***@example.ca");
    expect(isTestLead("TEST Pipeline", "a@b.ca", undefined)).toBe(true);
    expect(isTestLead("Jane", "jane@b.ca", undefined)).toBe(false);
  });
});
