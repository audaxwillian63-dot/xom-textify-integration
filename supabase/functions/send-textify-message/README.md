# Textify message worker

This server-only Supabase Edge Function delivers X-OM notifications through
Textify Africa. It claims rows with
`xom_claim_textify_deliveries(p_limit)` and records every outcome through
`xom_complete_textify_delivery(...)`.

The HTTP request may contain only an optional integer `limit`. Phone numbers,
message copy, channel, category, template data, and consent evidence always
come from the protected database claim. The worker accepts the categories
`marketing`, `bookings`, `payments`, `messages`, and `alerts`.

## Secrets and settings

Required:

- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`
- `TEXTIFY_API_KEY`
- `XOM_TEXTIFY_WORKER_SECRET` when invoking with the dedicated worker header

Optional:

- `TEXTIFY_SENDER_NAME` — approved Textify SMS sender name, at most 11
  characters
- `TEXTIFY_WHATSAPP_TEMPLATE_ID` — required before a claimed WhatsApp row can
  be delivered; it must be the UUID of the approved X-OM booking template
- `TEXTIFY_WHATSAPP_SOURCE` — `own` (the default) uses the registered X-OM
  business number; `default` explicitly uses Textify's shared number instead.
  Invalid values stop the worker before claiming any delivery. There is no
  automatic shared-number fallback.

Invoke with `POST` and either the exact service-role bearer or the dedicated
secret:

```text
Authorization: Bearer <SUPABASE_SERVICE_ROLE_KEY>
```

or:

```text
XOM_TEXTIFY_WORKER_SECRET: <XOM_TEXTIFY_WORKER_SECRET>
```

The standard hyphenated header `x-xom-textify-worker-secret` is also accepted.
Deploy with gateway JWT verification disabled when the dedicated secret header
will be used; the function performs its own exact secret/service-role check.

## Delivery safeguards

- Only Tanzanian mobile numbers in explicit `0…`, `255…`, `+255…`, or
  `00255…` form are accepted and normalized to `255…`.
- SMS copy is built only from the claimed `title` and `body`, adds X-OM if the
  text does not already start with the brand, and is capped at 320 Unicode
  characters including that prefix. `TEXTIFY_SENDER_NAME` is omitted when unset.
- Marketing SMS requires claim-time proof in `meta`:
  `consent_verified: true` and `consent_channel: "sms"`.
- WhatsApp never sends freeform copy. It uses
  `TEXTIFY_WHATSAPP_TEMPLATE_ID` with exactly two sanitized values from
  `meta.vars`: `customer_name` and `booking_code`.
  Host templates use the neutral greeting `there` instead of the guest's name.
- WhatsApp marketing is skipped in v1. It needs a separately approved template
  and an explicit parameter contract before it can be enabled.
- API keys, worker secrets, recipient phone numbers, and message copy are not
  logged.

Textify accepts messages at
`POST https://portal.textify.africa/api/v1/messages`. Its successful send
response is `201 Created` with `data: null`, so `p_provider_ref` is normally
null. See the [official Textify API documentation](https://textify.africa/docs/).

## Request example

```json
{ "limit": 10 }
```

Any other request field, including a recipient, title, body, channel, or
template id, is rejected.

An X-OM profile logo needs X-OM's own registered WhatsApp business profile;
setting `sender_name` does not change WhatsApp's identity. A logo inside the
message is a separate image-header template, not HTML. The current documented
Textify send contract exposes body parameters only, so no unverified media
fields are sent. See `supabase/whatsapp-templates/README.md` for the pending
provider steps and the local utility-template draft.

## Contract tests

Run the Node-compatible test suite from the repository root:

```sh
node --test supabase/functions/send-textify-message/contract.test.mjs
```
