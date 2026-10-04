-- Fuel Finder refuses requests from outside the UK (empty 403 from its firewall). Edge
-- Functions otherwise run in the region nearest the caller (Ireland for this project), so
-- pin the scheduled sync to London with the x-region header.

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
      'x-region', 'eu-west-2',
      'x-sync-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'sync_fuel_secret')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 150000
  );
$$;

revoke execute on function public.invoke_sync_fuel() from public, anon, authenticated;
