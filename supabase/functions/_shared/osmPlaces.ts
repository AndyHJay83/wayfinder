// Cafes and restaurants that match dietary requirements, from OpenStreetMap `diet:*` tags
// (OSM wiki: Key:diet:*). Values: "yes", "only", "limited", "no". We keep "yes" and "only".

import type { OsmElement } from "./osmParking.ts";

export const ALLOWED_AMENITIES = new Set(["cafe", "restaurant", "fast_food", "pub", "ice_cream"]);
export const ALLOWED_DIETS = new Set(["vegan", "vegetarian", "gluten_free", "halal", "kosher", "lactose_free"]);

export interface DietPlace {
  id: string;
  name: string | null;
  lat: number;
  lng: number;
  amenity: string | null;
  diets: Record<string, string>;
}

/** Overpass `around` filter: a circle, or a corridor along a polyline (lng/lat pairs). */
export function aroundFilter(opts: { lat?: number; lng?: number; radius: number; route?: number[][] }): string {
  const r = Math.round(opts.radius);
  if (opts.route && opts.route.length >= 2) {
    const coords = opts.route.map(([lng, lat]) => `${lat.toFixed(5)},${lng.toFixed(5)}`).join(",");
    return `(around:${r},${coords})`;
  }
  return `(around:${r},${opts.lat},${opts.lng})`;
}

/** One union clause per diet (OR across diets: any requested diet matches, ranked later). */
export function placesQuery(amenities: string[], diets: string[], around: string): string {
  const amenityRe = amenities.join("|");
  const clauses = diets.map((d) => `  nwr["amenity"~"^(${amenityRe})$"]["diet:${d}"~"^(yes|only)$"]${around};`);
  return `[out:json][timeout:25];\n(\n${clauses.join("\n")}\n);\nout center tags 200;`;
}

export function normalisePlaces(elements: OsmElement[], diets: string[]): DietPlace[] {
  const out: DietPlace[] = [];
  for (const e of elements) {
    const t = e.tags ?? {};
    const lat = e.lat ?? e.center?.lat, lng = e.lon ?? e.center?.lon;
    if (lat == null || lng == null) continue;
    const matched: Record<string, string> = {};
    for (const d of ALLOWED_DIETS) {
      const v = t[`diet:${d}`];
      if (v === "yes" || v === "only") matched[d] = v;
    }
    if (!diets.some((d) => matched[d])) continue;
    out.push({ id: `${e.type}/${e.id}`, name: t.name ?? t.brand ?? null, lat, lng, amenity: t.amenity ?? null, diets: matched });
  }
  // Places matching every requested diet first.
  const score = (p: DietPlace) => diets.filter((d) => p.diets[d]).length;
  return out.sort((a, b) => score(b) - score(a));
}
