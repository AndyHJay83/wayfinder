// Run with: deno test supabase/functions/tests/
import { assertEquals } from "jsr:@std/assert@1";
import { normaliseFuelType, normalisePrice, toPriceRows, toStationRow, unwrap } from "../_shared/fuelFinder.ts";
import { normalise, tileKey, tilesFor } from "../_shared/osmParking.ts";
import { aroundFilter, normalisePlaces, placesQuery } from "../_shared/osmPlaces.ts";
import { PLAN_SCHEMA, sanitise, systemPrompt } from "../_shared/tripPlan.ts";

Deno.test("unwrap handles bare arrays and nested envelopes", () => {
  assertEquals(unwrap([1, 2]), [1, 2]);
  assertEquals(unwrap({ data: [1] }), [1]);
  assertEquals(unwrap({ success: true, data: { success: true, data: [3] } }), [3]);
  assertEquals(unwrap({ nothing: true }), []);
});

Deno.test("fuel types are normalised", () => {
  assertEquals(normaliseFuelType("E10"), "E10");
  assertEquals(normaliseFuelType("b7_standard"), "B7");
  assertEquals(normaliseFuelType("B7_PREMIUM"), "SDV");
});

Deno.test("prices in pounds are converted to pence", () => {
  assertEquals(normalisePrice(142.9), 142.9);
  assertEquals(normalisePrice(1.429), 142.9);
  assertEquals(normalisePrice(null), null);
  assertEquals(normalisePrice(0), null);
});

Deno.test("station rows skip closed or badly placed stations", () => {
  const ok = toStationRow({
    node_id: "a", trading_name: "Shell Wimborne Rd", brand_name: "Shell",
    location: { latitude: 50.74, longitude: -1.88, address_line_1: "Wimborne Rd", city: "Bournemouth", postcode: "BH9" },
    is_motorway_service_station: false,
  });
  assertEquals(ok?.id, "a");
  assertEquals(ok?.address, "Wimborne Rd, Bournemouth");
  assertEquals(toStationRow({ node_id: "b", permanent_closure: true, location: { latitude: 50, longitude: -1 } }), null);
  assertEquals(toStationRow({ node_id: "c", location: { latitude: 0, longitude: 0 } }), null);
});

Deno.test("price rows only for known stations, latest per fuel", () => {
  const rows = toPriceRows({
    node_id: "a",
    fuel_prices: [
      { fuel_type: "E10", price: 142.9, price_last_updated: "2026-10-01T10:00:00Z", price_change_effective_timestamp: "2026-10-01T09:00:00Z" },
      { fuel_type: "B7_STANDARD", price: 149.9, price_last_updated: null, price_change_effective_timestamp: null },
      { fuel_type: "E5", price: null, price_last_updated: null, price_change_effective_timestamp: null },
    ],
  }, new Set(["a"]));
  assertEquals(rows.map((r) => r.fuel_type), ["E10", "B7"]);
  assertEquals(rows[0].reported_at, "2026-10-01T09:00:00Z");
  assertEquals(toPriceRows({ node_id: "zzz", fuel_prices: [] }, new Set(["a"])), []);
});

Deno.test("OSM car parks and street parking are normalised", () => {
  const spots = normalise([
    { type: "way", id: 1, center: { lat: 50.72, lon: -1.88 }, tags: { amenity: "parking", name: "Pavilion", fee: "yes", maxstay: "3 hours" } },
    { type: "way", id: 2, center: { lat: 50.721, lon: -1.881 }, tags: { highway: "residential", "parking:both": "lane", "parking:both:fee": "no", "parking:both:maxstay": "2 hours" } },
    { type: "way", id: 3, center: { lat: 50.722, lon: -1.882 }, tags: { highway: "residential", "parking:both": "no" } },
    { type: "way", id: 4, center: { lat: 50.723, lon: -1.883 }, tags: { highway: "residential", "parking:lane:left": "parallel", "parking:condition:left": "ticket", "parking:condition:left:time_interval": "Mo-Sa 08:00-18:00" } },
  ]);
  assertEquals(spots.map((s) => s.id), ["way/1", "way/2/both", "way/4/left"]);
  assertEquals(spots[0].kind, "car_park");
  assertEquals(spots[1].maxstay, "2 hours");
  assertEquals(spots[2].fee, "no");
  assertEquals(spots[2].fee_conditional, "yes @ (Mo-Sa 08:00-18:00)");
});

Deno.test("tiles cover the search circle", () => {
  assertEquals(tileKey(50.7234, -1.8812), "50.72,-1.89");
  const tiles = tilesFor(50.725, -1.885, 300);
  assertEquals(tiles.includes("50.72,-1.89"), true);
});


Deno.test("dietary query uses a corridor along the route", () => {
  const around = aroundFilter({ radius: 1500, route: [[-1.88, 50.72], [-1.9, 50.8]] });
  assertEquals(around, "(around:1500,50.72000,-1.88000,50.80000,-1.90000)");
  const q = placesQuery(["cafe"], ["vegan", "gluten_free"], around);
  assertEquals(q.includes(`["diet:vegan"~"^(yes|only)$"]`), true);
  assertEquals(q.includes(`["diet:gluten_free"~"^(yes|only)$"]`), true);
});

Deno.test("dietary places keep yes/only and rank full matches first", () => {
  const places = normalisePlaces([
    { type: "node", id: 1, lat: 1, lon: 2, tags: { amenity: "cafe", name: "A", "diet:vegan": "yes" } },
    { type: "node", id: 2, lat: 1, lon: 2, tags: { amenity: "cafe", name: "B", "diet:vegan": "only", "diet:gluten_free": "yes" } },
    { type: "node", id: 3, lat: 1, lon: 2, tags: { amenity: "cafe", name: "C", "diet:vegan": "limited" } },
  ], ["vegan", "gluten_free"]);
  assertEquals(places.map((p) => p.name), ["B", "A"]);
  assertEquals(places[0].diets, { vegan: "only", gluten_free: "yes" });
});

Deno.test("trip plan requests are bounded and saved places reach the prompt", () => {
  assertEquals(sanitise({ text: "   " }), null);
  const req = sanitise({
    text: "x".repeat(2000),
    history: [{ role: "system", content: "no" }, { role: "user", content: "hi" }],
    saved_places: ["Work", 3],
  })!;
  assertEquals(req.text.length, 600);
  assertEquals(req.history, [{ role: "user", content: "hi" }]);
  assertEquals(systemPrompt(req).includes("- Work"), true);
});

Deno.test("plan schema requires every field (structured output rule)", () => {
  const check = (node: Record<string, unknown>) => {
    if (node.type === "object") {
      const props = Object.keys(node.properties as object);
      assertEquals([...(node.required as string[])].sort(), props.sort());
      assertEquals(node.additionalProperties, false);
      for (const p of Object.values(node.properties as Record<string, Record<string, unknown>>)) check(p);
    }
    if (node.type === "array") check(node.items as Record<string, unknown>);
  };
  check(PLAN_SCHEMA as unknown as Record<string, unknown>);
});
