// Shared schema and prompt for the plan-trip function. Kept separate so it can be tested
// without calling the API.

export const CATEGORIES = ["petrol", "cafe", "food", "carPark", "search"] as const;
export const DIETS = ["vegan", "vegetarian", "gluten_free", "halal", "kosher", "lactose_free"] as const;

/** JSON schema for structured output. Every field is required; "" or -1 mean "not given". */
export const PLAN_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["question", "summary", "destination", "stops", "parking"],
  properties: {
    question: { type: "string", description: "One short clarifying question, or empty string when the plan is clear." },
    summary: { type: "string", description: "One sentence describing the plan, for the driver." },
    destination: {
      type: "object",
      additionalProperties: false,
      required: ["saved_place", "query"],
      properties: {
        saved_place: { type: "string", description: "Exact name from the saved places list, or empty." },
        query: { type: "string", description: "Search text for the destination when it isn't a saved place, or empty to keep the current destination." },
      },
    },
    stops: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["category", "query", "dietary", "stay_minutes", "needs_free_parking"],
        properties: {
          category: { type: "string", enum: [...CATEGORIES] },
          query: { type: "string", description: "Search text for category 'search' (e.g. 'launderette'), else empty." },
          dietary: { type: "array", items: { type: "string", enum: [...DIETS] } },
          stay_minutes: { type: "integer", description: "Expected time stopped, or -1 if unknown." },
          needs_free_parking: { type: "boolean" },
        },
      },
    },
    parking: {
      type: "object",
      additionalProperties: false,
      required: ["needed", "stay_minutes", "free_preferred"],
      properties: {
        needed: { type: "boolean", description: "True when the driver wants parking at the destination." },
        stay_minutes: { type: "integer", description: "Planned stay at the destination, 10 for pick up or drop off, -1 if unknown." },
        free_preferred: { type: "boolean" },
      },
    },
  },
} as const;

export interface PlanRequest {
  text: string;
  history: { role: "user" | "assistant"; content: string }[];
  saved_places: string[];
  current_destination: string;
}

export function systemPrompt(req: PlanRequest): string {
  const saved = req.saved_places.length ? req.saved_places.map((n) => `- ${n}`).join("\n") : "(none)";
  return `You turn a driver's spoken or typed request into a trip plan for a UK car navigation app.

The app will search for each stop along the route and pick the best one, so describe stops by category or search text, not by exact business.

Saved places (use the exact name in destination.saved_place when the driver means one, matching loosely, e.g. "work" matches "Work" or "Office"):
${saved}

Current destination: ${req.current_destination || "(none)"}

How to fill the plan:
- destination: a saved place name, or search text for somewhere else. Leave both empty only if the driver is adding stops to the current destination.
- stops, in the order the driver wants them: "petrol" for fuel, "cafe" for coffee, "food" for meals or snacks, "carPark" for a car park on the way, and "search" with query text for anything else (laundrette, pharmacy, cash machine, supermarket…). UK wording is fine in query.
- dietary needs ("gluten free", "vegan options") go on cafe or food stops.
- "no change for parking", "no cash" or "free parking" means needs_free_parking on stops and parking.free_preferred.
- parking.needed when the driver mentions parking at the destination; pick up or drop off is 10 minutes.
- Ask a question only if the plan can't be made without it, for example the destination is unclear and isn't a saved place. Otherwise question is empty and you make sensible assumptions.
- summary: one short, plain sentence, e.g. "Laundrette on the way, then Work. Looking for free parking."`;
}

/** Bounds user input so a stray request can't run up a large bill. */
export function sanitise(body: unknown): PlanRequest | null {
  if (!body || typeof body !== "object") return null;
  const b = body as Record<string, unknown>;
  const text = typeof b.text === "string" ? b.text.trim().slice(0, 600) : "";
  if (!text) return null;
  const history = Array.isArray(b.history)
    ? b.history
      .filter((m): m is { role: "user" | "assistant"; content: string } =>
        !!m && typeof m === "object" && ((m as { role?: unknown }).role === "user" || (m as { role?: unknown }).role === "assistant") &&
        typeof (m as { content?: unknown }).content === "string"
      )
      .slice(-8)
      .map((m) => ({ role: m.role, content: m.content.slice(0, 1500) }))
    : [];
  const saved = Array.isArray(b.saved_places)
    ? b.saved_places.filter((s): s is string => typeof s === "string").slice(0, 50).map((s) => s.slice(0, 80))
    : [];
  const current = typeof b.current_destination === "string" ? b.current_destination.slice(0, 120) : "";
  return { text, history, saved_places: saved, current_destination: current };
}
