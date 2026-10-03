// parking-osm: returns normalised OpenStreetMap parking near a point.
// Each ~1 km tile is fetched from the Overpass API at most once a week and cached in
// public.parking_cache, so the app never hits Overpass directly.
//
// Request:  POST { "lat": 50.72, "lng": -1.88, "radius_m": 500 }
// Response: ParkingSpot[] (see ../_shared/osmParking.ts)
//
// Optional secret APP_PUBLISHABLE_KEY: if set, callers must send it as the `apikey` header.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import { distanceMetres, normalise, overpassQuery, type ParkingSpot, tileCenter, tilesFor } from "../_shared/osmParking.ts";

const OVERPASS_URL = "https://overpass-api.de/api/interpreter";
const WEEK_MS = 7 * 24 * 3600 * 1000;
const TILE_RADIUS = 800; // covers a 0.01° tile from its centre

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("POST only", { status: 405 });

  const requiredKey = Deno.env.get("APP_PUBLISHABLE_KEY");
  if (requiredKey && req.headers.get("apikey") !== requiredKey) {
    return new Response("Forbidden", { status: 403 });
  }

  let body: { lat?: number; lng?: number; radius_m?: number };
  try {
    body = await req.json();
  } catch {
    return new Response("Invalid JSON", { status: 400 });
  }
  const { lat, lng } = body;
  const radius = Math.min(Math.max(body.radius_m ?? 500, 100), 1500);
  if (typeof lat !== "number" || typeof lng !== "number" || lat < 49 || lat > 61.5 || lng < -9 || lng > 2.5) {
    return new Response("lat/lng must be a UK coordinate", { status: 400 });
  }

  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });

  const keys = tilesFor(lat, lng, radius);
  const { data: cached, error } = await supabase.from("parking_cache").select("tile, fetched_at, spots").in("tile", keys);
  if (error) return Response.json({ error: error.message }, { status: 500 });

  const fresh = new Map<string, ParkingSpot[]>();
  for (const row of cached ?? []) {
    if (Date.now() - new Date(row.fetched_at).getTime() < WEEK_MS) fresh.set(row.tile, row.spots as ParkingSpot[]);
  }

  for (const key of keys.filter((k) => !fresh.has(k))) {
    const centre = tileCenter(key);
    try {
      const res = await fetch(OVERPASS_URL, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded", "User-Agent": "Wayfinder personal app" },
        body: "data=" + encodeURIComponent(overpassQuery(centre.lat, centre.lng, TILE_RADIUS)),
      });
      if (!res.ok) throw new Error(`Overpass ${res.status}`);
      const json = await res.json();
      const spots = normalise(json.elements ?? []);
      fresh.set(key, spots);
      await supabase.from("parking_cache").upsert({ tile: key, fetched_at: new Date().toISOString(), spots });
    } catch (err) {
      console.error("overpass failed for tile", key, err instanceof Error ? err.message : err);
      // Serve stale data for this tile if we have any.
      const stale = (cached ?? []).find((r) => r.tile === key);
      if (stale) fresh.set(key, stale.spots as ParkingSpot[]);
    }
  }

  const seen = new Set<string>();
  const result = [...fresh.values()].flat().filter((s) => {
    if (seen.has(s.id)) return false;
    seen.add(s.id);
    return distanceMetres({ lat, lng }, s) <= radius * 1.3;
  });
  return Response.json(result);
});
