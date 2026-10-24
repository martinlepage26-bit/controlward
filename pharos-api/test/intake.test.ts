import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker, { type Env } from "../src/index";
import { handleIntake, maskEmail, isTestLead } from "../src/intake";
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

  describe("kairos signup follow-up draft", () => {
    const signup = {
      name: "Owen Trial",
      email: "owen.trial@example.test",
      interest: "kairos",
      source: "kairos-signup",
      note: "KAIROS trial account 1008",
    };
    const referred = { ...signup, name: "Samira Trial", email: "samira.trial@example.test", note: "KAIROS trial account 88421 (referred)" };
    const subject = "Your KAIROS trial is active";
    const bodyFor = (name: string, account: string, thanks: boolean) =>
      `Hi ${name},\n\n${thanks ? "Thank you for coming through a referral. " : ""}Your KAIROS trial is active. Your trial account number is ${account}.\n\nMartin`;

    function filedBody() {
      expect(pcCalls).toHaveLength(1);
      return pcCalls[0].body;
    }

    it("files a draft follow-up for a kairos signup and does not send it", async () => {
      const r = await post(signup, { authorization: `Bearer ${INTAKE_KEY}` });
      expect(r.status).toBe(201);
      expect(r.body.route).toBe("kairos");
      expect(r.body.project_id).toBe("r0epsco9");

      const draft = r.body.follow_up_draft;
      expect(draft).toMatchObject({
        label: "DRAFT",
        status: "not_sent",
        to: signup.email,
        subject,
        account: "1008",
        referred: false,
        body: bodyFor(signup.name, "1008", false),
      });
      expect(draft.body).not.toMatch(/referral/i);
      expect(`${draft.subject}\n${draft.body}`).not.toMatch(/[—–]/);

      const item = filedBody();
      expect(item.source).toBe("contextward-intake");
      expect(String(item.summary)).toContain("DRAFT follow-up (not sent)");
      expect(String(item.summary)).toContain(draft.body);
      expect(String(item.summary)).toContain(`To: ${signup.email}`);
      expect(String(item.summary)).toContain(maskEmail(signup.email));
      expect(item.metadata).toMatchObject({
        route: "kairos",
        suggested_project_id: "r0epsco9",
        origin: "kairos-signup",
        test: true,
        subject: `DRAFT: ${subject}`,
        from: signup.email,
        draft_label: "DRAFT",
        draft_subject: subject,
        draft_to: signup.email,
        draft_plain: draft.body,
        draft_account: "1008",
        draft_referred: false,
        draft_status: "not_sent",
      });
      expect(Object.keys(item).sort()).toEqual(["link", "metadata", "source", "source_id", "summary"]);
      assertProjectControlDraftFits(item);

      expect(pcCalls.map((call) => call.url)).toEqual(["https://project-control.ml-c38.workers.dev/api/items"]);
      expect(pcCalls.every((call) => !/gmail|sendgrid|mailgun|resend|smtp|\/send\b/i.test(call.url))).toBe(true);
      expect(JSON.stringify(r.body)).not.toMatch(/"sent"\s*:\s*true/);

      const read = await worker.fetch(new Request(`${BASE}/v1/intake?id=${r.body.id}`, { headers: { authorization: `Bearer ${CONTEXTWARD_KEY}` } }), env);
      const lead = ((await read.json()) as { leads: Record<string, unknown>[] }).leads[0];
      expect(lead.draft_subject).toBe(subject);
      expect(lead.draft_body).toBe(draft.body);
      expect(lead.draft_status).toBe("not_sent");
    });

    it("thanks a referred trial user and still does not send", async () => {
      const r = await post(referred, { authorization: `Bearer ${INTAKE_KEY}` });
      expect(r.status).toBe(201);
      const draft = r.body.follow_up_draft;
      expect(draft).toMatchObject({
        label: "DRAFT",
        status: "not_sent",
        to: referred.email,
        subject,
        account: "88421",
        referred: true,
        body: bodyFor(referred.name, "88421", true),
      });
      expect(String(filedBody().summary)).toContain("Thank you for coming through a referral.");
      expect(filedBody().metadata.draft_referred).toBe(true);
      expect(pcCalls).toHaveLength(1);
      expect(String(pcCalls[0].url)).not.toMatch(/gmail|sendgrid|mailgun|resend|smtp/i);
    });

    it("does not draft a follow-up for any other source", async () => {
      const r = await post(
        { ...signup, source: "kairos", note: "KAIROS trial account 1008 (referred)" },
        { authorization: `Bearer ${INTAKE_KEY}` },
      );
      expect(r.status).toBe(201);
      expect(r.body.follow_up_draft).toBeUndefined();
      const item = filedBody();
      expect(String(item.summary)).not.toContain("DRAFT");
      expect(item.metadata).toEqual({ route: "kairos", suggested_project_id: "r0epsco9", origin: "kairos", test: true });
      const read = await worker.fetch(new Request(`${BASE}/v1/intake?id=${r.body.id}`, { headers: { authorization: `Bearer ${CONTEXTWARD_KEY}` } }), env);
      const lead = ((await read.json()) as { leads: { draft_subject: string | null }[] }).leads[0];
      expect(lead.draft_subject).toBeNull();
    });

    it("still files the item when drafting throws", async () => {
      let drafted = 0;
      const calls: { url: string; body: Record<string, unknown> }[] = [];
      env.PROJECT_CONTROL = {
        fetch: async (url: string, init: RequestInit) => {
          calls.push({ url: String(url), body: JSON.parse(String(init.body)) });
          return new Response(JSON.stringify({ id: "pc_despite_draft" }), { status: 201 });
        },
      } as unknown as Fetcher;
      const response = await handleIntake(new Request(`${BASE}/v1/intake`, {
        method: "POST",
        headers: { "content-type": "application/json", authorization: `Bearer ${INTAKE_KEY}` },
        body: JSON.stringify(signup),
      }), env, new URL(`${BASE}/v1/intake`), {
        buildDraft: () => { drafted += 1; throw new Error("draft down"); },
      });
      expect(drafted).toBe(1);
      expect(response.status).toBe(201);
      const body = await response.json() as { id: string; project_control: { filed: boolean; item_id?: string }; follow_up_draft?: unknown };
      expect(body.project_control).toEqual({ filed: true, item_id: "pc_despite_draft", status: 201 });
      expect(body.follow_up_draft).toBeUndefined();
      expect(calls).toHaveLength(1);
      expect(String(calls[0].body.summary)).not.toContain("DRAFT");
      expect(calls[0].body.metadata).toEqual({ route: "kairos", suggested_project_id: "r0epsco9", origin: "kairos-signup", test: true });
      const stored = await worker.fetch(new Request(`${BASE}/v1/intake?id=${body.id}`, { headers: { authorization: `Bearer ${CONTEXTWARD_KEY}` } }), env);
      expect(((await stored.json()) as { leads: unknown[] }).leads).toHaveLength(1);
      expect(pcCalls).toHaveLength(0);
    });

    it("escapes the name and email in the rendered draft", async () => {
      const hostile = {
        ...signup,
        name: 'Ann <script> "x"',
        email: "ann&co@example.test",
        note: "KAIROS trial account 42",
      };
      const r = await post(hostile, { authorization: `Bearer ${INTAKE_KEY}` });
      expect(r.status).toBe(201);
      const html = String(r.body.follow_up_draft.html);
      expect(html).toContain("DRAFT");
      expect(html).toContain("Ann &lt;script&gt; &quot;x&quot;");
      expect(html).toContain("ann&amp;co@example.test");
      expect(html).not.toContain("<script>");
      expect(html).not.toContain("ann&co@example.test");
      expect(r.body.follow_up_draft.body).toContain('Hi Ann <script> "x",');
      const read = await worker.fetch(new Request(`${BASE}/v1/intake?id=${r.body.id}`, { headers: { authorization: `Bearer ${CONTEXTWARD_KEY}` } }), env);
      const lead = ((await read.json()) as { leads: { draft_html: string }[] }).leads[0];
      expect(lead.draft_html).toBe(html);
      expect(lead.draft_html).not.toContain("<script>");
    });
  });
});

/** Project Control rejects message-body keys, summaries over 2000, and metadata values over 1000. */
function assertProjectControlDraftFits(item: { summary?: unknown; metadata?: Record<string, unknown> }) {
  const forbidden = new Set([
    "body", "text", "html", "raw", "snippet", "payload", "message", "content",
    "plain", "mime", "messagebody", "emailbody", "password", "passwords",
    "secret", "secrets", "token", "accesstoken", "refreshtoken", "authorization",
    "cookie", "cookies", "credential", "credentials", "apikey", "privatekey",
  ]);
  const summary = String(item.summary ?? "");
  expect(summary.length).toBeLessThanOrEqual(2000);
  const metadata = item.metadata ?? {};
  for (const [key, value] of Object.entries(metadata)) {
    expect(forbidden.has(key.toLowerCase().replace(/[^a-z0-9]/g, ""))).toBe(false);
    if (typeof value === "string") expect(value.length).toBeLessThanOrEqual(1000);
    expect(value === null || ["string", "boolean", "number"].includes(typeof value)).toBe(true);
  }
}
