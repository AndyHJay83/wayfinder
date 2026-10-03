-- Stage 10: run sync-fuel twice a day at 06:00 and 18:00 UTC
-- (07:00 / 19:00 UK time in summer, 06:00 / 18:00 in winter).
--
-- Before this works, add two Vault secrets once in the SQL editor (values are NOT in this repo):
--   select vault.create_secret('https://YOUR_PROJECT_REF.supabase.co', 'project_url');
--   select vault.create_secret('THE_SAME_VALUE_AS_SYNC_FUEL_SECRET', 'sync_fuel_secret');

create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

create or replace function public.invoke_sync_fuel()
returns bigint
language sql
security definer
set search_path = ''
as $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/sync-fuel',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-sync-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'sync_fuel_secret')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 150000
  );
$$;

revoke execute on function public.invoke_sync_fuel() from public, anon, authenticated;

select cron.schedule('sync-fuel-morning', '0 6 * * *', $$ select public.invoke_sync_fuel(); $$);
select cron.schedule('sync-fuel-evening', '0 18 * * *', $$ select public.invoke_sync_fuel(); $$);
