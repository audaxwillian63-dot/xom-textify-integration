<div align="center">

# X-OM & Textify Africa — Telecom & Zero-Loss Escrow Messaging Worker

[![Node.js](https://img.shields.io/badge/Node.js-20+-green.svg)](https://nodejs.org/)
[![Supabase Edge Functions](https://img.shields.io/badge/Supabase-Edge%20Functions-3ECF8E.svg)](https://supabase.com/docs/guides/functions)
[![Textify API](https://img.shields.io/badge/Textify%20API-v1-blue.svg)](https://portal.textify.africa)
[![Tests](https://img.shields.io/badge/Tests-13%20Passed%20(100%25)-brightgreen.svg)]()
[![TCRA Sender ID](https://img.shields.io/badge/Sender%20ID-XOM-00E5FF.svg)](https://xomai.tech)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**Carrier-grade, database-driven SMS and WhatsApp dispatch engine powering offline 4-digit arrival PIN check-ins, zero-loss escrow safety alerts, and guest/host reservation updates across Tanzania.**

[Live Production Marketplace](https://xomai.tech) · [Technical Brand & Architecture Portal](https://xomai.tech/brand/) · [Textify Africa](https://portal.textify.africa)

</div>

---

## 1. Problem & Innovation

In Tanzania, **over 80% of informal short-stay accommodations** arranged via WhatsApp or Instagram suffer from payment scams, lack of host verification, or guests arriving to locked gates because the host ran out of cellular data.

**X-OM solves this through an automated telecom-escrow pipeline:**

1. **Guaranteed Offline Check-In:** The instant a booking is confirmed via mobile money (M-Pesa, Mixx by Yas, Airtel Money, HaloPesa), Textify dispatches an encrypted **4-digit Arrival PIN** via SMS to the guest and host. The guest checks in at the gate even with zero internet or mobile data.
2. **Zero-Loss Escrow Protection:** Funds are locked in platform escrow. The host receives payment only after the guest arrives, inspects the physical property, and provides the secret 4-digit PIN. Real-time SMS receipts confirm the escrow hold.
3. **TCRA-Approved Alphanumeric Header (`XOM`):** Messages arrive under the official brand name `XOM`, preventing phishing and establishing consumer trust across Vodacom, Tigo, Airtel, and Halotel.
4. **Idempotent Queue Pipeline:** Uses PostgreSQL `FOR UPDATE SKIP LOCKED` so concurrent edge function worker runs never double-charge or send duplicate text messages.

---

## 2. Architecture & Execution Flow

```
[Guest Mobile Money Payment (Payme / M-Pesa)]
                     │
                     ▼
       [X-OM Escrow Vault Locked]
                     │
                     ▼
    [PostgreSQL notification_queue]
                     │
                     ▼
  [Atomic Claim: FOR UPDATE SKIP LOCKED]
  (Function: xom_claim_textify_deliveries)
                     │
                     ▼
   [Supabase Edge Function: send-textify-message]
   (Validates 255... phone, caps at 320 chars, adds XOM)
                     │
                     ▼
   [Textify Africa API (portal.textify.africa)]
   (POST https://portal.textify.africa/api/v1/messages)
                     │
                     ▼
   [Tanzania GSM Carriers (Vodacom, Tigo, Airtel, Halotel)]
                     │
                     ▼
     [Guest & Host Inboxes in 3 to 5 Seconds]
```

---

## 3. The 10 Coded Production SMS Messages

All 10 messages are natively bilingual (Swahili & English), dynamically injecting guest names, host names, property titles, check-in dates, and arrival times:

| # | Event Trigger | Recipient | SMS Template Copy |
| :--- | :--- | :--- | :--- |
| **1** | `BOOKING_CONFIRMED_CUSTOMER` | **Guest** | `X-OM: Habari {{customer_name}}! Malipo yamethibitishwa. Your stay at {{property_title}} is confirmed. Check in {{check_in_date}} at {{check_in_time}}, check out {{check_out_date}} at {{check_out_time}}. Host: {{host_name}}. Ref {{booking_code}}.` |
| **2** | `BOOKING_CONFIRMED_AGENT` | **Host** | `X-OM: Habari {{host_name}}! Una booking mpya kutoka kwa {{customer_name}} kwenye {{property_name}}. Check in {{check_in_date}} saa {{check_in_time}}, check out {{check_out_date}} saa {{check_out_time}}. Ref {{booking_code}}.' |
| **3** | `STAY_TOMORROW_CUSTOMER` | **Guest** | `X-OM: Habari {{customer_name}}! Safari yako {{property_title}} inaanza kesho. Check in {{check_in_date}} saa {{check_in_time}}. Host: {{host_name}}. Ref {{booking_code}}.' |
| **4** | `HOST_STAY_TOMORROW` | **Host** | `X-OM: Habari {{host_name}}! Mgeni {{customer_name}} anawasili kesho kwenye {{property_name}}. Check in kuanzia saa {{check_in_time}}. Ref {{booking_code}}.' |
| **5** | `STAY_CHECKIN_WINDOW` | **Guest** | `X-OM: Habari {{customer_name}}! Milango iko wazi kwa ajili ya check-in {{property_title}}. Karibu sana! Host: {{host_name}}. Ref {{booking_code}}.' |
| **6** | `GUEST_STAY_BEFORE_CHECKOUT` | **Guest** | `X-OM: Habari {{customer_name}}! Ukumbusho: Check-out ya stay yako {{property_title}} ni kesho {{check_out_date}} saa {{check_out_time}}. Ref {{booking_code}}.' |
| **7** | `HOST_STAY_BEFORE_CHECKOUT` | **Host** | `X-OM: Habari {{host_name}}! Mgeni {{customer_name}} anafanya check-out kesho {{check_out_date}} kufikia saa {{check_out_time}} kwenye {{property_name}}.' |
| **8** | `CANCEL_DONE_CUSTOMER` | **Guest** | `X-OM: Habari {{customer_name}}! Booking yako {{property_title}} (Ref {{booking_code}}) imeahirishwa kikamilifu.' |
| **9** | `HOST_BOOKING_CANCELLED` | **Host** | `X-OM: Habari {{host_name}}! Booking ya {{customer_name}} kwenye {{property_name}} (Ref {{booking_code}}) imeahirishwa na kalenda imefunguliwa.' |
| **10** | `PAYMENT_FAILED_CUSTOMER` | **Guest** | `X-OM: Habari {{customer_name}}! Malipo ya stay yako {{property_title}} hayajafanikiwa. Tafadhali jaribu tena kabla muda wa hold haujaisha.' |

---

## 4. Engineering Safeguards & Delivery Guarantees

- **Tanzanian Phone Normalization:** Strict regex sanitization supporting `0...`, `255...`, `+255...`, or `00255...`, normalized to carrier format `255[67]XXXXXXXX`.
- **Dual-Segment Character Bounds:** Automatically caps SMS copy at 320 characters to guarantee messages fit in standard 2 GSM segments, preventing unexpected cost overruns.
- **Atomic Locking (`FOR UPDATE SKIP LOCKED`):** Protects against worker concurrency race conditions.
- **Exponential Backoff Retry:** If Textify or local carrier networks return retryable status codes (`429`, `503`, `network_error`), the worker calculates exponential backoff retry intervals up to 5 attempts.

---

## 5. Automated Test Suite (100% Pass)

To run the full unit test suite locally:

```bash
npm test
```

### Test Results:
```text
✔ worker auth requires an exact configured secret or exact service-role bearer (498ms)
✔ request contract only permits a capped batch limit (61ms)
✔ claim rows accept only the supported channels and categories (2ms)
✔ Tanzanian mobile normalization is conservative (21ms)
✔ SMS payload uses only claimed copy, caps it at 320 characters, and optionally adds sender (40ms)
✔ marketing SMS requires exact claim-time consent proof for its channel (1ms)
✔ WhatsApp sends only the approved template and fixed booking parameters (10ms)
✔ WhatsApp rejects absent configuration, missing booking vars, and marketing (3ms)
✔ sender validation, provider references, and retry statuses are bounded (2ms)
✔ X-OM WhatsApp uses the own business number unless shared source is explicitly configured (2ms)
✔ SMS includes the brand with shared senders but empty messages remain blocked (1ms)
✔ SMS content always mentions guest name for guest and host name for host (1ms)
✔ host WhatsApp templates do not greet a host with the guest's name (1ms)

ℹ tests 13
ℹ pass 13
ℹ fail 0
```

---

## 6. Project Structure

```text
xom-textify-integration/
├── README.md                                   # Comprehensive documentation
├── LICENSE                                     # MIT License
├── package.json                                # NPM test scripts
├── supabase/
│   └── functions/
│       └── send-textify-message/
│           ├── index.ts                        # Deno edge function worker
│           ├── contract.ts                     # Business logic, payload & phone normalizer
│           └── contract.test.mjs               # 13 automated unit tests
├── sql/
│   ├── ACTIVATE_TEXTIFY_LIVE.sql               # Production activation patch
│   ├── 01_textify_messaging_center.sql         # Base database tables & queue
│   └── 02_stay_sms_checkin_checkout.sql        # Template updates & check-in timing
└── assets/
    └── xom-logo.svg                            # Official vector brand asset
```

---

## 7. Production Deployment & Live Verification

- **Production Marketplace:** [https://xomai.tech](https://xomai.tech)
- **Technical Architecture & Brand Docs:** [https://xomai.tech/brand/](https://xomai.tech/brand/)
- **Textify Africa Portal:** [https://portal.textify.africa](https://portal.textify.africa)
- **Sender ID:** `XOM`

---

## License

This integration module is released under the **MIT License**. Copyright &copy; 2026 X-OM (Makazi App).
