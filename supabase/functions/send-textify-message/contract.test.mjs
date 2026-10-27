import test from "node:test";
import assert from "node:assert/strict";
import {
  buildSmsContent,
  buildTextifyPayload,
  buildWhatsappTemplateParams,
  extractProviderRef,
  isAuthorizedWorker,
  marketingConsentIsVerified,
  MAX_SMS_CONTENT_CHARS,
  normalizeTanzaniaPhone,
  parseClaimedDelivery,
  readBatchLimit,
  textifyStatusIsRetryable,
  validateSenderName,
  validateWhatsappSource,
  WORKER_SECRET_HEADER,
} from "./contract.ts";

const whatsappTemplateId = "7c1a2e2a-4b0e-4e9a-9a2e-1a2b3c4d5e6f";
const rawDelivery = {
  delivery_id: "d81900f1-78e3-4d41-b645-2674ae9124a7",
  queue_id: "9f799d6e-e949-4d23-91ca-3ac14781517b",
  recipient_id: "7992edb4-8bf2-4650-b52c-86418e65659e",
  channel: "sms",
  title: "Booking confirmed",
  body: "Your room is ready.",
  category: "bookings",
  purpose: "transactional",
  priority: "normal",
  template_code: "BOOKING_CONFIRMED_CUSTOMER",
  event_type: "booking_confirmed",
  entity_type: "booking",
  entity_id: "2a2b7aad-cbd8-46e9-8a21-2166c3202233",
  dedupe_key: "booking-confirmed:test",
  meta: {
    vars: {
      customer_name: " Asha\nM. ",
      booking_code: " MKZ-123 ",
      property_name: "Ocean Palm",
      access_notes: "Door code 1234",
    },
  },
  attempts: 1,
  phone: "+255 712 345 678",
};

function parsed(overrides = {}) {
  const result = parseClaimedDelivery({ ...rawDelivery, ...overrides });
  assert.equal(result.ok, true);
  return result.delivery;
}

test("worker auth requires an exact configured secret or exact service-role bearer", () => {
  assert.equal(
    isAuthorizedWorker(
      new Headers({ [WORKER_SECRET_HEADER]: "worker-secret" }),
      "worker-secret",
      "service-key",
    ),
    true,
  );
  assert.equal(
    isAuthorizedWorker(
      new Headers({ XOM_TEXTIFY_WORKER_SECRET: "worker-secret" }),
      "worker-secret",
      "service-key",
    ),
    true,
  );
  assert.equal(
    isAuthorizedWorker(
      new Headers({ authorization: "Bearer service-key" }),
      "worker-secret",
      "service-key",
    ),
    true,
  );
  assert.equal(
    isAuthorizedWorker(
      new Headers({ authorization: "Bearer service-key-extra" }),
      "worker-secret",
      "service-key",
    ),
    false,
  );
  assert.equal(
    isAuthorizedWorker(new Headers({ [WORKER_SECRET_HEADER]: "" }), "", "service-key"),
    false,
  );
});

test("request contract only permits a capped batch limit", async () => {
  assert.deepEqual(
    await readBatchLimit(new Request("https://worker.test", { method: "POST", body: "{}" })),
    { ok: true, limit: 25 },
  );
  assert.deepEqual(
    await readBatchLimit(
      new Request("https://worker.test", { method: "POST", body: '{"limit":100}' }),
    ),
    { ok: true, limit: 25 },
  );
  assert.equal(
    (await readBatchLimit(
      new Request("https://worker.test", {
        method: "POST",
        body: '{"phone":"0712345678","body":"attacker copy"}',
      }),
    )).ok,
    false,
  );
  assert.equal(
    (await readBatchLimit(
      new Request("https://worker.test", { method: "POST", body: '{"limit":0}' }),
    )).ok,
    false,
  );
});

test("claim rows accept only the supported channels and categories", () => {
  const delivery = parsed();
  assert.equal(delivery.channel, "sms");
  assert.equal(delivery.category, "bookings");
  for (const category of ["marketing", "bookings", "payments", "messages", "alerts"]) {
    assert.equal(parseClaimedDelivery({ ...rawDelivery, category }).ok, true);
  }
  assert.deepEqual(parseClaimedDelivery({ ...rawDelivery, channel: "email" }), {
    ok: false,
    deliveryId: rawDelivery.delivery_id,
    error: "unsupported_channel",
  });
  assert.deepEqual(parseClaimedDelivery({ ...rawDelivery, category: "booking" }), {
    ok: false,
    deliveryId: rawDelivery.delivery_id,
    error: "unsupported_category",
  });
});

test("Tanzanian mobile normalization is conservative", () => {
  assert.equal(normalizeTanzaniaPhone("0712 345 678"), "255712345678");
  assert.equal(normalizeTanzaniaPhone("+255 (712) 345-678"), "255712345678");
  assert.equal(normalizeTanzaniaPhone("00255 612 345 678"), "255612345678");
  assert.equal(normalizeTanzaniaPhone("255712345678"), "255712345678");
  assert.equal(normalizeTanzaniaPhone("712345678"), null);
  assert.equal(normalizeTanzaniaPhone("+254712345678"), null);
  assert.equal(normalizeTanzaniaPhone("255512345678"), null);
  assert.equal(normalizeTanzaniaPhone("0712345678 ext 2"), null);
});

test("SMS payload uses only claimed copy, caps it at 320 characters, and optionally adds sender", () => {
  const delivery = parsed({ title: "Update", body: "x".repeat(400) });
  const result = buildTextifyPayload(delivery, "XOM", "");
  assert.equal(result.ok, true);
  if (!result.ok) return;
  assert.deepEqual(Object.keys(result.payload).sort(), ["is_scheduled", "messages", "sender_name"]);
  assert.equal(result.payload.sender_name, "XOM");
  assert.equal(result.payload.is_scheduled, false);
  assert.equal(result.payload.messages[0].receiver, "255712345678");
  assert.equal(Array.from(result.payload.messages[0].content).length, MAX_SMS_CONTENT_CHARS);
  assert.equal(result.payload.messages[0].content, buildSmsContent(delivery));
});

test("marketing SMS requires exact claim-time consent proof for its channel", () => {
  const missingProof = parsed({ category: "marketing", purpose: "marketing" });
  assert.equal(marketingConsentIsVerified(missingProof), false);
  assert.deepEqual(buildTextifyPayload(missingProof, "", ""), {
    ok: false,
    error: "marketing_consent_not_verified",
    retryable: false,
  });

  const wrongChannel = parsed({
    category: "marketing",
    purpose: "marketing",
    meta: { ...rawDelivery.meta, consent_verified: true, consent_channel: "whatsapp" },
  });
  assert.equal(marketingConsentIsVerified(wrongChannel), false);

  const consented = parsed({
    category: "marketing",
    purpose: "marketing",
    meta: { ...rawDelivery.meta, consent_verified: true, consent_channel: "sms" },
  });
  const result = buildTextifyPayload(consented, "", "");
  assert.equal(result.ok, true);
});

test("WhatsApp sends only the approved template and fixed booking parameters", () => {
  const delivery = parsed({ channel: "whatsapp" });
  assert.deepEqual(buildWhatsappTemplateParams(delivery.meta), ["Asha M.", "MKZ-123"]);
  const result = buildTextifyPayload(delivery, "IGNORED", whatsappTemplateId);
  assert.equal(result.ok, true);
  if (!result.ok) return;
  assert.deepEqual(result.payload, {
    channel: "whatsapp",
    template_id: whatsappTemplateId,
    whatsapp_source: "own",
    messages: [{
      receiver: "255712345678",
      template_params: ["Asha M.", "MKZ-123"],
    }],
  });
  const serialized = JSON.stringify(result.payload);
  assert.doesNotMatch(serialized, /Booking confirmed|Your room is ready|Door code 1234|content/);
});

test("WhatsApp rejects absent configuration, missing booking vars, and marketing", () => {
  const delivery = parsed({ channel: "whatsapp" });
  assert.deepEqual(buildTextifyPayload(delivery, "", ""), {
    ok: false,
    error: "whatsapp_template_not_configured",
    retryable: true,
  });
  assert.deepEqual(
    buildTextifyPayload(
      parsed({ channel: "whatsapp", meta: { vars: { customer_name: "Asha" } } }),
      "",
      whatsappTemplateId,
    ),
    { ok: false, error: "missing_whatsapp_booking_params", retryable: false },
  );
  assert.deepEqual(
    buildTextifyPayload(
      parsed({
        channel: "whatsapp",
        category: "marketing",
        purpose: "marketing",
        meta: { ...rawDelivery.meta, consent_verified: true, consent_channel: "whatsapp" },
      }),
      "",
      whatsappTemplateId,
    ),
    { ok: false, error: "whatsapp_marketing_template_not_configured", retryable: false },
  );
});

test("sender validation, provider references, and retry statuses are bounded", () => {
  assert.equal(validateSenderName(" X-OM "), "X-OM");
  assert.equal(validateSenderName(""), "");
  assert.equal(validateSenderName("TOO-LONG-NAME"), null);
  assert.equal(extractProviderRef({ success: true, data: null }), null);
  assert.equal(extractProviderRef({ data: { id: "provider-id" } }), "provider-id");
  assert.equal(textifyStatusIsRetryable(429), true);
  assert.equal(textifyStatusIsRetryable(503), true);
  assert.equal(textifyStatusIsRetryable(402), true);
  assert.equal(textifyStatusIsRetryable(400), false);
});

test("X-OM WhatsApp uses the own business number unless shared source is explicitly configured", () => {
  assert.equal(validateWhatsappSource(""), "own");
  assert.equal(validateWhatsappSource("own"), "own");
  assert.equal(validateWhatsappSource("default"), "default");
  assert.equal(validateWhatsappSource("arbitrary-number"), null);
  const message = buildTextifyPayload(parsed({ channel: "whatsapp" }), "", whatsappTemplateId, "default");
  assert.equal(message.ok && message.payload.whatsapp_source, "default");
  const uuidV7 = buildTextifyPayload(parsed({ channel: "whatsapp" }), "", "01a125a4-5faa-7b93-9747-1cd2aa6c02da");
  assert.equal(uuidV7.ok, true);
});

test("SMS includes the brand with shared senders but empty messages remain blocked", () => {
  assert.equal(buildSmsContent({ title: "Booking confirmed", body: "See details in the app." }), "X-OM\nBooking confirmed\nSee details in the app.");
  assert.equal(buildSmsContent({ title: "X-OM booking", body: "Update" }), "X-OM booking\nUpdate");
  assert.equal(buildSmsContent({ title: "", body: "" }), "");
});

test("SMS content always mentions guest name for guest and host name for host", () => {
  // Guest delivery: injects Habari Asha M.!
  const guestDelivery = {
    title: "Booking confirmed",
    body: "Your stay is confirmed. Check in at 14:00.",
    template_code: "BOOKING_CONFIRMED_CUSTOMER",
    meta: { vars: { customer_name: "Asha M." } },
  };
  const guestSms = buildSmsContent(guestDelivery);
  assert.match(guestSms, /Habari Asha M\.\!/);
  assert.match(guestSms, /Your stay is confirmed/);

  // Host delivery: injects Habari Baraka K.!
  const hostDelivery = {
    title: "New booking",
    body: "New booking for stay at City Studio.",
    template_code: "BOOKING_CONFIRMED_AGENT",
    meta: { vars: { host_name: "Baraka K.", customer_name: "Asha M." } },
  };
  const hostSms = buildSmsContent(hostDelivery);
  assert.match(hostSms, /Habari Baraka K\.\!/);
  assert.match(hostSms, /New booking/);
});

test("host WhatsApp templates do not greet a host with the guest's name", () => {
  const message = buildTextifyPayload(parsed({ channel: "whatsapp", template_code: "HOST_STAY_TOMORROW" }), "", whatsappTemplateId);
  assert.equal(message.ok, true);
  assert.deepEqual(message.payload.messages[0].template_params, ["there", "MKZ-123"]);
});
