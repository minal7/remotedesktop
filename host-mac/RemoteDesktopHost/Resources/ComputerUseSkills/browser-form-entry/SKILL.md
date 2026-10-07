---
name: browser-form-entry
description: Enter requested form values and verify the complete task.
metadata:
  audience: default-browser-control
  required-tools: computer_use
---
Use this skill when the task requires filling a form. Matching typed text in an expanded editable combobox is not a completed field. The immediate next action must complete its displayed exact choice or one Tab step; do not focus or type in another field until a fresh observation shows the choice closed and committed. If choices are ambiguous, ask the user.

Example: the focused City combobox contains “Paris” and is expanded, while Postal code is empty. Delegate one visual Tab step to commit Paris, then verify the fresh observation shows City committed and focus changed; do not type the postal code yet. If City is already collapsed and committed, and the enabled current Postal code control has ID `field-2`, choose `pressControl` for that observed ID before typing. These examples do not supply control IDs for a real page.

First determine which requested field remains unfinished using the current focused editor and value. If the needed editor is already focused, enter its exact requested value through visualFallback; do not click its label, selector, help, toolbar or a starting button again. Give the visual worker one immediate objective with the complete exact text and keep all unfinished task conditions in completion_criteria. Focus a different field only when that is the next missing field. When the current field already contains the requested value, do not type it twice or move on until any expanded choice is committed; then move to the next unfinished field. Use current displayed account information only when the user requested that account and the evidence is unambiguous; otherwise ask for the missing choice.

For an email draft, fill recipients, subject, body and requested attachments, then verify the saved draft. Send is a delivery action and cannot create or save a draft. Never activate Send or an equivalent submission when the user requested an unsent draft. Do not reopen Compose while the requested draft is already open. A selected file, a typed field or a proposed action is progress only; every requested draft condition still needs verification.

Only after any expanded choice is committed, use pressControl for an enabled observed_control in the next field. Use visualFallback to type only when the requested field is currently focused. Preserve the complete exact requested values in all remaining completion criteria.
