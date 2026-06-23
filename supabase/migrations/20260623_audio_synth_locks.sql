-- PM-LAUNCH-AUDIO-DUP-BILLING-HARDENING-001
--
-- Atomic synth lock for ElevenLabs audio generation.
--
-- Why:
-- - The Storage-object `.sflock` guard is fail-open and reduced the measured
--   cache stampede, but production ledger evidence on 2026-06-23 still showed
--   duplicate `stored` rows for the same full-audio asset.
-- - This table gives the render path an atomic Postgres UNIQUE lock, while the
--   runtime keeps the existing Storage lock as a fail-open fallback when this
--   migration has not been applied yet.
--
-- Privacy:
-- - Stores only path hashes / lock keys and a random token.
-- - Stores no raw user input, script text, transcript, or emotional content.

create extension if not exists pgcrypto;

create table if not exists public.audio_synth_locks (
  lock_key text primary key,
  lock_token uuid not null,
  lock_path_hash text not null,
  acquired_at timestamptz not null default now(),
  expires_at timestamptz not null,
  safe_metadata jsonb
);

create index if not exists audio_synth_locks_expires_at_idx
  on public.audio_synth_locks (expires_at);

alter table public.audio_synth_locks enable row level security;

revoke all on table public.audio_synth_locks from anon;
revoke all on table public.audio_synth_locks from authenticated;
grant select, insert, update, delete on table public.audio_synth_locks to service_role;

create or replace function public.pm_audio_synth_lock_claim(
  p_lock_key text,
  p_lock_token uuid,
  p_lock_path_hash text,
  p_ttl_seconds integer default 45
)
returns table (
  claimed boolean,
  reason text,
  lock_token uuid,
  expires_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text := left(coalesce(nullif(trim(p_lock_key), ''), ''), 256);
  v_token uuid := coalesce(p_lock_token, gen_random_uuid());
  v_path_hash text := left(coalesce(nullif(trim(p_lock_path_hash), ''), ''), 128);
  v_ttl integer := greatest(5, least(300, coalesce(p_ttl_seconds, 45)));
  v_expires timestamptz := now() + make_interval(secs => v_ttl);
  v_row public.audio_synth_locks%rowtype;
begin
  if v_key = '' or v_path_hash = '' then
    claimed := false;
    reason := 'invalid_lock_key';
    lock_token := null;
    expires_at := null;
    return next;
    return;
  end if;

  insert into public.audio_synth_locks (
    lock_key,
    lock_token,
    lock_path_hash,
    acquired_at,
    expires_at,
    safe_metadata
  )
  values (
    v_key,
    v_token,
    v_path_hash,
    now(),
    v_expires,
    jsonb_build_object('source', 'audio_synth_lock')
  )
  on conflict (lock_key) do update
    set lock_token = excluded.lock_token,
        lock_path_hash = excluded.lock_path_hash,
        acquired_at = now(),
        expires_at = excluded.expires_at,
        safe_metadata = excluded.safe_metadata
    where public.audio_synth_locks.expires_at <= now()
  returning * into v_row;

  if v_row.lock_key is not null then
    claimed := true;
    reason := 'claimed';
    lock_token := v_token;
    expires_at := v_expires;
    return next;
    return;
  end if;

  select *
  into v_row
  from public.audio_synth_locks
  where lock_key = v_key;

  claimed := false;
  reason := 'held';
  lock_token := null;
  expires_at := v_row.expires_at;
  return next;
end;
$$;

create or replace function public.pm_audio_synth_lock_release(
  p_lock_key text,
  p_lock_token uuid
)
returns table (
  released boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text := left(coalesce(nullif(trim(p_lock_key), ''), ''), 256);
  v_token uuid := p_lock_token;
begin
  if v_key = '' or v_token is null then
    released := false;
    return next;
    return;
  end if;

  delete from public.audio_synth_locks
  where lock_key = v_key
    and lock_token = v_token;

  released := found;
  return next;
end;
$$;

revoke all on function public.pm_audio_synth_lock_claim(text, uuid, text, integer) from public;
revoke all on function public.pm_audio_synth_lock_claim(text, uuid, text, integer) from anon;
revoke all on function public.pm_audio_synth_lock_claim(text, uuid, text, integer) from authenticated;
grant execute on function public.pm_audio_synth_lock_claim(text, uuid, text, integer) to service_role;

revoke all on function public.pm_audio_synth_lock_release(text, uuid) from public;
revoke all on function public.pm_audio_synth_lock_release(text, uuid) from anon;
revoke all on function public.pm_audio_synth_lock_release(text, uuid) from authenticated;
grant execute on function public.pm_audio_synth_lock_release(text, uuid) to service_role;

comment on table public.audio_synth_locks is
  'PM-LAUNCH-AUDIO-DUP-BILLING-HARDENING-001: atomic service-role-only synth locks for ElevenLabs audio generation. Stores no raw user text.';
