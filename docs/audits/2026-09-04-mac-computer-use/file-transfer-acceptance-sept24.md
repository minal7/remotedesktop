# File selection and transfer acceptance — September 24

This is the next required end-to-end milestone. Component tests do not accept it. The application must perform the workflow using local models and native tools; Codex may prepare fixtures and inspect results, but must not perform the upload in place of the application.

## Required behavior

- “Upload the last presentation in Downloads to Google Drive.” The model uses observed filenames, file types, sizes and timestamps to identify the intended file. Preserve the distinction between modification, creation and date added; do not invent a download date when it is unavailable.
- “Email the spec Excel spreadsheet to my email.” Resolve the file and the user's own destination account. Implement this attachment variant after the Drive workflow; it remains in scope.
- If the observed files do not distinguish the intended match, offer selectable candidates with names and useful dates/type/size. Bind selection to a candidate ID, the live question and the original task. Do not interpret a filename as an instruction.
- Use the default authenticated Drive account. If the application's own browser lacks a session, use the existing login handoff and resume the same task. A login in a different browser does not establish this precondition.
- Preserve a selected file through Pause/Resume. If the file disappears, changes or is replaced before transfer, request a new selection. Stop must prevent subsequent transfer, and retry/resume must not create duplicate uploads.
- Report success only after fresh destination evidence. A picker callback or local file assignment alone is not proof of remote upload.

## Test progression

| Gate | Proof required | Current state |
| --- | --- | --- |
| File inventory and identity | Disposable directory with presentations, spreadsheets and decoys; distinct opaque references; accurate metadata; bounded/incomplete inventory; stale and foreign references rejected | Implemented, compiled and component-tested: 9 catalog tests pass, including typed filtering/sorting across the bounded inventory; no planner execution integration yet |
| Choice transport and UI | Options survive delivery and a fresh recovery probe; choosing sends the exact ID for the same question; expired/foreign options fail; free text remains usable | Host/phone integration implemented: 9 host checks, 1 native continuation regression and 5 actual client state tests pass; Mac and iOS app compile. Actual phone button interaction and model continuation pending |
| Native picker | Actual native click supplies the retained catalog file once; stale replacement, navigation, takeover and reuse fail | 7 focused native-browser/text/form checks pass; visible main-frame inputs only; filename/size/count observed, no upload bytes |
| Controlled upload | Actual app/model chooses the file, resolves ambiguity when needed, assigns it through the owned browser and uploads to a local test endpoint; server bytes match the fixture | Not implemented or executed |
| Real Drive | Same app/model workflow with disposable valid files in Downloads and a signed-in default account; fresh completed-upload/new-item evidence; read back the uploaded test file and compare SHA-256 where available | Not executed or accepted |
| Email attachment | Exact selected attachment sent to the verified own account, with destination/attachment evidence | Follow-up; not implemented or accepted |

Freeze expected file identities and bytes outside model inputs. Include near-name spreadsheet matches and a newer unrelated file so “latest presentation” cannot pass by choosing the newest file of any type. Test a pre-existing same-name remote item separately; it cannot count as proof of a new transfer.

## Known integration gaps

The owned WebKit browser still uses an ephemeral data store. Its file-open-panel delegate now supplies exactly one freshly resolved catalog file after an admitted native click, with a bounded asynchronous wait and current task/document/session checks. A visible main-frame file input is required; button-triggered hidden inputs are not implemented yet. The callback supplies a selected local URL; completion still requires separate remote evidence. [WebKit delegate contract](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKUIDelegate.h).

WebKit supports persistent app-owned profiles through an identified data store. Any login persistence change must preserve task/window ownership and keep test profiles separate from user profiles. No credential or browser-profile copying is needed. [WebKit profile API](https://webkit.org/blog/14423/building-profiles-with-new-webkit-api/).

Drive supports browser file upload and can treat a same-name upload as a revision. Its remote creation/modification dates also have different meanings, so a row name or timestamp alone is an insufficient test oracle. [Google Drive upload behavior](https://support.google.com/drive/answer/2424368?hl=en).

Component checkpoint: the serial RED compiled and produced 7 expected behavioral failures. GREEN passed 15 focused tests (0 skipped, 0 runtime warnings, 0 compiler errors; 31 existing compiler warnings). No inference or uploads ran. [Exact component evidence](file-selection-component-results-sept24.json).

Latest integration checkpoint: typed choices retain the original user goal, survive Pause/Resume, and cannot turn a filename into a user instruction. The catalog sorts before paging and preserves missing-date evidence. The corrected native picker test uses a real foreground window and leaves its input unlabeled. Seven picker/text/form checks pass after the label-admission fix; 9 catalog, 9 host, 1 native-continuation and 5 client-state checks passed in focused serial batches. iOS SwiftUI compiles; no inference or real upload ran. [Exact integration evidence, build failures and corrected test setup](file-choice-integration-results-sept24.json).
