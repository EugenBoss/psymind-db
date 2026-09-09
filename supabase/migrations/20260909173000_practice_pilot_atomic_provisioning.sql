-- Complete Practice Pilot provisioning and scope billing access to the exact
-- organization created for the claimed seat. This supersedes the broad
-- owner/admin membership mutations in 20260909170000 without rewriting an
-- already-applied migration.

alter table public.practice_pilot_seat_reservations
  add column if not exists organization_id uuid
  references public.api_organizations(id) on delete set null;

create unique index if not exists practice_pilot_seat_reservations_organization_unique
  on public.practice_pilot_seat_reservations(organization_id)
  where organization_id is not null;

comment on column public.practice_pilot_seat_reservations.organization_id is
  'The single API organization provisioned for this Practice Pilot subscription seat.';

-- Keep the database-side entitlement upgrade ladder aligned with the paid plan contract.
-- Without this entry, free -> practice_pilot is evaluated as 0 -> 0 and does not reset
-- audio_credits_reset_at after a successful checkout/payment transition.

create or replace function public.pm_stripe_apply_entitlement_transition(
  p_event_id text,
  p_lease_owner text,
  p_event_type text,
  p_event_created_at timestamptz,
  p_transition text,
  p_user_id uuid,
  p_stripe_customer_id text,
  p_stripe_subscription_id text,
  p_profile_tier text,
  p_subscription_plan text,
  p_entitlement_plan text,
  p_billing_interval text,
  p_subscription_status text,
  p_current_period_end timestamptz,
  p_cancel_at_period_end boolean,
  p_invoice_id text default null,
  p_invoice_paid_at timestamptz default null,
  p_charge_id text default null
)
returns table (
  applied boolean,
  transition_outcome text,
  effective_plan text,
  effective_status text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_event public.stripe_webhook_events%rowtype;
  v_profile public.profiles%rowtype;
  v_entitlement public.user_entitlements%rowtype;
  v_state public.stripe_entitlement_state%rowtype;
  v_current_subscription text;
  v_ignore_reason text;
  v_outcome text := 'transition_applied';
  v_applied boolean := true;
  v_effective_plan text;
  v_effective_status text;
  v_old_rank integer := 0;
  v_new_rank integer := 0;
  v_last_priority integer := 0;
  v_new_priority integer := 0;
  v_is_grant boolean := false;
  v_current_is_practice_pilot boolean := false;
  v_target_is_practice_pilot boolean := false;
  v_pilot_reservation_id uuid;
  v_pilot_organization_id uuid;
begin
  if p_user_id is null then
    raise exception 'pm_stripe_missing_user_id' using errcode = '22023';
  end if;
  if p_transition not in ('checkout', 'paid', 'subscription_sync', 'payment_failed', 'canceled', 'refunded') then
    raise exception 'pm_stripe_invalid_transition' using errcode = '22023';
  end if;
  if p_event_created_at is null then
    raise exception 'pm_stripe_missing_event_created_at' using errcode = '22023';
  end if;
  if p_billing_interval is not null and p_billing_interval not in ('monthly', 'annual') then
    raise exception 'pm_stripe_invalid_billing_interval' using errcode = '22023';
  end if;

  select * into v_event
  from public.stripe_webhook_events e
  where e.event_id = p_event_id
  for update;
  if not found
     or v_event.processing_status <> 'processing'
     or v_event.lease_owner is distinct from p_lease_owner then
    raise exception 'pm_stripe_stale_or_missing_claim' using errcode = '40001';
  end if;

  select * into v_profile
  from public.profiles p
  where p.id = p_user_id
  for update;
  if not found then
    raise exception 'pm_stripe_profile_not_found' using errcode = 'P0002';
  end if;

  select * into v_entitlement
  from public.user_entitlements e
  where e.user_id = p_user_id
  for update;

  v_current_is_practice_pilot :=
    lower(coalesce(v_profile.tier, '')) = 'practice_pilot'
    or lower(coalesce(v_profile.subscription_plan, '')) in ('practice_pilot', 'practice_pilot_monthly')
    or lower(coalesce(v_entitlement.plan, '')) = 'practice_pilot';
  v_target_is_practice_pilot :=
    lower(coalesce(p_profile_tier, '')) = 'practice_pilot'
    or lower(coalesce(p_subscription_plan, '')) in ('practice_pilot', 'practice_pilot_monthly')
    or lower(coalesce(p_entitlement_plan, '')) = 'practice_pilot';

  insert into public.stripe_entitlement_state (
    user_id,
    stripe_customer_id,
    stripe_subscription_id,
    access_revoked,
    last_transition,
    last_outcome,
    created_at,
    updated_at
  ) values (
    p_user_id,
    coalesce(v_entitlement.stripe_customer_id, v_profile.stripe_customer_id),
    coalesce(v_entitlement.stripe_subscription_id, v_profile.stripe_subscription_id),
    coalesce(v_entitlement.status = 'refunded', false),
    'runtime_backfill',
    'state_initialized_during_transition',
    clock_timestamp(),
    clock_timestamp()
  )
  on conflict (user_id) do nothing;

  select * into v_state
  from public.stripe_entitlement_state s
  where s.user_id = p_user_id
  for update;

  v_current_subscription := coalesce(
    v_state.stripe_subscription_id,
    v_entitlement.stripe_subscription_id,
    v_profile.stripe_subscription_id
  );

  v_last_priority := case v_state.last_transition
    when 'refunded' then 100
    when 'canceled' then 90
    when 'paid' then 80
    when 'checkout' then 70
    when 'payment_failed' then 40
    when 'subscription_sync' then 30
    else 0
  end;
  v_new_priority := case p_transition
    when 'refunded' then 100
    when 'canceled' then 90
    when 'paid' then 80
    when 'checkout' then 70
    when 'payment_failed' then 40
    when 'subscription_sync' then 30
    else 0
  end;

  if v_state.last_event_created_at is not null
     and (
       p_event_created_at < v_state.last_event_created_at
       or (
         p_event_created_at = v_state.last_event_created_at
         and v_new_priority <= v_last_priority
       )
     ) then
    v_ignore_reason := 'stale_event_order';
  end if;

  if v_ignore_reason is null
     and v_current_subscription is not null
     and p_stripe_subscription_id is not null
     and v_current_subscription <> p_stripe_subscription_id then
    if p_transition in ('checkout', 'paid')
       and coalesce(v_profile.stripe_subscription_status, '') in ('canceled', 'unpaid', 'payment_failed') then
      null;
    else
      v_ignore_reason := 'stale_subscription';
    end if;
  end if;

  if v_ignore_reason is null and p_transition = 'refunded' then
    if p_entitlement_plan <> 'practitioner' then
      v_ignore_reason := 'non_practitioner_refund';
    elsif p_invoice_id is null or p_invoice_paid_at is null or p_charge_id is null then
      raise exception 'pm_stripe_refund_evidence_missing' using errcode = '22023';
    elsif v_state.last_paid_at is not null
       and (
         p_invoice_paid_at < v_state.last_paid_at
         or (
           p_invoice_paid_at = v_state.last_paid_at
           and v_state.last_paid_invoice_id is distinct from p_invoice_id
         )
       ) then
      v_ignore_reason := 'historical_invoice_refund';
    end if;
  end if;

  if v_ignore_reason is null and p_transition = 'paid' then
    if p_invoice_id is null or p_invoice_paid_at is null then
      raise exception 'pm_stripe_paid_evidence_missing' using errcode = '22023';
    elsif v_state.last_paid_at is not null
       and p_invoice_paid_at < v_state.last_paid_at then
      v_ignore_reason := 'older_paid_invoice';
    elsif v_state.access_revoked
       and (
         v_state.revoked_invoice_id = p_invoice_id
         or p_invoice_paid_at <= coalesce(v_state.revoked_at, p_invoice_paid_at)
       ) then
      v_ignore_reason := 'refunded_invoice_cannot_regrant';
    elsif coalesce(p_subscription_status, '') in ('canceled', 'unpaid') then
      v_ignore_reason := 'inactive_subscription_paid_event';
    end if;
  end if;

  if v_ignore_reason is null and p_transition = 'checkout'
     and v_state.access_revoked
     and v_current_subscription is not distinct from p_stripe_subscription_id then
    v_ignore_reason := 'refunded_checkout_cannot_regrant';
  end if;

  if v_ignore_reason is not null then
    v_applied := false;
    v_outcome := v_ignore_reason;
    v_effective_plan := coalesce(v_entitlement.plan, v_profile.tier, 'free');
    v_effective_status := coalesce(v_entitlement.status, v_profile.stripe_subscription_status, 'unknown');
  else
    v_is_grant := p_transition in ('checkout', 'paid', 'subscription_sync')
      and not (p_transition = 'subscription_sync' and v_state.access_revoked)
      and coalesce(p_subscription_status, '') not in ('canceled', 'unpaid');

    v_old_rank := case lower(coalesce(v_profile.tier, 'free'))
      when 'pro' then 1 when 'crestere' then 1
      when 'premium' then 2 when 'transformare' then 2 when 'training' then 2
      when 'practitioner' then 3 when 'lifetime' then 3 when 'founding_lifetime' then 3
      when 'practice_pilot' then 4
      else 0
    end;
    v_new_rank := case lower(coalesce(p_profile_tier, 'free'))
      when 'pro' then 1 when 'crestere' then 1
      when 'premium' then 2 when 'transformare' then 2 when 'training' then 2
      when 'practitioner' then 3 when 'lifetime' then 3 when 'founding_lifetime' then 3
      when 'practice_pilot' then 4
      else 0
    end;

    if p_transition = 'refunded' then
      update public.profiles p
      set tier = 'free',
          subscription_plan = null,
          stripe_customer_id = coalesce(p_stripe_customer_id, p.stripe_customer_id),
          stripe_subscription_id = coalesce(p_stripe_subscription_id, p.stripe_subscription_id),
          stripe_subscription_status = coalesce(p_subscription_status, p.stripe_subscription_status),
          stripe_current_period_end = coalesce(p_current_period_end, p.stripe_current_period_end),
          trial_active = false,
          updated_at = clock_timestamp()
      where p.id = p_user_id;

      insert into public.user_entitlements (
        user_id, plan, billing_interval, stripe_customer_id, stripe_subscription_id,
        status, current_period_end, cancel_at_period_end, created_at, updated_at
      ) values (
        p_user_id, 'free', null, p_stripe_customer_id, p_stripe_subscription_id,
        'refunded', p_current_period_end, coalesce(p_cancel_at_period_end, false),
        clock_timestamp(), clock_timestamp()
      )
      on conflict (user_id) do update set
        plan = 'free',
        billing_interval = null,
        stripe_customer_id = coalesce(excluded.stripe_customer_id, public.user_entitlements.stripe_customer_id),
        stripe_subscription_id = coalesce(excluded.stripe_subscription_id, public.user_entitlements.stripe_subscription_id),
        status = 'refunded',
        current_period_end = coalesce(excluded.current_period_end, public.user_entitlements.current_period_end),
        cancel_at_period_end = excluded.cancel_at_period_end,
        updated_at = clock_timestamp();
      v_effective_plan := 'free';
      v_effective_status := 'refunded';
      v_outcome := 'practitioner_access_revoked';

    elsif p_transition = 'canceled' or coalesce(p_subscription_status, '') in ('canceled', 'unpaid') then
      update public.profiles p
      set tier = 'free',
          subscription_plan = null,
          stripe_customer_id = coalesce(p_stripe_customer_id, p.stripe_customer_id),
          stripe_subscription_id = coalesce(p_stripe_subscription_id, p.stripe_subscription_id),
          stripe_subscription_status = coalesce(p_subscription_status, 'canceled'),
          stripe_current_period_end = coalesce(p_current_period_end, p.stripe_current_period_end),
          trial_active = false,
          updated_at = clock_timestamp()
      where p.id = p_user_id;

      insert into public.user_entitlements (
        user_id, plan, billing_interval, stripe_customer_id, stripe_subscription_id,
        status, current_period_end, cancel_at_period_end, created_at, updated_at
      ) values (
        p_user_id, 'free', null, p_stripe_customer_id, p_stripe_subscription_id,
        coalesce(p_subscription_status, 'canceled'), p_current_period_end,
        coalesce(p_cancel_at_period_end, false), clock_timestamp(), clock_timestamp()
      )
      on conflict (user_id) do update set
        plan = 'free',
        billing_interval = null,
        stripe_customer_id = coalesce(excluded.stripe_customer_id, public.user_entitlements.stripe_customer_id),
        stripe_subscription_id = coalesce(excluded.stripe_subscription_id, public.user_entitlements.stripe_subscription_id),
        status = excluded.status,
        current_period_end = coalesce(excluded.current_period_end, public.user_entitlements.current_period_end),
        cancel_at_period_end = excluded.cancel_at_period_end,
        updated_at = clock_timestamp();
      v_effective_plan := 'free';
      v_effective_status := coalesce(p_subscription_status, 'canceled');
      v_outcome := 'subscription_access_removed';

    elsif p_transition = 'payment_failed' then
      update public.profiles p
      set stripe_subscription_status = 'payment_failed',
          updated_at = clock_timestamp()
      where p.id = p_user_id;

      update public.user_entitlements e
      set status = 'payment_failed',
          updated_at = clock_timestamp()
      where e.user_id = p_user_id;
      v_effective_plan := coalesce(v_entitlement.plan, v_profile.tier, 'free');
      v_effective_status := 'payment_failed';
      v_outcome := 'payment_failure_recorded';

    elsif p_transition = 'subscription_sync' and v_state.access_revoked then
      update public.profiles p
      set tier = 'free',
          subscription_plan = null,
          stripe_customer_id = coalesce(p_stripe_customer_id, p.stripe_customer_id),
          stripe_subscription_id = coalesce(p_stripe_subscription_id, p.stripe_subscription_id),
          stripe_subscription_status = coalesce(p_subscription_status, p.stripe_subscription_status),
          stripe_current_period_end = coalesce(p_current_period_end, p.stripe_current_period_end),
          updated_at = clock_timestamp()
      where p.id = p_user_id;

      update public.user_entitlements e
      set plan = 'free',
          billing_interval = null,
          stripe_customer_id = coalesce(p_stripe_customer_id, e.stripe_customer_id),
          stripe_subscription_id = coalesce(p_stripe_subscription_id, e.stripe_subscription_id),
          status = 'refunded',
          current_period_end = coalesce(p_current_period_end, e.current_period_end),
          cancel_at_period_end = coalesce(p_cancel_at_period_end, e.cancel_at_period_end),
          updated_at = clock_timestamp()
      where e.user_id = p_user_id;
      v_effective_plan := 'free';
      v_effective_status := 'refunded';
      v_outcome := 'refunded_access_preserved';

    else
      if p_profile_tier is null or p_entitlement_plan is null then
        raise exception 'pm_stripe_grant_plan_missing' using errcode = '22023';
      end if;

      update public.profiles p
      set tier = p_profile_tier,
          subscription_plan = p_subscription_plan,
          stripe_customer_id = coalesce(p_stripe_customer_id, p.stripe_customer_id),
          stripe_subscription_id = coalesce(p_stripe_subscription_id, p.stripe_subscription_id),
          stripe_subscription_status = coalesce(p_subscription_status, p.stripe_subscription_status),
          stripe_current_period_end = p_current_period_end,
          trial_active = case when p_transition = 'checkout' then false else p.trial_active end,
          audio_credits_reset_at = case when v_new_rank > v_old_rank
            then clock_timestamp() else p.audio_credits_reset_at end,
          updated_at = clock_timestamp()
      where p.id = p_user_id;

      insert into public.user_entitlements (
        user_id, plan, billing_interval, stripe_customer_id, stripe_subscription_id,
        status, current_period_end, cancel_at_period_end, created_at, updated_at
      ) values (
        p_user_id, p_entitlement_plan, p_billing_interval, p_stripe_customer_id,
        p_stripe_subscription_id, coalesce(p_subscription_status, 'active'),
        p_current_period_end, coalesce(p_cancel_at_period_end, false),
        clock_timestamp(), clock_timestamp()
      )
      on conflict (user_id) do update set
        plan = excluded.plan,
        billing_interval = excluded.billing_interval,
        stripe_customer_id = coalesce(excluded.stripe_customer_id, public.user_entitlements.stripe_customer_id),
        stripe_subscription_id = coalesce(excluded.stripe_subscription_id, public.user_entitlements.stripe_subscription_id),
        status = excluded.status,
        current_period_end = excluded.current_period_end,
        cancel_at_period_end = excluded.cancel_at_period_end,
        updated_at = clock_timestamp();
      v_effective_plan := p_entitlement_plan;
      v_effective_status := coalesce(p_subscription_status, 'active');
      v_outcome := case p_transition
        when 'paid' then 'new_payment_applied'
        when 'checkout' then 'checkout_entitlement_applied'
        else 'subscription_entitlement_synced'
      end;
    end if;

    update public.stripe_entitlement_state s
    set stripe_customer_id = coalesce(p_stripe_customer_id, s.stripe_customer_id),
        stripe_subscription_id = coalesce(p_stripe_subscription_id, s.stripe_subscription_id),
        access_revoked = case
          when p_transition = 'refunded' then true
          when p_transition in ('paid', 'checkout') then false
          else s.access_revoked
        end,
        revoked_invoice_id = case
          when p_transition = 'refunded' then p_invoice_id
          when p_transition in ('paid', 'checkout') then null
          else s.revoked_invoice_id
        end,
        revoked_charge_id = case
          when p_transition = 'refunded' then p_charge_id
          when p_transition in ('paid', 'checkout') then null
          else s.revoked_charge_id
        end,
        revoked_at = case
          when p_transition = 'refunded' then p_event_created_at
          when p_transition in ('paid', 'checkout') then null
          else s.revoked_at
        end,
        last_paid_invoice_id = case
          when p_transition = 'paid' then p_invoice_id
          else s.last_paid_invoice_id
        end,
        last_paid_at = case
          when p_transition = 'paid' then p_invoice_paid_at
          else s.last_paid_at
        end,
        last_event_id = p_event_id,
        last_event_type = p_event_type,
        last_event_created_at = p_event_created_at,
        last_transition = p_transition,
        last_outcome = v_outcome,
        updated_at = clock_timestamp()
    where s.user_id = p_user_id;

    -- Practice Pilot provisioning and billing access changes are part of this
    -- transaction. The seat-to-organization mapping prevents one subscription
    -- from mutating unrelated organizations owned by the same user.
    if (v_current_is_practice_pilot or v_target_is_practice_pilot)
       and (
         p_transition in ('payment_failed', 'canceled')
         or coalesce(p_subscription_status, '') in ('past_due', 'unpaid', 'canceled')
       ) then
      perform pg_advisory_xact_lock(hashtext('practice_pilot_seats'));

      select r.id, r.organization_id
      into v_pilot_reservation_id, v_pilot_organization_id
      from public.practice_pilot_seat_reservations r
      where r.user_id = p_user_id
      for update;

      if v_pilot_reservation_id is null or v_pilot_organization_id is null then
        raise exception 'pm_practice_pilot_access_mapping_missing' using errcode = 'P0002';
      end if;

      update public.api_organizations o
      set status = 'suspended',
          practice_pilot_suspended_at = coalesce(o.practice_pilot_suspended_at, clock_timestamp()),
          updated_at = clock_timestamp()
      where o.id = v_pilot_organization_id
        and (o.status = 'active' or o.practice_pilot_suspended_at is not null);

      if p_transition = 'canceled' or coalesce(p_subscription_status, '') in ('unpaid', 'canceled') then
        update public.practice_pilot_seat_reservations
        set status = 'released', updated_at = clock_timestamp()
        where id = v_pilot_reservation_id;
      end if;

    elsif v_target_is_practice_pilot
       and v_is_grant
       and coalesce(p_subscription_status, '') in ('active', 'trialing', 'paid') then
      perform pg_advisory_xact_lock(hashtext('practice_pilot_seats'));

      select r.id, r.organization_id
      into v_pilot_reservation_id, v_pilot_organization_id
      from public.practice_pilot_seat_reservations r
      where r.user_id = p_user_id
      for update;

      if v_pilot_reservation_id is null then
        raise exception 'pm_practice_pilot_reservation_missing' using errcode = 'P0002';
      end if;

      if exists (
        select 1
        from public.practice_pilot_seat_reservations r
        where r.id = v_pilot_reservation_id and r.status = 'released'
      ) then
        if (
          select count(*)
          from public.practice_pilot_seat_reservations r
          where r.status in ('pending', 'active')
            and r.id <> v_pilot_reservation_id
        ) >= 3 then
          raise exception 'pm_practice_pilot_capacity_exhausted' using errcode = 'P0001';
        end if;

        update public.practice_pilot_seat_reservations
        set status = 'pending',
            expires_at = clock_timestamp() + interval '30 minutes',
            updated_at = clock_timestamp()
        where id = v_pilot_reservation_id;
      end if;

      if v_pilot_organization_id is null then
        insert into public.api_organizations(name, status, plan)
        values (
          format('Practice Pilot %s', left(p_user_id::text, 8)),
          'active',
          'pilot'
        )
        returning id into v_pilot_organization_id;

        update public.practice_pilot_seat_reservations
        set organization_id = v_pilot_organization_id,
            updated_at = clock_timestamp()
        where id = v_pilot_reservation_id;
      end if;

      -- Insert only when absent. Existing administrative membership state and
      -- role are intentionally preserved during billing recovery.
      insert into public.api_organization_members(
        organization_id,
        user_id,
        role,
        status
      ) values (
        v_pilot_organization_id,
        p_user_id,
        'owner',
        'active'
      )
      on conflict (organization_id, user_id) do nothing;

      update public.practice_pilot_seat_reservations
      set status = 'active', updated_at = clock_timestamp()
      where id = v_pilot_reservation_id;

      update public.api_organizations o
      set status = 'active',
          practice_pilot_suspended_at = null,
          updated_at = clock_timestamp()
      where o.id = v_pilot_organization_id
        and o.status = 'suspended'
        and o.practice_pilot_suspended_at is not null;
    end if;
  end if;

  perform * from public.pm_stripe_webhook_complete(
    p_event_id,
    p_lease_owner,
    case when v_applied then 'processed' else 'ignored' end,
    jsonb_build_object(
      'transition', p_transition,
      'outcome', v_outcome,
      'applied', v_applied,
      'user_id', p_user_id,
      'subscription_id', p_stripe_subscription_id,
      'invoice_id', p_invoice_id,
      'charge_id', p_charge_id
    )
  );

  return query select v_applied, v_outcome, v_effective_plan, v_effective_status;
end;
$$;

revoke all on function public.pm_stripe_apply_entitlement_transition(
  text, text, text, timestamptz, text, uuid, text, text, text, text, text, text,
  text, timestamptz, boolean, text, timestamptz, text
) from public, anon, authenticated;
grant execute on function public.pm_stripe_apply_entitlement_transition(
  text, text, text, timestamptz, text, uuid, text, text, text, text, text, text,
  text, timestamptz, boolean, text, timestamptz, text
) to service_role;

comment on function public.pm_stripe_apply_entitlement_transition(
  text, text, text, timestamptz, text, uuid, text, text, text, text, text, text,
  text, timestamptz, boolean, text, timestamptz, text
) is
  'Atomically applies profile+entitlement+watermark and finalizes the claimed Stripe event; practice_pilot participates in paid upgrade credit resets.';


create or replace function public.pm_practice_pilot_suspend_access(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_organization_id uuid;
begin
  select r.organization_id
  into v_organization_id
  from public.practice_pilot_seat_reservations r
  where r.user_id = p_user_id
  for update;

  if v_organization_id is null then
    raise exception 'pm_practice_pilot_access_mapping_missing' using errcode = 'P0002';
  end if;

  update public.api_organizations o
  set status = 'suspended',
      practice_pilot_suspended_at = coalesce(o.practice_pilot_suspended_at, clock_timestamp()),
      updated_at = clock_timestamp()
  where o.id = v_organization_id
    and (o.status = 'active' or o.practice_pilot_suspended_at is not null);
end;
$$;

create or replace function public.pm_practice_pilot_resume_access(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_organization_id uuid;
begin
  select r.organization_id
  into v_organization_id
  from public.practice_pilot_seat_reservations r
  where r.user_id = p_user_id
  for update;

  if v_organization_id is null then
    raise exception 'pm_practice_pilot_access_mapping_missing' using errcode = 'P0002';
  end if;

  update public.api_organizations o
  set status = 'active',
      practice_pilot_suspended_at = null,
      updated_at = clock_timestamp()
  where o.id = v_organization_id
    and o.status = 'suspended'
    and o.practice_pilot_suspended_at is not null;
end;
$$;

revoke all on function public.pm_practice_pilot_suspend_access(uuid) from public, anon, authenticated;
revoke all on function public.pm_practice_pilot_resume_access(uuid) from public, anon, authenticated;
grant execute on function public.pm_practice_pilot_suspend_access(uuid) to service_role;
grant execute on function public.pm_practice_pilot_resume_access(uuid) to service_role;

comment on function public.pm_practice_pilot_suspend_access(uuid) is
  'Suspends only the API organization mapped to the user Practice Pilot seat; does not change membership state.';
comment on function public.pm_practice_pilot_resume_access(uuid) is
  'Resumes only a billing-suspended API organization mapped to the user Practice Pilot seat; preserves membership state.';
