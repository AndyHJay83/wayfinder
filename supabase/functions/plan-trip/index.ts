// plan-trip: natural-language trip requests ("I need to go to work, but stop at a
// laundrette first, I've got no change for parking") → a structured plan the app runs
// through its own planner. Uses the Claude API with structured output.
//
// Request:  POST { "text": "...", "history": [{ "role": "user"|"assistant", "content": "..." }],
//                  "saved_places": ["Home", "Work"], "current_destination": "" }
// Response: the plan (see ../_shared/tripPlan.ts PLAN_SCHEMA).
//
// Secrets: ANTHROPIC_API_KEY (required). Optional APP_PUBLISHABLE_KEY: if set, callers must
// send it as the `apikey` header (recommended, so only the app can spend your API credit).

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import Anthropic from "npm:@anthropic-ai/sdk@^0.131.0";
import { PLAN_SCHEMA, sanitise, systemPrompt } from "../_shared/tripPlan.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("POST only", { status: 405 });

  const requiredKey = Deno.env.get("APP_PUBLISHABLE_KEY");
  if (requiredKey && req.headers.get("apikey") !== requiredKey) {
    return new Response("Forbidden", { status: 403 });
  }

  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) return Response.json({ error: "ANTHROPIC_API_KEY isn't set in Supabase Edge Function secrets." }, { status: 503 });

  let request;
  try {
    request = sanitise(await req.json());
  } catch {
    return new Response("Invalid JSON", { status: 400 });
  }
  if (!request) return new Response("text required", { status: 400 });

  const client = new Anthropic({ apiKey });
  try {
    const response = await client.messages.create({
      model: "claude-opus-5-5",
      max_tokens: 4000,
      system: systemPrompt(request),
      messages: [...request.history, { role: "user", content: request.text }],
      output_config: {
        effort: "low",
        format: { type: "json_schema", schema: PLAN_SCHEMA },
      },
    });

    if (response.stop_reason === "refusal") {
      return Response.json({ error: "Sorry, I can't help plan that trip." }, { status: 422 });
    }
    const text = response.content.find((block) => block.type === "text");
    if (!text || text.type !== "text") return Response.json({ error: "No plan returned" }, { status: 502 });
    return new Response(text.text, { headers: { "Content-Type": "application/json" } });
  } catch (err) {
    console.error("plan-trip failed", err instanceof Error ? err.message : err);
    const status = err instanceof Anthropic.APIError && typeof err.status === "number" ? err.status : 502;
    return Response.json({ error: "Couldn't reach the planner. Try again." }, { status: status >= 500 ? 502 : status });
  }
});
