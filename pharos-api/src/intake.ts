/**
 * Public lead intake: the front door for KAIROS, ContextWard and the PHAROS sites.
 *
 * POST /v1/intake stores one minimised lead, routes it to a project, places it in
 * the lead inbox (so the native Contextward app pulls it like any LeadGen lead) and
 * files a Project Control intake item for Martin. A KAIROS trial signup
 * (source kairos-signup) also stores a DRAFT follow-up on that item and on the
 * intake row the item links to. It never contacts the lead: there is no
 * auto-reply and no send, so Martin sends each draft himself.
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
const INTAKE_ID = /^in_[a-z0-9]{20}$/;
const PC_URL = "https://project-control.ml-c38.workers.dev";
const API_BASE = "https://pharos-contextward-api.ml-c38.workers.dev";
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
  follow_up_draft?: FollowUpDraft;
};

export type KairosDraftInput = { name: string; email: string; note: string | null };

/** A message Martin may send. status stays not_sent until he sends it himself, outside this worker. */
export type FollowUpDraft = {
  label: "DRAFT";
  status: "not_sent";
  to: string;
  subject: string;
  body: string;
  html: string;
  account: string | null;
  referred: boolean;
};

export type IntakeHooks = {
  /** Test seam. Production uses the template. A throw is ignored and the lead is still filed. */
  buildDraft?: (input: KairosDraftInput) => FollowUpDraft | Promise<FollowUpDraft>;
};

const KAIROS_ACCOUNT = /^KAIROS trial account ([A-Za-z0-9][A-Za-z0-9_-]{0,63})( \(referred\))?$/;
const DRAFT_SUBJECT = "Your KAIROS trial is active";

/** Project Control refuses these metadata names (normalized to letters and digits). */
const FORBIDDEN_INTAKE_KEYS = new Set([
  "body", "text", "html", "raw", "snippet", "payload", "message", "content",
  "plain", "mime", "messagebody", "emailbody", "password", "passwords",
  "secret", "secrets", "token", "accesstoken", "refreshtoken", "authorization",
  "cookie", "cookies", "credential", "credentials", "apikey", "privatekey",
]);

export function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (character) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[character] ?? character));
}

export function parseKairosTrialNote(note: string | null): { account: string | null; referred: boolean } {
  const match = note ? KAIROS_ACCOUNT.exec(note) : null;
  if (!match) return { account: null, referred: false };
  return { account: match[1], referred: Boolean(match[2]) };
}

/**
 * Deterministic plain-text draft. This worker has no model binding, so the
 * template is the draft. A future model call must catch its own failure and
 * use this. The only promise in the copy is that the KAIROS trial is active.
 */
export function buildKairosFollowUpDraft(input: KairosDraftInput): FollowUpDraft {
  const { account, referred } = parseKairosTrialNote(input.note);
  const thanks = referred ? "Thank you for coming through a referral. " : "";
  const accountSentence = account ? ` Your trial account number is ${account}.` : "";
  const body = `Hi ${input.name},\n\n${thanks}Your KAIROS trial is active.${accountSentence}\n\nMartin`;
  return {
    label: "DRAFT",
    status: "not_sent",
    to: input.email,
    subject: DRAFT_SUBJECT,
    body,
    html: renderDraftHtml({ name: input.name, email: input.email, account, referred }),
    account,
    referred,
  };
}

function renderDraftHtml(input: { name: string; email: string; account: string | null; referred: boolean }): string {
  const thanks = input.referred ? "Thank you for coming through a referral. " : "";
  const accountSentence = input.account ? ` Your trial account number is ${escapeHtml(input.account)}.` : "";
  return [
    "DRAFT follow-up (not sent). Martin sends this himself.",
    `To: ${escapeHtml(input.email)}`,
    `Subject: ${escapeHtml(DRAFT_SUBJECT)}`,
    `Hi ${escapeHtml(input.name)},`,
    `${thanks}Your KAIROS trial is active.${accountSentence}`,
    "Martin",
  ].join("\n");
}

export async function handleIntake(request: Request, env: Env, url: URL, hooks: IntakeHooks = {}): Promise<Response | null> {
  if (url.pathname !== "/v1/intake") return null;
  const origin = request.headers.get("origin");
  const cors = corsHeaders(origin);
  if (request.method === "OPTIONS") return new Response(null, { status: cors["access-control-allow-origin"] ? 204 : 403, headers: cors });
  if (request.method === "GET") {
    // Martin's view of recent intake, Contextward key only.
    if (!(await keyMatches(request.headers.get("authorization"), env.PHAROS_API_KEY))) return json({ error: "unauthorized" }, 401);
    if (!env.DB) return json({ error: "storage_unavailable" }, 503);
    const columns = "id, created_at, source, route, project_id, name, email, company, test, status, pc_item_id, pc_status, draft_subject, draft_body, draft_html, draft_status";
    const id = url.searchParams.get("id");
    if (id !== null && !INTAKE_ID.test(id)) return json({ error: "invalid_id" }, 422);
    const query = id
      ? env.DB.prepare(`SELECT ${columns} FROM intake_leads WHERE id = ? LIMIT 1`).bind(id)
      : env.DB.prepare(`SELECT ${columns} FROM intake_leads ORDER BY created_at DESC LIMIT 100`);
    const { results } = await query.all();
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
  const draft = await kairosDraft(source, { name, email, note }, hooks);
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

  const leadRow = (withDraft: boolean) => withDraft
    ? env.DB!.prepare(
      `INSERT INTO intake_leads (id, created_at, source, route, project_id, name, email, company, note, test, ip_hash, status, draft_subject, draft_body, draft_html, draft_status)
       VALUES (?, datetime('now'), ?, ?, ?, ?, ?, ?, ?, ?, ?, 'new', ?, ?, ?, ?)`
    ).bind(id, source, route, project, name, email, company, note, test ? 1 : 0, (body.__ip as string | undefined) ?? null, draft?.subject ?? null, draft?.body ?? null, draft?.html ?? null, draft?.status ?? null)
    : env.DB!.prepare(
      `INSERT INTO intake_leads (id, created_at, source, route, project_id, name, email, company, note, test, ip_hash, status)
       VALUES (?, datetime('now'), ?, ?, ?, ?, ?, ?, ?, ?, ?, 'new')`
    ).bind(id, source, route, project, name, email, company, note, test ? 1 : 0, (body.__ip as string | undefined) ?? null);
  const inboxRows = () => [
    env.DB!.prepare("UPDATE lead_inbox_counter SET value = value + 1 WHERE id = 1"),
    env.DB!.prepare(
      `INSERT INTO lead_inbox (source_id, content_hash, seq, payload_json, updated_at, acked_at, retracted)
       VALUES (?, ?, (SELECT value FROM lead_inbox_counter WHERE id = 1), ?, datetime('now'), NULL, 0)`
    ).bind(`intake:${id}`, hash, payload),
  ];
  // The draft columns are best effort. A failure there retries the lead alone so the signup is not lost.
  try {
    await env.DB.batch([leadRow(true), ...inboxRows()]);
  } catch {
    try {
      await env.DB.batch([leadRow(false), ...inboxRows()]);
    } catch {
      return json({ error: "storage_failure" }, 503, cors);
    }
  }
  const seqRow = await env.DB.prepare("SELECT seq FROM lead_inbox WHERE source_id = ?").bind(`intake:${id}`).first<{ seq: number }>();

  const filed = await fileProjectControlItem(env, { id, route, project, source, name, email, company, test, draft });
  await env.DB.prepare("UPDATE intake_leads SET pc_item_id = ?, pc_status = ? WHERE id = ?")
    .bind(filed.item_id ?? null, filed.status ?? null, id).run();

  const result: IntakeResult = {
    id, route, project_id: project, test, inbox_seq: seqRow?.seq ?? null, project_control: filed,
    ...(draft ? { follow_up_draft: draft } : {}),
  };
  // Browsers only learn that the lead was received; routing detail is for server callers.
  return json(server ? { accepted: true, ...result } : { accepted: true, id }, 201, cors);
}

async function kairosDraft(source: string, input: KairosDraftInput, hooks: IntakeHooks): Promise<FollowUpDraft | null> {
  if (source !== "kairos-signup") return null;
  try {
    return await Promise.resolve((hooks.buildDraft ?? buildKairosFollowUpDraft)(input));
  } catch {
    return null;
  }
}

function metadataFits(metadata: Record<string, unknown>): boolean {
  const keys = Object.keys(metadata);
  if (keys.length > 32 || keys.some((key) => key.length > 64 || ["__proto__", "prototype", "constructor"].includes(key))) return false;
  for (const [key, value] of Object.entries(metadata)) {
    if (FORBIDDEN_INTAKE_KEYS.has(key.toLowerCase().replace(/[^a-z0-9]/g, ""))) return false;
    const scalar = value === null || typeof value === "string" || typeof value === "boolean" || (typeof value === "number" && Number.isFinite(value));
    if (!scalar) return false;
    if (typeof value === "string" && value.length > 1000) return false;
  }
  return JSON.stringify(metadata).length <= 8000;
}

/** Appends the draft only when the result still matches the Project Control intake contract. */
function withFollowUpDraft(
  item: { source: string; source_id: string; summary: string; link: string; metadata: Record<string, unknown> },
  draft: FollowUpDraft | null,
) {
  if (!draft) return item;
  try {
    const summary = `${item.summary}\n\nDRAFT follow-up (not sent). Martin sends this himself.\nTo: ${draft.to}\nSubject: ${draft.subject}\n${draft.body}`;
    const metadata: Record<string, unknown> = {
      ...item.metadata,
      subject: `DRAFT: ${draft.subject}`,
      from: draft.to,
      draft_label: draft.label,
      draft_subject: draft.subject,
      draft_to: draft.to,
      draft_plain: draft.body,
      draft_account: draft.account,
      draft_referred: draft.referred,
      draft_status: draft.status,
    };
    if (summary.length > 2000 || !metadataFits(metadata)) return item;
    return { ...item, summary, metadata };
  } catch {
    return item;
  }
}

async function fileProjectControlItem(
  env: Env,
  lead: { id: string; route: string; project: string; source: string; name: string; email: string; company: string | null; test: boolean; draft: FollowUpDraft | null },
): Promise<{ filed: boolean; item_id?: string; status?: number }> {
  if (!env.PC_FEED_TOKEN) return { filed: false };
  const label = INTAKE_ROUTES[lead.route].label;
  const summary = `${lead.test ? "[TEST] " : ""}New lead via ${lead.source} for ${label}: ${lead.name} (${maskEmail(lead.email)})${lead.company ? `, ${lead.company}` : ""}. Suggested project ${lead.project}. Full record in the ContextWard lead inbox (${lead.id}). No reply has been sent.`;
  const payload = withFollowUpDraft({
    source: "contextward-intake",
    source_id: lead.id,
    summary,
    // Points at the stored intake row, not a generic page: the Project Control
    // item opens the exact lead. Key-gated, like every other read of intake.
    link: `${API_BASE}/v1/intake?id=${encodeURIComponent(lead.id)}`,
    metadata: { route: lead.route, suggested_project_id: lead.project, origin: lead.source, test: lead.test },
  }, lead.draft);
  try {
    // Same-account workers.dev fetches are refused by Cloudflare, so prefer the service binding.
    const send = env.PROJECT_CONTROL ? env.PROJECT_CONTROL.fetch.bind(env.PROJECT_CONTROL) : fetch;
    const response = await send(`${PC_URL}/api/items`, {
      method: "POST",
      headers: { authorization: `Bearer ${env.PC_FEED_TOKEN}`, "content-type": "application/json", "user-agent": "pharos-contextward-intake/1.0" },
      body: JSON.stringify(payload),
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
