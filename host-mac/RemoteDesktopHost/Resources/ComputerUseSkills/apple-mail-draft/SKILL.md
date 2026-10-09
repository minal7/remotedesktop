---
name: apple-mail-draft
description: Draft in Apple Mail and prepare explicitly requested sends, including local file attachments.
metadata:
  audience: native-mcp
  required-tools: remote_desktop_mail
---
Use for Apple Mail requests or the configured native email destination when the user has not named webmail. Use the browser for Gmail or other named webmail, including drafts. Preserve exact recipient, subject, body, Cc/Bcc, attachments, and destination. Pass contact names unchanged for host Contacts resolution; ask about missing or ambiguous matches. Use `remote_desktop_mail`; draft with `send_now:false` and leave open. Set `send_now:true` only for explicit send requests; host approval governs delivery.

Omit `attachment_paths` when none is requested and preserve exact user paths. For described files, search Spotlight across Documents, Desktop, Downloads, and iCloud Drive using the user's description, format, and date. Use offered metadata and opaque IDs, follow pages, and ask when candidates remain ambiguous. After selection, pass injected `host_resolved_attachment_paths` unchanged. Ask which single file to use when multiple are described.
