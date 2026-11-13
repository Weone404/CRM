// node --test tools/ads-agents/agents.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { parseJson, claudeArgs, buildPrompt } from "./agents.mjs";
import { PROMPTS } from "./prompts.mjs";

test("parseJson finds the object around fences and text, with braces inside strings", () => {
  assert.deepEqual(parseJson('Here:\n```json\n{"verdict":"approve","notes":"a } b"}\n```'), { verdict: "approve", notes: "a } b" });
  assert.equal(parseJson("no json"), null);
  assert.deepEqual(parseJson('{bad} then {"ok":1}'), { ok: 1 });
});
test("only the researcher gets tools, and only web search/fetch", () => {
  const r = claudeArgs("researcher"), b = claudeArgs("builder"), v = claudeArgs("reviewer");
  assert.equal(r[r.indexOf("--tools") + 1], "WebSearch,WebFetch");
  for (const a of [b, v]) { assert.equal(a[a.indexOf("--tools") + 1], ""); assert.ok(a.includes("--disallowedTools")); }
  for (const a of [r, b, v]) assert.ok(a.includes("--strict-mcp-config"));
});
test("every role has instructions and the prompt carries input and context", () => {
  for (const k of ["researcher", "builder", "reviewer"]) assert.ok(PROMPTS[k].length > 500);
  const p = buildPrompt("builder", { input: { task: { goal: "x" } } }, { today: "2026-11-13" });
  assert.ok(p.includes('"goal":"x"') && p.includes('"today":"2026-11-13"'));
});
