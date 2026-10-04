// places-osm: cafes/restaurants matching dietary requirements (OpenStreetMap diet:* tags),
// near a point or in a corridor along a route.
//
// Request:  POST { "amenities": ["cafe"], "diets": ["vegan"], "lat": 50.72, "lng": -1.88, "radius_m": 3000 }
//       or  POST { "amenities": ["cafe"], "diets": ["gluten_free"], "route": [[lng, lat], ...], "corridor_m": 2000 }
// Response: DietPlace[] (see ../_shared/osmPlaces.ts)
//
// No cache table: dietary searches are rare and the query is cheap. Optional secret
// APP_PUBLISHABLE_KEY: if set, callers must send it as the `apikey` header.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { ALLOWED_AMENITIES, ALLOWED_DIETS, aroundFilter, normalisePlaces, placesQuery } from "../_shared/osmPlaces.ts";

const OVERPASS_URL = "https://overpass-api.de/api/interpreter";

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("POST only", { status: 405 });

  const requiredKey = Deno.env.get("APP_PUBLISHABLE_KEY");
  if (requiredKey && req.headers.get("apikey") !== requiredKey) {
    return new Response("Forbidden", { status: 403 });
  }

  let body: {
    amenities?: string[]; diets?: string[]; lat?: number; lng?: number;
    radius_m?: number; route?: number[][]; corridor_m?: number;
  };
  try {
    body = await req.json();
  } catch {
    return new Response("Invalid JSON", { status: 400 });
  }

  const amenities = (body.amenities ?? []).filter((a) => ALLOWED_AMENITIES.has(a));
  const diets = (body.diets ?? []).filter((d) => ALLOWED_DIETS.has(d));
  if (amenities.length === 0 || diets.length === 0) return new Response("amenities and diets required", { status: 400 });

  const route = Array.isArray(body.route)
    ? body.route.filter((p) => Array.isArray(p) && p.length === 2 && p.every((n) => typeof n === "number")).slice(0, 120)
    : undefined;
  const hasPoint = typeof body.lat === "number" && typeof body.lng === "number";
  if (!hasPoint && !(route && route.length >= 2)) return new Response("lat/lng or route required", { status: 400 });

  const radius = route && route.length >= 2
    ? Math.min(Math.max(body.corridor_m ?? 2000, 200), 5000)
    : Math.min(Math.max(body.radius_m ?? 3000, 200), 10000);
  const around = aroundFilter({ lat: body.lat, lng: body.lng, radius, route });

  try {
    const res = await fetch(OVERPASS_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded", "User-Agent": "Wayfinder personal app" },
      body: "data=" + encodeURIComponent(placesQuery(amenities, diets, around)),
    });
    if (!res.ok) return Response.json({ error: `Overpass ${res.status}` }, { status: 502 });
    const json = await res.json();
    return Response.json(normalisePlaces(json.elements ?? [], diets).slice(0, 60));
  } catch (err) {
    return Response.json({ error: err instanceof Error ? err.message : "Overpass failed" }, { status: 502 });
  }
});
