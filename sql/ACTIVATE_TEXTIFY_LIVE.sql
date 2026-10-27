-- ============================================================================
-- MAKAZI (X-OM) Live Textify SMS Activation & Personalization Patch
-- Sender ID: XOM
-- Country: Tanzania (255)
-- Run this in your Supabase SQL Editor to make Textify live immediately.
-- ============================================================================

begin;

-- 1. Ensure Textify Delivery Settings are globally active for SMS
create table if not exists public.textify_delivery_settings (
  id smallint primary key default 1 check (id = 1),
  enabled boolean not null default false,
  sms_enabled boolean not null default false,
  whatsapp_enabled boolean not null default false,
  marketing_enabled boolean not null default false,
  enabled_at timestamptz,
  updated_at timestamptz not null default now()
);

insert into public.textify_delivery_settings (id, enabled, sms_enabled, whatsapp_enabled, marketing_enabled, enabled_at)
values (1, true, true, false, false, now())
on conflict (id) do update
set enabled = true,
    sms_enabled = true,
    whatsapp_enabled = false,
    marketing_enabled = false,
    enabled_at = coalesce(textify_delivery_settings.enabled_at, now()),
    updated_at = now();

-- 2. Upgrade xom_booking_notify_vars to reliably provide BOTH customer_name and host_name
create or replace function public.xom_booking_notify_vars(p_booking uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  b record;
  pname text;
  cin text;
  cout text;
  nights int;
  date_in text;
  date_out text;
  cname text;
  hname text;
begin
  select * into b from public.short_stay_bookings where id = p_booking;
  if not found then
    return '{}'::jsonb;
  end if;

  select
    coalesce(nullif(title, ''), 'your stay'),
    coalesce(nullif(check_in_time, ''), '14:00'),
    coalesce(nullif(check_out_time, ''), '11:00')
  into pname, cin, cout
  from public.properties where id = b.property_id;

  nights := greatest(coalesce(b.nights, (b.check_out - b.check_in)), 1);
  date_in := to_char(b.check_in, 'Dy, DD Mon YYYY');
  date_out := to_char(b.check_out, 'Dy, DD Mon YYYY');

  -- Extract clean customer (guest) name
  select coalesce(nullif(trim(p.name), ''), nullif(trim(b.customer_name), ''), 'Guest')
  into cname
  from public.profiles p where p.id = b.customer_id;
  cname := coalesce(cname, coalesce(nullif(trim(b.customer_name), ''), 'Guest'));

  -- Extract clean host name
  select coalesce(nullif(trim(p.name), ''), 'Host')
  into hname
  from public.profiles p where p.id = b.broker_id;
  if hname is null or hname = 'Host' then
    select coalesce(nullif(trim(p.name), ''), 'Host')
    into hname
    from public.properties prop
    join public.profiles p on p.id = prop.owner_id
    where prop.id = b.property_id;
  end if;
  hname := coalesce(hname, 'Host');

  return jsonb_build_object(
    'property_name', coalesce(pname, coalesce(b.place_name, 'your stay')),
    'property_title', coalesce(pname, coalesce(b.place_name, 'your stay')),
    'customer_name', cname,
    'host_name', hname,
    'nights', nights,
    'guests', coalesce(b.guests, 1),
    'rooms_count', coalesce((to_jsonb(b)->>'rooms_count')::int, 1),
    'room_type', coalesce(b.room_type, to_jsonb(b)->>'room_label', 'unit'),
    'booking_code', coalesce(b.booking_code, left(b.id::text, 8)),
    'booking_id', b.id,
    'payment_status', coalesce(b.payment_status, 'none'),
    'booking_status', coalesce(b.status, 'hold'),
    'check_in_time', coalesce(cin, '14:00'),
    'check_out_time', coalesce(cout, '11:00'),
    'check_in_date', date_in,
    'check_out_date', date_out,
    'check_in_label', date_in || ' · ' || coalesce(cin, '14:00') || ' EAT',
    'check_out_label', date_out || ' · ' || coalesce(cout, '11:00') || ' EAT',
    'dates_suffix', ' (' || date_in || ' → ' || date_out || ')',
    'total_tzs', coalesce(b.total_tzs, 0),
    'cancel_body', case
      when coalesce(b.refund_tzs, 0) > 0
        then 'A guest refund has affected this booking''s settlement.'
      else 'A booking has been cancelled.'
    end
  );
end;
$$;

-- 3. Upgrade all SMS templates to explicitly address Guest by name and Host by name
update public.notification_templates
set body_template = case code
  -- Guest SMS Templates
  when 'BOOKING_CONFIRMED_CUSTOMER' then
    'Habari {{customer_name}}! Malipo yamethibitishwa. Your stay at {{property_title}} is confirmed. Check in {{check_in_date}} at {{check_in_time}}, check out {{check_out_date}} at {{check_out_time}}. Host: {{host_name}}. Ref {{booking_code}}.'
  when 'STAY_TOMORROW_CUSTOMER' then
    'Habari {{customer_name}}! Safari yako {{property_title}} inaanza kesho. Check in {{check_in_date}} saa {{check_in_time}}. Host: {{host_name}}. Ref {{booking_code}}.'
  when 'STAY_CHECKIN_WINDOW' then
    'Habari {{customer_name}}! Milango iko wazi kwa ajili ya check-in {{property_title}}. Karibu sana! Host: {{host_name}}. Ref {{booking_code}}.'
  when 'GUEST_STAY_BEFORE_CHECKOUT' then
    'Habari {{customer_name}}! Ukumbusho: Check-out ya stay yako {{property_title}} ni kesho {{check_out_date}} saa {{check_out_time}}. Ref {{booking_code}}.'

  -- Host SMS Templates
  when 'BOOKING_CONFIRMED_AGENT' then
    'Habari {{host_name}}! Una booking mpya kutoka kwa {{customer_name}} kwenye {{property_name}}. Check in {{check_in_date}} saa {{check_in_time}}, check out {{check_out_date}} saa {{check_out_time}}. Ref {{booking_code}}.'
  when 'HOST_STAY_TOMORROW' then
    'Habari {{host_name}}! Mgeni {{customer_name}} anawasili kesho kwenye {{property_name}}. Check in kuanzia saa {{check_in_time}}. Ref {{booking_code}}.'
  when 'HOST_STAY_BEFORE_CHECKOUT' then
    'Habari {{host_name}}! Mgeni {{customer_name}} anafanya check-out kesho {{check_out_date}} kufikia saa {{check_out_time}} kwenye {{property_name}}.'

  -- Other Transactional Notices
  when 'CANCEL_DONE_CUSTOMER' then
    'Habari {{customer_name}}! Booking yako {{property_title}} (Ref {{booking_code}}) imeahirishwa kikamilifu.'
  when 'HOST_BOOKING_CANCELLED' then
    'Habari {{host_name}}! Booking ya {{customer_name}} kwenye {{property_name}} (Ref {{booking_code}}) imeahirishwa na kalenda imefunguliwa.'
  when 'PAYMENT_FAILED_CUSTOMER' then
    'Habari {{customer_name}}! Malipo ya stay yako {{property_title}} hayajafanikiwa. Tafadhali jaribu tena kabla muda wa hold haujaisha.'
  else body_template
end,
channels = case
  when not ('sms' = any(channels)) then array_append(channels, 'sms')
  else channels
end
where code in (
  'BOOKING_CONFIRMED_CUSTOMER',
  'BOOKING_CONFIRMED_AGENT',
  'STAY_TOMORROW_CUSTOMER',
  'HOST_STAY_TOMORROW',
  'STAY_CHECKIN_WINDOW',
  'HOST_STAY_BEFORE_CHECKOUT',
  'GUEST_STAY_BEFORE_CHECKOUT',
  'CANCEL_DONE_CUSTOMER',
  'HOST_BOOKING_CANCELLED',
  'PAYMENT_FAILED_CUSTOMER'
);

-- 4. Enable transactional SMS for all registered users with a phone
alter table public.notification_preferences
  alter column sms_enabled set default true;

update public.notification_preferences pref
set sms_enabled = true
from public.profiles p
where p.id = pref.user_id
  and coalesce(trim(p.phone), '') <> ''
  and not pref.sms_enabled;

-- 5. Unpause the background scheduler job in pg_cron
do $$
begin
  if exists (select 1 from cron.job where jobname = 'xom-send-textify-message') then
    perform cron.alter_job(
      job_id := (select jobid from cron.job where jobname = 'xom-send-textify-message' limit 1),
      active := true
    );
  else
    perform cron.schedule(
      'xom-send-textify-message',
      '* * * * *',
      $cron$
      select net.http_post(
        url := 'https://tuxdoasyrucqblnxtjky.supabase.co/functions/v1/send-textify-message',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'x-xom-textify-worker-secret',
          (select decrypted_secret from vault.decrypted_secrets where name = 'xom_textify_worker_secret')
        ),
        body := jsonb_build_object('limit', 25),
        timeout_milliseconds := 20000
      );
      $cron$
    );
  end if;
end;
$$;

commit;

-- ============================================================================
-- VERIFICATION REPORT
-- ============================================================================
select
  s.enabled as system_enabled,
  s.sms_enabled as sms_active,
  s.whatsapp_enabled as whatsapp_active,
  s.marketing_enabled as marketing_active,
  s.enabled_at
from public.textify_delivery_settings s
where id = 1;

select jobname, schedule, active
from cron.job
where jobname in ('xom-send-transactional-email', 'xom-send-textify-message');

select code, body_template
from public.notification_templates
where code in (
  'BOOKING_CONFIRMED_CUSTOMER',
  'BOOKING_CONFIRMED_AGENT',
  'STAY_TOMORROW_CUSTOMER',
  'HOST_STAY_TOMORROW',
  'STAY_CHECKIN_WINDOW'
);
