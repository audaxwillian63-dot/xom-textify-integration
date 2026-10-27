-- X-OM Textify messaging center (SMS + approved WhatsApp templates).
--
-- Provider sends remain disabled until an API key, sender name/template and
-- private worker schedule are configured. Marketing is always opt-in twice:
-- at provider level and in each recipient's notification preferences.

do $prerequisites$
begin
  if to_regclass('public.notification_preferences') is null
     or to_regclass('public.notification_templates') is null
     or to_regclass('public.notification_queue') is null
     or to_regclass('public.notification_deliveries') is null
     or to_regclass('public.notification_broadcasts') is null
     or to_regclass('public.notifications') is null
     or to_regclass('public.profiles') is null
     or to_regprocedure('public.makazi_ensure_notification_prefs(uuid)') is null
     or to_regprocedure('public.makazi_enqueue_notification(uuid,text,text,uuid,text,text,text,text,text,text,jsonb,text,text)') is null
     or to_regprocedure('public.xom_admin_audience_ids(text,uuid[])') is null then
    raise exception 'X-OM communication engine and admin broadcasts are required before Textify';
  end if;
end
$prerequisites$;

create table if not exists public.textify_delivery_settings (
  id smallint primary key default 1 check (id = 1),
  enabled boolean not null default false,
  sms_enabled boolean not null default false,
  whatsapp_enabled boolean not null default false,
  marketing_enabled boolean not null default false,
  enabled_at timestamptz,
  updated_at timestamptz not null default now()
);

alter table public.textify_delivery_settings enable row level security;
revoke all on table public.textify_delivery_settings
  from public, anon, authenticated;
grant select on table public.textify_delivery_settings to service_role;

insert into public.textify_delivery_settings (id)
values (1)
on conflict (id) do nothing;

alter table public.notification_deliveries
  add column if not exists attempts integer not null default 0,
  add column if not exists next_attempt_at timestamptz not null default now(),
  add column if not exists last_attempt_at timestamptz;

alter table public.notification_deliveries
  drop constraint if exists notification_deliveries_status_check;
alter table public.notification_deliveries
  add constraint notification_deliveries_status_check
  check (status in (
    'pending', 'sending', 'sent', 'delivered', 'failed', 'skipped'
  ));

create index if not exists notification_deliveries_textify_due_idx
  on public.notification_deliveries (channel, next_attempt_at, created_at)
  where channel in ('sms', 'whatsapp') and status = 'pending';

create or replace function public.xom_textify_transactional_template_codes()
returns text[]
language sql
immutable
as $function$
  select array[
    'PAYMENT_FAILED_CUSTOMER',
    'BOOKING_CONFIRMED_CUSTOMER',
    'BOOKING_CONFIRMED_AGENT',
    'CANCEL_DONE_CUSTOMER',
    'HOST_BOOKING_CANCELLED',
    'STAY_TOMORROW_CUSTOMER',
    'HOST_STAY_TOMORROW',
    'STAY_CHECKIN_WINDOW',
    'HOST_STAY_BEFORE_CHECKOUT',
    'GUEST_STAY_BEFORE_CHECKOUT'
  ]::text[];
$function$;

revoke all on function public.xom_textify_transactional_template_codes()
  from public, anon, authenticated;
grant execute on function public.xom_textify_transactional_template_codes()
  to service_role;

create or replace function public.xom_set_textify_delivery_enabled(
  p_enabled boolean,
  p_sms_enabled boolean default true,
  p_whatsapp_enabled boolean default false,
  p_marketing_enabled boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_previous boolean := false;
  v_enabled boolean := coalesce(p_enabled, false);
  v_sms boolean := v_enabled and coalesce(p_sms_enabled, false);
  v_whatsapp boolean := v_enabled and coalesce(p_whatsapp_enabled, false);
  v_marketing boolean := v_enabled and coalesce(p_marketing_enabled, false);
  v_enabled_at timestamptz;
begin
  if session_user <> 'postgres'
     and coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'Service role required';
  end if;

  select enabled, enabled_at into v_previous, v_enabled_at
  from public.textify_delivery_settings
  where id = 1
  for update;

  if v_enabled
     and (not coalesce(v_previous, false) or v_enabled_at is null) then
    v_enabled_at := now();
  elsif not v_enabled then
    v_enabled_at := null;
  end if;

  update public.textify_delivery_settings
  set enabled = v_enabled,
      sms_enabled = v_sms,
      whatsapp_enabled = v_whatsapp,
      marketing_enabled = v_marketing,
      enabled_at = v_enabled_at,
      updated_at = now()
  where id = 1;

  if v_sms then
    update public.notification_templates
    set channels = array_append(channels, 'sms')
    where code = any(public.xom_textify_transactional_template_codes())
      and active
      and not ('sms' = any(channels));
  else
    update public.notification_templates
    set channels = array_remove(channels, 'sms')
    where code = any(public.xom_textify_transactional_template_codes())
      and 'sms' = any(channels);
  end if;

  if v_whatsapp then
    update public.notification_templates
    set channels = array_append(channels, 'whatsapp')
    where code = any(public.xom_textify_transactional_template_codes())
      and active
      and not ('whatsapp' = any(channels));
  else
    update public.notification_templates
    set channels = array_remove(channels, 'whatsapp')
    where code = any(public.xom_textify_transactional_template_codes())
      and 'whatsapp' = any(channels);
  end if;

  if not v_enabled then
    update public.notification_deliveries
    set status = 'skipped',
        error = 'textify_delivery_disabled',
        updated_at = now()
    where channel in ('sms', 'whatsapp')
      and status in ('pending', 'sending');
  elsif not v_sms then
    update public.notification_deliveries
    set status = 'skipped', error = 'textify_sms_disabled', updated_at = now()
    where channel = 'sms' and status in ('pending', 'sending');
  end if;

  if v_enabled and not v_whatsapp then
    update public.notification_deliveries
    set status = 'skipped', error = 'textify_whatsapp_disabled', updated_at = now()
    where channel = 'whatsapp' and status in ('pending', 'sending');
  end if;

  return jsonb_build_object(
    'enabled', v_enabled,
    'sms_enabled', v_sms,
    'whatsapp_enabled', v_whatsapp,
    'marketing_enabled', v_marketing,
    'enabled_at', v_enabled_at
  );
end;
$function$;

revoke all on function public.xom_set_textify_delivery_enabled(
  boolean, boolean, boolean, boolean
) from public, anon, authenticated;
grant execute on function public.xom_set_textify_delivery_enabled(
  boolean, boolean, boolean, boolean
) to service_role;

create or replace function public.xom_claim_textify_deliveries(
  p_limit integer default 10
)
returns table (
  delivery_id uuid,
  queue_id uuid,
  recipient_id uuid,
  channel text,
  title text,
  body text,
  category text,
  purpose text,
  priority text,
  template_code text,
  event_type text,
  entity_type text,
  entity_id text,
  dedupe_key text,
  meta jsonb,
  attempts integer,
  phone text
)
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_settings public.textify_delivery_settings%rowtype;
begin
  if session_user <> 'postgres'
     and coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'Service role required';
  end if;

  select * into v_settings
  from public.textify_delivery_settings
  where id = 1;

  if not coalesce(v_settings.enabled, false)
     or v_settings.enabled_at is null then
    return;
  end if;

  update public.notification_deliveries d
  set status = 'pending',
      next_attempt_at = now(),
      error = coalesce(d.error, 'stale_worker_claim'),
      updated_at = now()
  where d.channel in ('sms', 'whatsapp')
    and d.status = 'sending'
    and d.updated_at < now() - interval '15 minutes'
    and d.attempts < 5;

  update public.notification_deliveries d
  set status = 'failed',
      error = coalesce(d.error, 'retry_limit_reached'),
      updated_at = now()
  where d.channel in ('sms', 'whatsapp')
    and d.status in ('pending', 'sending')
    and d.attempts >= 5;

  -- A user can withdraw consent after a message was queued. Re-check at the
  -- final claim and permanently skip that old delivery.
  update public.notification_deliveries d
  set status = 'skipped',
      error = case
        when d.channel = 'sms' then 'sms_not_enabled_by_recipient'
        else 'whatsapp_not_enabled_by_recipient'
      end,
      updated_at = now()
  from public.notification_queue q
  where q.id = d.queue_id
    and d.channel in ('sms', 'whatsapp')
    and d.status = 'pending'
    and (
      (d.channel = 'sms' and not coalesce((
        select p.sms_enabled
        from public.notification_preferences p
        where p.user_id = d.recipient_id
      ), false))
      or (d.channel = 'whatsapp' and not coalesce((
        select p.whatsapp_enabled
        from public.notification_preferences p
        where p.user_id = d.recipient_id
      ), false))
    );

  update public.notification_deliveries d
  set status = 'skipped',
      error = 'marketing_consent_required',
      updated_at = now()
  from public.notification_queue q
  where q.id = d.queue_id
    and d.channel in ('sms', 'whatsapp')
    and d.status = 'pending'
    and (
      coalesce(q.meta->>'broadcast_purpose', '') = 'marketing'
      or q.category = 'marketing'
      or q.purpose = 'marketing'
    )
    and (
      not coalesce(v_settings.marketing_enabled, false)
      or not coalesce((
        select p.marketing
        from public.notification_preferences p
        where p.user_id = d.recipient_id
      ), false)
    );

  -- The only approved WhatsApp template in v1 is the booking template used by
  -- transactional events. Marketing and free-form admin broadcasts must never
  -- reach the provider as that template.
  update public.notification_deliveries d
  set status = 'skipped',
      error = 'whatsapp_template_unavailable',
      updated_at = now()
  from public.notification_queue q
  where q.id = d.queue_id
    and d.channel = 'whatsapp'
    and d.status = 'pending'
    and (
      q.event_type = 'ADMIN_BROADCAST'
      or coalesce(q.meta->>'broadcast_purpose', '') = 'marketing'
      or q.category = 'marketing'
      or q.purpose = 'marketing'
    );

  update public.notification_deliveries d
  set status = 'skipped',
      error = 'recipient_phone_missing',
      updated_at = now()
  from public.profiles p
  where p.id = d.recipient_id
    and d.channel in ('sms', 'whatsapp')
    and d.status = 'pending'
    and coalesce(trim(p.phone), '') = '';

  with ranked as (
    select
      d.id,
      d.status,
      row_number() over (
        partition by d.recipient_id, d.channel, q.template_code, q.event_id
        order by d.created_at, d.id
      ) as occurrence
    from public.notification_deliveries d
    join public.notification_queue q on q.id = d.queue_id
    where d.channel in ('sms', 'whatsapp')
      and d.status in ('pending', 'sending', 'sent', 'delivered')
      and d.created_at >= v_settings.enabled_at
      and q.event_id is not null
  )
  update public.notification_deliveries d
  set status = 'skipped',
      error = 'duplicate_booking_event',
      updated_at = now()
  from ranked r
  where d.id = r.id
    and r.status = 'pending'
    and r.occurrence > 1;

  return query
  with picked as (
    select d.id
    from public.notification_deliveries d
    join public.notification_queue q on q.id = d.queue_id
    join public.profiles profile on profile.id = d.recipient_id
    join public.notification_preferences pref on pref.user_id = d.recipient_id
    where d.channel in ('sms', 'whatsapp')
      and d.status = 'pending'
      and d.next_attempt_at <= now()
      and d.created_at >= v_settings.enabled_at
      and coalesce(trim(profile.phone), '') <> ''
      and case d.channel
        when 'sms' then v_settings.sms_enabled and pref.sms_enabled
        when 'whatsapp' then v_settings.whatsapp_enabled and pref.whatsapp_enabled
        else false
      end
      and (
        (
          coalesce(q.meta->>'broadcast_purpose', '') <> 'marketing'
          and q.category <> 'marketing'
          and q.purpose <> 'marketing'
        )
        or (v_settings.marketing_enabled and pref.marketing)
      )
    order by
      case q.priority
        when 'critical' then 0
        when 'high' then 1
        when 'normal' then 2
        else 3
      end,
      d.created_at
    limit greatest(1, least(coalesce(p_limit, 10), 25))
    for update of d skip locked
  ), claimed as (
    update public.notification_deliveries d
    set status = 'sending',
        attempts = d.attempts + 1,
        last_attempt_at = now(),
        updated_at = now()
    from picked p
    where d.id = p.id
    returning d.*
  )
  select
    d.id,
    d.queue_id,
    d.recipient_id,
    d.channel,
    q.title,
    q.body,
    case
      when coalesce(q.meta->>'broadcast_purpose', '') = 'marketing'
        or q.category = 'marketing'
        or q.purpose = 'marketing'
        then 'marketing'
      when q.category in ('bookings', 'payments', 'messages', 'alerts')
        then q.category
      else 'alerts'
    end,
    q.purpose,
    q.priority,
    q.template_code,
    q.event_type,
    q.entity_type,
    q.entity_id,
    q.dedupe_key,
    coalesce(q.meta, '{}'::jsonb) || case
      when coalesce(q.meta->>'broadcast_purpose', '') = 'marketing'
        or q.category = 'marketing'
        or q.purpose = 'marketing'
        then jsonb_build_object(
          'consent_verified', true,
          'consent_channel', d.channel
        )
      else '{}'::jsonb
    end,
    d.attempts,
    profile.phone
  from claimed d
  join public.notification_queue q on q.id = d.queue_id
  join public.profiles profile on profile.id = d.recipient_id
  order by d.created_at;
end;
$function$;

revoke all on function public.xom_claim_textify_deliveries(integer)
  from public, anon, authenticated;
grant execute on function public.xom_claim_textify_deliveries(integer)
  to service_role;

create or replace function public.xom_complete_textify_delivery(
  p_delivery_id uuid,
  p_success boolean,
  p_provider_ref text default null,
  p_error text default null,
  p_retryable boolean default true
)
returns text
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_delivery public.notification_deliveries%rowtype;
  v_status text;
  v_delay interval;
begin
  if session_user <> 'postgres'
     and coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'Service role required';
  end if;

  select * into v_delivery
  from public.notification_deliveries
  where id = p_delivery_id
    and channel in ('sms', 'whatsapp')
  for update;

  if not found then
    raise exception 'Textify delivery not found';
  end if;

  if v_delivery.status in ('sent', 'delivered', 'skipped') then
    return v_delivery.status;
  end if;

  if coalesce(p_success, false) then
    v_status := 'sent';
    update public.notification_deliveries
    set status = v_status,
        provider_ref = nullif(left(coalesce(p_provider_ref, ''), 255), ''),
        error = null,
        updated_at = now()
    where id = p_delivery_id;
  elsif not coalesce(p_retryable, true) then
    v_status := 'skipped';
    update public.notification_deliveries
    set status = v_status,
        error = left(coalesce(nullif(p_error, ''), 'non_retryable'), 1000),
        updated_at = now()
    where id = p_delivery_id;
  elsif v_delivery.attempts >= 5 then
    v_status := 'failed';
    update public.notification_deliveries
    set status = v_status,
        error = left(coalesce(nullif(p_error, ''), 'retry_limit_reached'), 1000),
        updated_at = now()
    where id = p_delivery_id;
  else
    v_status := 'pending';
    v_delay := case v_delivery.attempts
      when 1 then interval '1 minute'
      when 2 then interval '5 minutes'
      when 3 then interval '20 minutes'
      else interval '1 hour'
    end;
    update public.notification_deliveries
    set status = v_status,
        next_attempt_at = now() + v_delay,
        error = left(coalesce(nullif(p_error, ''), 'temporary_provider_error'), 1000),
        updated_at = now()
    where id = p_delivery_id;
  end if;

  return v_status;
end;
$function$;

revoke all on function public.xom_complete_textify_delivery(
  uuid, boolean, text, text, boolean
) from public, anon, authenticated;
grant execute on function public.xom_complete_textify_delivery(
  uuid, boolean, text, text, boolean
) to service_role;

-- Preserve the existing admin preview + confirmation controls, but make the
-- selected channels real and require consent before any marketing row exists.
create or replace function public.xom_admin_broadcast_send(
  p_audience text,
  p_ids uuid[],
  p_title text,
  p_body text,
  p_category text,
  p_priority text,
  p_channels text[],
  p_route text,
  p_reason text,
  p_confirm_count int,
  p_purpose text default 'inform'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  ids uuid[];
  n integer;
  queued integer := 0;
  rid uuid;
  uid uuid;
  qid uuid;
  prefs public.notification_preferences%rowtype;
  settings public.textify_delivery_settings%rowtype;
  requested text[];
  selected text[];
  purpose_value text := lower(coalesce(nullif(trim(p_purpose), ''), 'inform'));
  priority_value text := lower(coalesce(nullif(trim(p_priority), ''), 'normal'));
  category_value text := lower(coalesce(nullif(trim(p_category), ''), 'system'));
  delivery_category_value text;
begin
  if not public.is_admin() then raise exception 'Admin only'; end if;
  if coalesce(trim(p_title), '') = '' or coalesce(trim(p_body), '') = '' then
    raise exception 'Title and message are required';
  end if;
  if purpose_value not in ('inform', 'marketing') then
    raise exception 'Choose transactional or marketing';
  end if;
  if priority_value not in ('low', 'normal', 'high', 'critical') then
    raise exception 'Invalid priority';
  end if;
  if purpose_value = 'marketing' and priority_value in ('critical', 'high') then
    raise exception 'Marketing messages cannot use transactional priority';
  end if;
  if category_value not in (
    'system', 'alerts', 'bookings', 'payments', 'messages', 'promotions'
  ) then
    raise exception 'Invalid category';
  end if;
  if category_value = 'promotions' and purpose_value <> 'marketing' then
    raise exception 'Promotions require marketing purpose and consent';
  end if;

  delivery_category_value := case
    when purpose_value = 'marketing' then 'marketing'
    when category_value = 'system' then 'alerts'
    else category_value
  end;

  select coalesce(array_agg(distinct c), '{}'::text[]) into requested
  from unnest(coalesce(p_channels, array['in_app'])) c
  where c in ('in_app', 'push', 'sms', 'whatsapp');
  if coalesce(array_length(requested, 1), 0) = 0 then
    raise exception 'Choose at least one supported channel';
  end if;
  if not ('in_app' = any(requested)) then
    raise exception 'In-app delivery is required for admin broadcasts';
  end if;
  if 'whatsapp' = any(requested) then
    raise exception
      'WhatsApp admin broadcasts are unavailable until a broadcast template is approved';
  end if;

  ids := public.xom_admin_audience_ids(p_audience, p_ids);
  n := coalesce(array_length(ids, 1), 0);
  if n <= 0 then raise exception 'Audience is empty'; end if;
  if p_confirm_count is distinct from n then
    raise exception 'Confirm the audience count (%) before sending', n;
  end if;

  select * into settings from public.textify_delivery_settings where id = 1;

  insert into public.notification_broadcasts (
    admin_id, audience, audience_count, title, body, category, priority,
    purpose, channels, route, reason, status
  ) values (
    auth.uid(), p_audience, n, left(trim(p_title), 180), left(trim(p_body), 1000),
    category_value, priority_value, purpose_value, requested,
    p_route, nullif(trim(p_reason), ''), 'sent'
  ) returning id into rid;

  foreach uid in array ids loop
    prefs := public.makazi_ensure_notification_prefs(uid);
    if purpose_value = 'marketing' and not prefs.marketing then
      continue;
    end if;

    selected := requested;
    if not prefs.push_enabled then selected := array_remove(selected, 'push'); end if;
    if not prefs.sms_enabled
       or not coalesce(settings.enabled and settings.sms_enabled, false)
       or (purpose_value = 'marketing' and not settings.marketing_enabled) then
      selected := array_remove(selected, 'sms');
    end if;
    if not prefs.whatsapp_enabled
       or not coalesce(settings.enabled and settings.whatsapp_enabled, false)
       or purpose_value = 'marketing' then
      -- Defense in depth if the supported-channel validation changes later.
      selected := array_remove(selected, 'whatsapp');
    end if;
    if coalesce(array_length(selected, 1), 0) = 0 then
      continue;
    end if;

    qid := public.makazi_enqueue_notification(
      p_recipient := uid,
      p_template_code := null,
      p_event_type := 'ADMIN_BROADCAST',
      p_title := left(trim(p_title), 180),
      p_body := left(trim(p_body), 1000),
      p_route := coalesce(p_route, '/notifications'),
      p_entity_type := 'broadcast',
      p_entity_id := rid::text,
      p_dedupe_key := 'ADMIN_BROADCAST:' || rid::text || ':' || uid::text,
      p_force_priority := priority_value
    );

    if qid is not null then
      update public.notification_queue
      set channels = selected,
          category = delivery_category_value,
          meta = coalesce(meta, '{}'::jsonb) || jsonb_build_object(
            'broadcast_id', rid,
            'broadcast_purpose', purpose_value,
            'requested_channels', requested,
            'original_category', category_value
          )
      where id = qid;

      -- makazi_enqueue_notification dispatches due rows immediately, before
      -- this function can replace its default in-app-only channel list. Add
      -- any selected external deliveries inside this same transaction. Future
      -- quiet-hours rows remain queued and will use the corrected channel list
      -- when the normal dispatcher runs.
      insert into public.notification_deliveries (
        queue_id, notification_id, recipient_id, channel, status
      )
      select
        q.id,
        nullif(q.meta->>'notification_id', '')::uuid,
        q.recipient_id,
        channel_name,
        'pending'
      from public.notification_queue q
      cross join unnest(selected) as chosen(channel_name)
      where q.id = qid
        and q.status = 'sent'
        and channel_name <> 'in_app'
        and not exists (
          select 1
          from public.notification_deliveries existing
          where existing.queue_id = q.id
            and existing.channel = channel_name
        );

      -- The in-app notification was also created before the broadcast metadata
      -- reached the queue. Keep its category and audit metadata consistent.
      update public.notifications notification
      set category = delivery_category_value,
          meta = coalesce(notification.meta, '{}'::jsonb) || jsonb_build_object(
            'broadcast_id', rid,
            'broadcast_purpose', purpose_value,
            'requested_channels', requested,
            'original_category', category_value
          )
      from public.notification_deliveries delivery
      where delivery.queue_id = qid
        and delivery.channel = 'in_app'
        and delivery.notification_id = notification.id;

      if exists (
        select 1 from public.notification_queue
        where id = qid
          and status in ('queued', 'sending', 'sent', 'partial')
      ) then
        queued := queued + 1;
      end if;
    end if;
  end loop;

  update public.notification_broadcasts
  set audience_count = queued,
      status = case when queued > 0 then 'sent' else 'suppressed' end
  where id = rid;

  begin
    perform public.emit_platform_event(
      'ADMIN_BROADCAST', 'broadcast', rid::text, 'info',
      jsonb_build_object(
        'audience', p_audience,
        'audience_total', n,
        'eligible_count', queued,
        'title', left(trim(p_title), 180),
        'channels', requested,
        'reason', p_reason,
        'purpose', purpose_value
      ),
      null, 'sent', rid::text, 'admin', 'ADMIN_BROADCAST:' || rid::text
    );
  exception when others then
    null;
  end;

  return jsonb_build_object(
    'ok', true,
    'broadcast_id', rid,
    'audience_total', n,
    'sent', queued
  );
end;
$function$;

revoke all on function public.xom_admin_broadcast_send(
  text, uuid[], text, text, text, text, text[], text, text, integer, text
) from public, anon;
grant execute on function public.xom_admin_broadcast_send(
  text, uuid[], text, text, text, text, text[], text, text, integer, text
) to authenticated;

-- Five-minute holds are too short for SMS. A late message would tell a guest
-- to pay for inventory that may already have been released.
update public.notification_templates
set channels = array_remove(channels, 'sms')
where code in ('HOLD_EXPIRES_10M', 'HOLD_EXPIRES_2M')
  and 'sms' = any(channels);

-- Initial channel state follows the disabled provider row. This also cleans up
-- legacy pending-channel declarations that had no sender behind them.
select public.xom_set_textify_delivery_enabled(
  enabled,
  sms_enabled,
  whatsapp_enabled,
  marketing_enabled
)
from public.textify_delivery_settings
where id = 1;

comment on table public.textify_delivery_settings is
  'Server-only kill switches for Textify SMS, WhatsApp and opted-in marketing.';
comment on function public.xom_claim_textify_deliveries(integer) is
  'Claims consent-checked X-OM SMS/WhatsApp deliveries for the private Textify worker.';
