-- Stage 13: OpenStreetMap parking data cache (filled by the parking-osm Edge Function).
-- One row per ~1 km grid tile, refreshed when older than 7 days.

create table public.parking_cache (
  tile text primary key,                     -- e.g. "50.72,-1.88" (0.01° grid)
  fetched_at timestamptz not null default now(),
  spots jsonb not null default '[]'::jsonb
);

comment on table public.parking_cache is 'Normalised OSM parking per tile. Written and read only by the parking-osm Edge Function (service role).';

-- No policies: anon/authenticated can't read or write; the Edge Function uses the service role.
alter table public.parking_cache enable row level security;
