# App Review notes: Remote Desktop 1.2.1

Paste the section below into App Store Connect → the version → App Review Information → Notes
(the limit is 4,000 characters). No sign-in is needed, so leave "Sign-in required" unticked.

---

Remote Desktop controls the user's own Mac from iPhone or iPad. It needs the free companion app
"Remote Desktop Host" running on a Mac signed in to the same Apple Account as the iPhone or iPad.
There is no account, server or sign-in of our own: pairing is automatic through the user's private
iCloud (CloudKit) database.

How to test
1. On a Mac (macOS 14 or later, Apple silicon), download and open Remote Desktop Host 0.4.0:
   https://github.com/minal7/remotedesktop/releases/tag/v0.4.0
   It is signed with our Developer ID and notarized by Apple. Allow Local Network, Screen
   Recording and Accessibility when macOS asks, so the Mac can be found, seen and controlled.
2. Sign the Mac and the iPhone or iPad in to the same Apple Account, with iCloud on, and keep
   both on the same Wi-Fi network.
3. Open Remote Desktop on the iPhone or iPad. The Mac appears in the list within a minute. Tap it
   to view and control the Mac's screen.

Computer Use (Beta), optional
- Under the Mac in the app, tap "Set up Computer use (Beta)". The Mac downloads two open models (7.9 GB,
  from Hugging Face) and runs them only on the Mac. It needs an Apple silicon Mac with 24 GB of
  memory or more; on smaller Macs setup explains that and stops.
- Then tap "Computer use (Beta)" and type a request such as "Open Safari and find the weather in Cupertino". Progress and the
  answer appear on the phone.
- Before sending, submitting, paying, purchasing, deleting or sharing, the phone shows an approval
  card. Deny ends the task. Stop ends a task at any time, and the live view lets the person take over.
- It never tries to solve CAPTCHAs or similar human checks; it hands control back to the person.
- No prompt, screenshot or result is sent to us or to any AI service. Prompts and results travel
  directly between the phone and the Mac over the local network (TLS).

Privacy policy: https://minal7.github.io/remotedesktop/privacy.html
Support: https://minal7.github.io/remotedesktop/support.html
