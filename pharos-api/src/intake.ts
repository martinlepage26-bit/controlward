/**
 * Public lead intake: the front door for KAIROS, ContextWard and the PHAROS sites.
 *
 * POST /v1/intake stores one minimised lead, routes it to a project, places it in
 * the lead inbox (so the native Contextward app pulls it like any LeadGen lead) and
 * files a Project Control intake item for Martin. It never contacts the lead:
 * there is no auto-reply, so nothing is sent to a real person.
 *
 * Callers: browsers on an allowed origin (form posts) or servers holding
 * INTAKE_KEY (the KAIROS signup hook). Browser posts are throttled per IP hash.
 */
import type { Env } from "./index";

export const INTAKE_ROUTES: Record<string, { project: string; label: string }> = {
  kairos: { project: "r0epsco9", label: "KAIROS" },
  contextward: { project: "kpji3kub", label: "ContextWard" },
  quickscan: { project: "kpji3kub", label: "PHAROS Quick Scan (99 $)" },
  pharos: { project: "kpji3kub", label: "PHAROS offers" },
  security: { project: "merp9zud", label: "PHAROS Security and Confidentiality Offer" },
  lavoie: { project: "client-lavoie", label: "Lavoie / SOS Plomberie" },
  fba: { project: "client-fba", label: "FBA" },
  secondact: { project: "side-secondact", label: "SecondAct" },
  aid: { project: "1clc7lle", label: "Govern-AID" },
  northbound: { project: "8qkmgyhr", label: "NORTHBOUND Meta ads" },
  "meta-ads": { project: "8qkmgyhr", label: "NORTHBOUND Meta ads" },
  research: { project: "ws-pharos-research", label: "PHAROS Research" },
};
const DEFAULT_ROUTE = "contextward";

const ORIGIN = /^https:\/\/([a-z0-9-]+\.)*(pharos-ai\.ca|govern-ai\.ca)$|^https:\/\/([a-z0-9-]+\.)?kairos-dashboard-dy4\.pages\.dev$|^https:\/\/[a-z0-9-]+\.ml-c38\.workers\.dev$/;
const EMAIL = /^[^\s@<>()",;:]{1,64}@[A-Za-z0-9.-]{1,190}\.[A-Za-z]{2,24}$/;
const PC_URL = "https://project-control.ml-c38.workers.dev";
const BROWSER_LIMIT_PER_HOUR = 5;

const json = (body: unknown, status = 200, headers: HeadersInit = {}) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store", ...headers } });

function corsHeaders(origin: string | null): Record<string, string> {
  if (!origin || !ORIGIN.test(origin)) return {};
  return {
    "access-control-allow-origin": origin,
    "access-control-allow-methods": "POST, OPTIONS",
    "access-control-allow-headers": "content-type",
    "access-control-max-age": "86400",
    vary: "origin",
  };
}

function clean(value: unknown, max: number): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.replace(/[\u0000-\u001f\u007f]/g, " ").trim();
  return trimmed ? trimmed.slice(0, max) : null;
}

async function sha256Hex(value: string): Promise<string> {
  const bytes = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function keyMatches(provided: string | null, expected: string | undefined): Promise<boolean> {
  if (!expected || !provided) return false;
  const [a, b] = await Promise.all([sha256Hex(provided), sha256Hex(`Bearer ${expected}`)]);
  return a === b;
}

export function maskEmail(email: string): string {
  const [local, domain] = email.split("@");
  return `${local.slice(0, 1)}***@${domain}`;
}

export function isTestLead(name: string, email: string, flagged: unknown): boolean {
  return flagged === true || /^test\b/i.test(name) || /@example\.(test|com|org)$/i.test(email) || /\+test@/i.test(email);
}

export type IntakeResult = {
  id: string;
  route: string;
  project_id: string;
  test: boolean;
  inbox_seq: number | null;
  project_control: { filed: boolean; item_id?: string; status?: number };
};

export async function handleIntake(request: Request, env: Env, url: URL): Promise<Response | null> {
  if (url.pathname !== "/v1/intake") return null;
  const origin = request.headers.get("origin");
  const cors = corsHeaders(origin);
  if (request.method === "OPTIONS") return new Response(null, { status: cors["access-control-allow-origin"] ? 204 : 403, headers: cors });
  if (request.method === "GET") {
    // Martin's view of recent intake, Contextward key only.
    if (!(await keyMatches(request.headers.get("authorization"), env.PHAROS_API_KEY))) return json({ error: "unauthorized" }, 401);
    if (!env.DB) return json({ error: "storage_unavailable" }, 503);
    const { results } = await env.DB.prepare(
      "SELECT id, created_at, source, route, project_id, name, email, company, test, status, pc_item_id, pc_status FROM intake_leads ORDER BY created_at DESC LIMIT 100"
    ).all();
    return json({ schema_version: "contextward.intake.v1", leads: results ?? [] });
  }
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405, cors);
  if (!env.DB) return json({ error: "storage_unavailable" }, 503, cors);

  const server = await keyMatches(request.headers.get("authorization"), env.INTAKE_KEY);
  if (!server && !cors["access-control-allow-origin"]) return json({ error: "origin_not_allowed" }, 403);

  const raw = await request.text();
  if (raw.length > 8 * 1024) return json({ error: "payload_too_large" }, 413, cors);
  let body: Record<string, unknown>;
  try { body = JSON.parse(raw); } catch { return json({ error: "invalid_json" }, 400, cors); }
  if (!body || typeof body !== "object" || Array.isArray(body)) return json({ error: "invalid_body" }, 400, cors);

  // Honeypot: bots fill every field. Accept silently, store nothing.
  if (clean(body.website, 200)) return json({ accepted: true }, 202, cors);

  const name = clean(body.name, 120);
  const email = clean(body.email, 254)?.toLowerCase() ?? null;
  if (!name || !email || !EMAIL.test(email)) return json({ error: "name_and_valid_email_required" }, 422, cors);
  const routeKey = clean(body.interest, 40)?.toLowerCase() ?? DEFAULT_ROUTE;
  const route = INTAKE_ROUTES[routeKey] ? routeKey : DEFAULT_ROUTE;
  const source = (clean(body.source, 40) ?? (server ? "server" : "web")).toLowerCase().replace(/[^a-z0-9_.-]/g, "-");
  const company = clean(body.company, 200);
  const note = clean(body.note, 500);
  const test = isTestLead(name, email, body.test);

  if (!server) {
    const ipHash = await sha256Hex(`intake:${request.headers.get("cf-connecting-ip") ?? "unknown"}`);
    const recent = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM intake_leads WHERE ip_hash = ? AND created_at > datetime('now', '-1 hour')"
    ).bind(ipHash).first<{ n: number }>();
    if ((recent?.n ?? 0) >= BROWSER_LIMIT_PER_HOUR) return json({ error: "rate_limited" }, 429, cors);
    body.__ip = ipHash;
  }

  const id = `in_${crypto.randomUUID().replace(/-/g, "").slice(0, 20)}`;
  const project = INTAKE_ROUTES[route].project;
  const [first, ...rest] = name.split(/\s+/);
  const event = {
    schema_version: "leadgen.event.v1",
    event_id: id,
    captured_at: new Date().toISOString(),
    raw_identity: { email, first_name: first ?? null, last_name: rest.join(" ") || null, phone_raw: null, company_name_raw: company },
    fit_score: null,
    intent_score: null,
    composite_score: null,
  };
  const payload = JSON.stringify(event);
  const hash = await sha256Hex(payload);

  try {
    await env.DB.batch([
      env.DB.prepare(
        `INSERT INTO intake_leads (id, created_at, source, route, project_id, name, email, company, note, test, ip_hash, status)
         VALUES (?, datetime('now'), ?, ?, ?, ?, ?, ?, ?, ?, ?, 'new')`
      ).bind(id, source, route, project, name, email, company, note, test ? 1 : 0, (body.__ip as string | undefined) ?? null),
      env.DB.prepare("UPDATE lead_inbox_counter SET value = value + 1 WHERE id = 1"),
      env.DB.prepare(
        `INSERT INTO lead_inbox (source_id, content_hash, seq, payload_json, updated_at, acked_at, retracted)
         VALUES (?, ?, (SELECT value FROM lead_inbox_counter WHERE id = 1), ?, datetime('now'), NULL, 0)`
      ).bind(`intake:${id}`, hash, payload),
    ]);
  } catch {
    return json({ error: "storage_failure" }, 503, cors);
  }
  const seqRow = await env.DB.prepare("SELECT seq FROM lead_inbox WHERE source_id = ?").bind(`intake:${id}`).first<{ seq: number }>();

  const filed = await fileProjectControlItem(env, { id, route, project, source, name, email, company, test });
  await env.DB.prepare("UPDATE intake_leads SET pc_item_id = ?, pc_status = ? WHERE id = ?")
    .bind(filed.item_id ?? null, filed.status ?? null, id).run();

  const result: IntakeResult = { id, route, project_id: project, test, inbox_seq: seqRow?.seq ?? null, project_control: filed };
  // Browsers only learn that the lead was received; routing detail is for server callers.
  return json(server ? { accepted: true, ...result } : { accepted: true, id }, 201, cors);
}

async function fileProjectControlItem(
  env: Env,
  lead: { id: string; route: string; project: string; source: string; name: string; email: string; company: string | null; test: boolean },
): Promise<{ filed: boolean; item_id?: string; status?: number }> {
  if (!env.PC_FEED_TOKEN) return { filed: false };
  const label = INTAKE_ROUTES[lead.route].label;
  const summary = `${lead.test ? "[TEST] " : ""}New lead via ${lead.source} for ${label}: ${lead.name} (${maskEmail(lead.email)})${lead.company ? `, ${lead.company}` : ""}. Suggested project ${lead.project}. Full record in the ContextWard lead inbox (${lead.id}). No reply has been sent.`;
  try {
    const response = await fetch(`${PC_URL}/api/items`, {
      method: "POST",
      headers: { authorization: `Bearer ${env.PC_FEED_TOKEN}`, "content-type": "application/json", "user-agent": "pharos-contextward-intake/1.0" },
      body: JSON.stringify({
        source: "contextward-intake",
        source_id: lead.id,
        summary,
        link: "https://pharos-contextward-api.ml-c38.workers.dev/v1/health",
        metadata: { route: lead.route, suggested_project_id: lead.project, origin: lead.source, test: lead.test },
      }),
    });
    const out = (await response.json().catch(() => ({}))) as { id?: string };
    return { filed: response.ok, item_id: out.id, status: response.status };
  } catch {
    return { filed: false, status: 0 };
  }
}

/** Retention: test leads go after 7 days, real intake rows after 400 days. */
export async function purgeIntake(env: Env): Promise<void> {
  if (!env.DB) return;
  await env.DB.prepare("DELETE FROM intake_leads WHERE test = 1 AND created_at < datetime('now', '-7 days')").run();
  await env.DB.prepare("DELETE FROM intake_leads WHERE created_at < datetime('now', '-400 days')").run();
}
