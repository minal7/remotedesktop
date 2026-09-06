# Owned sign-in windows with explicit handback

Parent source: `9d003d3`. Status: source repair and prepared regressions. No type checking, app build, test execution, inference, app launch, computer use, real login or public-website task ran. Correctness work continues; performance optimization and the user's live scenarios remain deferred.

## First-principles failure

Authentication is an interaction between the person, the website and its provider. A provider window may need the originating window, messages between those windows and a shared browser session. Replacing the popup with an unrelated browser or loading its URL into the main window can destroy those relationships. Cancelling every targetless navigation, as the previous source did, prevents these flows entirely.

The ownership requirements are separate from authentication success:

1. A person must visibly own the sign-in interaction while AI effects are closed.
2. The child must belong to the same task and account-control context as its opener.
3. A remote Resume must not destroy an unfinished login or run a successor executor through it.
4. Closing the child only removes that window. It cannot prove successful login, identify an account or authorize handback.
5. After explicit handback, the main task must observe its current page again and verify its remaining obligations. Provider navigation cannot masquerade as an AI navigation receipt.

## Source implementation

`ComputerUseOwnedBrowser` now implements the public `WKUIDelegate` creation and close callbacks. It constructs a single child using WebKit's provided configuration and lets WebKit perform the initial load. This follows Apple's configuration/load contract and preserves the relationships the framework supplies; runtime session/opener behavior still requires qualification. [Apple creation contract](https://developer.apple.com/documentation/webkit/wkuidelegate/webview(_:createwebviewwith:for:windowfeatures:)).

Creation requires the exact main WebKit view, no existing child or pending navigation/DOM operation, a settled main page, a closed action gate and matching paused/resumable task controls. Scripted popup creation is enabled in the WebKit preferences so asynchronous provider callbacks can request a window, but the application delegate still refuses creation during automation, approval, nonresumable pause and unrelated ownership. Only one window is admitted; extra and nested popup requests are refused.

HTTP(S) locations without embedded credentials and `about:blank` are accepted. Empty/omitted locations are accepted only at child creation, allowing a website to allocate a blank window before assigning the provider URL. The upstream `LocalDOMWindow` creation path retains an empty URL for an empty `window.open` argument; installed WebKit behavior remains unexecuted. Later child navigations require an explicit supported location. [WebKit creation source](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/page/LocalDOMWindow.cpp).

The child uses a narrow AppKit `NSWindow` boundary because WebKit supplies a concrete view tied to the opener. SwiftUI renders observable website/status values and local Close/Stop controls; the owned browser retains the WebKit/window/delegate lifecycle. The window has standard title/close/resize controls, no restoration and an initial frame constrained to the parent display's visible bounds. The main browser disables Let AI continue and gives guidance while a child is open. Child website labels use the existing scheme/host/port projection. Raw callback URLs and raw WebKit error descriptions are not published by this new UI.

The host's existing button `scopeID` changes when Resume allocates a successor execution. Using it for child ownership would close the popup before the resumed executor could check it. A new `ownerID` instead remains stable for the same task, peer, session, authorization generation and transport generation; it changes when any of those owners change. It does not replace or relax button/run/presentation validation.

An open child independently blocks `hasOwnership`, document validation, navigation admission, task claiming, required presentation and explicit browser reacquisition. Early authenticated Resume therefore returns a nonterminal intervention with specific close/finish guidance before the successor executor runs. It preserves the child and original task. Child network navigation remains permitted during the brief working phase of this rejected Resume, avoiding cancellation of the person's in-flight authentication.

The app never sends its DOM commands to the child. Creation itself does not extract credentials, page fields or cookies. The supplied configuration may inherit the host's isolated user script; that script's value-reading commands are not dispatched into the child. Existing parent authentication guards remain necessary after handback. This does not qualify visual/AX observation privacy or page-displayed content.

Child navigation/response/failure callbacks use a separate identity branch and never update main-page navigation state or receipts. Displayable provider error pages can be shown to the person without becoming successful task evidence. Unsupported destinations or failed loads show fixed guidance. The child's DOM close notification removes its view/window as described by Apple's close callback contract. [Apple close callback](https://developer.apple.com/documentation/webkit/wkuidelegate/webviewdidclose(_:)).

Explicit child close and provider close retain the main page/session and paused task. Stop, main close, ownership change/revocation and WebContent termination retire the child. Delegate and observation identity is retired before stopping its load or releasing the view, so late callbacks cannot target a replacement or publish main-page evidence. Child close never opens the action gate. Main-page history/navigation changes continue to use the earlier handback proof; an unchanged authentication form still requests intervention after Resume.

## Prepared regression coverage

Four owned-browser methods and one host/native method are added to the default source selection:

- Four creation variants (direct provider URL, explicit `about:blank`, empty argument and omitted argument) preserve opener `postMessage`, a shared session cookie and the original navigation receipt. A provider-induced main-page history change is unavailable until explicit handback; a fresh exact field edit produces one independent input event. The fixture verifies no host DOM dispatch during user control and website-only popup labels.
- Creation is refused during automation, approval and a pause that cannot resume. A resumable pause admits one child while refusing an unsupported initial location, an extra parent popup and a nested child popup.
- A new execution scope with the same task owner preserves the popup and rejects early handback. Stop, main close, changed owner and revoked controls retire a held child load; a bounded late-response check rejects its subsequent script. This check is not a general proof that every WebContent teardown race is handled.
- Closing a child without changing the parent does not assert successful authentication. Explicit handback still encounters the parent's protected form and returns `authenticationRequired` without another page load.
- The production host/coordinator/native path pauses on a controlled authentication form. An authenticated early Resume changes the execution scope but preserves the owner/popup, increments the host pause epoch and runs no successor executor. After a provider message closes the popup and changes the main form, a higher authenticated Resume continues the same literal request, edits the fresh field once and retains durable replay behavior. No model or desktop fallback is used in this fixture; it is not a travel/concert/movie acceptance test.

One additional opt-in visible method prepares actual NSWindow lifecycle checks: child visibility, key window, standard controls, display bounds, disabled restoration and closing the child while preserving the paused parent. It is separately inventoried with the existing visible-browser method and requires `RUN_OWNED_BROWSER_VISIBLE_ACCEPTANCE=1` when execution is eventually authorized. No window was rendered for this repair.

## Verification and remaining work

The [default manifest](../../../host-mac/AcceptanceFixtures/osatlas-deterministic-tests.json) selects **597** source methods. The [focused manifest](browser-popup-handoff-inventory.json) selects **77** methods (owned browser, DOM adapter and selected host handoff flows). The [opt-in visible manifest](browser-popup-visible-inventory.json) selects **2** methods. Exact source inventory checks, four-file `swiftc -frontend -parse` and `git diff --check` pass. Parsing does not resolve symbols, check protocol conformance/concurrency or compile executable code. None of the assertions above has executed; historical inventory snapshots are unchanged.

Continue the repair plan with these gaps explicit:

1. Qualify WebKit callback ordering, process termination, early Resume with an in-flight child response, actual local Stop from the child, revocation/transport changes and visible lifecycle. The prepared fixtures do not establish runtime correctness.
2. Qualify cross-origin providers, cookie/storage policy, redirect/POST/fragment combinations, opener policy, account identity and session expiration. Same-origin loopback fixtures do not establish real provider compatibility.
3. Handle providers that prohibit embedded browsers, external app/custom-scheme callbacks and system authentication where appropriate. No external browser profile is imported, and no provider restriction is bypassed. Nested provider windows, dialogs and file selection remain unsupported.
4. A paused website can request a window without a fresh click. The source admits only one concurrently, but does not distinguish provider UI from an advertisement or enforce a total creation limit across repeated close/open cycles. Review user-facing admission and abuse handling before real-web qualification.
5. Complete remaining-goal reconciliation after login. Retained attempted edits and scoped clarification cannot be blindly rebound to a changed page; preserve their effect evidence while binding fresh targets to the remaining work.
6. Implement full navigation/search, date/location controls, result extraction and verified public source links. An owned sign-in window does not establish these browsing capabilities.
7. Complete privacy checks across page content, visual/AX observations and other tool results. Website labels alone do not sanitize all observation routes.
8. Measure browser/WebContent resource use within the overall 8 GB product budget during the later performance phase. One child bounds concurrent windows, not memory, CPU or fan load. Do not run live website or account tests before the user's explicit permission.
