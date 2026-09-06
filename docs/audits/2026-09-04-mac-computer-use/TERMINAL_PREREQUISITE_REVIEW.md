# Explicit prerequisites before terminal answers

Parent source: `ddb0c59`. Status: source implementation and regression registration only. No build, tests, model inference, app launch or computer-use action ran. Performance optimization and real-site qualification remain deferred.

## First-principles problem

Evidence of a result and evidence of executing a requested workflow are different obligations. A visible appointment can answer “When is my appointment?” It cannot by itself prove “Click the appointment details button, then tell me the appointment” if that click never happened.

The visual executor already checks visible answer evidence and requires host verification for `COMPLETE`. Its post-action verifier also retains the immediately preceding semantic effect. These checks did not independently require every earlier explicit action to be represented in ordered host history. A terminal answer could therefore bypass missing prerequisites even when its quoted facts were visible.

The new check shares the existing pointer/input command grammar. It examines the original trusted request and the full raw host history immediately before accepting a terminal report or completion. It does not use the compacted history supplied to the model. The separate host completion verifier now also receives raw history; model routing continues to receive its existing redacted, bounded history.

## Prerequisite states

- **Recorded:** Every recognized explicit prerequisite has a matching ordered host-history entry. Either all action clauses have been consumed, or exactly one terminal information clause remains. Existing current-screen and capability-specific outcome verification is still required.
- **Pending or unproven:** An action is missing, reordered or extra; input bytes do not match; a known sequence contains an unsupported operation; another clause remains after the information clause; or repeated action syntax has no compiled visual step contract.
- **Not applicable:** The task does not contain an explicit low-level sequence handled by this grammar. This is not completion proof. Existing capability-specific checks continue to decide its outcome, and broader whole-goal qualification remains open.

The shared matcher keeps application names, action families, direction/shortcut markers and exact literal input in order. An already-current application can satisfy its opening/scope clause only when the current application identity is authoritative. A family-only `TYPE` marker or model-compacted history cannot discharge an input clause. Exact long input retains the existing full-payload history digest, so changing a clipped suffix cannot reuse the same evidence.

Unrequested `WAIT` entries are no-effect settling observations; they do not consume a pending effect. An explicitly requested wait still needs its own entry. Separately written repeated action clauses require separate history entries. Effect repetitions expressed with `twice`, `again` or a non-one `N times` suffix remain unproven until the visual compiler creates distinct steps. This leaves the existing native form compiler's repetition support intact and does not remove global visual TYPE/ENTER guards. Quoted payload text such as `again` and ordinary factual questions are not treated as repeated effects.

## Production integration

The terminal action gate checks both typed and raw reports, as well as `COMPLETE`, against the original request and raw host history. A pending prerequisite produces a typed unable result instead of success. An independently verified obstacle can still be reported without performing the remaining workflow, and a clarification can still ask for information. Obstacle metadata cannot waive prerequisites for `COMPLETE`.

The early visible delivery-quote return also checks prerequisites before terminating. Its existing quote/subject validation and follow-up-effect restrictions remain required. This prevents that shortcut from bypassing an explicit unperformed action.

The prerequisite check does not turn raw gesture history into an independent OS dispatch receipt or prove a target's final state. It is an additional necessary condition. Existing action authorization, target binding, last-effect checks, fresh visible evidence, uncertainty handling and terminal-state revalidation remain in force.

## Prepared verification

Three planner methods specify complete versus incomplete ordered app/click/type/Return workflows, missing prefixes, wrong order, changed or redacted payloads, extra actions, settling versus explicit waits, authoritative application scope, long/Unicode/marker-looking payloads, unsupported barriers, later actions/answers, and repeated clauses versus uncompiled repetition syntax.

Two terminal-gate methods require every explicit prerequisite even when a fixture supplies a positive host-completion flag or an already-verified typed answer. They also require final outcome proof after prerequisites are recorded, and preserve obstacle and clarification outcomes.

A fake-runtime method uses the production executor, a proposal-only semantic router and a controlled appointment screen. The router proposes a visible answer before the requested click. The expected outcome is typed inability, with no input and no visual inference. This fixture has not run and does not qualify actual model interpretation.

The [21-method focused inventory](terminal-prerequisite-inventory.json) and the 463-method default inventory match exact source identifiers. `git diff --check` passes. These are source checks, not compilation or execution evidence.

## Remaining repairs

1. Compile complete visual/structured task contracts, including high-level search, future targets, intermediate information results, generated content and constraints. An unrecognized task shape still relies on its existing capability verifier; this check does not prove all natural-language requirements.
2. Replace action-family history with per-step target/payload/observation-bound receipts and durable reconciliation. A raw recorded click is not independent proof that the intended application outcome occurred.
3. Compile repeated visual operations before removing task-wide TYPE/ENTER suppression. The prerequisite guard deliberately does not fabricate repeat steps or authorize replay.
4. Add bounded recovery from premature terminal proposals so the planner can complete missing supported steps. This patch prevents false success; it does not supply a replacement effect plan after every rejected proposal.
5. Qualify combined navigation, input, submissions, current results, compound answers and cancellation through the actual model and production host/controller. Travel, concert and movie website testing still requires the user's explicit permission.
6. Measure resource use in the later performance phase. No 8 GB, thermal or latency claim follows from these source changes.
