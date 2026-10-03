// Normalises OpenStreetMap parking tags into one simple record per spot.
// Tag references (OSM wiki): amenity=parking, Street parking (parking:<side>=*, parking:<side>:fee,
// :maxstay, :restriction, :access and their :conditional forms). The deprecated
// parking:lane:* / parking:condition:* scheme is still common in UK data, so it is read too.

export interface OsmElement {
  type: "node" | "way" | "relation";
  id: number;
  lat?: number;
  lon?: number;
  center?: { lat: number; lon: number };
  tags?: Record<string, string>;
}

export interface ParkingSpot {
  id: string;
  kind: "car_park" | "street";
  name: string | null;
  lat: number;
  lng: number;
  fee: string | null;
  fee_conditional: string | null;
  maxstay: string | null;
  maxstay_conditional: string | null;
  restriction: string | null;
  restriction_conditional: string | null;
  access: string | null;
  opening_hours: string | null;
  charge: string | null;
}

const SIDES = ["both", "left", "right"] as const;
const NO_PARKING = new Set(["no", "separate", "no_parking", "no_stopping", "fire_lane"]);

export function overpassQuery(lat: number, lng: number, radius: number): string {
  const around = `(around:${Math.round(radius)},${lat},${lng})`;
  return `[out:json][timeout:25];
(
  nwr["amenity"="parking"]${around};
  way["highway"]["parking:both"]${around};
  way["highway"]["parking:left"]${around};
  way["highway"]["parking:right"]${around};
  way["highway"]["parking:lane:both"]${around};
  way["highway"]["parking:lane:left"]${around};
  way["highway"]["parking:lane:right"]${around};
);
out center tags;`;
}

function position(e: OsmElement): { lat: number; lng: number } | null {
  if (e.lat != null && e.lon != null) return { lat: e.lat, lng: e.lon };
  if (e.center) return { lat: e.center.lat, lng: e.center.lon };
  return null;
}

/** Legacy parking:condition values → fee / access / restriction. */
function fromLegacyCondition(condition: string | undefined) {
  switch (condition) {
    case "free": return { fee: "no" };
    case "ticket": return { fee: "yes" };
    case "disc": return { fee: "no" };
    case "residents": return { access: "private" };
    case "customers": return { access: "customers" };
    case "private": return { access: "private" };
    case "no_parking": return { restriction: "no_parking" };
    case "no_stopping": return { restriction: "no_stopping" };
    case "loading": return { restriction: "loading_only" };
    default: return {};
  }
}

export function normalise(elements: OsmElement[]): ParkingSpot[] {
  const spots: ParkingSpot[] = [];
  for (const e of elements) {
    const t = e.tags ?? {};
    const pos = position(e);
    if (!pos) continue;

    if (t.amenity === "parking") {
      spots.push({
        id: `${e.type}/${e.id}`,
        kind: "car_park",
        name: t.name ?? t.operator ?? null,
        ...pos,
        fee: t.fee ?? null,
        fee_conditional: t["fee:conditional"] ?? null,
        maxstay: t.maxstay ?? null,
        maxstay_conditional: t["maxstay:conditional"] ?? null,
        restriction: null,
        restriction_conditional: null,
        access: t.access ?? null,
        opening_hours: t.opening_hours ?? null,
        charge: t.charge ?? null,
      });
      continue;
    }

    // Street parking: one spot per way (the first side that allows parking).
    for (const side of SIDES) {
      const current = t[`parking:${side}`];
      const legacyLane = t[`parking:lane:${side}`];
      if (current === undefined && legacyLane === undefined) continue;
      if ((current && NO_PARKING.has(current)) || (!current && legacyLane && NO_PARKING.has(legacyLane))) continue;

      const p = `parking:${side}`;
      const legacy = fromLegacyCondition(t[`parking:condition:${side}`]);
      const legacyInterval = t[`parking:condition:${side}:time_interval`];
      let feeConditional = t[`${p}:fee:conditional`] ?? null;
      if (!feeConditional && legacy.fee === "yes" && legacyInterval) feeConditional = `yes @ (${legacyInterval})`;

      spots.push({
        id: `${e.type}/${e.id}/${side}`,
        kind: "street",
        name: t.name ?? null,
        ...pos,
        fee: t[`${p}:fee`] ?? (legacyInterval && legacy.fee === "yes" ? "no" : legacy.fee) ?? null,
        fee_conditional: feeConditional,
        maxstay: t[`${p}:maxstay`] ?? t[`parking:condition:${side}:maxstay`] ?? null,
        maxstay_conditional: t[`${p}:maxstay:conditional`] ?? null,
        restriction: t[`${p}:restriction`] ?? legacy.restriction ?? null,
        restriction_conditional: t[`${p}:restriction:conditional`] ?? null,
        access: t[`${p}:access`] ?? legacy.access ?? null,
        opening_hours: null,
        charge: t[`${p}:charge`] ?? null,
      });
      break;
    }
  }
  return spots;
}

/** 0.01° grid tile key (~1.1 km north-south). */
export function tileKey(lat: number, lng: number): string {
  return `${(Math.floor(lat * 100) / 100).toFixed(2)},${(Math.floor(lng * 100) / 100).toFixed(2)}`;
}

export function tileCenter(key: string): { lat: number; lng: number } {
  const [lat, lng] = key.split(",").map(Number);
  return { lat: lat + 0.005, lng: lng + 0.005 };
}

export function distanceMetres(a: { lat: number; lng: number }, b: { lat: number; lng: number }): number {
  const R = 6_371_000, toRad = Math.PI / 180;
  const dLat = (b.lat - a.lat) * toRad, dLng = (b.lng - a.lng) * toRad;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(a.lat * toRad) * Math.cos(b.lat * toRad) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
}

/** Tiles covering a circle. */
export function tilesFor(lat: number, lng: number, radius: number): string[] {
  const dLat = radius / 111_000, dLng = radius / (111_000 * Math.cos((lat * Math.PI) / 180));
  const keys = new Set<string>();
  for (let y = lat - dLat; y <= lat + dLat + 0.01; y += 0.01) {
    for (let x = lng - dLng; x <= lng + dLng + 0.01; x += 0.01) keys.add(tileKey(Math.min(y, lat + dLat), Math.min(x, lng + dLng)));
  }
  return [...keys];
}
