# Local agent harness

The agent that runs on the Mac when you ask for something from your iPhone or iPad. All of its code is in [host-mac/LocalAgentKit](../../host-mac/LocalAgentKit). It replaces the old `AgentLoop` path for phone tasks; the phone app, its transport, the live view, approvals and takeover are unchanged.

## The constraint it's built around

A 16 GB Mac runs a roughly 7–9B vision model with a usable context of about 4–8 K tokens, at a cost per token that matters on a base chip. So:

- **No conversation.** Each step's prompt is rebuilt from scratch and fitted to a fixed token budget. A 200-step task sends prompts the same size as a 5-step task.
- **Text first, pixels when needed.** The screen is a numbered list of elements read from accessibility, which costs far less than a screenshot and gives exact targets. A screenshot is attached only when accessibility is poor, when the model asks, or when it's stuck.
- **The model never does what code can do.** Finding elements, resolving targets, noticing that nothing changed, detecting loops, judging risk and folding history are all deterministic host code.

## One step

```
observe -> fit prompt -> decide -> validate -> safety -> act -> settle -> measure change -> record
```

| Stage | What happens | Where |
| --- | --- | --- |
| Observe | Walks the front window's accessibility tree under a node and time budget. Falls back to Vision OCR when the tree is poor (Java, Qt, canvas, remote sessions). IDs stay stable while an element persists. | `Perception/` |
| Fit prompt | Ranks elements by usefulness now (focus, dialog, new, matches the goal), keeps what fits, prints them in screen order, and says what it dropped. | `Core/ContextBudget.swift` |
| Decide | One JSON action, with its shape enforced by grammar in llama.cpp, so parsing can't fail. The required `step` field makes the model state where it is in the plan. | `Core/Tools.swift` |
| Safety | Deterministic and independent of the model. See below. | `Core/Safety.swift` |
| Act | Semantic first (AXPress, focus, menu paths), real input second. Only falls back when nothing changed, and never after an approval. | `Actuation/` |
| Measure | Compares scenes and reports a plain result ("a dialog opened", "nothing changed on screen"). | `Perception/Scene.swift` |

## Keeping a small model on track

- **Working memory** has fixed shares: goal, plan, notes, recent actions, older actions folded to one line. Finishing a plan step folds its detail away so the model isn't tempted to redo it.
- **`read`** answers a question from text too long for one prompt by asking over chunks, then keeps the answer as a note.
- **`find`** searches the whole window, including what didn't fit the listing or is scrolled away.
- **The supervisor** escalates: same action refused on the same screen, then a screenshot, then a new plan, then asking the person. It compares actions by meaning, so "File, New, File, New" is caught even though each click changes the screen.
- **The completion check** is a separate strict question with a fresh look at the screen. A false "done" sends the model back with what's missing.

## Two models

With a computer-use model configured, two models split the work. Which pair ships is still to be chosen from measured results.

- **The planner** is a small text model. It breaks the goal into jobs, carries facts between them, reads results and the accessibility or OCR text of the screen, and writes the answer. It never sees or clicks anything. See `Core/Orchestrator.swift`.
- **The worker** is a computer-use-trained vision model, spoken to in the exact prompt, tool schema, coordinate grid and history shape it trained on (`Core/CUADialect.swift`). It hears only its current job and the facts it needs, so its prompt stays the same size however long the task runs.
- **Frames.** A browser-trained worker sees the app's window. A desktop-trained worker sees a display-shaped image holding only the target app's windows, which keeps the scale it trained on without showing it anything else. Clicks outside those windows are refused.
- **Trouble goes up.** A job ends early if actions stop changing anything or fall into a loop, and the planner then changes approach. After three failed jobs in a row the person is asked.

Every action from either route goes through the same `execute`, so safety checks, approvals, Stop and takeover don't depend on which model chose it. Clicks are judged by the control under the pointer. Near misses beside a dangerous control still ask.

## Safety

- Screen content is data. The prompt says so, and more importantly no decision below depends on the model believing it.
- Consequential actions (send, pay, delete, submit and similar, by the target's label) wait for approval on the phone. An approval is void if the target changed while waiting.
- Password fields are never typed into; the person is asked to take over. Saved-password apps aren't opened.
- Apps that can run commands always ask, and show what would be typed.
- Input goes through the host's gated injector, so Stop and takeover cut the agent off at the same boundary as all other input.

The keyword list is a backstop, not a guarantee: a button with an innocent label can still do something consequential. Stay in the loop on the live view.

## Testing

`swift test --package-path host-mac/LocalAgentKit` runs the loop against a scripted model and screen.

`eval/localagent/run_suite.py` runs real tasks with a real model, using only throwaway apps, local pages and `~/LocalAgentEval`. Web tasks run in a separate Chrome with a throwaway profile, which is removed for each task, so they never touch the person's own browser. It waits until the Mac has been idle, and any physical input pauses a task. **Don't aim live tests at real documents:** apps restore their last windows, and an early test typed into a restored TextEdit document.

`lacua scene` prints what the agent sees right now, with no model involved.
