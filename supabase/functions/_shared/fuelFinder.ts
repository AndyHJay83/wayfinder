// Fuel Finder API client (UK government fuel price scheme).
// Docs: https://www.developer.fuel-finder.service.gov.uk  ·  https://www.gov.uk/guidance/access-fuel-price-data
// OAuth 2.0 client credentials; two paginated endpoints (500 records per batch); 100 requests/minute.

export const FUEL_FINDER_BASE = "https://www.fuel-finder.service.gov.uk";

/** Sent on every request. Without a User-Agent the service's firewall can answer 403. */
export const FUEL_FINDER_HEADERS = {
  "Accept": "application/json",
  "Content-Type": "application/json",
  "User-Agent": "Wayfinder/1.0 (personal navigation app; +https://github.com/AndyHJay83/wayfinder)",
};

/** First part of an error reply, for logs. Fuel Finder replies never contain our credentials. */
export async function replySnippet(res: Response): Promise<string> {
  const text = (await res.text().catch(() => "")).replace(/\s+/g, " ").trim();
  return text ? ` (${text.slice(0, 200)})` : "";
}

export interface StationInfo {
  node_id: string;
  trading_name?: string;
  brand_name?: string;
  temporary_closure?: boolean | null;
  permanent_closure?: boolean | null;
  is_motorway_service_station?: boolean | null;
  is_supermarket_service_station?: boolean | null;
  location?: {
    address_line_1?: string | null;
    address_line_2?: string | null;
    city?: string | null;
    postcode?: string | null;
    latitude?: number | null;
    longitude?: number | null;
  };
  amenities?: string[] | null;
  opening_times?: Record<string, unknown>;
}

export interface StationPrices {
  node_id: string;
  fuel_prices: {
    price: number | null;
    fuel_type: string;
    price_last_updated: string | null;
    price_change_effective_timestamp: string | null;
  }[];
}

/** The API has been seen to return bare arrays, {data: [...]} and {data: {data: [...]}}. */
export function unwrap<T>(body: unknown): T[] {
  let current: unknown = body;
  for (let i = 0; i < 3; i++) {
    if (Array.isArray(current)) return current as T[];
    if (current && typeof current === "object" && "data" in current) {
      current = (current as { data: unknown }).data;
    } else break;
  }
  return [];
}

/** E10, E5, B7, SDV (premium diesel), B10, HVO. */
export function normaliseFuelType(raw: string): string {
  const upper = raw.toUpperCase().trim().replace(/_STANDARD$/, "");
  return upper === "B7_PREMIUM" ? "SDV" : upper;
}

/** Pence per litre. The scheme reports pence (e.g. 142.9); guard against pounds (1.429). */
export function normalisePrice(price: number | null): number | null {
  if (price == null || !Number.isFinite(price) || price <= 0) return null;
  return price < 10 ? Math.round(price * 1000) / 10 : price;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export class FuelFinderClient {
  private token?: string;

  constructor(
    private clientId: string,
    private clientSecret: string,
    private fetchImpl: typeof fetch = fetch,
  ) {}

  async authenticate(): Promise<void> {
    const res = await this.fetchImpl(`${FUEL_FINDER_BASE}/api/v1/oauth/generate_access_token`, {
      method: "POST",
      headers: FUEL_FINDER_HEADERS,
      body: JSON.stringify({ client_id: this.clientId, client_secret: this.clientSecret }),
    });
    if (!res.ok) throw new Error(`Fuel Finder auth failed: ${res.status}${await replySnippet(res)}`);
    const body = await res.json();
    const token = body?.data?.access_token ?? body?.access_token;
    if (!token) throw new Error("Fuel Finder auth response had no access_token");
    this.token = token;
  }

  private async get(path: string, batch: number): Promise<unknown | null> {
    for (let attempt = 0; attempt < 3; attempt++) {
      if (!this.token) await this.authenticate();
      const url = new URL(path, FUEL_FINDER_BASE);
      url.searchParams.set("batch-number", String(batch));
      const res = await this.fetchImpl(url, {
        headers: { ...FUEL_FINDER_HEADERS, Authorization: `Bearer ${this.token}` },
      });
      if (res.status === 404) return null; // past the last batch
      if (res.status === 401 || res.status === 403) {
        this.token = undefined; // tokens can be revoked mid-run; get a fresh one
        continue;
      }
      if (res.status === 429) {
        await sleep(15_000);
        continue;
      }
      if (!res.ok) throw new Error(`Fuel Finder ${path} batch ${batch}: ${res.status}${await replySnippet(res)}`);
      return await res.json();
    }
    throw new Error(`Fuel Finder ${path} batch ${batch}: gave up after retries`);
  }

  /** Walks batches until an empty or short page. Spaced to stay under 100 requests/minute. */
  async all<T>(path: string, batchSize = 500, maxBatches = 60): Promise<T[]> {
    const out: T[] = [];
    for (let batch = 1; batch <= maxBatches; batch++) {
      const body = await this.get(path, batch);
      if (body == null) break;
      const items = unwrap<T>(body);
      out.push(...items);
      if (items.length < batchSize) break;
      await sleep(700);
    }
    return out;
  }

  stations() {
    return this.all<StationInfo>("/api/v1/pfs");
  }

  prices() {
    return this.all<StationPrices>("/api/v1/pfs/fuel-prices");
  }
}

export interface StationRow {
  id: string;
  name: string;
  brand: string | null;
  latitude: number;
  longitude: number;
  is_motorway_services: boolean;
  is_supermarket: boolean;
  amenities: unknown;
  opening_hours: unknown;
  address: string | null;
  postcode: string | null;
  temporarily_closed: boolean;
}

export function toStationRow(s: StationInfo): StationRow | null {
  const lat = s.location?.latitude, lng = s.location?.longitude;
  if (s.permanent_closure || lat == null || lng == null) return null;
  // Rough UK bounding box guards against swapped or zero coordinates.
  if (lat < 49 || lat > 61.5 || lng < -9 || lng > 2.5) return null;
  const address = [s.location?.address_line_1, s.location?.address_line_2, s.location?.city]
    .filter((x) => x && String(x).trim()).join(", ");
  return {
    id: s.node_id,
    name: (s.trading_name ?? s.brand_name ?? "Fuel station").trim(),
    brand: s.brand_name?.trim() || null,
    latitude: lat,
    longitude: lng,
    is_motorway_services: !!s.is_motorway_service_station,
    is_supermarket: !!s.is_supermarket_service_station,
    amenities: s.amenities ?? [],
    opening_hours: s.opening_times ?? {},
    address: address || null,
    postcode: s.location?.postcode ?? null,
    temporarily_closed: !!s.temporary_closure,
  };
}

export interface PriceRow {
  station_id: string;
  fuel_type: string;
  price_pence: number;
  reported_at: string | null;
}

export function toPriceRows(s: StationPrices, knownStations: Set<string>): PriceRow[] {
  if (!knownStations.has(s.node_id)) return [];
  const rows = new Map<string, PriceRow>();
  for (const p of s.fuel_prices ?? []) {
    const price = normalisePrice(p.price);
    if (price == null || !p.fuel_type) continue;
    const fuel = normaliseFuelType(p.fuel_type);
    rows.set(fuel, {
      station_id: s.node_id,
      fuel_type: fuel,
      price_pence: price,
      reported_at: p.price_change_effective_timestamp ?? p.price_last_updated ?? null,
    });
  }
  return [...rows.values()];
}
