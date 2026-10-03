-- Stage 10: UK Fuel Finder price cache.
-- Stations and current prices, synced twice a day by the sync-fuel Edge Function.
-- The app reads through stations_near / stations_along using the publishable key (read only).

create extension if not exists postgis with schema extensions;

create table public.stations (
  id text primary key,                       -- Fuel Finder node_id
  name text not null,
  brand text,
  latitude double precision not null,
  longitude double precision not null,
  location extensions.geography(Point, 4326) not null,
  is_motorway_services boolean not null default false,
  is_supermarket boolean not null default false,
  amenities jsonb not null default '[]'::jsonb,
  opening_hours jsonb not null default '{}'::jsonb,
  address text,
  postcode text,
  temporarily_closed boolean not null default false,
  updated_at timestamptz not null default now()
);

comment on table public.stations is 'UK forecourts from the Fuel Finder scheme. Written only by the sync-fuel Edge Function.';

create index stations_location_gix on public.stations using gist (location);

create table public.prices (
  station_id text not null references public.stations (id) on delete cascade,
  fuel_type text not null,                   -- E10, E5, B7, SDV, B10, HVO
  price_pence numeric(6, 1) not null,
  reported_at timestamptz,
  primary key (station_id, fuel_type)
);

comment on table public.prices is 'Latest reported price per station and fuel. Price age must always be shown with the price.';

create index prices_fuel_type_idx on public.prices (fuel_type);

-- Keep location in sync with latitude/longitude.
create or replace function public.stations_set_location()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.location := extensions.st_setsrid(extensions.st_makepoint(new.longitude, new.latitude), 4326)::extensions.geography;
  new.updated_at := now();
  return new;
end;
$$;

create trigger stations_set_location
  before insert or update of latitude, longitude on public.stations
  for each row execute function public.stations_set_location();

-- Row level security: the app (anon/authenticated) may read, never write.
alter table public.stations enable row level security;
alter table public.prices enable row level security;

create policy "Anyone can read stations" on public.stations
  for select to anon, authenticated using (true);

create policy "Anyone can read prices" on public.prices
  for select to anon, authenticated using (true);

revoke insert, update, delete, truncate on public.stations, public.prices from anon, authenticated;

-- Stations within radius_m of a point, with price, price age and distance.
create or replace function public.stations_near(
  lat double precision,
  lng double precision,
  radius_m double precision default 8000,
  fuel_type text default 'E10'
)
returns table (
  station_id text,
  name text,
  brand text,
  latitude double precision,
  longitude double precision,
  is_motorway_services boolean,
  price_pence numeric,
  reported_at timestamptz,
  price_age_seconds double precision,
  distance_m double precision,
  distance_along_m double precision
)
language sql
stable
security invoker
set search_path = ''
as $$
  with here as (
    select extensions.st_setsrid(extensions.st_makepoint(lng, lat), 4326)::extensions.geography as g
  )
  select
    s.id,
    s.name,
    s.brand,
    s.latitude,
    s.longitude,
    s.is_motorway_services,
    p.price_pence,
    p.reported_at,
    extract(epoch from (now() - p.reported_at))::double precision,
    extensions.st_distance(s.location, here.g),
    null::double precision
  from public.stations s
  cross join here
  left join public.prices p
    on p.station_id = s.id and p.fuel_type = stations_near.fuel_type
  where extensions.st_dwithin(s.location, here.g, least(radius_m, 50000))
    and not s.temporarily_closed
  order by extensions.st_distance(s.location, here.g)
  limit 200;
$$;

-- Stations within corridor_m of a route, with distance along the route.
-- route is a JSON array of [lng, lat] pairs, e.g. [[-1.88, 50.72], [-1.80, 50.75], ...].
create or replace function public.stations_along(
  route jsonb,
  corridor_m double precision default 2000,
  fuel_type text default 'E10'
)
returns table (
  station_id text,
  name text,
  brand text,
  latitude double precision,
  longitude double precision,
  is_motorway_services boolean,
  price_pence numeric,
  reported_at timestamptz,
  price_age_seconds double precision,
  distance_m double precision,
  distance_along_m double precision
)
language sql
stable
security invoker
set search_path = ''
as $$
  with pts as (
    select extensions.st_makepoint((pt ->> 0)::double precision, (pt ->> 1)::double precision) as geom, ord
    from jsonb_array_elements(route) with ordinality as t(pt, ord)
  ),
  line as (
    select extensions.st_setsrid(extensions.st_makeline(array_agg(geom order by ord)), 4326) as geom
    from pts
  )
  select
    s.id,
    s.name,
    s.brand,
    s.latitude,
    s.longitude,
    s.is_motorway_services,
    p.price_pence,
    p.reported_at,
    extract(epoch from (now() - p.reported_at))::double precision,
    extensions.st_distance(s.location, line.geom::extensions.geography),
    extensions.st_linelocatepoint(line.geom, s.location::extensions.geometry)
      * extensions.st_length(line.geom::extensions.geography)
  from public.stations s
  cross join line
  left join public.prices p
    on p.station_id = s.id and p.fuel_type = stations_along.fuel_type
  where extensions.st_dwithin(s.location, line.geom::extensions.geography, least(corridor_m, 10000))
    and not s.temporarily_closed
  order by 11
  limit 500;
$$;

grant execute on function public.stations_near(double precision, double precision, double precision, text) to anon, authenticated;
grant execute on function public.stations_along(jsonb, double precision, text) to anon, authenticated;
