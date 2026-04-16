# signaling/ — DEPRECATED

This folder hosts the original Cloudflare Worker signaling service. It has
been **replaced** by CloudKit-backed signaling (see
`protocol/Swift/CloudKitSignalingClient.swift`).

Kept in-tree for now as a reference for the wire-level envelope shape and
for early LAN-development history. No code in the iOS app or Mac host
talks to this worker anymore.

## Why it was replaced

- **Cost scaling.** The Worker is cheap but not free — at any serious
  user count we would start paying Cloudflare per-request. CloudKit's
  per-user quotas live in each user's own iCloud account, so the cost
  to us is $0 forever regardless of scale.
- **Operational surface.** Removing the worker removes a deploy target,
  a secret rotation story, and a piece of infrastructure to monitor.
- **Same-iCloud pairing model.** v1 targets users controlling *their own*
  Mac from *their own* iPad/iPhone. CloudKit's private-database model
  matches that exactly and gates pairing on the same iCloud account.

## When to resurrect

Only if we ever need cross-iCloud pairing (sharing with another user's
device) and CloudKit's `CKShare` model turns out to be too restrictive.
At that point this worker would come back as the public-signaling path,
but CloudKit would stay the default.

## To remove this folder entirely

```sh
git rm -r signaling/
```

When comfortable that no rollback is needed.
