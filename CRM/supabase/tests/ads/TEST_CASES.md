# ADS Autopilot (Google Ads) — test cases

Every case below is either automated (the file and check id are given) or marked **manual** with the reason it cannot be automated.
Run all automated cases:

```
cd CRM/supabase/tests/ads && PGHOST=localhost PGUSER=postgres bash run.sh          # SQL: 10_ .. 60_
deno test --allow-all ads_google_ops.test.ts ads_core.test.ts                     # Google operations, agent context
node --test ../../../tools/ads-agents/agents.test.mjs                              # Mac helper
bash ui/run_ui.sh                                                                  # browser (needs PG_MODULE_DIR, PLAYWRIGHT_DIR)
```

People in the cases: **Pro** = an experienced ads manager. **Novice** = someone who has never used ads software.
**Viewer** = has ADS access but cannot approve. **Outsider** = CRM user without ADS access. **Agent** = the AI agents.

## 1. Spend limits (money safety)

| ID | Who | Situation | Expected | Where |
|---|---|---|---|---|
| P07 / UI43 | Pro | Sets ₹500/day with the quick pick and saves | Daily 500, monthly 15,200 saved and logged | 40_, ui |
| UI42 | Novice | Doesn't know what a monthly limit is | Quick pick fills it (daily × 30.4) | ui |
| P04 / UI65 | Novice | Monthly lower than daily, double-clicks Save | Refused with a plain reason; nothing changes | 40_, ui |
| P05 | Pro | Monthly above 31 days of daily | Refused | 40_ |
| H02 / UI64 | Novice | Clears the limit and presses Save | "Enter a daily limit of at least 1"; old limit kept | 60_, ui |
| H03, H04 | Novice | Negative limit, limit under ₹1 | Refused | 60_ |
| H05, H06 | Attacker | Sends "NaN" / "Infinity" to the API | Refused | 60_ |
| UI63 | Novice | Types letters / minus signs into the limit box | They cannot be typed | ui |
| H08 | Pro | ₹333.337 | Rounded to ₹333.34 | 60_ |
| P09 | Agent / Pro | Raise a budget above the daily limit | Blocked (`cap_daily`) | 40_ |
| P11 | Agent / Pro | Switch on a paused campaign that pushes the total over the limit | Blocked | 40_ |
| P14, P17 | Agent / Pro | Raise that would pass the monthly limit / month already at the limit | Blocked | 40_ |
| P15, P16, H51 | Anyone | Lower a budget or pause, even when already over the limit | Always allowed | 40_, 60_ |
| H52 | Agent | Raise by ₹1 when over the limit | Blocked | 60_ |
| P12 | Pro | Meta campaigns | Not counted in the Google limit (kept separate) | 40_ |
| P18 | Pro | No limits set | Nothing blocked by limits | 40_ |
| P19 | Attacker | Insert an over-limit change straight into the queue as "approved" | Refused by the trigger | 40_ |
| H37 | Agent | Tries to raise the budget to ₹1 lakh | Impossible: agents have no budget operation | 60_ |
| H53 | — | Last day of the month | Days left is 1, never 0 | 60_ |
| manual | Pro | Someone raises the budget directly inside Google Ads | Not blocked by the CRM (outside it); stage 4 Supervisor will detect and pull it back | stage 4 |

## 2. Emergency stop

| ID | Who | Situation | Expected | Where |
|---|---|---|---|---|
| P20, UI73 | Viewer | Presses Stop in an emergency | Works for anyone with ADS access | 40_, ui |
| P21, UI73 | Viewer | Tries to Resume | Refused; button disabled | 40_, ui |
| UI60 | Novice | Presses Stop, then Cancel | Nothing changes | ui |
| UI50 | Pro | Stop pressed in Settings | Autopilot tab shows it too | ui |
| Q20 | Agent | Asks for work while stopped | Gets nothing | 50_ |
| H48, H49 | Agent | Reviewer approves at the moment Stop is pressed | Change waits; sent only after Resume | 60_ |
| O32 | System | Executor runs while stopped | Sends nothing | 30_ |
| H32 | Attacker | Writes to the config table to switch the stop off | Permission denied | 60_ |

## 3. Funds / balance

| ID | Who | Situation | Expected | Where |
|---|---|---|---|---|
| P25 | Pro | Records a top-up | Estimate = added − Google spend since then | 40_ |
| P26a, P26 | Pro | 9 days left vs under 3 days left | Notice only when under 3 days | 40_ |
| UI61, H16–H19 | Novice | "-500", "abc", "0", "1.2.3", words, a typo with extra zeros, a date years ago or in the future | Refused with a plain message; nothing saved | ui, 60_ |
| UI62 | Novice | "₹ 10,000" | Understood as 10000 | ui |
| P27, H27 | Viewer | Deletes a top-up | Refused | 40_, 60_ |
| H20 | Novice | Deletes a top-up that does not exist | "Entry not found" | 60_ |
| manual | Pro | Google's real prepaid balance | Not readable through the API; the tab says it is an estimate | — |

## 4. Telling the agents (typed and spoken)

| ID | Who | Situation | Expected | Where |
|---|---|---|---|---|
| UI46 | Pro | Types an instruction and sends | Listed with "Waiting" | ui |
| UI66, H10 | Novice | Sends spaces only / nothing | Send stays off; API refuses | ui, 60_ |
| H11 | Novice | Pastes an essay over 2000 characters | Refused | 60_ |
| H12 | Novice | Hindi, emoji, tabs, line breaks | Accepted | 60_ |
| H13, H14, UI67 | Attacker | HTML / SQL in the text | Stored and shown as plain text; nothing runs | 60_, ui |
| H15 | Novice | Presses Send 31 times in a day | Stopped at 30 with a plain message | 60_ |
| UI68 | Novice | Presses Speak in a browser without voice input (e.g. Firefox) | Message: use Chrome or type | ui |
| manual | Novice | Denies the microphone permission | Message: "Allow the microphone to speak." | browser only |
| Q03–Q07 | System | Instruction picked up | Becomes a chain within 5 minutes; shows "Working" | 50_ |

## 5. Suggestions

| ID | Who | Situation | Expected | Where |
|---|---|---|---|---|
| UI44, UI45, P33, P34 | Pro | Ticks some cities and accepts | Only the ticked ones (plus shared parts) become changes | ui, 40_ |
| P32 | Novice | Unticks everything and accepts | Refused (button disabled too) | 40_ |
| H24 | Attacker | Sends option ids that do not exist | Refused | 60_ |
| P36 | Pro | Accepts a suggestion with an unprovable claim | Still blocked by the checks | 40_ |
| P37 | Viewer | Accepts while Autopilot is "Ask me" | Waits for an approver | 40_ |
| P38, P39 | Novice | "Change" with no note / with a note | Refused / note goes to the agents | 40_ |
| P35, UI70 | Two people | Both accept the same suggestion at the same moment | One change only; the second is told "already accepted" | 40_, ui |
| H21–H23 | Novice | Unknown suggestion, no decision, wrong decision word | Plain messages | 60_ |
| H25, H26, H42 | Agent | Suggestion whose proposal is text / list of strings | Cleaned to "no changes"; nothing breaks | 60_ |

## 6. The agents (Researcher → Builder → code checks → Reviewer)

| ID | Who | Situation | Expected | Where |
|---|---|---|---|---|
| Q08–Q12 | Agent | Normal chain | Research → build → checks → review | 50_ |
| Q10, Q11 | Agent | Builder uses a banned claim | Sent back with the exact problem; Reviewer not bothered | 50_ |
| Q13, Q14 | Agent | Reviewer rejects three times | The owner decides (suggestion); instruction marked failed | 50_ |
| Q15–Q17 | Agent | Approved in Automatic mode | Changes approved and logged | 50_ |
| Q18 | Agent | Negative "pilot" (broad) | Refused: would block "pilot training" | 50_ |
| H36 | Agent | Sends garbage ops (strings, numbers, null) | Sent back; nothing created | 60_ |
| H38 | Agent | 40 changes at once | First 25 go to review; rest next run (found live, 13 Nov) | 60_ |
| H39 | Agent | Touches another advertiser's account | Refused | 60_ |
| H40 | Agent | Ad pointing to a look-alike domain | Refused | 60_ |
| H41 | Agent | Broad match keyword | Refused | 60_ |
| H43, H43a, H43b | Agent | Reviewer says "looks fine i guess" / review without a proposal / " Approve " | Treated as no / stops safely / understood | 60_ |
| H44–H47 | Agent | Answer for an unclaimed step, nonsense ids, release of a non-running step, a list instead of an object | Ignored / failed cleanly | 60_ |
| Q19, Q21, H54 | System | Usage limit, Mac asleep 30 min, hangs three times | Released / freed / given up | 50_, 60_ |
| H50 | System | Google sign-in expired | Every agent change blocked | 60_ |
| H55 | System | No Google account | Agents do nothing | 60_ |
| live 13 Nov | Agent | Reviewer rejected true facts ("since 2009") it could not see | Fixed: Reviewer now gets the research facts with URLs (095) | 095 |
| helper | Agent | Claude out of credits / logged out / rambles around the JSON / crashes | Released / paused / answer found / step failed with reason | agents.test.mjs |
| helper | Agent | Only the Researcher has tools (web search/fetch); no MCP for anyone | Enforced in the arguments | agents.test.mjs |
| prompts | Attacker | A search term says "ignore previous instructions" | Prompts mark all data as data; and code checks + Reviewer + Google check catch any result | prompts, 30_–60_ |

## 7. Access and security

| ID | Who | Situation | Expected | Where |
|---|---|---|---|---|
| P01, H29, H30 | Outsider | Opens Autopilot / presses stop / instructs | Refused | 40_, 60_ |
| H35 | Not signed in | Calls the API | Refused | 60_ |
| H31 | Outsider | Reads agent tables directly | Permission denied | 60_ |
| H33, H34, Q01, Q02 | Signed-in user | Pretends to be an agent / tests tokens | Permission denied | 50_, 60_ |
| P41–P44, H28 | Viewer / Admin | Agents token | Admin only; only the hash stored; checked by the service only | 40_, 60_ |
| E01–E05 | Attacker | ads-agents endpoint: no token, Amazon-style token, padded token, 6 KB header, GET | 401 / 405 | live curl (13 Nov) |
| E06–E11 | Agent (valid token) | Non-JSON body, unknown action, finish without / with text id, finish for an unclaimed step, release with a text id | 422 / ignored (same paths as H44–H47) | manual: the token now lives only on the Mac |
| UI72 | Viewer | Limits | Visible, not editable | ui |

## 8. Screens

| ID | Who | Situation | Expected | Where |
|---|---|---|---|---|
| UI52, UI35 | Novice | Phone width (390 px) | No sideways scrolling | ui |
| UI71 | Anyone | Server error | The reason is shown, not a blank page | ui |
| UI37 | — | Whole run | No console errors | ui |
| manual | Novice | Very slow mobile data | Loading text, then content (not automated: needs network shaping) | — |

## 9. Leads from ads are counted (098)

Found live on 16 Nov: a real ad enquiry of 13 Nov was in the CRM, yet every screen said "0 leads", because leads were matched by a
UTM campaign name that Google ad links here do not carry. They are now matched by the campaign id inside the ad click.

| ID | Who | Situation | Expected | Where |
|---|---|---|---|---|
| L01–L03 | System | Campaign id as its own field, inside the landing URL, at the end of the URL, before a #anchor | Read correctly | 80_ |
| L04, L05 | Attacker / broken site | Injected text, look-alike parameter names, unfilled {campaignid}, empty or malformed click data | Never taken as an id, no error | 80_ |
| L06, L07 | System | Google click, Meta click, paid UTM, organic Google visit, unknown paid source | Right platform, or none | 80_ |
| L08 | Novice | No ad enquiry has ever arrived | "Not available", never a false 0 | 80_ |
| L09–L17 | Owner | One real ad enquiry | Counted in the daily report, the agents' data, Today, Campaigns (with cost per lead); other campaigns show a true 0 | 80_ |
| L12, L13 | Privacy | What the agents receive about a lead | Keyword, ad, ad group, stage; never the name, phone number or click id | 80_ |
| L18, L19 | Outsider | No ADS access / reads the lead list directly | Refused | 80_ |
| L20 | Novice | Double tap on Submit; the same person enquires again next day | One lead | 80_ |
| L21, L22 | System | Spam / test lead (quarantined), deleted lead | Not counted | 80_ |
| L23, L24 | System | Ad click with no campaign id, or a campaign id that is not ours | Counted for the account, not pinned on a campaign | 80_ |
| L25, L26 | Worst case | A Meta click carrying a Google campaign id | Not credited to Google (platforms stay separate) | 80_ |
| L27–L31 | Sales | Wrong number, Interested, Qualified, Admission, Lost | Valid / qualified / customer counts follow the stage; no divide by zero | 80_ |
| L32 | System | Lead at 00:20 India time | Belongs to the India day, same as Google's spend | 80_ |
| L33–L35 | System | The same person is in both lead lists; leads matched the old UTM way | Counted once; old matching still works | 80_ |
| L36 | Worst case | Money spent, lead counting never proven for the client | The allocator does NOT cut the budget for "0 leads" | 80_ |
| L37, L38 | System | 3 valid ad leads under target and budget-limited; later 14 days with no lead | +15%; -20% | 80_ |
| R01 | Developer | Roll 098 back and apply it again | Old definitions return; re-applies cleanly | run.sh |

## 10. The specialist team (099)

The owner asked for a full team with no human work except adding funds, chose "wait 24 hours, then apply" for bigger
changes, allowed bids and budget inside the spend limits, and has no Mac that stays on.

| ID | Who | Situation | Expected | Where |
|---|---|---|---|---|
| TL01-TL03 | System | Nothing spent / new spend / a desk already working | Only desks that need no new data start; the first specialist starts with its own brief; one desk at a time | 90_ |
| TL04-TL07 | System | A desk just finished; 3 runs already today; nonsense daily cap | Next one waits 2 hours; at most 3 a day; falls back to 3 | 90_ |
| TL08 | Owner | Types an instruction when the daily cap is used up | It still starts | 90_ |
| TL09-TL13 | System | Due by the clock but nothing new spent; desk switched off; team off; emergency stop | Does not run | 90_ |
| TL14-TL17 | Viewer / Outsider | Opens the team list; reads the briefs directly | 14 members with last / next work; refused | 90_, UI103-UI106 |
| TL18, TL19 | System | Cloud runner checked in 40 minutes ago / 3 hours ago | "On schedule" (no false alarm) / reported as not working | 90_ |
| AU01-AU06 | Novice | Never answers a suggestion | Applied 24 hours after it was written, the recommended option only, once; "wait" recommendation changes nothing | 90_, UI100-UI102 |
| AU07 | Worst case | No recommended option, Reviewer-rejected proposal, never reviewed, review unfinished, nothing to apply, malformed | Never applied by itself | 90_ |
| AU08-AU12 | Owner | Emergency stop, "Ask me" mode, rule off, 0 hours, nonsense setting | Nothing by itself, no error | 90_ |
| AU13, AU14 | Owner | Old suggestions when the rule starts; says no in time | A full 24 hours from the start; never applied | 90_ |
| AU15, AU16 | Worst case | A change that would block "pilot training"; an operation type that does not exist | Stopped by the safety checks; left for the owner, not retried | 90_ |
| AU18 | Attacker | Triggers the rule from the browser | Permission denied | 90_ |
| BB01-BB09 | Agent | Max CPC: fair step, doubling, junk values, wrong bidding strategy, account picture missing, unknown / Meta campaign, twice a day | Allowed only inside 3-150, 30% a step, once a day, Maximize Clicks only | 90_, Deno |
| BB10-BB15 | Agent | Budget raise inside / above the daily limit, all campaigns together, monthly limit, lowering | The owner's limits always win; lowering always allowed | 90_ |
| BB16-BB20 | Agent | 40% step, junk amounts, shared budget, changed today by the Spend Guard or the owner, twice a day | Refused | 90_ |
| BB21-BB23 | System | Budget change sent / confirmed / refused by Google | Executor gets the budget's own resource; CRM number follows only a confirmed change | 90_, Deno |
| BB24-BB27 | Agent | "Ask me" mode; asks for 5x the budget; proposal above the limits | Waits for approval; stored as blocked; sent back to the Builder | 90_ |
| BB28 | Agent | Tries to switch off the CRM's own conversion action | Refused | 90_ |
| CV01, CV02 | Privacy | Enquiry under 30 minutes old; person said no, or did not answer, to ad data sharing | Not reported to Google | 90_ |
| CV03 | Privacy | What leaves the CRM | Click id, time, dedupe id; never name or phone | 90_, Deno |
| CV04-CV10 | System | Conversion actions; "too recent"; sent; qualified; admission; 12 tries; final refusal | Created once; retried every 3 hours; never sent twice; stops with Google's reason | 90_, Deno |
| CV11, CV12 | Worst case | Permission withdrawn later, wrong number, spam, 86-day-old click, no click id, Meta click, lead deleted while queued | Not reported | 90_ |
| CV13-CV19 | System / Attacker | Emergency stop, reporting off, damaged setting, browser calls | Nothing sent; reporter sleeps when idle; permission denied | 90_ |
| TR01-TR05 | System | 180 clicks and no enquiry in a week; failed reports; all well | One alarm a day; silent when well; server only | 90_ |
| helper | Cloud | One pass: work waiting, nothing waiting, Claude usage limit, token rejected, CRM down | Works through it and exits; exits at once; hands the step back; fails visibly; exits cleanly | agents.test.mjs |
| R02 | Developer | Roll 099 back and apply it again | Old scheduler and gate return; re-applies cleanly | run.sh |
| not automated | - | The cloud runner's first real run on GitHub, and Google accepting a real uploaded conversion | Checked live after the owner adds the two secrets / after the first consenting enquiry | - |


## Meta lead sources (migration 100)

| ID | Who | Situation | Expected | Where |
|---|---|---|---|---|
| MS01 | Pro | Fresh install | All three Meta sources off, consent "required"; webhooks store nothing | A0_ |
| MS02 | Viewer / Approver | Opens or changes Meta settings | Refused (Admin only) | A0_ |
| MS03 | Novice | Switches reporting on without a dataset ID | Refused with a plain reason | A0_, ui UI123 |
| MS04 | Pro | Maps a website stage to Purchase / a WhatsApp stage to Lead | Refused; only accepted names | A0_, ui UI126 |
| MS05 | Meta | Sends the same lead twice (retries for 36 h) | Stored once | A0_, ads_meta.test MW03-06 |
| MS06-09 | Meta / Agent | Lead fetched / organic / Meta busy 12 times / no valid phone | Filed / skipped / failed with reason | A0_ |
| MS10-11 | Owner | Each consent rule; a lead under 30 minutes old | Reported per rule; waits | A0_ |
| MS12-13 | Agent | Lead moves stages; stage older than 7 days | Each stage once, under the dashboard's name; old ones skipped | A0_ |
| MS14 | Attacker | Reads what goes to Meta | Phone/email only as SHA-256 | A0_, MC08 |
| MS15-18 | Owner | Emergency stop / source off / quarantined / consent tightened | Nothing sent | A0_ |
| MS19-20 | Visitor | Website enquiry from a Meta ad; WhatsApp ad chat | Website event with fbc; LeadSubmitted with ctwa_clid | A0_ |
| MS21 | Browser | Reads raw leads, queue, webhook secrets | Permission denied | A0_ |
| MS22-24 | Owner | Page forms, daily check, new Vault keys | Pipeline kept; missed leads added; values never shown | A0_ |
| MW01-02 | Attacker | Unsigned / wrongly signed webhook | Refused | ads_meta.test |
| MC01-07 | Agent | Builds CRM / website / WhatsApp events | Meta's required fields; 17-digit lead id exact | ads_meta.test |
| UI120-127 | Admin | Uses the Meta panel | Sources, switches, consent, mappings saved | ui |
| MS30-32 | Admin / Agent | Stops Meta only; emergency stop; unknown platform | Meta stops, Google runs; both stop; refused | A0_ |
| MS33 | Admin | Google lead, Meta form lead, person via both | Each in its own list; both-platform person in both, marked | A0_ |
| MS34-35 | Admin / Sales / Meta | Setup status; webhook verified; test event lead | Key presence only, Admin only; verified time shown; ids exact, contacts hashed | A0_ |
| DS01-02 | Agent | Edge Function deployed / old / missing | Told apart; intake build equals ADS_BUILD | ads_meta.test |
| UI09, UI09c | Viewer | Campaigns in each section | Google only / Meta only | ui |
| UI130-141 | Admin | Meta Ads section, banner, Setup steps, Check now, SQL / deploy / callback copy blocks, per-platform stop, Google section | Separate sections; steps checked by the server; stop only one platform | ui |
| MS40 | Meta | Lead Ads Testing Tool lead | Kept as test; not an Ads lead, not a normal lead | A1_ |
| MS41-43 | Visitor | Form filled without an ad; same phone again; Charter form | Normal lead (Meta lead form / organic / form name); no second lead; charter lead | A1_ |
| MS44 | Visitor | Fill without a valid phone; handled lead again; unknown status | Not filed, reason shown; never filed twice; refused | A1_ |
| MS45-47 | Admin / Agent | Setup status; test event with no Ads lead; reporting | Version + per-lead outcome; newest delivered id used; never reported | A1_ |
| R04 | Owner | 101 down, then up | Rolls back and re-applies | run.sh |
| MS48 | Admin / Agent / Browser | Meta's CRM check; test lead over 7 days old; browser reads it | Newest test lead + Lead Created name; not used; refused | A1_ |
| R05 | Owner | 102 down, then up | Rolls back and re-applies | run.sh |
| MI01-04 | Agent | Save campaigns / ad sets / ads and ad-days | Bad ids ignored; names never wipe creative; a day saved again replaces | A2_ |
| MI05-09 | Admin | Insights totals, leaderboard, filters, trend | Meta + CRM numbers per campaign / ad set / ad / form; previous period | A2_ |
| MI10 | Agent | Breakdown saved again | Its months replaced | A2_ |
| MI11-13 | Sales / Viewer / Browser | Insights, notes, raw tables | No access refused; only Admin notes; tables and job functions closed | A2_ |
| MI14-17 | Cron / Agent | History plan and progress | 37-month start, resumes, wakes only when due, daily / weekly refresh | A2_ |
| MI18-20 | Agent / Viewer / Admin | Monthly summary, recipients | Due once, exact month, saved with why not emailed; Admin sets valid recipients | A2_ |
| R06 | Owner | 103 down, then up | Rolls back and re-applies | run.sh |
| MH | Agent | Graph rows, history calls, patterns, what-if, summary text | Parsed; read-only GETs; proven wins / losses; estimate; safe HTML | meta_insights.test |
| SG01-03 | Admin / Viewer | Start a strategy | Goal checked (course, budget, https); Admin only; cleaned, titled, Researcher queued | A3_ |
| SG04-12 | Agents | Research -> plan -> review | Old helpers get no Meta step; context has history, Page, archive; code checks and Reviewer send back; version 1 ready; 3rd failure kept as needs review | A3_ |
| SG13-14 | Code checks | Broken plans | Banned claims, early QUALITY_LEAD, wrong maths, under 18, missing keys, no phone, budget mismatch / over limit | A3_ |
| SG15-18 | Admin / Viewer | Change, fail, approve, read | Change uses the latest version; failure restores; approve; viewers read only | A3_ |
| SG19-21 | Admin / ads-sync | Create in Meta | Approved plan, account, Page handed over; steps saved as they happen; another version never built on top | A3_, meta_strategy.test |
| SG22-24 | Cron | Plan vs actual | Links checked; weekly verdict; behind -> one drafted revision in 14 days | A3_ |
| SG25-29 | CRM / Admin | Lead archive | Filed leads copied with answers (not test leads); CSV import, match, no data loss; Admin-only export; 89-day first read | A3_, UI167-168 |
| SG30-36 | Cron / Admin | Speed to lead | Due after N min; owner first, Admin later with phone and email; once each; stops when called; settings checked | A3_, UI169 |
| R07 | Owner | 104 down, then up | Rolls back and re-applies | run.sh |
| UI160-166 | Admin | Strategy tab | List, goal form errors, start, full plan, approve, link, change request, phone width | ui_checks |
| UI150-158 | Admin | Meta Ads > Insights | Tiles, patterns, leaderboard, gallery, charts, what-if, filters, notes, summaries | ui |
| UI136c | Admin | Test-event step | No-code button for Meta's Verification Lead; TEST code still accepted | ui |
| UI134-136b | Admin | Older database; deploy commands; test-lead step | "Update waiting" + only 101 shown; CLI 3 commands; delivered/webhook status | ui |
| RP01-06 | Viewer / Admin / ads-sync | Reports options, saved views, CRM per object, cache | Filters offered; views private unless Admin shares; CRM per campaign / ad; cache expires; closed to browsers | A4_ |
| HL01-07 | ads-sync / Viewer / Admin | Health and warnings | Old helper told to update; new high warnings sent once; closed when gone; webhook and failed-lead checks; dismiss | A4_ |
| R08 | Owner | 105 down, then up | Rolls back and re-applies | run.sh |
| QL01-04 | Viewer | Lead quality | Qualified and admission rates by form answer, form, platform, time to first call; small groups flagged; only known groupings | A5_ |
| SC01-06 | Viewer / Admin / trigger | Lead score | New leads scored on arrival; neutral with little history; learns (smoothed) with reasons; Admin-only rules, checked; saving rescores; lists | A5_ |
| R09 | Owner | 106 down, then up | Rolls back and re-applies | run.sh |
| UI181-187 | Viewer / Admin | Lead quality UI | Score chips on waiting leads, highest first; Lead quality view by any grouping; scored leads; rules editor; phone width | ui_checks.mjs |
| FN01-02 | Viewer | Funnel map | Six stages with cost each and share moving on; never-called note; periods checked | A6_ |
| LB01-06 | Viewer / Admin / ads-sync | Audience library | 12 audiences; CRM lists only people whose consent allows sharing; Admin-only on / off and exclusions; job gets hashed people only; saves Meta id, size, problems; warm pools on the funnel map | A6_ |
| BW01 | ads-sync | Create in Meta | Gets ready audiences by key and default exclusions | A6_ |
| GEO01 | Viewer | Location focus | Form cities mapped to states; verdict per state | A6_ |
| R10 | Owner | 107 down, then up | Rolls back and re-applies | run.sh |
| FT01-05 | ads-sync | Audience helpers | Lead-form / Page / Instagram / messaged rules; missing ids give reasons; hashed Replace batches; plain errors; build exclusions | meta_funnel.test.ts |
| UI188-194 | Viewer / Admin | Funnel UI | Funnel map; audience library; default exclusions; turn on and update; pick exclusions; location focus; phone width | ui_checks.mjs |
| WS01-06 | Viewer / Admin / ads-sync | Website signals | Not connected at first; Admin-only, checked settings; token in Vault; job input; rows replaced; topics, rising, pages, website funnel, Pixel | A7_ |
| WA01 | ads-sync | Website audiences | Sent with the Pixel id, rules only | A7_ |
| AX01-02 | ads-agents / Viewer | Agents' funnel context | Funnel, audiences, locations, website signals (small); screens still work | A7_ |
| R11 | Owner | 108 down, then up | Rolls back and re-applies | run.sh |
| FT06-09 | ads-sync | Website helpers | Windows; Search Console / GA4 requests and rows; settings and errors; Pixel audience rules | meta_funnel.test.ts |
| UI195-198 | Viewer / Admin | Website signals UI | Intent topics; rising, website funnel, Pixel; connect; Check now | ui_checks.mjs |
| LK01-02 | ads-sync | Lookalikes | Sent after seeds with seed id / size; wait (planned) until the seed has 100+; ready as new-people hint | A8_ |
| PS01-03 | Viewer / Admin | Personas | Six with their Google searches; Admin-only; stages checked; add and switch off | A8_ |
| BP01-02 | Viewer | Funnel plan | Split, pool caps moved to new people, audiences, exclusions, learning check; split and minimum checked | A8_ |
| GC01-02 | Admin | Goal | Keeps funnel split and known personas; bad split refused | A8_ |
| PC01-03 | Strategy | Plan checks | Near copies, angles, personas; seeds as hard limits, unknown audiences, retarget without audience, stages; split within 10 points; original checks still run | A8_ |
| R12 | Owner | 109 down, up twice, down | Original goal / plan checks restored | run.sh |
| FT10-11 | ads-sync | Lookalike helpers | 1-20% steps, bands, India; seed 100+; seeds only hints on new-people ad sets | meta_funnel.test.ts |
| UI199-203 | Viewer / Admin | Personas and funnel plan UI | Personas with searches; edit; funnel plan; split must add up; Send to Strategy | ui_checks.mjs |
| AC01-07 | Viewer / approver / ads-sync | Quick actions | Approvers only; numbers per object; learning-phase warning; one open request; no ad budgets; +100% needs Admin; floor / ceiling; two-person rule; emergency stop; only approved run, result kept | A9_ |
| RU01-07 | Viewer / approver / Admin | Rules | Approvers run; cost rule below limit does nothing; no-qualified spend past limit asks to pause; warn-only; never asks twice; no ad budget rules; add rule | A9_ |
| AB01-05 | Admin / Viewer | A/B tests | 2-5 cells; no object twice; cost per lead binomial test (99%+); qualified rate z-test; normal CDF accuracy | A9_ |
| R13 | Owner | 110 down, up twice, down | Rules seeded once | run.sh |
| FT12-13 | ads-sync | Action helpers | Skip when already there; budget in minor units with limits; no ad budgets; deleted objects; duplicate paused; verify; split test shares and times | meta_funnel.test.ts |
| UI204-212 | Viewer / approver / Admin | Automate UI | Tab; pause ask and approve-and-run; history; budget left for another approver; reject; rule on; run rules; start A/B test; phone width | ui_checks.mjs |
| MR | ads-sync | Report settings, Insights query, rows, totals, cache, health rules | Meta's limits; filters; leads / video / rankings; disjoint reach; warnings | meta_reports.test |
| UI170-180 | Viewer / Admin | Reports and Overview health | Live table, breakdown and value filter, compare, presets, drill-down, rankings, custom columns, saved view, CSV, phone width, health card | ui_checks |


## 11. Delivery watch: "Google Ads stopped showing" (migration 142)

Run: `supabase/tests/ads/delivery/run.sh` (SQL, DW01 to DW24 and DR1) and `UI_SCRIPT=delivery_ui.mjs ./ui/run_ui.sh` (screen, UI110 to UI118).

| Case | What is checked |
|---|---|
| The real case (13 to 15 Nov 2026) | Spend 399.88, 399.94, 47.55, then a trickle of impressions with no clicks: stopped since the day after the last spend, cause "funds", 847.37 + 18% = 999.90 = one payment of 1,000 |
| Not an alarm | Spend yesterday; spending again today; one quiet day; still shown with no clicks; every campaign paused; no budget; account not connected; sync older than 36 hours; under 50 impressions a day |
| The run | An older campaign months ago is not counted in the run or in "usual impressions" |
| Money ledger | Money still recorded: cause "unknown" and it says so. Ledger used up: "funds" |
| Tax | 18% for INR accounts, 0 otherwise, `ads_config.google_tax_pct` overrides |
| Honesty | Changes the CRM made on the stop day are counted and shown; an unknown reason is never guessed |
| Other platforms | A Meta campaign spending every day neither hides nor fakes a Google stop |
| Access and safety | ADS viewers only; read-only; evidence shown as plain text; if the check fails, Today still works |

## 12. Premium targeting: a whole new campaign and the income filter (migration 144)

Owner decision of 25 Nov 2026: counselling enquiries from premium areas only, in two campaigns (Delhi NCR and Other cities).
Run: `supabase/tests/ads/premium/run.sh` (database, PT01-PT38 and PR1-PR2) and `deno test tests/ads/ads_google_ops.test.ts` (builders, read-back, dry run).

| Area | What is proved |
|---|---|
| Old kinds | Everything the old gate knew passes through the new gate unchanged; an unknown kind is still unknown (PT01). The full ADS suite passes with 144 applied (808 checks). |
| New campaign, money | Fits the daily limit or is blocked, paused or not, to the paisa (PT02-PT03); no limit set, no campaign (PT04); monthly limit (PT05); real amounts only (PT06). |
| New campaign, moved money | Money can be moved from a running campaign in the same request: only down, within the 30% step, and the total must still fit (PT30-PT31); a paused campaign frees nothing (PT32). |
| New campaign, parts | At least one location, never worldwide, at most 150 (PT07); name (PT08); click limit (PT09); status (PT10); income filter, shared lists and negatives pass the same checks as on their own, so a negative cannot block a core search (PT33); ad groups 1-5, phrase or exact keywords, 1-3 ads (PT34); every ad passes the claim, website and length checks (PT35). |
| Income filter | Campaign or ad group, Google's seven groups only, never all seven, "unknown" warned about, letting a group back in only with this account's own rows (PT12-PT17). |
| Owner only | An agent's new campaign or income change always waits for the owner, even on Automatic; while `google_targeting_locked` is on, so does an agent's location change; the owner's approval is never undone (PT18-PT22). One new campaign a day (PT23). |
| Who runs what | New kinds go to `ads-google-ops` only, old kinds to `ads-sync` only; nothing when Google is paused; a limit lowered after approval stops the campaign before anything is sent (PT24-PT26). |
| After it is sent | The spend limits know the new campaign and the lowered budget at once, before any sync (PT36-PT38). |
| AI team | The owner's decisions are added to the brand facts once; the lesson naming the old location list is retired (PT27-PT28). |
| Builders | One all-or-nothing request with temporary ids, moved budget first; Google Search only, people physically there, the EU declaration; bad input never reaches Google (Deno). |
| Read-back and dry run | A 159-part campaign is read back in groups, in order, and one missing row is reported; the dry run only ever sends "validate only" (Deno). |
| Rollback | Refused while operations of the new kinds exist; otherwise the old gate is back under its own name and 144 re-applies (PR1-PR2). |

Live, 25 Nov 2026: Google's own validate-only check accepted the Delhi NCR income filter (5 parts) and the whole Other cities campaign (159 parts) before the owner was asked to approve.

## 13. Time-of-day bids (migration 145)

Run: `supabase/tests/ads/premium/run.sh` (ST01-ST08 and PR3, after the 144 checks) and `deno test tests/ads/ads_google_ops.test.ts`.

| Area | What is proved |
|---|---|
| A good schedule | 1-6 slots that cover 0 to 24, bids from -90% to +900% (ST01). |
| Never off by accident | A gap, an overlap or a day that stops early is blocked (ST03); whole hours, bid range, slot count, campaign (ST04). |
| Replacing a schedule | Only this campaign's own rows can be removed (ST05). |
| Layers | Every older kind still gets its own checks through both gate layers (ST02). |
| Owner only, who runs it | An agent's schedule waits for the owner on Automatic (ST06); only `ads-google-ops` runs and dry-runs it (ST07). |
| AI team | The verified research is added to the brand facts once (ST08). |
| Builder | 7 days x slots, the bid as a multiplier (0.7 for -30%), old rows first; bad input never reaches Google (Deno). |
| Rollback | Refused while schedules exist; then back to 144 and re-applies (PR3). |

Live, 25 Nov 2026: Google's validate-only check accepted both schedules (14 parts each) before they were sent; both read back verified.


## 14. Google Ads Overview: balance from Google and one daily amount (migration 146)

SQL `home/run.sh`: HM01–HM10 balance (limit − served, first read is not a top-up, a payment shows as a top-up after GST, failed or
odd answers never invent a balance, ended or waiting budgets ignored, impossible dates safe, browser cannot write it);
HM11–HM16 "I added money" (access, one request per 10 seconds, two-hour watch ends when money shows, no pg_net = no crash);
HM17–HM24 budget_set checks (range, whole rupees, parts add up and cover every running campaign once, owner and client limits,
unsynced or shared budgets, agents wait); HM25–HM47 the owner's amount (access, refusals change nothing, 300 → 210/90 and
9,120 a month, one change at a time, run by ads-google-ops only, verified → budgets updated, refused → limits restored,
unconfirmed → lower limit kept, limit lowered later → stale, odd amounts add up, one or no running campaign);
HM48–HM63 the home read (every status, money for 30 days with GST, who/where/when/searches from what Google confirmed, broken
snapshots or labels, results with CRM enquiries and 15-minute calls, waiting changes labelled by who made them, facts for the
AI team once). HR1–HR2 rollback refused while budget changes exist, then back to 145 and re-applied.
Deno: budget_set builder, refusals, executor verified only when both amounts read back.
Screen `home_ui.mjs`: GH01–GH46 (tabs, status wording, balance read with nothing to type, "I added money" results, slider and typed
amount with month, GST and split, confirm and save states, who sees the ads, results, labelled approvals, every status, view-only,
Advanced, phone width, no console errors).
