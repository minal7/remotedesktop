---
name: file-identification
description: Identify a requested local file from the host's current file catalog for an open browser chooser.
metadata:
  audience: browser-file-identification
  required-tools: listFiles
---
Use the user's original request and accepted answers as the file query. For a browser chooser, search the host Spotlight catalog across Documents, Desktop, Downloads, and iCloud Drive. Start from the requested file kind and date; use a literal name fragment when the user supplied one. Read offered metadata and opaque IDs, compare full timestamps, and follow each offered cursor through relevant pages. Select a candidate when the evidence identifies one file. Ask one concise question when equally supported candidates remain or user-only details are missing. Use the exact host-injected path after selection. Verify upload separately from the destination page.
