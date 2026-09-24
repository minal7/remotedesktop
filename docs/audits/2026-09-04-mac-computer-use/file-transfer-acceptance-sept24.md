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
| File inventory and identity | Disposable directory with presentations, spreadsheets and decoys; distinct opaque references; accurate metadata; bounded/incomplete inventory; stale and foreign references rejected | Implemented, compiled and component-tested: 6 catalog tests pass after expected RED; no planner integration yet |
| Choice transport and UI | Options survive delivery and a fresh recovery probe; choosing sends the exact ID for the same question; expired/foreign options fail; free text remains usable | Wire/store implemented, compiled and component-tested: 5 new choice tests and 4 legacy checks pass; HostManager and client integration pending |
| Controlled upload | Actual app/model chooses the file, resolves ambiguity when needed, assigns it through the owned browser and uploads to a local test endpoint; server bytes match the fixture | Not implemented or executed |
| Real Drive | Same app/model workflow with disposable valid files in Downloads and a signed-in default account; fresh completed-upload/new-item evidence; read back the uploaded test file and compare SHA-256 where available | Not executed or accepted |
| Email attachment | Exact selected attachment sent to the verified own account, with destination/attachment evidence | Follow-up; not implemented or accepted |

Freeze expected file identities and bytes outside model inputs. Include near-name spreadsheet matches and a newer unrelated file so “latest presentation” cannot pass by choosing the newest file of any type. Test a pre-existing same-name remote item separately; it cannot count as proof of a new transfer.

## Known integration gaps

The owned WebKit browser currently uses an ephemeral data store and does not implement its file-open-panel delegate. WebKit documents that an unimplemented macOS file-panel callback behaves as cancellation. The callback supplies selected local URLs; completion still requires separate remote evidence. [WebKit delegate contract](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKUIDelegate.h).

WebKit supports persistent app-owned profiles through an identified data store. Any login persistence change must preserve task/window ownership and keep test profiles separate from user profiles. No credential or browser-profile copying is needed. [WebKit profile API](https://webkit.org/blog/14423/building-profiles-with-new-webkit-api/).

Drive supports browser file upload and can treat a same-name upload as a revision. Its remote creation/modification dates also have different meanings, so a row name or timestamp alone is an insufficient test oracle. [Google Drive upload behavior](https://support.google.com/drive/answer/2424368?hl=en).

Component checkpoint: the serial RED compiled and produced 7 expected behavioral failures. GREEN passed 15 focused tests (0 skipped, 0 runtime warnings, 0 compiler errors; 31 existing compiler warnings). No inference or uploads ran. [Exact component evidence](file-selection-component-results-sept24.json).
