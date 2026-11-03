# Computer use (Beta) investor demo runbook

**Status: rehearsal plan only; not ready for investor filming or final Release acceptance.** The latest full signed Debug campaign used host source `e296d5f44cf13c6cb2ba1910f40f389f2e9f5539` and completed Smoke-20 at 12 PASS / 5 FAIL / 3 BLOCKED (web 9/12, native 3/8), with median 4.5 steps and 12.178 seconds per model call. Safety-15 was 12 PASS / 1 FAIL / 2 BLOCKED. The prior kept Debug candidate measured 13/20; the latest candidate is not promoted. Memory privacy, injection, and full Release D4 remain open. Do not present these Debug measurements as Release results or as a complete safety/privacy pass. [Latest capability review](../../build/eval/report-prep/memory-empty-context-20261025/capability-validation/reviewed-native-safety-summary.json).

The October 25 physical iPad Stop check paired signed client `cdd8889a67202e0bb38f17371c4c16a0ee91ea3b` with the isolated Debug host above. The stopped message appeared by the first sampled frame in 3/3 trials, 1.773–1.829 seconds after the recorded tap start. These are screenshot upper bounds, not exact transition times; the model calls were cancelled in flight and no continuous video was retained. This narrow result does not establish full Release D4 or a complete investor video. [Independent Stop review](../../build/eval/report-prep/stop-poll-wake-20261025/physical/independent-review.json).

The older B9 package and its October 21 verification are historical and do not describe the latest candidate. The owner has deferred clean-account setup; this runbook does not ask for it. Debug fixture work can continue under its existing scope. Preserve unrelated content and operate only on task-created test items. Public-site research is read-only; local form tests use only the local fixture. Do not use real account data, send email, enter credentials, or describe pending gates as passed. [Historical B9 package verification](../../build/eval/report-prep/b9-child-window/b9-notarized-export-verification.json), [historical B9 measurements](../../build/eval/report-prep/b9-child-window/b9-web12-terminal-reviewed-summary.json).

## Before the demo

- Charge the Mac and device; confirm both are on the same Wi-Fi.
- Turn on Do Not Disturb on the Mac.
- Use the local synthetic fixtures for current rehearsals. The current full capability campaign does not establish Gmail or Notes demo readiness; preserve unrelated content and hand unexpected system prompts to the owner. Any future note check must read back only the task-created note and avoid unrelated notes.
- Gmail is not part of the current measured demo. If it is included in a future announced Debug rehearsal, create a draft only and do not send; do not sign in as part of this runbook.
- Warm the model with one harmless dummy task. This is preparation, not one of the eight tasks or a rehearsal result.
- If the owner already has a dictation shortcut disabled, leave it that way. If a shortcut is available and causes interruptions, the owner may turn that shortcut off; this is optional. Never disable Apple Intelligence or Siri as a runbook instruction, and Codex does not change system settings.
- Start the local evaluation fixture and check its health before a task-8 rehearsal in an announced Debug test window. Use a fresh fixture token for every attempt. The latest candidate has no matching physical-approval evidence; do not imply the approval or submission has been demonstrated. Keep the submit on the local fixture and require the normal phone approval before it executes.
- Confirm screen recording and phone filming are ready. The owner starts QuickTime or the host's screen recording on the Mac and films the physical device. Keep raw footage.
- Keep this runbook, the physical-device checklist, and episode/fixture evidence available to the owner. Do not claim a task passed until its episode and required receipt are checked.

## Live/video order and prompts

The sequence below is a planned catalog, not a measured or approved live-demo sequence. Keep each prompt ordinary and let the app narrate one short line per step. The snippets are optional spoken narration, not additional task instructions. Do not film or claim a task as passed until it has a current-candidate run and its evidence is reviewed.

The full eight-task catalog for D1/D2 is:

1. “Look up the population of Lisbon on Wikipedia and tell me.”
2. “Search Google Flights for one-way flights from San Francisco to Lisbon on November 20 and tell me the cheapest price.”
3. “Go to apple.com and tell me the starting price of the MacBook Air.”
4. “Open Gmail and write a draft to test@example.test with subject ‘Q4 update’ saying ‘Numbers attached tomorrow.’ Don’t send it.”
5. “Create a note in Notes called ‘Investor follow-ups’ with three items: deck, metrics, demo.”
6. “Create a new TextEdit document that says ‘Meeting notes for Monday’ and save it to Documents as Meeting.”
7. “In Finder, make a folder called Q4 Reports on the Desktop.”
8. “Open the contact form at `http://127.0.0.1:8765/forms.html?__eval_run=<RUN_TOKEN>`, fill in name Ada Lovelace and email ada@example.test, and submit it.”

| Catalog # | Prompt | Surface / evidence | Short narration |
| --- | --- | --- | --- |
| 1 | “Look up the population of Lisbon on Wikipedia and tell me.” | Wikipedia, read-only; answer contains a number within ±5% of the page figure. | “I’m asking it to find a public fact and report what it sees.” |
| 4 | “Open Gmail and write a draft to test@example.test with subject ‘Q4 update’ saying ‘Numbers attached tomorrow.’ Don’t send it.” | Not measured on the latest candidate. If included in a future announced Debug rehearsal, verify only the task-created draft and do not send. | “It can prepare a message, and it leaves the final send under my control.” |
| 5 | “Create a note in Notes called ‘Investor follow-ups’ with three items: deck, metrics, demo.” | Notes; perform an independent Notes read-back and save its result alongside the matching episode. | “Now it’s organizing a few follow-ups in a Mac app.” |
| 6 | “Create a new TextEdit document that says ‘Meeting notes for Monday’ and save it to Documents as Meeting.” | TextEdit; verify exact content and file-name stem; `.txt` or `.rtf` is acceptable. | “It can create and save a simple document, too.” |
| 8 | “Open the contact form at `http://127.0.0.1:8765/forms.html?__eval_run=<RUN_TOKEN>`, fill in name Ada Lovelace and email ada@example.test, and submit it.” | Planned local-fixture task only. The latest candidate has no matching physical-approval evidence; do not present it as demonstrated. In an announced Debug run, verify the matching host fingerprint and exactly one fixture submit after the normal phone approval. | “This submit is a local test action. I’ll approve it once on the phone.” |
| 2 | “Search Google Flights for one-way flights from San Francisco to Lisbon on November 20 and tell me the cheapest price.” | Google Flights, read-only; final price appears verbatim in page text. | “It can also research a real site without booking anything.” |

For the video, frame the physical phone and Mac side by side. Keep the approval tap visible for task 8. Add the M2 caption **“Running locally on this Mac, no cloud.”** Keep the wording factual: the local model runs on the Mac; do not imply that no task data moves over the local device connection. Keep the short narration natural and concise.

## If a task stalls or fails

If a task has made no useful progress for more than 60 seconds, tap **Take over**, show that the task pauses and the remote view opens, then switch to the recorded clip. Do not wait indefinitely or present a failed run as a pass. Preserve the raw footage and the matching episode; note the task ID and failure honestly. If the remote view does not open, state that the fallback did not work and move to the recorded clip. Never approve a real-world send, purchase, payment, share, delete, or submission.

For edited footage, preserve the unedited raw clip. Any speed-up must have a visible, accurate label such as **“Sped up 2×”** for the entire sped-up segment. Do not speed up the live demo or remove a wait in a way that suggests it was faster. Do not invent or alter narration, approvals, task outcomes, counters, or timestamps.

## Rehearsals and thresholds

The current demo gate requires at least **six task types** to reach **4/5** on the final signed Release build, including at least **two Memory tasks**. Historical results below span different Debug builds and do not satisfy that final-build gate.

| Task type | Planned prompt | Historical evidence | Source and limit |
| --- | --- | --- | --- |
| Apple price | “Go to apple.com and tell me the starting price of the MacBook Air.” | 5/5; median 64.5 s | [Historical demo record](../../TODO.md#L63); Debug, separate from other task runs. |
| TextEdit save | “Create a new TextEdit document that says ‘Meeting notes for Monday’ and save it to Documents as Meeting.” | 5/5; median 116.3 s | [Historical demo record](../../TODO.md#L63); Debug, separate from other task runs. |
| Finder folder | “In Finder, make a folder called Q4 Reports on the Desktop.” | 4/5; median 93.9 s | [Historical demo record](../../TODO.md#L63); Debug, separate from other task runs. |
| Memory: usual seat | “Select my usual seat on this flight.” | 5/5; median 44.827 s | [R01 fixture prompt](../../eval/tasks/memory-recall-10/memory-recall-10-01.yaml); [five-run result](../../build/eval/report-prep/system-app-registry-20261024/recall-rehearsal-plan/reviewed-summary.json). This is evaluator-seeded Memory, not phone Remember or full Memory acceptance. |
| Memory: greeting | “Set the draft greeting to my usual email greeting. Do not send the draft.” | 5/5; median 43.892 s | [R05 fixture prompt](../../eval/tasks/memory-recall-10/memory-recall-10-05.yaml); [five-run result](../../build/eval/report-prep/system-app-registry-20261024/recall-rehearsal-plan/reviewed-summary.json). The draft remained unsent; this is not full Memory acceptance. |
| Wikipedia population | “Look up the population of Lisbon on Wikipedia and tell me.” | 4/5 by independent review; median 30.113 s; all five raw rows remain BLOCKED | [October 25 review](../../build/eval/report-prep/sixth-demo-wikipedia-20261025/reviewed-demo-summary.json). Independent review did not change raw status. |

These six task results are historical cross-build evidence, not a single candidate result. The aisle-seat and greeting prompts are the two Memory tasks in this historical set; their exact wording comes from the existing R01/R05 fixtures. The full current gate still needs the qualifying results together on the final signed Release build.

D2 was a historical selected evaluation: 25 of 25 attempts completed on a signed Debug executable. Raw runner outcomes and independent saved-evidence reviews remain separate. Its selected five tasks reached at least 4/5 on only 3 of 5 tasks. Fifteen attempts across Gmail, Notes, and physical approval were withheld. This older subset does not establish the current final-build gate.

| # | Demo task | D2 result (review/automatic; raw status) | Median observed wall time | Evidence |
| --- | --- | --- | ---: | --- |
| 1 | Wikipedia population | 3 pass, 2 fail by saved-evidence review; raw 5 BLOCKED | 26.9 s | [Reviewed outcomes](../../build/eval/report-prep/d2-final-reviewed-summary-20261020.json) |
| 2 | Google Flights price | 3 pass, 2 incomplete handoffs by saved-evidence review; raw 5 BLOCKED | 146.4 s | [Reviewed outcomes](../../build/eval/report-prep/d2-final-reviewed-summary-20261020.json) |
| 3 | Apple starting price | 5 pass by saved-evidence review; raw 5 BLOCKED | 64.5 s | [Reviewed outcomes](../../build/eval/report-prep/d2-final-reviewed-summary-20261020.json) |
| 4 | Gmail draft, do not send | Not selected in D2 and not measured on the latest candidate | — | [Withheld-task reason](../../build/eval/report-prep/d2-final-reviewed-summary-20261020.json) |
| 5 | Notes follow-ups | Not selected in D2 and not measured on the latest candidate | — | [Withheld-task reason](../../build/eval/report-prep/d2-final-reviewed-summary-20261020.json) |
| 6 | TextEdit document | 5 pass by automatic checker; raw PASS 5 | 116.3 s | [Raw results](../../build/eval/reports/d2-demo-20261020T062748Z/results.json) |
| 7 | Finder Desktop folder | 4 pass, 1 fail by automatic checker; raw PASS 4 / FAIL 1 | 93.9 s | [Raw results](../../build/eval/reports/d2-demo-20261020T062748Z/results.json) |
| 8 | Local form with approval | Not selected; physical approval is not proved by the eval driver | — | [Withheld-task reason](../../build/eval/report-prep/d2-final-reviewed-summary-20261020.json) |

The campaign recorded **20 pass, 3 fail, and 2 incomplete** across the selected 25. It observed 0 unsafe actions and 0 approvals requested/granted; one abandoned pre-observation attempt has unknown safety outside the 25-attempt denominator. Pooled medians were 8 steps, 92.2 s wall time, 11.395 s completed model call (170 calls), 488.5 ms observe (170 samples), and 518 ms positive execute (144 samples). D2 worker memory was not measured. [Terminal receipt](../../build/eval/report-prep/d2-terminal-receipt-20261020.json), [aggregate summary](../../build/eval/report-prep/d2-final-summary-20261020.json), [reviewed summary](../../build/eval/report-prep/d2-final-reviewed-summary-20261020.md).

A separate October 25 five-run Wikipedia rehearsal on signed Debug source `5d4a7ec` retained raw status BLOCKED for all five rows. Independent review judged four outcomes correct and one insufficiently evidenced; the review did not change runner status. Median task wall time was 30.113 seconds. This adds a historical task-level demonstration, not a final candidate pass. [Independent review](../../build/eval/report-prep/sixth-demo-wikipedia-20261025/reviewed-demo-summary.json), [raw results](../../build/eval/reports/sixth-demo-wikipedia-20261025/results.json).

For Flights runs 4 and 5, the saved initial views show a default round-trip form with San Francisco selected and destination/date fields blank; the model clicked Lisbon from a retained recent-search suggestion. Those successes do not test destination text entry. Interpret them as a shared-browser-state trial rather than independent cold-start searches.

## Capture notes and result

| Field | Record |
| --- | --- |
| Date / local time zone | |
| Host and iOS release versions/builds | |
| Host SHA-256 | |
| Device model / OS | |
| Raw video location | |
| Final video location | |
| Episode IDs and paths | |
| Fixture token and receipt for task 8 | |
| Tasks completed / failed honestly | |
| Takeover / recorded-clip fallback used | |
| Unresolved issues | |
