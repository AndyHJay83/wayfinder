// sync-fuel: pulls every UK station and its latest prices from the Fuel Finder API and
// upserts them into public.stations / public.prices. Called twice a day by pg_cron.
//
// Secrets (Dashboard → Edge Functions → Secrets, or `supabase secrets set`):
//   FUEL_FINDER_CLIENT_ID, FUEL_FINDER_CLIENT_SECRET  – from the Fuel Finder developer portal
//   SYNC_FUEL_SECRET                                  – any long random string; also stored in Vault
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by the platform. Never log any of them.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import { FuelFinderClient, toPriceRows, toStationRow } from "../_shared/fuelFinder.ts";

const CHUNK = 500;

function chunks<T>(items: T[], size = CHUNK): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

Deno.serve(async (req) => {
  const expected = Deno.env.get("SYNC_FUEL_SECRET");
  const given = req.headers.get("x-sync-secret") ?? "";
  if (!expected || !timingSafeEqual(given, expected)) {
    return new Response("Forbidden", { status: 403 });
  }

  const clientId = Deno.env.get("FUEL_FINDER_CLIENT_ID");
  const clientSecret = Deno.env.get("FUEL_FINDER_CLIENT_SECRET");
  if (!clientId || !clientSecret) {
    return new Response("Fuel Finder credentials are not set", { status: 500 });
  }

  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });

  const started = Date.now();
  try {
    const api = new FuelFinderClient(clientId, clientSecret);

    const stations = (await api.stations()).map(toStationRow).filter((s) => s !== null);
    for (const batch of chunks(stations)) {
      const { error } = await supabase.from("stations").upsert(batch, { onConflict: "id" });
      if (error) throw new Error(`stations upsert: ${error.message}`);
    }

    const known = new Set(stations.map((s) => s.id));
    const prices = (await api.prices()).flatMap((s) => toPriceRows(s, known));
    for (const batch of chunks(prices)) {
      const { error } = await supabase.from("prices").upsert(batch, { onConflict: "station_id,fuel_type" });
      if (error) throw new Error(`prices upsert: ${error.message}`);
    }

    const summary = { stations: stations.length, prices: prices.length, seconds: Math.round((Date.now() - started) / 1000) };
    console.log("sync-fuel done", summary);
    return Response.json(summary);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error("sync-fuel failed:", message);
    return Response.json({ error: message }, { status: 502 });
  }
});
