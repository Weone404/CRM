// amazon-schema: READ-ONLY. Reads Amazon.in's own field rules (Product Type Definitions) for our product types,
// so suggestions only use fields and values Amazon really accepts. Never changes a listing.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { cronOk, loadApi, scrub } from "../_shared/amazon_deno.ts";

const WANT = ["item_name", "item_highlights", "title_differentiation", "bullet_point", "product_description", "generic_keyword",
  "theme", "special_feature", "specific_uses_for_product", "cover", "material", "style", "pattern", "occasion_type", "target_audience_keyword",
  "recommended_uses_for_product", "paper_size", "ruling_type", "format", "binding", "page_count", "pages", "color", "size", "is_customizable",
  "customized_gift_service", "personalization", "included_components", "lifestyle", "seasons", "gift_options"];

function walk(node: any, out: { maxLength?: number; maxItems?: number; enums?: string[]; enumNames?: string[] }, depth = 0) {
  if (!node || typeof node !== "object" || depth > 8) return;
  if (typeof node.maxLength === "number") out.maxLength = Math.max(out.maxLength ?? 0, node.maxLength);
  if (typeof node.maxUtf8ByteLength === "number") out.maxLength = Math.max(out.maxLength ?? 0, node.maxUtf8ByteLength);
  if (Array.isArray(node.enum) && node.enum.length) out.enums = [...(out.enums ?? []), ...node.enum.map(String)].slice(0, 120);
  if (Array.isArray(node.anyOf)) for (const a of node.anyOf) if (Array.isArray(a.enum)) out.enums = [...(out.enums ?? []), ...a.enum.map(String)].slice(0, 120);
  for (const v of Object.values(node)) if (v && typeof v === "object") walk(v, out, depth + 1);
}

Deno.serve(async (req) => {
  let secrets: Record<string, string> = {};
  try {
    if (!(await cronOk(req))) return new Response(JSON.stringify({ detail: "forbidden" }), { status: 403 });
    const body = await req.json().catch(() => ({}));
    const types: string[] = Array.isArray(body.types) ? body.types.slice(0, 4) : ["BLANK_BOOK", "PLANNER"];
    const { api, secrets: s } = await loadApi(); secrets = s;
    const result: Record<string, unknown> = {};
    for (const pt of types) {
      const def = await api.request("GET", `/definitions/2020-09-01/productTypes/${encodeURIComponent(pt)}`, {
        query: { marketplaceIds: api.marketplaceId, requirements: "LISTING", locale: "en_IN" } });
      const r = await fetch(def?.schema?.link?.resource);
      const schema = await r.json();
      const props = schema?.properties ?? {};
      const fields: Record<string, unknown> = {};
      for (const k of WANT) {
        if (!props[k]) { fields[k] = "NOT IN SCHEMA"; continue; }
        const o: any = {}; walk(props[k], o);
        fields[k] = { title: props[k].title, description: String(props[k].description ?? "").slice(0, 300), maxItems: props[k].maxItems,
          maxLength: o.maxLength, enums: o.enums ? [...new Set(o.enums)] : undefined };
      }
      result[pt] = { version: def?.productTypeVersion?.version, required: schema?.required ?? [], all_fields: Object.keys(props).sort(), fields };
    }
    return new Response(JSON.stringify(result), { headers: { "Content-Type": "application/json" } });
  } catch (e) {
    return new Response(JSON.stringify({ detail: scrub(e instanceof Error ? e.message : String(e), secrets).slice(0, 500) }), { status: 500 });
  }
});
