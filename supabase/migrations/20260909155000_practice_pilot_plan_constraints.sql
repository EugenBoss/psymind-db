-- Practice Pilot is a paid account plan written by the Stripe webhook to both
-- profiles.tier and user_entitlements.plan. Keep both constraints in sync.
alter table public.profiles drop constraint if exists profiles_tier_check;

alter table public.profiles add constraint profiles_tier_check
  check (tier = any (array[
    'free'::text,
    'pro'::text,
    'premium'::text,
    'practitioner'::text,
    'practice_pilot'::text,
    'lifetime'::text,
    'founding_lifetime'::text,
    'crestere'::text,
    'transformare'::text,
    'training'::text
  ]));

alter table public.user_entitlements drop constraint if exists user_entitlements_plan_check;

alter table public.user_entitlements add constraint user_entitlements_plan_check
  check (plan = any (array[
    'free'::text,
    'pro'::text,
    'premium'::text,
    'practitioner'::text,
    'practice_pilot'::text
  ]));
