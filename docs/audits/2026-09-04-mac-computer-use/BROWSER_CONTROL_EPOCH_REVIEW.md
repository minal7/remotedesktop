# Order local browser handoff and phone controls

Parent source: `1d59557`. This is a source repair and regression registration, not runtime qualification. No build, XCTest execution, model inference, app launch, computer-use activity, login or live website run was performed. Performance work remains deferred.

## First-principles failure

The person must retain control while signing in. A command's arrival time does not tell us when the person chose it: the phone can retry or deliver an earlier Resume after local takeover. A phone-only revision counter cannot order choices made on the Mac, and allocating phone revisions on the Mac creates collisions with unseen in-flight commands.

The previous source also replayed the last persisted remote state. A duplicate phone Pause could therefore pause the task again after a newer local handback. That was an unintended new effect from a retry.

The repair uses two clocks with different owners. The phone allocates command revisions. The host allocates a separate durable **host control epoch** for local takeover and handback. A nonterminal phone command must echo the host epoch it observed when the person issued it. Retries retain that original epoch. Neither clock is derived from wall time.

| Order of events | Required result |
| --- | --- |
| Phone Resume arrives; then local takeover | The gate closes and the local pause wins. |
| Local takeover; then an older in-flight phone Resume | Reject Resume without acknowledging its revision. |
| Phone Pause arrives; then local handback; then a duplicate Pause | Replay the current running state without pausing again. |
| Local handback; then an older higher-revision phone Pause | Reject the stale epoch even though its phone revision is higher. |
| Current-epoch phone Resume after takeover | Use the existing explicit Resume path, join prior execution and reacquire the browser page. |
| Stop during any of these sequences | Stop remains absorbing; later controls cannot revive the task. |

## Host changes

`ComputerUseTaskLedger` retains `hostControlEpoch` and an optional local state alongside the remote control snapshot. Effective state is Cancel first, then the local override, then the remote state. A local control requires the claimed task's exact bound sender/session and an established prompt-body digest. Local takeover and handback do not consume remote revisions.

An accepted current-epoch remote command clears the local override. Duplicate commands return the effective state. An incorrect epoch returns a separate rejection disposition and leaves the actual applied revision unchanged. Fresh Cancel remains admissible regardless of its observed epoch. Terminal records still acknowledge later remote revisions without becoming executable. Exhausted host epochs reject further nonterminal transitions; Stop remains available. Malformed epoch/state records fail closed.

The shared pause path persists the host epoch for local browser takeover, physical-input intervention, an executor-requested login/manual step, and blocked execution/approval handoffs. It closes the action gate before persistence and cancellation. Failed persistence leaves effects blocked, poisons the ledger's write path and disables local handback. Local handback persists before opening the execution path. A failed attempt to continue creates a newer pause epoch when storage permits it.

Browser control snapshots include the host epoch. Publishing and revalidating them invalidates obsolete Resume presentations, including a failed handback that returns to the same visible paused phase. Stop still accepts a prior presentation for the same run when mouse-down intervention precedes its click handler.

Approval cards carry the host epoch as well as their existing task ID, nonce and remote revision. The host checks all of those before accepting a response. The approved-action ledger checks effective state, so a prior remote Pause neither blocks a valid later local handback nor authorizes an action during a local pause. Historical action-evidence updates cannot carry lifecycle epochs.

## Phone changes

The recovery record now distinguishes:

- The highest phone revision allocated, used for the next command number.
- The highest revision actually acknowledged by the host, which cannot be forgotten when a local choice supersedes a pending phone intent.
- The original revision and kind of the last phone command, which do not change when a higher acknowledgement arrives before relaunch.
- The latest observed host epoch and the epoch frozen with the last phone command.
- Whether the latest accepted host state is paused, so relaunch can restore the handoff without inventing a new phone Pause.

A greater authenticated, task-correlated host epoch retires older pending Pause/Resume and approval state only after saving that change. It may supersede an unacknowledged phone command while carrying a lower actual applied revision. It does not fabricate an acknowledgement and cannot satisfy pending Stop. The real applied-revision floor remains enforced across recovery. Metadata from an older epoch, or legacy unversioned lifecycle traffic after a nonzero epoch, cannot replace the newer state.

Retries and relaunch use the command's original epoch, not the latest observed value. The Keychain recovery record and pairing-code rebinding preserve those fields. A failed save also retains the newest observed epoch in memory as a barrier: older traffic cannot reopen the UI state, and a new Pause/Resume cannot be issued against the older durable clock. Stop remains available.

Versioned host pauses no longer trigger an automatically allocated phone Pause. That automatic echo could turn a delayed status into a new command that undid a subsequent handback. The legacy fallback remains for hosts without a nonzero local epoch.

## Compatibility and boundaries

All new wire fields are optional. Missing command epochs mean zero, never the current host value. Existing pre-handoff controls retain their old behavior. After a local handoff, older clients cannot resume with an empty or epoch-less request; local browser controls or an updated phone are required. Stop remains available. This fail-closed compatibility behavior needs visible host/phone qualification.

The epoch records control transitions, not every keystroke or mouse movement during an already-paused login session. Continuous manual-input/handback races still need end-to-end review with the input gate. This change also does not provide a general multi-client controller lease or a new transport delivery guarantee.

Normal ledger reconstruction preserves epochs and effective state. It does not introduce automatic host-process restart continuation for already-started tasks: existing at-most-once recovery remains in force. Browser state is still nonpersistent, and closing the browser or restarting its owner can lose the login session. Ledger deletion, expiry and process-wide ownership remain separate recovery concerns.

The prior [browser login handback repair](BROWSER_LOGIN_HANDBACK_REVIEW.md) retains the owned browser session and reacquires a manually navigated page after explicit handback. The new protocol orders that handback. Neither repair proves real account login, popup authentication, complete ticket search or verified whole-goal results.

## Prepared regression coverage and checks

Six new host methods cover both arrival orders, duplicate replay, persistence/reconstruction, pre-Prompt handback, owner binding, malformed/exhausted epochs, host/browser composition, storage failure with cancellation-ignoring execution, and approval epoch matching. Seven new phone methods cover wire compatibility, evidence isolation, delayed Resume, restored handoff, stale lifecycle traffic, Stop, current approval echo, foreign scope, failed saves and retained actual acknowledgements. Existing intervention/Resume fixtures now supply the host epoch explicitly; the pairing-recovery fixture checks preservation of every new field.

The source inventory verifier passes for **575 default host methods**, **37 focused host methods**, and **12 focused phone methods**. `git diff --check` passes. These checks find registered method identities and whitespace issues; they do not compile Swift, execute assertions or verify UI behavior.

- [Focused host inventory](browser-control-epoch-host-inventory.json)
- [Focused phone inventory](browser-control-epoch-client-inventory.json)

## Next repair and qualification steps

1. Finish browser capability support for complete multi-step search, date/location controls and source-backed result extraction, preserving the original goal through login.
2. Review supported account flows, popup/new-window authentication, session lifetime and explicit login-state observation without collecting authentication secrets.
3. Qualify these host/phone control regressions, the visible buttons, lost/delayed messages and restart recovery when execution is authorized. Include control changes while a browser navigation or approval is pending.
4. Complete the deferred performance/resource work and the small bounded live-run plan before asking to run real travel, concert and movie scenarios.
5. Run those real-site scenarios only after the user's explicit permission. Compare dates, locations, availability, prices/fees and source links independently; stop before unrequested purchase or booking.
