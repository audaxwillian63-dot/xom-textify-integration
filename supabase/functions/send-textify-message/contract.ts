export const MAX_BATCH_SIZE = 25;
export const MAX_SMS_CONTENT_CHARS = 320;
export const WORKER_SECRET_HEADER = "x-xom-textify-worker-secret";

export const ALLOWED_CATEGORIES = new Set([
  "marketing",
  "bookings",
  "payments",
  "messages",
  "alerts",
]);

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const TANZANIA_MOBILE = /^255[67]\d{8}$/;

export type TextifyChannel = "sms" | "whatsapp";
export type WhatsappSource = "own" | "default";
export type TextifyCategory = "marketing" | "bookings" | "payments" | "messages" | "alerts";
export type DeliveryMeta = Record<string, unknown>;

export type ClaimedTextifyDelivery = {
  delivery_id: string;
  queue_id: string;
  recipient_id: string;
  channel: TextifyChannel;
  title: string;
  body: string;
  category: TextifyCategory;
  purpose: string;
  priority: string;
  template_code: string;
  event_type: string;
  entity_type: string;
  entity_id: string;
  dedupe_key: string;
  meta: DeliveryMeta;
  attempts: number;
  phone: string;
};

export type BatchLimitResult =
  | { ok: true; limit: number }
  | { ok: false; status: number; error: string };

export type SmsPayload = {
  sender_name?: string;
  is_scheduled: false;
  messages: Array<{ receiver: string; content: string }>;
};

export type WhatsappPayload = {
  channel: "whatsapp";
  template_id: string;
  whatsapp_source: WhatsappSource;
  messages: Array<{ receiver: string; template_params: string[] }>;
};

export type TextifyPayloadResult =
  | { ok: true; payload: SmsPayload | WhatsappPayload }
  | { ok: false; error: string; retryable: boolean };

export function secureEqual(left: string, right: string): boolean {
  if (left.length !== right.length) return false;
  let mismatch = 0;
  for (let i = 0; i < left.length; i += 1) {
    mismatch |= left.charCodeAt(i) ^ right.charCodeAt(i);
  }
  return mismatch === 0;
}

/** Authorize only a dedicated server secret or the exact service-role bearer. */
export function isAuthorizedWorker(
  headers: Headers,
  workerSecret: string,
  serviceRoleKey: string,
): boolean {
  const suppliedWorkerSecret =
    headers.get(WORKER_SECRET_HEADER) ??
    headers.get("xom_textify_worker_secret") ??
    "";
  if (
    workerSecret.length > 0 && suppliedWorkerSecret.length > 0 &&
    secureEqual(suppliedWorkerSecret, workerSecret)
  ) {
    return true;
  }

  const authorization = headers.get("authorization") ?? "";
  return serviceRoleKey.length > 0 &&
    secureEqual(authorization, `Bearer ${serviceRoleKey}`);
}

/** The caller can control only a bounded claim size, never recipients or copy. */
export async function readBatchLimit(request: Request): Promise<BatchLimitResult> {
  const declaredLength = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(declaredLength) && declaredLength > 1024) {
    return { ok: false, status: 413, error: "Request body is too large" };
  }

  const raw = await request.text();
  if (new TextEncoder().encode(raw).byteLength > 1024) {
    return { ok: false, status: 413, error: "Request body is too large" };
  }
  if (!raw.trim()) return { ok: true, limit: MAX_BATCH_SIZE };

  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    return { ok: false, status: 400, error: "Invalid JSON" };
  }
  if (!isRecord(value)) {
    return { ok: false, status: 400, error: "Body must be a JSON object" };
  }
  if (Object.keys(value).some((key) => key !== "limit")) {
    return { ok: false, status: 400, error: "Only limit may be supplied" };
  }
  if (value.limit == null) return { ok: true, limit: MAX_BATCH_SIZE };
  if (
    typeof value.limit !== "number" || !Number.isInteger(value.limit) ||
    value.limit < 1
  ) {
    return { ok: false, status: 400, error: "limit must be a positive integer" };
  }
  return { ok: true, limit: Math.min(value.limit, MAX_BATCH_SIZE) };
}

export function parseClaimedDelivery(value: unknown):
  | { ok: true; delivery: ClaimedTextifyDelivery }
  | { ok: false; deliveryId: string | null; error: string } {
  if (!isRecord(value)) {
    return { ok: false, deliveryId: null, error: "invalid_delivery_row" };
  }

  const deliveryId = cleanString(value.delivery_id, 80);
  if (!UUID.test(deliveryId)) {
    return { ok: false, deliveryId: null, error: "invalid_delivery_id" };
  }
  const queueId = cleanString(value.queue_id, 80);
  if (!UUID.test(queueId)) {
    return { ok: false, deliveryId, error: "invalid_queue_id" };
  }
  const recipientId = cleanString(value.recipient_id, 80);
  if (!UUID.test(recipientId)) {
    return { ok: false, deliveryId, error: "invalid_recipient_id" };
  }

  const channel = cleanString(value.channel, 20).toLowerCase();
  if (channel !== "sms" && channel !== "whatsapp") {
    return { ok: false, deliveryId, error: "unsupported_channel" };
  }
  const category = cleanString(value.category, 40).toLowerCase();
  if (!ALLOWED_CATEGORIES.has(category)) {
    return { ok: false, deliveryId, error: "unsupported_category" };
  }

  const title = cleanMessageText(value.title, 180, true);
  const body = cleanMessageText(value.body, 4000, false);
  if (!title && !body) {
    return { ok: false, deliveryId, error: "missing_message_copy" };
  }

  const phone = cleanString(value.phone, 64);
  if (!phone) {
    return { ok: false, deliveryId, error: "recipient_phone_missing" };
  }

  const attempts = Number(value.attempts);
  return {
    ok: true,
    delivery: {
      delivery_id: deliveryId,
      queue_id: queueId,
      recipient_id: recipientId,
      channel,
      title,
      body,
      category: category as TextifyCategory,
      purpose: cleanString(value.purpose, 40).toLowerCase(),
      priority: cleanString(value.priority, 40).toLowerCase(),
      template_code: cleanString(value.template_code, 80).toUpperCase(),
      event_type: cleanString(value.event_type, 80),
      entity_type: cleanString(value.entity_type, 80),
      entity_id: cleanString(value.entity_id, 240),
      dedupe_key: cleanString(value.dedupe_key, 240),
      meta: isRecord(value.meta) ? value.meta : {},
      attempts: Number.isInteger(attempts) && attempts >= 0 ? attempts : 0,
      phone,
    },
  };
}

/**
 * Accept only explicit Tanzanian mobile formats. Bare local subscriber numbers,
 * extensions, letters, and non-Tanzanian country codes are rejected.
 */
export function normalizeTanzaniaPhone(value: string): string | null {
  const raw = value.trim();
  if (!raw || !/^[+\d\s().-]+$/.test(raw)) return null;

  let compact = raw.replace(/[\s().-]/g, "");
  if (compact.startsWith("+")) compact = compact.slice(1);
  if (compact.startsWith("00255")) compact = compact.slice(2);
  if (/^0[67]\d{8}$/.test(compact)) compact = `255${compact.slice(1)}`;

  return TANZANIA_MOBILE.test(compact) ? compact : null;
}

export function buildSmsContent(
  delivery: {
    title: string;
    body: string;
    template_code?: string;
    meta?: DeliveryMeta;
  },
): string {
  const parts = [delivery.title, delivery.body].filter(Boolean);
  let copy = parts.join("\n").replace(/\n{3,}/g, "\n\n").trim();
  if (!copy) return "";

  const vars = isRecord(delivery.meta?.vars) ? delivery.meta.vars : {};
  const isHost = (delivery.template_code ?? "").startsWith("HOST_") ||
    (delivery.template_code ?? "") === "BOOKING_CONFIRMED_AGENT";
  const nameCandidate = isHost
    ? (safeMetaValue(vars.host_name, 60) || safeMetaValue(delivery.meta?.recipient_name, 60))
    : (safeMetaValue(vars.customer_name, 60) || safeMetaValue(delivery.meta?.recipient_name, 60));

  if (nameCandidate && nameCandidate.toLowerCase() !== "there" && nameCandidate.toLowerCase() !== "guest") {
    const lowerCopy = copy.toLowerCase();
    const lowerName = nameCandidate.toLowerCase();
    if (!lowerCopy.includes(lowerName)) {
      copy = `Habari ${nameCandidate}!\n${copy}`;
    }
  }

  const normalized = /^X-OM\b/i.test(copy) ? copy : `X-OM\n${copy}`;
  return Array.from(normalized).slice(0, MAX_SMS_CONTENT_CHARS).join("");
}

export function marketingConsentIsVerified(
  delivery: Pick<ClaimedTextifyDelivery, "category" | "purpose" | "channel" | "meta">,
): boolean {
  const isMarketing = delivery.category === "marketing" || delivery.purpose === "marketing";
  if (!isMarketing) return true;
  return delivery.meta.consent_verified === true &&
    delivery.meta.consent_channel === delivery.channel;
}

/**
 * The approved v1 WhatsApp template has exactly two variables. Their values
 * come only from the database's allowlisted booking vars; notification title
 * and body are never used as WhatsApp freeform parameters.
 */
export function buildWhatsappTemplateParams(meta: DeliveryMeta, templateCode = ""): string[] | null {
  const vars = isRecord(meta.vars) ? meta.vars : {};
  const isHost = templateCode.startsWith("HOST_") || templateCode === "BOOKING_CONFIRMED_AGENT";
  const customerName = isHost ? "there" : safeMetaValue(vars.customer_name, 80);
  const bookingCode = safeMetaValue(vars.booking_code, 40);
  return customerName && bookingCode ? [customerName, bookingCode] : null;
}

export function validateSenderName(value: string): string | null {
  const senderName = value.trim();
  if (!senderName) return "";
  if (senderName.length > 11 || /[\u0000-\u001f\u007f]/.test(senderName)) return null;
  return senderName;
}

export function validateWhatsappSource(value: string): WhatsappSource | null {
  const source = value.trim() || "own";
  return source === "own" || source === "default" ? source : null;
}

export function buildTextifyPayload(
  delivery: ClaimedTextifyDelivery,
  senderName: string,
  whatsappTemplateId: string,
  whatsappSource: WhatsappSource = "own",
): TextifyPayloadResult {
  const receiver = normalizeTanzaniaPhone(delivery.phone);
  if (!receiver) {
    return { ok: false, error: "recipient_phone_invalid", retryable: false };
  }
  if (!marketingConsentIsVerified(delivery)) {
    return { ok: false, error: "marketing_consent_not_verified", retryable: false };
  }

  if (delivery.channel === "sms") {
    const content = buildSmsContent(delivery);
    if (!content) return { ok: false, error: "missing_sms_content", retryable: false };
    const payload: SmsPayload = {
      is_scheduled: false,
      messages: [{ receiver, content }],
    };
    if (senderName) payload.sender_name = senderName;
    return { ok: true, payload };
  }

  if (delivery.category === "marketing" || delivery.purpose === "marketing") {
    return {
      ok: false,
      error: "whatsapp_marketing_template_not_configured",
      retryable: false,
    };
  }
  if (!whatsappTemplateId) {
    return { ok: false, error: "whatsapp_template_not_configured", retryable: true };
  }
  if (!UUID.test(whatsappTemplateId)) {
    return { ok: false, error: "whatsapp_template_invalid", retryable: true };
  }
  const templateParams = buildWhatsappTemplateParams(delivery.meta, delivery.template_code);
  if (!templateParams) {
    return { ok: false, error: "missing_whatsapp_booking_params", retryable: false };
  }
  return {
    ok: true,
    payload: {
      channel: "whatsapp",
      template_id: whatsappTemplateId,
      whatsapp_source: whatsappSource,
      messages: [{ receiver, template_params: templateParams }],
    },
  };
}

export function textifyStatusIsRetryable(status: number): boolean {
  return status === 401 || status === 402 || status === 403 || status === 408 || status === 409 ||
    status === 425 || status === 429 || status >= 500;
}

export function extractProviderRef(value: unknown): string | null {
  if (!isRecord(value)) return null;
  const data = isRecord(value.data) ? value.data : {};
  for (const candidate of [data.id, data.message_id, value.id, value.message_id]) {
    const ref = cleanString(candidate, 200).replace(/[\u0000-\u001f\u007f]/g, "");
    if (ref) return ref;
  }
  return null;
}

function safeMetaValue(value: unknown, maxLength: number): string {
  if (typeof value !== "string" && typeof value !== "number") return "";
  return Array.from(
    String(value)
      .replace(/[\u0000-\u001f\u007f]+/g, " ")
      .replace(/\s+/g, " ")
      .trim(),
  ).slice(0, maxLength).join("");
}

function cleanMessageText(value: unknown, maxLength: number, oneLine: boolean): string {
  if (typeof value !== "string") return "";
  let cleaned = value
    .replace(/\r\n?/g, "\n")
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]+/g, " ");
  if (oneLine) cleaned = cleaned.replace(/\n+/g, " ");
  return Array.from(cleaned.trim()).slice(0, maxLength).join("");
}

function cleanString(value: unknown, maxLength: number): string {
  return typeof value === "string" ? value.trim().slice(0, maxLength) : "";
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
