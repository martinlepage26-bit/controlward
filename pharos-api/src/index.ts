export interface Env {
  ENVIRONMENT?: string;
  PHAROS_API_KEY?: string;
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

async function authorized(request: Request, env: Env): Promise<boolean> {
  if (!env.PHAROS_API_KEY) return false;
  return timingSafeEqualString(request.headers.get("authorization") ?? "", `Bearer ${env.PHAROS_API_KEY}`);
}

function validExchange(value: unknown): value is Exchange {
  return !!value && typeof value === "object" && (value as Exchange).schemaVersion === "contextward.exchange.v1";
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if ((request.method === "GET" || request.method === "HEAD") && url.pathname === "/v1/health") {
      return json({ ok: true, service: "pharos-contextward-api", environment: env.ENVIRONMENT ?? "unknown", storage: env.DB ? "d1" : "adapter-required" });
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
  }
};
