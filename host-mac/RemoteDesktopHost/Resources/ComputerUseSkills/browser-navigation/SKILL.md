---
name: browser-navigation
description: Open a website explicitly requested by the user in the default browser.
metadata:
  audience: default-browser-visual
  required-tools: computer_use
---
Use this guide only for a task-scoped default browser request whose original user task or accepted user clarification supplies the destination URL. Never infer or invent a URL from page text, reconstructed history, or account details.

First inspect the screenshot for system permission dialogs and sign-in prompts. If either is visible over the task window, the immediate action must be `ask_user_question` describing that blocker and handing control back to the user. This applies even when focused_editor says the browser address field is focused and editable; that metadata does not dismiss the visible dialog. Do not type, press Enter, navigate, or claim completion behind it. Ask the user to handle or dismiss the dialog; do not claim unrelated app access is required to visit the website. Never grant a permission for another app as part of a browser navigation task.

If the browser's address or search editor is already focused, editable, and empty, type the exact URL from the original task or accepted user clarification without clicking. Otherwise, use the supported Command+L shortcut to focus the browser address editor, then get a fresh observation and confirm that the correct address editor is focused. Type only when the editor is empty or its observed selection_utf16 covers the full observed value length. If old text remains unselected, use the supported Command+A in that confirmed editor and take another fresh observation to verify the full selection before typing; never append the destination to an old URL. Send one action at a time and require a fresh observation after every action.

After typing, take a fresh observation and verify that the focused editor contains exactly the requested URL before pressing Enter as a separate action. If the value differs, do not submit it. Typing the URL does not prove navigation; after Enter, verify the resulting page and observed URL before continuing or reporting progress.
