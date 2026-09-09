-- Practice Pilot uses one monthly generation-credit pool across the account
-- audio endpoint and API v1 practice generation. The account path already
-- reserves from usage_counters.audio_renders_count through
-- pm_increment_usage_counter(); the API path joins that same atomic counter.

create or replace function public.api_v1_seed_usage_limits()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  insert into public.api_organization_usage_limits (
    organization_id,
    event_type,
    limit_quantity,
    enabled
  )
  select
    new.id,
    metric,
    case
      when new.plan = 'pilot' and metric = 'practice_generation' then 40
      else null
    end,
    new.plan = 'pilot' and metric = 'practice_generation'
  from unnest(array[
    'practice_generation',
    'script_generation',
    'audio_generation',
    'audio_minutes',
    'regeneration',
    'api_request'
  ]) as metrics(metric)
  on conflict (organization_id, event_type) do nothing;
  return new;
end;
$$;

insert into public.api_organization_usage_limits (
  organization_id,
  event_type,
  period,
  limit_quantity,
  enabled
)
select distinct
  reservation.organization_id,
  'practice_generation',
  'month',
  40,
  true
from public.practice_pilot_seat_reservations reservation
join public.api_organizations organization
  on organization.id = reservation.organization_id
where reservation.organization_id is not null
  and reservation.status in ('pending', 'active')
  and organization.plan = 'pilot'
on conflict (organization_id, event_type) do update
set period = 'month',
    limit_quantity = 40,
    enabled = true,
    updated_at = clock_timestamp();

create or replace function public.api_v1_reserve_usage(
  p_organization_id uuid,
  p_event_key text,
  p_event_type text,
  p_resource_type text,
  p_resource_id uuid,
  p_quantity numeric,
  p_metadata jsonb default '{}'::jsonb
)
returns table (
  allowed boolean,
  replayed boolean,
  reason text,
  used_quantity numeric,
  limit_quantity numeric
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_observed_at timestamptz := clock_timestamp();
  v_period_start timestamptz := date_trunc('month', v_observed_at);
  v_period_end timestamptz := v_period_start + interval '1 month';
  v_limit public.api_organization_usage_limits%rowtype;
  v_existing public.api_usage_ledger%rowtype;
  v_used numeric;
  v_replay_limit numeric;
  v_pilot_user_id uuid;
  v_shared_allowed boolean;
  v_shared_used integer;
  v_shared_remaining integer;
  v_shared_credit_already_consumed boolean := false;
begin
  if p_event_key is null or char_length(p_event_key) not between 1 and 240
     or p_event_key <> btrim(p_event_key)
     or p_event_type not in ('practice_generation','script_generation','audio_generation','audio_minutes','regeneration','api_request')
     or p_resource_type is null or char_length(p_resource_type) not between 1 and 80
     or p_resource_id is null or p_quantity is null or p_quantity <= 0
     or p_metadata is null or jsonb_typeof(p_metadata) <> 'object' then
    raise exception 'api_v1_invalid_usage_reservation' using errcode = '22023';
  end if;

  if not exists (
    select 1
    from public.api_organizations
    where id = p_organization_id
      and status = 'active'
  ) then
    return query select false, false, 'organization_inactive'::text, null::numeric, null::numeric;
    return;
  end if;

  if p_event_type = 'practice_generation' then
    select reservation.user_id
    into v_pilot_user_id
    from public.practice_pilot_seat_reservations reservation
    join public.api_organizations organization
      on organization.id = reservation.organization_id
    join public.user_entitlements entitlement
      on entitlement.user_id = reservation.user_id
    where reservation.organization_id = p_organization_id
      and reservation.status = 'active'
      and organization.plan = 'pilot'
      and organization.status = 'active'
      and entitlement.plan = 'practice_pilot'
      and entitlement.status in ('active', 'trialing', 'past_due')
    limit 1;

    if v_pilot_user_id is not null and p_quantity <> 1 then
      raise exception 'practice_pilot_generation_credit_quantity_must_be_one'
        using errcode = '22023';
    end if;
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(concat(p_organization_id, ':', p_event_type, ':', v_period_start), 0)
  );

  select *
  into v_existing
  from public.api_usage_ledger
  where organization_id = p_organization_id
    and event_key = p_event_key
  for update;

  if found then
    if v_existing.event_type <> p_event_type
       or v_existing.resource_type is distinct from p_resource_type
       or v_existing.resource_id is distinct from p_resource_id
       or v_existing.quantity <> p_quantity then
      raise exception 'api_v1_usage_idempotency_conflict' using errcode = '23505';
    end if;

    v_shared_credit_already_consumed :=
      coalesce(v_existing.metadata->>'practice_pilot_shared_credit', '') = 'consumed';

    if v_existing.status in ('reserved', 'committed') then
      if v_pilot_user_id is not null then
        select coalesce(sum(counter.audio_renders_count), 0)::integer
        into v_used
        from public.usage_counters counter
        where counter.user_id = v_pilot_user_id
          and counter.date between v_existing.period_start::date
            and (v_existing.period_end - interval '1 day')::date;
        v_replay_limit := 40;
      else
        select coalesce(sum(quantity), 0)
        into v_used
        from public.api_usage_ledger
        where organization_id = p_organization_id
          and event_type = p_event_type
          and period_start = v_existing.period_start
          and status in ('reserved', 'committed');
        select usage_limit.limit_quantity
        into v_replay_limit
        from public.api_organization_usage_limits usage_limit
        where usage_limit.organization_id = p_organization_id
          and usage_limit.event_type = p_event_type;
      end if;
      return query select true, true, null::text, v_used, v_replay_limit;
      return;
    end if;
  end if;

  select *
  into v_limit
  from public.api_organization_usage_limits
  where organization_id = p_organization_id
    and event_type = p_event_type
  for update;

  if not found then
    return query select false, false, 'entitlement_missing'::text, null::numeric, null::numeric;
    return;
  end if;
  if not v_limit.enabled then
    return query select false, false, 'entitlement_disabled'::text, null::numeric, v_limit.limit_quantity;
    return;
  end if;

  select coalesce(sum(quantity), 0)
  into v_used
  from public.api_usage_ledger
  where organization_id = p_organization_id
    and event_type = p_event_type
    and period_start = v_period_start
    and status in ('reserved', 'committed');

  if v_limit.limit_quantity is not null and v_used + p_quantity > v_limit.limit_quantity then
    return query select false, false, 'quota_exceeded'::text, v_used, v_limit.limit_quantity;
    return;
  end if;

  if v_pilot_user_id is not null and not v_shared_credit_already_consumed then
    select shared.allowed, shared.used, shared.remaining
    into v_shared_allowed, v_shared_used, v_shared_remaining
    from public.pm_increment_usage_counter(
      v_pilot_user_id,
      'audio_renders_count',
      v_observed_at::date,
      v_period_start::date,
      (v_period_end - interval '1 day')::date,
      40,
      1
    ) shared;

    if not coalesce(v_shared_allowed, false) then
      return query select false, false, 'quota_exceeded'::text, v_shared_used::numeric, 40::numeric;
      return;
    end if;
  elsif v_pilot_user_id is not null then
    select coalesce(sum(counter.audio_renders_count), 0)::integer
    into v_shared_used
    from public.usage_counters counter
    where counter.user_id = v_pilot_user_id
      and counter.date between v_period_start::date and (v_period_end - interval '1 day')::date;
  end if;

  if v_existing.id is null then
    insert into public.api_usage_ledger (
      organization_id,
      event_key,
      event_type,
      resource_type,
      resource_id,
      quantity,
      metadata,
      status,
      period_start,
      period_end
    ) values (
      p_organization_id,
      p_event_key,
      p_event_type,
      p_resource_type,
      p_resource_id,
      p_quantity,
      case
        when v_pilot_user_id is not null
          then p_metadata || jsonb_build_object('practice_pilot_shared_credit', 'consumed')
        else p_metadata
      end,
      'reserved',
      v_period_start,
      v_period_end
    );
  else
    update public.api_usage_ledger
    set status = 'reserved',
        released_at = null,
        period_start = v_period_start,
        period_end = v_period_end,
        occurred_at = v_observed_at,
        metadata = case
          when v_pilot_user_id is not null
            then p_metadata || jsonb_build_object('practice_pilot_shared_credit', 'consumed')
          else p_metadata
        end
    where id = v_existing.id;
  end if;

  if v_pilot_user_id is not null then
    return query select true, false, null::text, v_shared_used::numeric, 40::numeric;
  else
    return query select true, false, null::text, v_used + p_quantity, v_limit.limit_quantity;
  end if;
end;
$$;

revoke all on function public.api_v1_reserve_usage(uuid, text, text, text, uuid, numeric, jsonb)
  from public, anon, authenticated;
grant execute on function public.api_v1_reserve_usage(uuid, text, text, text, uuid, numeric, jsonb)
  to service_role;

comment on function public.api_v1_reserve_usage(uuid, text, text, text, uuid, numeric, jsonb) is
  'Atomically reserves API usage. Practice Pilot practice_generation shares the user monthly audio_renders_count pool (40 total across account and API); retries with the same event key do not consume twice.';
