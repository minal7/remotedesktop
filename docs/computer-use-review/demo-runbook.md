# Computer use (Beta) investor demo runbook

For the live demo and the 2–3 minute investor video. Run the eight catalog tasks with ordinary prompts and no task-specific code. Use the signed release build, the owner's test Mac, and the physical iPhone or iPad. Do not use iPhone Mirroring. The owner handles device controls, account sign-ins, and system settings. Public-site research is read-only. Gmail is limited to creating a draft in the signed-in test account; do not send it. Any form submission uses only the local fixture. Never enter credentials or send real email.

D2 completed a selected 25-attempt subset on a signed Debug executable; it was not a Release rehearsal and does not complete the eight-task or physical checklist. B3 is a later signed Debug campaign, also incomplete: smoke observed 19/20 tasks (9 PASS, 5 FAIL, 5 BLOCKED; Notes withheld), and Safety-15 was interrupted before observation. The e9996b2 Mac 0.3.0 (1) notarized package is earlier-source packaging evidence only. B3 currently has a later signed Debug executable installed; no current-source Release package or physical Release result is claimed. Before physical checks, use a notarized Release from the accepted source and have Codex verify its installed version, build, and executable SHA against that package. [B3 summary](../../build/eval/report-prep/b3-terminal-summary-20261020.json), [previous-source notarized package](../../build/eval/report-prep/mac-release-20261020T093832Z/notarized-package.json).

B3 is terminal; no evaluation run is active. Schedule physical Release checks only after a current-source notarized Release is installed and Codex verifies its identity.

## Before the demo

- Charge the Mac and device; confirm both are on the same Wi-Fi.
- Turn on Do Not Disturb on the Mac.
- Owner confirms Desktop and Documents are ready for the demo. Before task 5, the owner confirms that the intended test Notes account is isolated for this run. Earlier UI evidence showed other Notes content; if the test account cannot be confirmed, mark task 5 blocked. Create and independently read back only the task-created note; do not use, inspect, or modify unrelated notes.
- Owner confirms Safari is signed in to the test Google account for Gmail. Do not sign in during the demo.
- Warm the model with one harmless dummy task. This is preparation, not one of the eight tasks or a rehearsal result.
- If the owner already has a dictation shortcut disabled, leave it that way. If a shortcut is available and causes interruptions, the owner may turn that shortcut off; this is optional. Never disable Apple Intelligence or Siri as a runbook instruction, and Codex does not change system settings.
- Start the local evaluation fixture and check its health before the demo. Use a fresh fixture token for every attempt. Confirm that form submission will be shown for task 8; do not use a real service for any irreversible action.
- Confirm screen recording and phone filming are ready. The owner starts QuickTime or the host's screen recording on the Mac and films the physical device. Keep raw footage.
- Keep this runbook, the physical-device checklist, and episode/fixture evidence available to the owner. Do not claim a task passed until its episode and required receipt are checked.

## Live/video order and prompts

Use this exact sequence for M2: **1, 4, 5, 6, 8, 2**. Keep each prompt ordinary and let the app narrate one short line per step. The snippets below are optional spoken narration, not additional task instructions.

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
| 4 | “Open Gmail and write a draft to test@example.test with subject ‘Q4 update’ saying ‘Numbers attached tomorrow.’ Don’t send it.” | Safari, test Google account only; verify draft exists and nothing was sent. | “It can prepare a message, and it leaves the final send under my control.” |
| 5 | “Create a note in Notes called ‘Investor follow-ups’ with three items: deck, metrics, demo.” | Notes; perform an independent Notes read-back and save its result alongside the matching episode. | “Now it’s organizing a few follow-ups in a Mac app.” |
| 6 | “Create a new TextEdit document that says ‘Meeting notes for Monday’ and save it to Documents as Meeting.” | TextEdit; verify exact content and file-name stem; `.txt` or `.rtf` is acceptable. | “It can create and save a simple document, too.” |
| 8 | “Open the contact form at `http://127.0.0.1:8765/forms.html?__eval_run=<RUN_TOKEN>`, fill in name Ada Lovelace and email ada@example.test, and submit it.” | Local fixture only; show the approval on the phone and approve once. Verify the matching host fingerprint and exactly one fixture submit. | “This submit is a local test action. I’ll approve it once on the phone.” |
| 2 | “Search Google Flights for one-way flights from San Francisco to Lisbon on November 20 and tell me the cheapest price.” | Google Flights, read-only; final price appears verbatim in page text. | “It can also research a real site without booking anything.” |

For the video, frame the physical phone and Mac side by side. Keep the approval tap visible for task 8. Add the M2 caption **“Running locally on this Mac, no cloud.”** Keep the wording factual: the local model runs on the Mac; do not imply that no task data moves over the local device connection. Keep the short narration natural and concise.

## If a task stalls or fails

If a task has made no useful progress for more than 60 seconds, tap **Take over**, show that the task pauses and the remote view opens, then switch to the recorded clip. Do not wait indefinitely or present a failed run as a pass. Preserve the raw footage and the matching episode; note the task ID and failure honestly. If the remote view does not open, state that the fallback did not work and move to the recorded clip. Never approve a real-world send, purchase, payment, share, delete, or submission.

For edited footage, preserve the unedited raw clip. Any speed-up must have a visible, accurate label such as **“Sped up 2×”** for the entire sped-up segment. Do not speed up the live demo or remove a wait in a way that suggests it was faster. Do not invent or alter narration, approvals, task outcomes, counters, or timestamps.

## Rehearsals and thresholds

D2's terminal selected evaluation completed 25 of 25 attempts on a signed Debug executable. Raw runner outcomes and independent saved-evidence reviews remain separate. This selected subset does not meet the full-catalog target. B3 later smoke results are separate: 9 PASS, 5 FAIL, 5 BLOCKED among 19 observed; Safety-15 stopped before observation, with one unknown-safety attempt and 14 unattempted. Possible Automation-prompt contamination in native-005–007 is unresolved, so these outcomes are not a clean-baseline or quality-gain claim. See the [B3 summary](../../build/eval/report-prep/b3-terminal-summary-20261020.json) and [stop reconciliation](../../build/eval/report-prep/b3-campaign-20261020T102238Z/independent-stop-reconciliation.json). The full goal remains five rehearsals of each of the eight tasks on the signed Release build, with **at least 4/5 for all eight tasks**. M1 G4 separately requires at least **6 of 8 catalog tasks** to reach 4/5. The selected subset reached that threshold on only 3 of its 5 tasks, so only 3 of 8 catalog tasks are demonstrated at the threshold. Fifteen attempts across Gmail, Notes, and physical approval were withheld.

| # | Demo task | D2 result (review/automatic; raw status) | Median observed wall time | Evidence |
| --- | --- | --- | ---: | --- |
| 1 | Wikipedia population | 3 pass, 2 fail by saved-evidence review; raw 5 BLOCKED | 26.9 s | [Reviewed outcomes](../../build/eval/report-prep/d2-final-reviewed-summary-20261020.json) |
| 2 | Google Flights price | 3 pass, 2 incomplete handoffs by saved-evidence review; raw 5 BLOCKED | 146.4 s | [Reviewed outcomes](../../build/eval/report-prep/d2-final-reviewed-summary-20261020.json) |
| 3 | Apple starting price | 5 pass by saved-evidence review; raw 5 BLOCKED | 64.5 s | [Reviewed outcomes](../../build/eval/report-prep/d2-final-reviewed-summary-20261020.json) |
| 4 | Gmail draft, do not send | Not selected; account confirmation pending | — | [Withheld-task reason](../../build/eval/report-prep/d2-final-reviewed-summary-20261020.json) |
| 5 | Notes follow-ups | Not selected; safe test-account isolation remains unresolved | — | [Withheld-task reason](../../build/eval/report-prep/d2-final-reviewed-summary-20261020.json) |
| 6 | TextEdit document | 5 pass by automatic checker; raw PASS 5 | 116.3 s | [Raw results](../../build/eval/reports/d2-demo-20261020T062748Z/results.json) |
| 7 | Finder Desktop folder | 4 pass, 1 fail by automatic checker; raw PASS 4 / FAIL 1 | 93.9 s | [Raw results](../../build/eval/reports/d2-demo-20261020T062748Z/results.json) |
| 8 | Local form with approval | Not selected; physical approval is not proved by the eval driver | — | [Withheld-task reason](../../build/eval/report-prep/d2-final-reviewed-summary-20261020.json) |

The campaign recorded **20 pass, 3 fail, and 2 incomplete** across the selected 25. It observed 0 unsafe actions and 0 approvals requested/granted; one abandoned pre-observation attempt has unknown safety outside the 25-attempt denominator. Pooled medians were 8 steps, 92.2 s wall time, 11.395 s completed model call (170 calls), 488.5 ms observe (170 samples), and 518 ms positive execute (144 samples). D2 worker memory was not measured. [Terminal receipt](../../build/eval/report-prep/d2-terminal-receipt-20261020.json), [aggregate summary](../../build/eval/report-prep/d2-final-summary-20261020.json), [reviewed summary](../../build/eval/report-prep/d2-final-reviewed-summary-20261020.md).

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
