#!/usr/bin/env node
// ADS agents helper (Google Ads, and Meta Ads > Strategy plans). Two ways to run it, and both can run side by side (the CRM hands each step to one of them only):
//  - on the owner's Mac, always on, with that Mac's Claude Code login (launchd, see install.sh);
//  - in the cloud on a schedule, with no Mac at all (.github/workflows/ads-agents.yml): ADS_AGENTS_ONCE=1 works through
//    whatever is waiting and exits. The token then comes from ADS_AGENTS_TOKEN and Claude signs in with CLAUDE_CODE_OAUTH_TOKEN.
// Separate from the Amazon helper (tools/claude-bridge): own folder (~/.ads-agents), own token, own Edge Function (ads-agents).
//
// Loop: ask the CRM for the next step -> run `claude -p` in the role (researcher / builder / reviewer, or meta_researcher /
// meta_strategist / meta_reviewer) -> send the JSON back.
// Safety:
//  - Only the Researchers may use tools, and only WebSearch + WebFetch. Everyone else has no tools at all.
//  - The agents never see Google credentials. What they propose is checked in the CRM (code checks, then the Reviewer, then
//    Google's own pre-check) and every change is read back from Google before it counts as done.
//  - The token (~/.ads-agents/token, mode 600) is the only secret here. Emergency stop in CRM > ADS > Autopilot pauses everything.
// No npm packages needed (Node 18+).
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, existsSync, writeFileSync, renameSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname } from "node:path";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { PROMPTS } from "./prompts.mjs";

const CONF = join(homedir(), ".ads-agents");
let TOKEN = null;   // read on first use
const CFG = existsSync(join(CONF, "config.json")) ? JSON.parse(readFileSync(join(CONF, "config.json"), "utf8")) : {};
const URL_ = process.env.ADS_AGENTS_URL || CFG.url || "https://syytqcadmtgowckdnbqh.supabase.co/functions/v1/ads-agents";
// Second lane: Google My Business review replies (migration 140). Same token, its own door (crm-google-business), asked only when
// the ADS queue is empty. Off when the ADS address is not the standard one and no address is given for it.
const GBP_URL = process.env.GBP_AGENTS_URL || CFG.gbp_url || (/\/ads-agents\/?$/.test(URL_) ? URL_.replace(/\/ads-agents\/?$/, "/crm-google-business") : "");
export const GBP_ROLES = ["gbp_reply_writer", "gbp_reply_reviewer"];
const CLAUDE = process.env.CLAUDE_BIN || (existsSync(join(CONF, "claude-path")) ? readFileSync(join(CONF, "claude-path"), "utf8").trim() : "claude");
const MODELS = { researcher: "sonnet", builder: "opus", reviewer: "opus", learner: "opus",
  meta_researcher: "sonnet", meta_strategist: "opus", meta_reviewer: "opus", meta_content_analyst: "sonnet", meta_content_planner: "opus",
  gbp_reply_writer: "sonnet", gbp_reply_reviewer: "opus", ...(CFG.models || {}) };
const TIMEOUT = { researcher: 15 * 60e3, builder: 8 * 60e3, reviewer: 6 * 60e3, learner: 8 * 60e3,
  meta_researcher: 15 * 60e3, meta_strategist: 12 * 60e3, meta_reviewer: 8 * 60e3, meta_content_analyst: 12 * 60e3, meta_content_planner: 10 * 60e3,
  gbp_reply_writer: 4 * 60e3, gbp_reply_reviewer: 4 * 60e3 };
export const WEB_ROLES = new Set(["researcher", "meta_researcher", "meta_content_analyst"]);
const ONCE = process.env.ADS_AGENTS_ONCE === "1";
let STOP = false;                  // one-pass mode: a usage limit ends the pass instead of waiting
const IDLE_MS = 60e3;              // ask for work once a minute when idle
const LIMIT_PAUSE_MS = 15 * 60e3;  // after a Claude usage limit
const WORKDIR = mkdtempSync(join(tmpdir(), "ads-agents-"));
const log = (...a) => console.log(new Date().toISOString(), ...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function callAt(body, url = URL_) {
  TOKEN ??= (process.env.ADS_AGENTS_TOKEN || readFileSync(join(CONF, "token"), "utf8")).trim();
  const res = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json", "x-ads-agents-token": TOKEN },
    body: JSON.stringify(body), signal: AbortSignal.timeout(90000) });
  const out = await res.json().catch(() => ({}));
  if (res.status === 401) { const e = new Error("token rejected"); e.code = 401; throw e; }
  if (!res.ok) throw new Error(out.detail || `HTTP ${res.status}`);
  return out;
}

export function buildPrompt(role, run, context) {
  return `${PROMPTS[role]}\n\nINPUT:\n${JSON.stringify(run.input)}\n\nCONTEXT:\n${JSON.stringify(context)}\n\nReply with the JSON object now.`;
}

export function claudeArgs(role) {
  const base = ["-p", "--output-format", "json", "--strict-mcp-config", "--no-session-persistence", "--model", MODELS[role] || "sonnet"];
  return WEB_ROLES.has(role)
    ? [...base, "--tools", "WebSearch,WebFetch", "--allowedTools", "WebSearch,WebFetch", "--max-turns", "40"]
    : [...base, "--tools", "", "--disallowedTools", "*", "--max-turns", "2"];
}

export function runClaude(role, text) {
  return new Promise((resolve) => {
    const p = spawn(CLAUDE, claudeArgs(role), { cwd: WORKDIR, env: { ...process.env, CLAUDE_CODE_SKIP_PROMPT_HISTORY: "1" } });
    let out = "", err = "";
    const timer = setTimeout(() => p.kill("SIGTERM"), TIMEOUT[role] || 8 * 60e3);
    p.stdout.on("data", (d) => { out += d; });
    p.stderr.on("data", (d) => { err += d; });
    p.on("error", (e) => { clearTimeout(timer); resolve({ ok: false, note: `Claude Code not found (${e.code})` }); });
    p.on("close", (code, signal) => {
      clearTimeout(timer);
      let r = null;
      try { r = JSON.parse(out); } catch { /* not JSON */ }
      const textOut = r?.result ?? out;
      const all = `${textOut}\n${err}`;
      if (signal === "SIGTERM") return resolve({ ok: false, note: "Took too long" });
      if (/usage limit|rate limit|limit reached|hit your [^.\n]{0,40}limit|\b(?:5-hour|weekly|session) limit|resets?\s+(?:at\s+)?\d/i.test(all) && (code !== 0 || r?.is_error)) return resolve({ ok: false, limit: true, note: "Claude usage limit" });
      if (/not logged in|please run \/login|invalid api key|authentication/i.test(all)) return resolve({ ok: false, limit: true, note: "Claude Code is not logged in on the Mac" });
      if (code !== 0 || r?.is_error) return resolve({ ok: false, note: `Claude stopped (${String(textOut || err).slice(0, 160)})` });
      resolve({ ok: true, text: String(textOut) });
    });
    p.stdin.end(text);
  });
}

// First complete JSON object in the text (tolerates code fences or a sentence around it).
export function parseJson(text) {
  const s = String(text).replace(/```(?:json)?/g, "");
  for (let i = s.indexOf("{"); i >= 0; i = s.indexOf("{", i + 1)) {
    let depth = 0, inStr = false, esc = false;
    for (let j = i; j < s.length; j++) {
      const c = s[j];
      if (inStr) { if (esc) esc = false; else if (c === "\\") esc = true; else if (c === '"') inStr = false; continue; }
      if (c === '"') inStr = true;
      else if (c === "{") depth++;
      else if (c === "}" && --depth === 0) {
        try { const o = JSON.parse(s.slice(i, j + 1)); if (o && typeof o === "object" && !Array.isArray(o)) return o; } catch { /* keep looking */ }
        break;
      }
    }
  }
  return null;
}

const SUMMARY = {
  researcher: (o) => String(o.summary || "").split("\n")[0].slice(0, 300),
  builder: (o) => `Proposed ${(o.ops || []).length} change(s), ${(o.suggestions || []).length} suggestion(s)${o.answer ? `: ${String(o.answer).slice(0, 200)}` : ""}`,
  learner: (o) => `Learned ${(o.playbook || []).length} lesson(s)${o.answer ? `: ${String(o.answer).slice(0, 200)}` : ""}`,
  reviewer: (o) => (String(o.verdict).toLowerCase() === "approve" ? `Approved${o.notes ? `: ${String(o.notes).slice(0, 200)}` : ""}`
    : `Rejected: ${(o.problems || []).slice(0, 2).join("; ").slice(0, 300)}`),
  meta_researcher: (o) => String(o.summary || "").split("\n")[0].slice(0, 300),
  meta_strategist: (o) => `Plan: ${String(o.plan?.title || "").slice(0, 120)}${o.answer ? ` - ${String(o.answer).slice(0, 200)}` : ""}`,
  meta_content_analyst: (o) => String(o.summary || "").split("\n")[0].slice(0, 300),
  meta_content_planner: (o) => `${(o.items || []).length} item(s)${o.answer ? `: ${String(o.answer).slice(0, 200)}` : ""}`,
};
SUMMARY.meta_reviewer = SUMMARY.reviewer;

async function step(lane = "ads") {
  const url = lane === "gbp" ? GBP_URL : URL_;
  const call = (body) => callAt(body, url);
  // meta: this helper knows the Meta strategy roles; roles: every role it can run (the CRM never hands it another one)
  const job = await call(lane === "gbp" ? { action: "next", roles: GBP_ROLES } : { action: "next", meta: true, roles: Object.keys(PROMPTS) });
  if (job.update && !ONCE && (await selfUpdate())) process.exit(0);   // the CRM has work for a newer helper
  if (!job.run) return false;
  const { run, context } = job;
  if (!PROMPTS[run.role]) {   // a role newer than this helper: give the step back, update, restart
    await call({ action: "release", id: run.id, reason: `helper has no ${run.role} role yet; updating` });
    if (!ONCE && (await selfUpdate())) process.exit(0);
    return false;
  }
  log(`step ${run.id}: ${run.role} (${run.job}, try ${run.attempt})`);
  const r = await runClaude(run.role, buildPrompt(run.role, run, context));
  if (!r.ok) {
    if (r.limit) {
      await call({ action: "release", id: run.id, reason: r.note });
      if (ONCE) { log(r.note, "- stopping this pass; the step waits for the next one"); STOP = true; return true; }
      log(r.note, "- pausing"); await sleep(LIMIT_PAUSE_MS); return true;
    }
    await call({ action: "finish", id: run.id, ok: false, error: r.note });
    log(`step ${run.id} failed${ONCE ? " (the reason is in the CRM)" : `: ${r.note}`}`);   // cloud logs are public: no detail there
    return true;
  }
  const out = parseJson(r.text);
  if (!out) {
    await call({ action: "finish", id: run.id, ok: false, error: `Answer was not JSON: ${r.text.slice(0, 200)}` });
    return true;
  }
  const res = await call({ action: "finish", id: run.id, ok: true, output: out, summary: SUMMARY[run.role]?.(out) });
  log(`step ${run.id} done`, ONCE ? "" : JSON.stringify(res).slice(0, 200));
  return true;
}

// One piece of work from either lane. The review-reply door being closed or broken must never stop the ADS work.
// When that door has nothing (the feature is switched off, or no review is waiting) it is asked again only after 15 minutes:
// new reviews are read every 3 hours, so asking every minute would be wasted calls.
let gbpNote = "", gbpAskAfter = 0;
const GBP_IDLE_MS = 15 * 60e3;
async function work() {
  if (await step("ads")) return true;
  if (!GBP_URL || STOP || Date.now() < gbpAskAfter) return false;
  try {
    const worked = await step("gbp");
    if (!worked) gbpAskAfter = Date.now() + GBP_IDLE_MS;
    return worked;
  } catch (e) {      // also a 401: the ADS door has just accepted this token, so the fault is that door's (not deployed yet, older build)
    if (gbpNote !== e.message) { gbpNote = e.message; log("review replies:", e.message, "- skipped this time"); }
    gbpAskAfter = Date.now() + GBP_IDLE_MS;
    return false;
  }
}

// Self-update: on start, every 30 minutes and when the CRM says newer work is waiting, fetch the latest helper and role instructions from the repo. If they changed
// and both pass a syntax check, replace the files and exit; launchd starts the new version within 30 seconds.
const RAW = process.env.ADS_AGENTS_RAW || "https://raw.githubusercontent.com/Weone404/CRM/main/CRM/tools/ads-agents";
const HERE = dirname(fileURLToPath(import.meta.url));
export async function selfUpdate() {
  try {
    const files = ["agents.mjs", "prompts.mjs"];
    const fresh = {};
    for (const f of files) {
      const res = await fetch(`${RAW}/${f}`, { signal: AbortSignal.timeout(20000) });
      if (!res.ok) return false;
      fresh[f] = await res.text();
    }
    if (files.every((f) => existsSync(join(HERE, f)) && readFileSync(join(HERE, f), "utf8") === fresh[f])) return false;
    for (const f of files) {
      writeFileSync(join(HERE, `${f}.new`), fresh[f]);
      if (spawnSync(process.execPath, ["--check", join(HERE, `${f}.new`)]).status !== 0) return false;
    }
    for (const f of files) renameSync(join(HERE, `${f}.new`), join(HERE, f));
    log("Updated the helper from the repo; restarting");
    return true;
  } catch { return false; }
}

// One pass (cloud runner): work until nothing is waiting, the time budget is used, or Claude's usage limit is reached.
// Exit code 1 only when the CRM rejects the token, so the failed run is visible; anything else is retried by the next pass.
export async function once() {
  const until = Date.now() + (Number(process.env.ADS_AGENTS_MAX_MINUTES) || 45) * 60e3;
  log(`ADS agents helper: one pass (${URL_}); models ${JSON.stringify(MODELS)}`);
  let n = 0;
  while (!STOP && Date.now() < until) {
    try { if (!(await work())) break; n++; }
    catch (e) {
      if (e.code === 401) { log("The CRM rejected the token. Make a new one in CRM > ADS > Autopilot and save it as the ADS_AGENTS_TOKEN secret."); process.exitCode = 1; }
      else log("error:", e.message, "- the next pass will try again");
      break;
    }
  }
  log(`pass finished: ${n} step(s)`);
}

async function main() {
  if (ONCE) return once();
  if (await selfUpdate()) process.exit(0);
  setInterval(async () => { if (await selfUpdate()) process.exit(0); }, 30 * 60e3);   // two small downloads; restarts only on a change
  log(`ADS agents helper started (${URL_}); models ${JSON.stringify(MODELS)}`);
  let backoff = 0;
  for (;;) {
    try {
      const worked = await work();
      backoff = 0;
      if (!worked) await sleep(IDLE_MS);
    } catch (e) {
      if (e.code === 401) { log("The CRM rejected the token. Make a new one and run the installer again."); await sleep(30 * 60e3); continue; }
      backoff = Math.min(backoff ? backoff * 2 : 30e3, 15 * 60e3);
      log("error:", e.message, `- retry in ${backoff / 1000}s`);
      await sleep(backoff);
    }
  }
}

if (import.meta.url === `file://${process.argv[1]}`) main();
