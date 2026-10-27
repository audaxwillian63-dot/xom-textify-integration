// Server-only worker for database-queued X-OM SMS and WhatsApp deliveries.
// The HTTP caller may select only a batch size; recipients and copy always
// come from rows claimed by the protected database RPC.

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";
import {
  buildTextifyPayload,
  type ClaimedTextifyDelivery,
  extractProviderRef,
  isAuthorizedWorker,
  parseClaimedDelivery,
  readBatchLimit,
  textifyStatusIsRetryable,
  validateSenderName,
  validateWhatsappSource,
  type WhatsappSource,
} from "./contract.ts";

const TEXTIFY_ENDPOINT = "https://portal.textify.africa/api/v1/messages";
const PROVIDER_TIMEOUT_MS = 15_000;
const MAX_PROVIDER_RESPONSE_BYTES = 4096;
const SEND_CONCURRENCY = 5;

type DeliveryResult = "sent" | "skipped" | "retrying" | "failed" | "finalize_failed";

type DeliveryOutcome = {
  success: boolean;
  providerRef: string | null;
  error: string | null;
  retryable: boolean;
  result: Exclude<DeliveryResult, "finalize_failed">;
};

function json(body: unknown, status = 200, extraHeaders: Record<string, string> = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      ...extraHeaders,
    },
  });
}

function safeEnv(name: string): string {
  return (Deno.env.get(name) ?? "").trim();
}

function failedOutcome(
  error: string,
  retryable: boolean,
  attempts: number,
): DeliveryOutcome {
  return {
    success: false,
    providerRef: null,
    error,
    retryable,
    result: retryable ? (attempts < 5 ? "retrying" : "failed") : "skipped",
  };
}

async function sendThroughTextify(
  delivery: ClaimedTextifyDelivery,
  apiKey: string,
  senderName: string,
  whatsappTemplateId: string,
  whatsappSource: WhatsappSource,
): Promise<DeliveryOutcome> {
  const built = buildTextifyPayload(delivery, senderName, whatsappTemplateId, whatsappSource);
  if (!built.ok) {
    return failedOutcome(built.error, built.retryable, delivery.attempts);
  }

  try {
    const response = await fetch(TEXTIFY_ENDPOINT, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      signal: AbortSignal.timeout(PROVIDER_TIMEOUT_MS),
      body: JSON.stringify(built.payload),
    });

    const responseText = (await response.text()).slice(0, MAX_PROVIDER_RESPONSE_BYTES);
    let responsePayload: unknown = null;
    try {
      responsePayload = JSON.parse(responseText);
    } catch {
      // A 2xx response is authoritative even if the optional envelope is absent.
    }

    if (!response.ok) {
      const lowerText = responseText.toLowerCase();
      const isBalanceError =
        response.status === 402 ||
        lowerText.includes("insufficient") ||
        lowerText.includes("balance") ||
        lowerText.includes("credit");
      const retryable = isBalanceError || textifyStatusIsRetryable(response.status);
      const errorLabel = isBalanceError
        ? "textify_insufficient_credit"
        : `textify_http_${response.status}`;
      if (isBalanceError) {
        console.warn("[send-textify-message] Textify account has insufficient balance or credit. Marking delivery as retryable.");
      }
      return failedOutcome(
        errorLabel,
        retryable,
        delivery.attempts,
      );
    }

    if (
      typeof responsePayload === "object" && responsePayload !== null &&
      !Array.isArray(responsePayload) &&
      (responsePayload as Record<string, unknown>).success === false
    ) {
      const msg = String((responsePayload as Record<string, unknown>).message ?? "").toLowerCase();
      const isBalanceError = msg.includes("insufficient") || msg.includes("balance") || msg.includes("credit");
      if (isBalanceError) {
        console.warn("[send-textify-message] Textify payload rejected due to insufficient balance. Marking delivery as retryable.");
      }
      return failedOutcome(
        isBalanceError ? "textify_insufficient_credit" : "textify_provider_rejected",
        isBalanceError,
        delivery.attempts,
      );
    }

    // Textify's send endpoint normally returns data:null, so a provider ref is
    // optional. Do not fabricate one from recipient or message content.
    return {
      success: true,
      providerRef: extractProviderRef(responsePayload),
      error: null,
      retryable: false,
      result: "sent",
    };
  } catch {
    return failedOutcome("textify_network_error", true, delivery.attempts);
  }
}

async function completeDelivery(
  admin: SupabaseClient,
  deliveryId: string,
  outcome: DeliveryOutcome,
): Promise<boolean> {
  const params = {
    p_delivery_id: deliveryId,
    p_success: outcome.success,
    p_provider_ref: outcome.providerRef,
    p_error: outcome.error,
    p_retryable: outcome.retryable,
  };
  try {
    const first = await admin.rpc("xom_complete_textify_delivery", params);
    if (!first.error) return true;

    const second = await admin.rpc("xom_complete_textify_delivery", params);
    if (!second.error) return true;
    console.error("[send-textify-message] completion failed", {
      deliveryId,
      code: second.error.code ?? "rpc_error",
    });
    return false;
  } catch {
    console.error("[send-textify-message] completion transport failed", { deliveryId });
    return false;
  }
}

async function processDelivery(
  admin: SupabaseClient,
  rawDelivery: unknown,
  apiKey: string,
  senderName: string,
  whatsappTemplateId: string,
  whatsappSource: WhatsappSource,
): Promise<DeliveryResult> {
  const parsed = parseClaimedDelivery(rawDelivery);
  if (!parsed.ok) {
    if (!parsed.deliveryId) {
      console.error("[send-textify-message] claim returned an unusable delivery row");
      return "finalize_failed";
    }
    const outcome = failedOutcome(parsed.error, false, 0);
    return await completeDelivery(admin, parsed.deliveryId, outcome)
      ? outcome.result
      : "finalize_failed";
  }

  const outcome = await sendThroughTextify(
    parsed.delivery,
    apiKey,
    senderName,
    whatsappTemplateId,
    whatsappSource,
  );
  return await completeDelivery(admin, parsed.delivery.delivery_id, outcome)
    ? outcome.result
    : "finalize_failed";
}

async function processWithLimit<T, R>(
  values: T[],
  concurrency: number,
  worker: (value: T) => Promise<R>,
): Promise<R[]> {
  const results = new Array<R>(values.length);
  let next = 0;
  const runners = Array.from(
    { length: Math.min(concurrency, values.length) },
    async () => {
      while (true) {
        const index = next;
        next += 1;
        if (index >= values.length) return;
        results[index] = await worker(values[index]);
      }
    },
  );
  await Promise.all(runners);
  return results;
}

Deno.serve(async (request: Request) => {
  if (request.method !== "POST") {
    return json({ ok: false, error: "Method not allowed" }, 405, { Allow: "POST" });
  }

  try {
    const supabaseUrl = safeEnv("SUPABASE_URL");
    const serviceRoleKey = safeEnv("SUPABASE_SERVICE_ROLE_KEY");
    const workerSecret = safeEnv("XOM_TEXTIFY_WORKER_SECRET");
    if (!supabaseUrl || !serviceRoleKey) {
      return json({ ok: false, error: "Worker is not configured" }, 500);
    }
    if (!isAuthorizedWorker(request.headers, workerSecret, serviceRoleKey)) {
      return json({ ok: false, error: "Unauthorized" }, 401);
    }

    const apiKey = safeEnv("TEXTIFY_API_KEY");
    if (!apiKey) {
      return json({ ok: false, error: "Textify provider is not configured" }, 503);
    }
    const configuredSender = safeEnv("TEXTIFY_SENDER_NAME") || "XOM";
    const senderName = validateSenderName(configuredSender);
    if (senderName == null) {
      return json({ ok: false, error: "Textify sender name is invalid" }, 503);
    }
    const whatsappTemplateId = safeEnv("TEXTIFY_WHATSAPP_TEMPLATE_ID");
    const whatsappSource = validateWhatsappSource(safeEnv("TEXTIFY_WHATSAPP_SOURCE"));
    if (!whatsappSource) {
      return json({ ok: false, error: "Textify WhatsApp source is invalid" }, 503);
    }

    const requested = await readBatchLimit(request);
    if (!requested.ok) return json({ ok: false, error: requested.error }, requested.status);

    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data, error } = await admin.rpc("xom_claim_textify_deliveries", {
      p_limit: requested.limit,
    });
    if (error) {
      console.error("[send-textify-message] claim failed", {
        code: error.code ?? "rpc_error",
      });
      return json({ ok: false, error: "Could not claim Textify deliveries" }, 500);
    }

    const deliveries = Array.isArray(data) ? data.slice(0, requested.limit) : [];
    const results = await processWithLimit(
      deliveries,
      SEND_CONCURRENCY,
      (delivery) =>
        processDelivery(
          admin,
          delivery,
          apiKey,
          senderName,
          whatsappTemplateId,
          whatsappSource,
        ),
    );
    const counts: Record<DeliveryResult, number> = {
      sent: 0,
      skipped: 0,
      retrying: 0,
      failed: 0,
      finalize_failed: 0,
    };
    for (const result of results) counts[result] += 1;

    return json({
      ok: counts.finalize_failed === 0,
      claimed: deliveries.length,
      ...counts,
    }, counts.finalize_failed === 0 ? 200 : 500);
  } catch {
    console.error("[send-textify-message] worker failed");
    return json({ ok: false, error: "Textify worker failed" }, 500);
  }
});
