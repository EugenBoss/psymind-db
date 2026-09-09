-- Practice Pilot: atomic three-seat reservation and access suspension.
create table if not exists public.practice_pilot_seat_reservations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade unique,
  status text not null default 'pending' check (status in ('pending','active','released')),
  expires_at timestamptz not null default (clock_timestamp() + interval '30 minutes'),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp()
);
alter table public.practice_pilot_seat_reservations enable row level security;
revoke all on table public.practice_pilot_seat_reservations from public, anon, authenticated;
grant select, insert, update, delete on table public.practice_pilot_seat_reservations to service_role;
alter table public.api_organizations add column if not exists practice_pilot_suspended_at timestamptz;

create or replace function public.pm_practice_pilot_claim_seat(p_user_id uuid)
returns table (granted boolean, reservation_id uuid)
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  perform pg_advisory_xact_lock(hashtext('practice_pilot_seats'));
  update public.practice_pilot_seat_reservations set status = 'released', updated_at = clock_timestamp()
    where status = 'pending' and expires_at <= clock_timestamp();
  select id into v_id from public.practice_pilot_seat_reservations where user_id = p_user_id and status in ('pending','active') for update;
  if v_id is not null then return query select true, v_id; return; end if;
  if (select count(*) from public.practice_pilot_seat_reservations where status in ('pending','active')) >= 3 then return query select false, null::uuid; return; end if;
  insert into public.practice_pilot_seat_reservations(user_id, status) values (p_user_id, 'pending')
    on conflict (user_id) do update set status = 'pending', expires_at = clock_timestamp() + interval '30 minutes', updated_at = clock_timestamp()
    returning id into v_id;
  return query select true, v_id;
end; $$;

create or replace function public.pm_practice_pilot_release_seat(p_reservation_id uuid)
returns void language sql security definer set search_path = public, pg_temp as $$
  update public.practice_pilot_seat_reservations set status = 'released', updated_at = clock_timestamp()
  where id = p_reservation_id and status = 'pending';
$$;

create or replace function public.pm_practice_pilot_activate_seat(p_reservation_id uuid)
returns void language sql security definer set search_path = public, pg_temp as $$
  update public.practice_pilot_seat_reservations set status = 'active', updated_at = clock_timestamp()
  where id = p_reservation_id and status = 'pending' and expires_at > clock_timestamp();
$$;

revoke all on function public.pm_practice_pilot_claim_seat(uuid) from public, anon, authenticated;
revoke all on function public.pm_practice_pilot_release_seat(uuid) from public, anon, authenticated;
revoke all on function public.pm_practice_pilot_activate_seat(uuid) from public, anon, authenticated;
grant execute on function public.pm_practice_pilot_claim_seat(uuid) to service_role;
grant execute on function public.pm_practice_pilot_release_seat(uuid) to service_role;
grant execute on function public.pm_practice_pilot_activate_seat(uuid) to service_role;

create or replace function public.pm_practice_pilot_suspend_access(p_user_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update public.api_organization_members m set status = 'suspended', updated_at = clock_timestamp()
    where m.user_id = p_user_id and m.role in ('owner','admin') and m.status = 'active';
  update public.api_organizations o set status = 'suspended', practice_pilot_suspended_at = clock_timestamp(), updated_at = clock_timestamp()
    where exists (select 1 from public.api_organization_members m where m.organization_id = o.id and m.user_id = p_user_id and m.role in ('owner','admin'))
      and o.status = 'active' and o.practice_pilot_suspended_at is null;
end; $$;

revoke all on function public.pm_practice_pilot_suspend_access(uuid) from public, anon, authenticated;
grant execute on function public.pm_practice_pilot_suspend_access(uuid) to service_role;

create or replace function public.pm_practice_pilot_resume_access(p_user_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update public.api_organization_members m set status = 'active', updated_at = clock_timestamp()
    where m.user_id = p_user_id and m.role in ('owner','admin') and m.status = 'suspended'
      and exists (select 1 from public.api_organizations o where o.id = m.organization_id and o.practice_pilot_suspended_at is not null);
  update public.api_organizations o set status = 'active', practice_pilot_suspended_at = null, updated_at = clock_timestamp()
    where o.status = 'suspended' and o.practice_pilot_suspended_at is not null
      and exists (select 1 from public.api_organization_members m where m.organization_id = o.id and m.user_id = p_user_id and m.role in ('owner','admin'));
end; $$;

revoke all on function public.pm_practice_pilot_resume_access(uuid) from public, anon, authenticated;
grant execute on function public.pm_practice_pilot_resume_access(uuid) to service_role;
