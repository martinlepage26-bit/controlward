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

  it("uses the Project Control service binding when present", async () => {
    const bound: string[] = [];
    env.PROJECT_CONTROL = { fetch: async (url: string) => { bound.push(String(url)); return new Response(JSON.stringify({ id: "viaBinding" }), { status: 201 }); } } as unknown as Fetcher;
    const r = await post(lead, { authorization: `Bearer ${INTAKE_KEY}` });
    expect(r.body.project_control.item_id).toBe("viaBinding");
    expect(bound[0]).toContain("/api/items");
    expect(pcCalls).toHaveLength(0);
  });

  it("files the item against the published Project Control request contract", async () => {
    const calls: { url: string; init: RequestInit }[] = [];
    vi.stubGlobal("fetch", async (url: string, init: RequestInit) => {
      calls.push({ url: String(url), init });
      return new Response(JSON.stringify({ id: "pc_contract" }), { status: 201, headers: { "content-type": "application/json" } });
    });
    const r = await post(lead, { authorization: `Bearer ${INTAKE_KEY}` });

    expect(r.status).toBe(201);
    expect(calls).toHaveLength(1);
    expect(calls[0].url).toBe("https://project-control.ml-c38.workers.dev/api/items");
    expect(calls[0].init.method).toBe("POST");

    const headers = calls[0].init.headers as Record<string, string>;
    expect(headers.authorization).toBe("Bearer pc-feed-not-real");
    expect(headers["content-type"]).toBe("application/json");
    expect(headers["user-agent"]).toBe("pharos-contextward-intake/1.0");

    const body = JSON.parse(String(calls[0].init.body)) as Record<string, unknown>;
    expect(Object.keys(body).sort()).toEqual(["link", "metadata", "source", "source_id", "summary"]);
    expect(body.source).toBe("contextward-intake");
    expect(body.source_id).toBe(r.body.id);
    expect(body.metadata).toEqual({ route: "quickscan", suggested_project_id: "kpji3kub", origin: "kairos", test: true });
    // The link resolves to this lead, not to a generic health page.
    expect(body.link).toBe(`https://pharos-contextward-api.ml-c38.workers.dev/v1/intake?id=${r.body.id}`);
  });

  it("reports the upstream status when Project Control rejects the item", async () => {
    vi.stubGlobal("fetch", async () => new Response(JSON.stringify({ error: "forbidden" }), { status: 403 }));
    const r = await post(lead, { authorization: `Bearer ${INTAKE_KEY}` });
    expect(r.status).toBe(201);
    expect(r.body.project_control).toEqual({ filed: false, item_id: undefined, status: 403 });
  });

  describe("project control binding contract", () => {
    function stubBinding(impl: (url: string, init: RequestInit) => Promise<Response>) {
      const calls: { url: string; init: RequestInit }[] = [];
      env.PROJECT_CONTROL = {
        fetch: async (url: string, init: RequestInit) => { calls.push({ url: String(url), init }); return impl(url, init); },
      } as unknown as Fetcher;
      return calls;
    }

    it("files through the binding with the feed token and the documented payload, never global fetch", async () => {
      const calls = stubBinding(async () => new Response(JSON.stringify({ id: "pc_binding" }), { status: 201 }));
      const r = await post(lead, { authorization: `Bearer ${INTAKE_KEY}` });

      expect(r.status).toBe(201);
      expect(r.body.project_control).toEqual({ filed: true, item_id: "pc_binding", status: 201 });
      expect(pcCalls).toHaveLength(0);
      expect(calls).toHaveLength(1);
      expect(calls[0].url).toBe("https://project-control.ml-c38.workers.dev/api/items");
      expect(calls[0].init.method).toBe("POST");
      expect((calls[0].init.headers as Record<string, string>).authorization).toBe("Bearer pc-feed-not-real");

      const body = JSON.parse(String(calls[0].init.body)) as Record<string, unknown>;
      expect(Object.keys(body).sort()).toEqual(["link", "metadata", "source", "source_id", "summary"]);
      expect(body.source).toBe("contextward-intake");
      expect(body.source_id).toBe(r.body.id);
      expect(String(body.summary)).toContain("t***@example.test");
      expect(String(body.summary)).not.toContain("test.pipeline@");
      expect(body.metadata).toEqual({ route: "quickscan", suggested_project_id: "kpji3kub", origin: "kairos", test: true });
    });

    it("still stores the lead when the binding throws", async () => {
      stubBinding(async () => { throw new Error("binding down"); });
      const r = await post(lead, { authorization: `Bearer ${INTAKE_KEY}` });
      expect(r.status).toBe(201);
      expect(r.body.project_control).toEqual({ filed: false, status: 0 });
      const stored = await worker.fetch(new Request(`${BASE}/v1/intake?id=${r.body.id}`, { headers: { authorization: `Bearer ${CONTEXTWARD_KEY}` } }), env);
      expect(((await stored.json()) as { leads: unknown[] }).leads).toHaveLength(1);
    });

    it("skips filing silently when PC_FEED_TOKEN is not set", async () => {
      const calls = stubBinding(async () => new Response(JSON.stringify({ id: "pc_binding" }), { status: 201 }));
      delete env.PC_FEED_TOKEN;
      const r = await post(lead, { authorization: `Bearer ${INTAKE_KEY}` });
      expect(r.status).toBe(201);
      expect(r.body.project_control).toEqual({ filed: false });
      expect(calls).toHaveLength(0);
      expect(pcCalls).toHaveLength(0);
      const stored = await worker.fetch(new Request(`${BASE}/v1/intake?id=${r.body.id}`, { headers: { authorization: `Bearer ${CONTEXTWARD_KEY}` } }), env);
      expect(((await stored.json()) as { leads: unknown[] }).leads).toHaveLength(1);
    });
  });

  it("resolves one intake lead by id and rejects a malformed id", async () => {
    const created = await post(lead, { authorization: `Bearer ${INTAKE_KEY}` });
    const read = async (query: string) =>
      worker.fetch(new Request(`${BASE}/v1/intake${query}`, { headers: { authorization: `Bearer ${CONTEXTWARD_KEY}` } }), env);

    const one = await read(`?id=${created.body.id}`);
    expect(one.status).toBe(200);
    expect(((await one.json()) as { leads: { id: string }[] }).leads.map((row) => row.id)).toEqual([created.body.id]);

    expect((await read("?id=not-an-id")).status).toBe(422);
    expect(((await (await read("")).json()) as { leads: unknown[] }).leads).toHaveLength(1);
  });

  it("helpers", () => {
    expect(maskEmail("martin@example.ca")).toBe("m***@example.ca");
    expect(isTestLead("TEST Pipeline", "a@b.ca", undefined)).toBe(true);
    expect(isTestLead("Jane", "jane@b.ca", undefined)).toBe(false);
  });
});
