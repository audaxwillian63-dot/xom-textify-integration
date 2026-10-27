<div align="center">

# X-OM & Textify Africa — Hyperlocal Intention AI & Telecom Escrow Engine

[![Node.js](https://img.shields.io/badge/Node.js-20+-green.svg)](https://nodejs.org/)
[![Supabase Edge Functions](https://img.shields.io/badge/Supabase-Edge%20Functions-3ECF8E.svg)](https://supabase.com/docs/guides/functions)
[![Textify API](https://img.shields.io/badge/Textify%20API-v1-blue.svg)](https://portal.textify.africa)
[![Tests](https://img.shields.io/badge/Tests-13%20Passed%20(100%25)-brightgreen.svg)]()
[![TCRA Sender ID](https://img.shields.io/badge/Sender%20ID-XOM-00E5FF.svg)](https://xomai.tech)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**World's first Hyperlocal Geo-Intelligence AI that translates human intention and trip purpose into the perfect short stay, paired with Textify Africa's carrier-grade GSM SMS engine for offline 4-digit arrival PIN check-ins and zero-loss escrow protection across Tanzania.**

[Live Production Marketplace](https://xomai.tech) · [Technical Brand & Architecture Portal](https://xomai.tech/brand/) · [Textify Africa](https://portal.textify.africa)

</div>

---

## 1. The Core Breakthrough: Hyperlocal Intention AI

Traditional platforms (Airbnb, Booking.com) operate on rigid legacy filters: city dropdowns, calendar dates, and price sliders. They have zero understanding of African urban geography and zero comprehension of **why** a person is traveling.

**X-OM pioneers a completely new paradigm:** instead of asking *"Where are you going?"*, X-OM asks:
> *"Why are you traveling? Tell me your purpose in your own words."*

### Why Nobody Has Ever Done This:
- **Intention Decomposition:** A guest saying *"Nakuja kufanya biashara Kariakoo, nahitaji sehemu salama yenye usafiri rahisi asubuhi"* is not just looking for a room. They need secure stock access, early morning transit routes, and practical gate access.
- **Hyperlocal Geo-Intelligence:** African cities don't function by generic postal codes. X-OM maps **9 districts and 70+ wards** (e.g. knowing Hananasif is inside Kinondoni, Upanga borders Muhimbili National Hospital, Sinza balances nightlife with quiet residential pockets, and Kigamboni requires ferry/bridge logistics).
- **Conversational Concierge Voice:** Rather than dumping cold database tables, X-OM's local AI speaks warmly in Swahili and English (*"Habari! Nimekupatia machaguo mazuri ya kulinganisha hapa:"*), presenting multiple live stays side-by-side with genuine tradeoff advice.

---

## 2. Closing the Offline Loop with Textify Africa

Once the Hyperlocal AI identifies the stay and the guest pays via mobile money (M-Pesa, Mixx by Yas, Airtel Money, HaloPesa), **Textify Africa powers the real-world physical check-in**:

1. **Guaranteed Offline Check-In:** In East Africa, travelers and hosts frequently run out of mobile data while moving. Textify dispatches an encrypted **4-digit Arrival PIN** via direct GSM SMS (Vodacom, Tigo, Airtel, Halotel). The guest checks in at the gate with zero internet.
2. **Zero-Loss Escrow Protection:** Funds are held in platform escrow. The host receives payout only after the guest arrives, inspects the physical property, and provides the secret PIN. Real-time SMS receipts confirm the escrow lock.
3. **TCRA-Approved Alphanumeric Header (`XOM`):** Messages arrive under the official brand name `XOM`, preventing phishing and establishing consumer trust.
4. **Idempotent Queue Pipeline:** Uses PostgreSQL `FOR UPDATE SKIP LOCKED` so concurrent edge function worker invocations never double-charge or send duplicate text messages.

---

## 3. Architecture & Execution Flow

```
[Guest Query: "Coming for trade near Kariakoo, need quiet sleep under 50k"]
                                │
                                ▼
       [Hyperlocal Geo-Intelligence AI Engine]
       - Decomposes intention & purpose
       - Resolves district/ward containment (Ilala/Kinondoni)
       - Evaluates live host amenities (AC, Wi-Fi, noise level)
                                │
                                ▼
              [Conversational Side-by-Side Match]
                                │
                                ▼
         [Guest Pays via Mobile Money into Escrow]
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
                                │
                                ▼
            [Tanzania GSM Carriers (Vodacom, Tigo, Airtel, Halotel)]
                                │
                                ▼
             [Offline 4-Digit Arrival PIN in 3 to 5 Seconds]
```

---

## 4. The 10 Coded Production SMS Messages

All 10 messages are natively bilingual (Swahili & English), dynamically injecting guest names, host names, property titles, check-in dates, and arrival times:

| # | Event Trigger | Recipient | SMS Template Copy |
| :--- | :--- | :--- | :--- |
| **1** | `BOOKING_CONFIRMED_CUSTOMER` | **Guest** | `X-OM: Habari {{customer_name}}! Malipo yamethibitishwa. Your stay at {{property_title}} is confirmed. Check in {{check_in_date}} at {{check_in_time}}, check out {{check_out_date}} at {{check_out_time}}. Host: {{host_name}}. Ref {{booking_code}}.' |
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

## 5. Engineering Safeguards & Delivery Guarantees

- **Tanzanian Phone Normalization:** Strict regex sanitization supporting `0...`, `255...`, `+255...`, or `00255...`, normalized to carrier format `255[67]XXXXXXXX`.
- **Dual-Segment Character Bounds:** Automatically caps SMS copy at 320 characters to guarantee messages fit in standard 2 GSM segments, preventing unexpected carrier costs.
- **Atomic Locking (`FOR UPDATE SKIP LOCKED`):** Protects against worker concurrency race conditions.
- **Exponential Backoff Retry:** If Textify or local carrier networks return retryable status codes (`429`, `503`, `network_error`), the worker calculates exponential backoff retry intervals up to 5 attempts.

---

## 6. Automated Test Suite (100% Pass)

To run the full unit test suite locally:

```bash
npm test
```

### Test Results:
```text
✔ worker auth requires an exact configured secret or exact service-role bearer (81ms)
✔ request contract only permits a capped batch limit (15ms)
✔ claim rows accept only the supported channels and categories (1ms)
✔ Tanzanian mobile normalization is conservative (1ms)
✔ SMS payload uses only claimed copy, caps it at 320 characters, and optionally adds sender (26ms)
✔ marketing SMS requires exact claim-time consent proof for its channel (1ms)
✔ WhatsApp sends only the approved template and fixed booking parameters (1ms)
✔ WhatsApp rejects absent configuration, missing booking vars, and marketing (1ms)
✔ sender validation, provider references, and retry statuses are bounded (1ms)
✔ X-OM WhatsApp uses the own business number unless shared source is explicitly configured (1ms)
✔ SMS includes the brand with shared senders but empty messages remain blocked (1ms)
✔ SMS content always mentions guest name for guest and host name for host (1ms)
✔ host WhatsApp templates do not greet a host with the guest's name (1ms)

ℹ tests 13
ℹ pass 13
ℹ fail 0
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
