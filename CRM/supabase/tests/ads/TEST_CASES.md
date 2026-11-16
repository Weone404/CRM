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

