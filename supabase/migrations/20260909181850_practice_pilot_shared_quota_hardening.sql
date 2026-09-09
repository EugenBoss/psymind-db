-- Harden the Practice Pilot shared generation-credit pool after adversarial
-- review: fail closed without a paid seat mapping, keep readback on the same
-- counter as enforcement, and keep a released idempotent retry in its original
-- billing period.

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
    false
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

create or replace function public.pm_sync_practice_pilot_shared_quota_limit(
  p_organization_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_enabled boolean;
begin
  if p_organization_id is null then
    return;
  end if;

  select exists (
    select 1
    from public.api_organizations organization
    join public.practice_pilot_seat_reservations reservation
      on reservation.organization_id = organization.id
    join public.user_entitlements entitlement
      on entitlement.user_id = reservation.user_id
    where organization.id = p_organization_id
      and organization.plan = 'pilot'
      and organization.status = 'active'
      and reservation.status = 'active'
      and entitlement.plan = 'practice_pilot'
      and entitlement.status in ('active', 'trialing')
  ) into v_enabled;

  insert into public.api_organization_usage_limits (
    organization_id,
    event_type,
    period,
    limit_quantity,
    enabled
  )
  select
    organization.id,
    'practice_generation',
    'month',
    40,
    v_enabled
  from public.api_organizations organization
  where organization.id = p_organization_id
    and organization.plan = 'pilot'
  on conflict (organization_id, event_type) do update
  set period = 'month',
      limit_quantity = 40,
      enabled = excluded.enabled,
      updated_at = clock_timestamp();
end;
$$;

create or replace function public.pm_practice_pilot_seat_sync_shared_quota()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    perform public.pm_sync_practice_pilot_shared_quota_limit(old.organization_id);
    return old;
  end if;
  if tg_op = 'UPDATE'
     and old.organization_id is distinct from new.organization_id then
    perform public.pm_sync_practice_pilot_shared_quota_limit(old.organization_id);
  end if;
  perform public.pm_sync_practice_pilot_shared_quota_limit(new.organization_id);
  return new;
end;
$$;

create or replace function public.pm_practice_pilot_entitlement_sync_shared_quota()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := case when tg_op = 'DELETE' then old.user_id else new.user_id end;
  v_organization_id uuid;
begin
  for v_organization_id in
    select reservation.organization_id
    from public.practice_pilot_seat_reservations reservation
    where reservation.user_id = v_user_id
      and reservation.organization_id is not null
  loop
    perform public.pm_sync_practice_pilot_shared_quota_limit(v_organization_id);
  end loop;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create or replace function public.pm_practice_pilot_organization_sync_shared_quota()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if old.plan = 'pilot' or new.plan = 'pilot' then
    perform public.pm_sync_practice_pilot_shared_quota_limit(new.id);
  end if;
  return new;
end;
$$;

drop trigger if exists practice_pilot_seat_sync_shared_quota
  on public.practice_pilot_seat_reservations;
create trigger practice_pilot_seat_sync_shared_quota
after insert or update or delete
on public.practice_pilot_seat_reservations
for each row execute function public.pm_practice_pilot_seat_sync_shared_quota();

drop trigger if exists practice_pilot_entitlement_sync_shared_quota
  on public.user_entitlements;
create trigger practice_pilot_entitlement_sync_shared_quota
after insert or update or delete
on public.user_entitlements
for each row execute function public.pm_practice_pilot_entitlement_sync_shared_quota();

drop trigger if exists practice_pilot_organization_sync_shared_quota
  on public.api_organizations;
create trigger practice_pilot_organization_sync_shared_quota
after update of status, plan
on public.api_organizations
for each row execute function public.pm_practice_pilot_organization_sync_shared_quota();

update public.api_organization_usage_limits usage_limit
set period = 'month',
    limit_quantity = 40,
    enabled = false,
    updated_at = clock_timestamp()
from public.api_organizations organization
where organization.id = usage_limit.organization_id
  and organization.plan = 'pilot'
  and usage_limit.event_type = 'practice_generation';

select public.pm_sync_practice_pilot_shared_quota_limit(organization.id)
from public.api_organizations organization
where organization.plan = 'pilot';

create or replace function public.api_v1_read_usage(p_organization_id uuid)
returns table (
  organization_id uuid,
  period_start timestamptz,
  period_end timestamptz,
  usage jsonb
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_observed_at timestamptz := clock_timestamp();
  v_period_start timestamptz := date_trunc('month', v_observed_at);
  v_period_end timestamptz := v_period_start + interval '1 month';
  v_pilot_user_id uuid;
  v_shared_used numeric := 0;
begin
  if p_organization_id is null then
    raise exception 'api_v1_invalid_usage_readback' using errcode = '22023';
  end if;

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
    and entitlement.status in ('active', 'trialing')
  limit 1;

  if v_pilot_user_id is not null then
    select coalesce(sum(counter.audio_renders_count), 0)::numeric
    into v_shared_used
    from public.usage_counters counter
    where counter.user_id = v_pilot_user_id
      and counter.date between v_period_start::date
        and v_observed_at::date;
  end if;

  return query
  select
    organization.id,
    v_period_start,
    v_period_end,
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'event_type', limits.event_type,
          'used_quantity', case
            when limits.event_type = 'practice_generation' and v_pilot_user_id is not null
              then v_shared_used::text
            else coalesce(counted.used_quantity, 0)::text
          end,
          'reserved_quantity', case
            when limits.event_type = 'practice_generation' and v_pilot_user_id is not null
              then '0'
            else coalesce(counted.reserved_quantity, 0)::text
          end,
          'quota_consumed_quantity', case
            when limits.event_type = 'practice_generation' and v_pilot_user_id is not null
              then v_shared_used::text
            else coalesce(counted.quota_consumed_quantity, 0)::text
          end,
          'limit_quantity', limits.limit_quantity::text,
          'remaining_quantity', case
            when limits.enabled and limits.limit_quantity is not null then
              greatest(
                limits.limit_quantity - case
                  when limits.event_type = 'practice_generation' and v_pilot_user_id is not null
                    then v_shared_used
                  else coalesce(counted.quota_consumed_quantity, 0)
                end,
                0
              )::text
            else null
          end,
          'enabled', limits.enabled,
          'quota_status', case
            when not limits.enabled then 'disabled'
            when limits.limit_quantity is null then 'unlimited'
            when case
              when limits.event_type = 'practice_generation' and v_pilot_user_id is not null
                then v_shared_used
              else coalesce(counted.quota_consumed_quantity, 0)
            end > limits.limit_quantity then 'exceeded'
            when case
              when limits.event_type = 'practice_generation' and v_pilot_user_id is not null
                then v_shared_used
              else coalesce(counted.quota_consumed_quantity, 0)
            end = limits.limit_quantity then 'reached'
            else 'available'
          end,
          'resource_usage', case
            when limits.event_type = 'practice_generation' and v_pilot_user_id is not null
              then jsonb_build_array(jsonb_build_object(
                'resource_type', 'shared_account_and_api',
                'is_aggregate', false,
                'used_quantity', v_shared_used::text,
                'reserved_quantity', '0',
                'quota_consumed_quantity', v_shared_used::text
              ))
            else coalesce(counted.resource_usage, '[]'::jsonb)
          end
        )
        order by limits.event_type
      ) filter (where limits.event_type is not null),
      '[]'::jsonb
    )
  from public.api_organizations organization
  left join public.api_organization_usage_limits limits
    on limits.organization_id = organization.id
   and limits.event_type in ('practice_generation', 'audio_minutes')
  left join lateral (
    with selected_resource_types as materialized (
      select coalesce(ledger.resource_type, 'unattributed') as resource_type
      from public.api_usage_ledger ledger
      where ledger.organization_id = organization.id
        and ledger.event_type = limits.event_type
        and ledger.period_start = v_period_start
        and ledger.status in ('reserved', 'committed')
      group by coalesce(ledger.resource_type, 'unattributed')
      order by
        (coalesce(ledger.resource_type, 'unattributed') <> 'other_resources'),
        coalesce(ledger.resource_type, 'unattributed')
      limit 999
    ), per_resource as materialized (
      select
        case when selected.resource_type is null then 'other_resources'
          else coalesce(ledger.resource_type, 'unattributed') end as resource_type,
        (selected.resource_type is null) as is_aggregate,
        coalesce(sum(ledger.quantity) filter (where ledger.status = 'committed'), 0) as used_quantity,
        coalesce(sum(ledger.quantity) filter (where ledger.status = 'reserved'), 0) as reserved_quantity,
        sum(ledger.quantity) as quota_consumed_quantity
      from public.api_usage_ledger ledger
      left join selected_resource_types selected
        on selected.resource_type = coalesce(ledger.resource_type, 'unattributed')
      where ledger.organization_id = organization.id
        and ledger.event_type = limits.event_type
        and ledger.period_start = v_period_start
        and ledger.status in ('reserved', 'committed')
      group by case when selected.resource_type is null then 'other_resources'
        else coalesce(ledger.resource_type, 'unattributed') end,
        (selected.resource_type is null)
    )
    select
      coalesce(sum(per_resource.used_quantity), 0) as used_quantity,
      coalesce(sum(per_resource.reserved_quantity), 0) as reserved_quantity,
      coalesce(sum(per_resource.quota_consumed_quantity), 0) as quota_consumed_quantity,
      coalesce(jsonb_agg(jsonb_build_object(
        'resource_type', coalesce(per_resource.resource_type, 'unattributed'),
        'is_aggregate', per_resource.is_aggregate,
        'used_quantity', per_resource.used_quantity::text,
        'reserved_quantity', per_resource.reserved_quantity::text,
        'quota_consumed_quantity', per_resource.quota_consumed_quantity::text
      ) order by per_resource.resource_type nulls first), '[]'::jsonb) as resource_usage
    from per_resource
  ) counted on true
  where organization.id = p_organization_id
    and organization.status = 'active'
  group by organization.id;
end;
$$;

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
  v_is_pilot_organization boolean;
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

  perform pg_advisory_xact_lock(
    public.api_v1_usage_event_lock_key(p_organization_id, p_event_key)
  );

  select organization.plan = 'pilot'
  into v_is_pilot_organization
  from public.api_organizations organization
  where organization.id = p_organization_id
    and organization.status = 'active';

  if not found then
    return query select false, false, 'organization_inactive'::text, null::numeric, null::numeric;
    return;
  end if;

  if p_event_type = 'practice_generation' and v_is_pilot_organization then
    select reservation.user_id
    into v_pilot_user_id
    from public.practice_pilot_seat_reservations reservation
    join public.user_entitlements entitlement
      on entitlement.user_id = reservation.user_id
    where reservation.organization_id = p_organization_id
      and reservation.status = 'active'
      and entitlement.plan = 'practice_pilot'
      and entitlement.status in ('active', 'trialing')
    limit 1;

    if v_pilot_user_id is null then
      return query select false, false, 'entitlement_missing'::text, null::numeric, 40::numeric;
      return;
    end if;

    if p_quantity <> 1 then
      raise exception 'practice_pilot_generation_credit_quantity_must_be_one'
        using errcode = '22023';
    end if;

    if p_resource_type <> 'practice'
       or not exists (
         select 1
         from public.api_practices practice
         where practice.id = p_resource_id
           and practice.organization_id = p_organization_id
       ) then
      raise exception 'practice_pilot_generation_resource_mismatch'
        using errcode = '22023';
    end if;

    perform public.pm_sync_practice_pilot_shared_quota_limit(p_organization_id);
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
          and counter.date between v_period_start::date
            and v_observed_at::date;
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

    if v_pilot_user_id is not null and v_shared_credit_already_consumed then
      update public.api_usage_ledger
      set status = 'reserved',
          released_at = null,
          metadata = p_metadata || jsonb_build_object(
            'practice_pilot_shared_credit', 'consumed'
          )
      where id = v_existing.id;

      select coalesce(sum(counter.audio_renders_count), 0)::integer
      into v_shared_used
      from public.usage_counters counter
      where counter.user_id = v_pilot_user_id
        and counter.date between v_period_start::date
          and v_observed_at::date;

      return query select true, true, null::text, v_shared_used::numeric, 40::numeric;
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

  if v_pilot_user_id is not null then
    select shared.allowed, shared.used, shared.remaining
    into v_shared_allowed, v_shared_used, v_shared_remaining
    from public.pm_increment_usage_counter(
      v_pilot_user_id,
      'audio_renders_count',
      v_observed_at::date,
      v_period_start::date,
      v_observed_at::date,
      40,
      1
    ) shared;

    if not coalesce(v_shared_allowed, false) then
      return query select false, false, 'quota_exceeded'::text, v_shared_used::numeric, 40::numeric;
      return;
    end if;
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

revoke all on function public.api_v1_seed_usage_limits() from public, anon, authenticated;
revoke all on function public.pm_sync_practice_pilot_shared_quota_limit(uuid)
  from public, anon, authenticated;
revoke all on function public.pm_practice_pilot_seat_sync_shared_quota()
  from public, anon, authenticated;
revoke all on function public.pm_practice_pilot_organization_sync_shared_quota()
  from public, anon, authenticated;
revoke all on function public.pm_practice_pilot_entitlement_sync_shared_quota()
  from public, anon, authenticated;
revoke all on function public.api_v1_read_usage(uuid) from public, anon, authenticated;
revoke all on function public.api_v1_reserve_usage(uuid, text, text, text, uuid, numeric, jsonb)
  from public, anon, authenticated;

grant execute on function public.pm_sync_practice_pilot_shared_quota_limit(uuid)
  to service_role;
grant execute on function public.api_v1_read_usage(uuid) to service_role;
grant execute on function public.api_v1_reserve_usage(uuid, text, text, text, uuid, numeric, jsonb)
  to service_role;

comment on function public.api_v1_read_usage(uuid) is
  'Reads current API usage. Practice Pilot practice_generation reports the same 40-credit account-and-API pool used for enforcement.';
comment on function public.api_v1_reserve_usage(uuid, text, text, text, uuid, numeric, jsonb) is
  'Atomically reserves API usage. Practice Pilot practice_generation fails closed without an active paid seat, shares the 40-credit account counter, and replays an existing event without consuming or moving its original credit.';
