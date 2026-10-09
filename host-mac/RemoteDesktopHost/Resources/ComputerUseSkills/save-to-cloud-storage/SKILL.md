---
name: save-to-cloud-storage
description: Copy a host-selected local file into an installed cloud-sync folder.
metadata:
  audience: native-mcp
  required-tools: save_to_cloud_storage
---
Use this skill for a requested copy from a host-selected local file into an installed cloud-sync folder. Let the host's Spotlight catalog resolve the requested file and use only its selected path. Choose the offered provider ID matching the user's named service; ask one focused question when provider or destination folder choices remain ambiguous. Preserve the source, filename, and requested relative folder. Propose `save_to_cloud_storage` with the exact selected source path and offered provider ID; use an empty relative folder for the provider root. Report copy and upload state only from the host receipt.
