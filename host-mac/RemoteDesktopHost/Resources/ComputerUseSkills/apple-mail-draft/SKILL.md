---
name: apple-mail-draft
description: Default email drafting and approved sending in Apple Mail, including local file attachments.
metadata:
  audience: native-mcp
  required-tools: remote_desktop_mail
---
Preserve the prompt's exact recipient, subject, body, copies, attachments, and destination. Pass contact names as given; the host resolves Contacts and asks when a match is missing or ambiguous. Use `remote_desktop_mail` for native Apple Mail. Create drafts with `send_now:false`, leave them open, and require no approval. Set `send_now:true` only for explicit send requests; host approval governs delivery.

Omit `attachment_paths` when no attachment is requested. Preserve exact user paths. For a described local file, search Spotlight across Documents, Desktop, Downloads, and iCloud Drive using the user's natural description, requested kind, and date. Use offered metadata and opaque candidate IDs, follow pages until one candidate is supported, and ask a concise question when choices remain materially ambiguous. After host selection, pass the injected `host_resolved_attachment_paths` unchanged. For multiple described files, ask which single file to use. For website or webmail, choose the browser workflow.
