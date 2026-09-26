export interface Env {
  ENVIRONMENT?: string;
  /** Contextward key: exchange push, auth check, lead pull and ack. */
  PHAROS_API_KEY?: string;
  /** LeadGen OS exporter key: lead push only. */
  LEADGEN_PUSH_KEY?: string;
  DB?: D1Database;
}

type Exchange = { schemaVersion?: string; exportedAt?: string; [key: string]: unknown };

const json = (body: unknown, status = 200, headers: HeadersInit = {}) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...headers } });

const encoder = new TextEncoder();

async function digest(value: string): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(value)));
}

/** Constant-time comparison. Hashing first gives equal-length inputs, so neither content nor length leaks through timing. */
export async function timingSafeEqualString(provided: string, expected: string): Promise<boolean> {
  const [a, b] = await Promise.all([digest(provided), digest(expected)]);
  if (a.byteLength !== b.byteLength) return false;
  const subtle = crypto.subtle as SubtleCrypto & { timingSafeEqual?: (x: ArrayBufferView, y: ArrayBufferView) => boolean };
  if (typeof subtle.timingSafeEqual === "function") return subtle.timingSafeEqual(a, b);
  let difference = 0;
  for (let index = 0; index < a.byteLength; index += 1) difference |= a[index] ^ b[index];
  return difference === 0;
}

/** Each route accepts exactly one key. A missing or empty configured key fails closed. */
async function hasKey(request: Request, key: string | undefined): Promise<boolean> {
  if (!key) return false;
  return timingSafeEqualString(request.headers.get("authorization") ?? "", `Bearer ${key}`);
}

const authorized = (request: Request, env: Env) => hasKey(request, env.PHAROS_API_KEY);

function validExchange(value: unknown): value is Exchange {
  return !!value && typeof value === "object" && (value as Exchange).schemaVersion === "contextward.exchange.v1";
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const leads = await handleLeadInbox(request, env, url);
    if (leads) return leads;
    if ((request.method === "GET" || request.method === "HEAD") && url.pathname === "/v1/health") {
      return json({ ok: true, service: "pharos-contextward-api", environment: env.ENVIRONMENT ?? "unknown", storage: env.DB ? "d1" : "adapter-required" });
    }
    if (request.method === "GET" && url.pathname === "/v1/auth/check") {
      if (!(await authorized(request, env))) return json({ error: "unauthorized" }, 401);
      return json({ ok: true, authenticated: true });
    }
    if (url.pathname === "/v1/exchange/push" && request.method === "POST") {
      if (!(await authorized(request, env))) return json({ error: "unauthorized" }, 401);
      const idempotencyKey = request.headers.get("idempotency-key");
      if (!idempotencyKey) return json({ error: "missing_idempotency_key" }, 400);
      let body: unknown;
      try { body = await request.json(); } catch { return json({ error: "invalid_json" }, 400); }
      if (!validExchange(body)) return json({ error: "invalid_exchange_schema", expected: "contextward.exchange.v1" }, 422);
      const receipt = `receipt_${crypto.randomUUID()}`;
      if (!env.DB) return json({ accepted: true, persisted: false, idempotencyKey, schemaVersion: body.schemaVersion, receipt, next: "configure the D1 binding before production writes" }, 202);
      try {
        await env.DB.prepare("INSERT INTO exchange_receipts (idempotency_key, receipt, payload_json) VALUES (?, ?, ?)").bind(idempotencyKey, receipt, JSON.stringify(body)).run();
      } catch (error) {
        if (String(error).toLowerCase().includes("unique")) {
          const existing = await env.DB.prepare("SELECT receipt FROM exchange_receipts WHERE idempotency_key = ?").bind(idempotencyKey).first<{ receipt: string }>();
          return json({ accepted: true, persisted: true, duplicate: true, idempotencyKey, receipt: existing?.receipt ?? receipt, schemaVersion: body.schemaVersion }, 200);
        }
        return json({ error: "storage_failure", idempotencyKey }, 503);
      }
      return json({ accepted: true, persisted: true, idempotencyKey, schemaVersion: body.schemaVersion, receipt }, 202);
    }
    return json({ error: "not_found" }, 404);
  },

  /** Daily retention for the lead inbox. */
  async scheduled(_controller: ScheduledController, env: Env): Promise<void> {
    await purgeLeadInbox(env);
  }
} satisfies ExportedHandler<Env>;

// MARK: - Lead inbox

const LEAD_EVENT_SCHEMA = "leadgen.event.v1";
const MAX_PUSH_LEADS = 100;
const MAX_PUSH_BYTES = 256 * 1024;
const MAX_ACKS = 500;
const MAX_RETRACTS = 100;
const DEFAULT_PULL_LIMIT = 100;
const MAX_PULL_LIMIT = 200;
const SOURCE_ID = /^[A-Za-z0-9_.:-]{1,128}$/;
const noStore = { "cache-control": "no-store" };

/** The only lead fields stored or served. Everything else in a push is dropped. */
export type InboxEvent = {
  schema_version: typeof LEAD_EVENT_SCHEMA;
  event_id: string;
  captured_at: string | null;
  raw_identity: { email: string | null; first_name: string | null; last_name: string | null; phone_raw: string | null; company_name_raw: string | null };
  fit_score: number | null;
  intent_score: number | null;
  composite_score: number | null;
};

function text(value: unknown, max: number): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed ? trimmed.slice(0, max) : null;
}

function score(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? Math.min(100, Math.max(0, Math.round(value))) : null;
}

/** Builds the stored event in a fixed key order, so JSON.stringify is canonical for hashing. */
export function minimiseLead(sourceId: string, event: unknown): InboxEvent | null {
  if (!event || typeof event !== "object") return null;
  const input = event as Record<string, unknown>;
  if ((input.schema_version ?? LEAD_EVENT_SCHEMA) !== LEAD_EVENT_SCHEMA) return null;
  const identity = (input.raw_identity && typeof input.raw_identity === "object" ? input.raw_identity : {}) as Record<string, unknown>;
  const minimised: InboxEvent = {
    schema_version: LEAD_EVENT_SCHEMA,
    event_id: sourceId,
    captured_at: text(input.captured_at, 40),
    raw_identity: {
      email: text(identity.email, 254),
      first_name: text(identity.first_name, 120),
      last_name: text(identity.last_name, 120),
      phone_raw: text(identity.phone_raw, 40),
      company_name_raw: text(identity.company_name_raw, 200),
    },
    fit_score: score(input.fit_score),
    intent_score: score(input.intent_score),
    composite_score: score(input.composite_score),
  };
  const { email, first_name, last_name } = minimised.raw_identity;
  return email || first_name || last_name ? minimised : null;
}

async function sha256Hex(value: string): Promise<string> {
  return [...(await digest(value))].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function handleLeadInbox(request: Request, env: Env, url: URL): Promise<Response | null> {
  const route = `${request.method} ${url.pathname}`;
  if (route === "POST /v1/leads/push") {
    if (!(await hasKey(request, env.LEADGEN_PUSH_KEY))) return json({ error: "unauthorized" }, 401);
    return pushLeads(request, env);
  }
  if (route === "GET /v1/leads") {
    if (!(await hasKey(request, env.PHAROS_API_KEY))) return json({ error: "unauthorized" }, 401);
    return pullLeads(env, url);
  }
  if (route === "POST /v1/leads/ack") {
    if (!(await hasKey(request, env.PHAROS_API_KEY))) return json({ error: "unauthorized" }, 401);
    return ackLeads(request, env);
  }
  return null;
}

async function readBody(request: Request, maxBytes: number): Promise<{ body?: unknown; error?: Response }> {
  const raw = await request.text();
  if (new TextEncoder().encode(raw).byteLength > maxBytes) return { error: json({ error: "payload_too_large" }, 413) };
  try { return { body: JSON.parse(raw) }; } catch { return { error: json({ error: "invalid_json" }, 400) }; }
}

async function pushLeads(request: Request, env: Env): Promise<Response> {
  if (!env.DB) return json({ error: "storage_unavailable" }, 503);
  const { body, error } = await readBody(request, MAX_PUSH_BYTES);
  if (error) return error;
  const packet = body as { schema_version?: unknown; leads?: unknown };
  if (!packet || packet.schema_version !== "leadgen.push.v1" || !Array.isArray(packet.leads)) {
    return json({ error: "invalid_push_schema", expected: "leadgen.push.v1" }, 422);
  }
  if (packet.leads.length > MAX_PUSH_LEADS) return json({ error: "too_many_leads", max: MAX_PUSH_LEADS }, 413);
  const retract = (packet as { retract?: unknown }).retract ?? [];
  if (!Array.isArray(retract)) return json({ error: "invalid_retract" }, 422);
  if (retract.length > MAX_RETRACTS) return json({ error: "too_many_retractions", max: MAX_RETRACTS }, 413);
  for (const [index, sourceId] of retract.entries()) {
    if (typeof sourceId !== "string" || !SOURCE_ID.test(sourceId)) return json({ error: "invalid_retract", index }, 422);
  }

  const incoming = new Map<string, { payload: string; hash: string }>();
  for (const [index, item] of packet.leads.entries()) {
    const sourceId = (item as { source_id?: unknown })?.source_id;
    if (typeof sourceId !== "string" || !SOURCE_ID.test(sourceId)) return json({ error: "invalid_source_id", index }, 422);
    const event = minimiseLead(sourceId, (item as { event?: unknown }).event);
    if (!event) return json({ error: "invalid_lead_event", index }, 422);
    const payload = JSON.stringify(event);
    incoming.set(sourceId, { payload, hash: await sha256Hex(payload) });
  }
  const retractIds = [...new Set(retract as string[])].filter((id) => !incoming.has(id));
  if (incoming.size === 0 && retractIds.length === 0) return json({ accepted: 0, created: 0, updated: 0, unchanged: 0, retracted: 0 });

  // D1 allows at most 100 bound parameters per statement, so look ids up in chunks.
  const known = new Map<string, { hash: string; retracted: number }>();
  const ids = [...incoming.keys(), ...retractIds];
  for (let start = 0; start < ids.length; start += 90) {
    const chunk = ids.slice(start, start + 90);
    const existing = await env.DB.prepare(`SELECT source_id, content_hash, retracted FROM lead_inbox WHERE source_id IN (${chunk.map(() => "?").join(",")})`)
      .bind(...chunk).all<{ source_id: string; content_hash: string; retracted: number }>();
    for (const row of existing.results ?? []) known.set(row.source_id, { hash: row.content_hash, retracted: row.retracted });
  }

  let created = 0, updated = 0, unchanged = 0;
  const statements: D1PreparedStatement[] = [];
  for (const [sourceId, { payload, hash }] of incoming) {
    const previous = known.get(sourceId)?.hash;
    if (previous === hash) { unchanged += 1; continue; }
    if (previous === undefined) created += 1; else updated += 1;
    statements.push(env.DB.prepare("UPDATE lead_inbox_counter SET value = value + 1 WHERE id = 1"));
    statements.push(env.DB.prepare(
      `INSERT INTO lead_inbox (source_id, content_hash, seq, payload_json, updated_at, acked_at, retracted)
       VALUES (?, ?, (SELECT value FROM lead_inbox_counter WHERE id = 1), ?, datetime('now'), NULL, 0)
       ON CONFLICT(source_id) DO UPDATE SET content_hash = excluded.content_hash, seq = excluded.seq,
         payload_json = excluded.payload_json, updated_at = excluded.updated_at, acked_at = NULL, retracted = 0
       WHERE lead_inbox.content_hash <> excluded.content_hash`
    ).bind(sourceId, hash, payload));
  }
  // A retraction becomes a PII-free tombstone with a new seq, even for ids never seen or already purged,
  // so a client that received the lead earlier still hears about it.
  let retracted = 0;
  for (const sourceId of retractIds) {
    if (known.get(sourceId)?.retracted === 1) continue;
    retracted += 1;
    statements.push(env.DB.prepare("UPDATE lead_inbox_counter SET value = value + 1 WHERE id = 1"));
    statements.push(env.DB.prepare(
      `INSERT INTO lead_inbox (source_id, content_hash, seq, payload_json, updated_at, acked_at, retracted)
       VALUES (?, 'retracted', (SELECT value FROM lead_inbox_counter WHERE id = 1), NULL, datetime('now'), NULL, 1)
       ON CONFLICT(source_id) DO UPDATE SET content_hash = 'retracted', seq = excluded.seq, payload_json = NULL,
         updated_at = excluded.updated_at, acked_at = NULL, retracted = 1
       WHERE lead_inbox.retracted = 0`
    ).bind(sourceId));
  }
  try {
    if (statements.length) await env.DB.batch(statements);
  } catch {
    return json({ error: "storage_failure" }, 503);
  }
  return json({ accepted: incoming.size, created, updated, unchanged, retracted });
}

async function pullLeads(env: Env, url: URL): Promise<Response> {
  if (!env.DB) return json({ error: "storage_unavailable" }, 503);
  const sinceRaw = url.searchParams.get("since") ?? "0";
  const limitRaw = url.searchParams.get("limit") ?? String(DEFAULT_PULL_LIMIT);
  if (!/^\d{1,15}$/.test(sinceRaw)) return json({ error: "invalid_cursor" }, 400);
  if (!/^\d{1,4}$/.test(limitRaw)) return json({ error: "invalid_limit" }, 400);
  const since = Number(sinceRaw);
  const limit = Math.min(Math.max(Number(limitRaw), 1), MAX_PULL_LIMIT);
  const { results } = await env.DB.prepare(
    "SELECT source_id, seq, content_hash, payload_json, retracted FROM lead_inbox WHERE acked_at IS NULL AND seq > ? ORDER BY seq LIMIT ?"
  ).bind(since, limit + 1).all<{ source_id: string; seq: number; content_hash: string; payload_json: string | null; retracted: number }>();
  const counter = await env.DB.prepare("SELECT epoch FROM lead_inbox_counter WHERE id = 1").first<{ epoch: string | null }>();
  const page = (results ?? []).slice(0, limit);
  const leads = page.map((row) => row.retracted === 1 || row.payload_json === null
    ? { source_id: row.source_id, seq: row.seq, retracted: true }
    : { source_id: row.source_id, seq: row.seq, content_hash: row.content_hash, event: JSON.parse(row.payload_json) });
  const cursor = page.length ? page[page.length - 1].seq : since;
  return json({ schema_version: "contextward.lead-inbox.v1", epoch: counter?.epoch ?? "none", leads, cursor, has_more: (results ?? []).length > limit }, 200, noStore);
}

async function ackLeads(request: Request, env: Env): Promise<Response> {
  if (!env.DB) return json({ error: "storage_unavailable" }, 503);
  const { body, error } = await readBody(request, 64 * 1024);
  if (error) return error;
  const acks = (body as { acks?: unknown })?.acks;
  if (!Array.isArray(acks)) return json({ error: "invalid_ack_schema" }, 422);
  if (acks.length > MAX_ACKS) return json({ error: "too_many_acks", max: MAX_ACKS }, 413);
  const statements: D1PreparedStatement[] = [];
  for (const [index, item] of acks.entries()) {
    const { source_id: sourceId, seq } = (item ?? {}) as { source_id?: unknown; seq?: unknown };
    if (typeof sourceId !== "string" || !SOURCE_ID.test(sourceId) || !Number.isSafeInteger(seq)) return json({ error: "invalid_ack", index }, 422);
    // Only the exact version pulled is acked; a newer push (new seq) stays pending. Re-acks are no-ops that still count.
    statements.push(env.DB.prepare(
      "UPDATE lead_inbox SET acked_at = COALESCE(acked_at, datetime('now')), payload_json = NULL WHERE source_id = ? AND seq = ?"
    ).bind(sourceId, seq as number));
  }
  if (!statements.length) return json({ acked: 0, stale: 0 });
  let results: D1Result[];
  try { results = await env.DB.batch(statements); } catch { return json({ error: "storage_failure" }, 503); }
  const acked = results.filter((result) => (result.meta?.changes ?? 0) > 0).length;
  return json({ acked, stale: statements.length - acked });
}

export async function purgeLeadInbox(env: Env): Promise<void> {
  if (!env.DB) return;
  // Unacked leads are kept until Contextward pulls them: deleting them would lose them for good,
  // because the exporter only re-sends changed leads. Withdrawn leads are handled by retraction.
  await env.DB.prepare("DELETE FROM lead_inbox WHERE acked_at IS NOT NULL AND acked_at < datetime('now', '-30 days')").run();
  // Manual exchange snapshots can carry lead PII; keep them 30 days.
  await env.DB.prepare("DELETE FROM exchange_receipts WHERE created_at < datetime('now', '-30 days')").run();
}
