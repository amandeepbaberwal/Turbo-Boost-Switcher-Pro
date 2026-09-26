# Mac Turbo Disabler (community clean-room build)

Password-once Turbo Boost toggle for Intel Macs: a root helper daemon owns
the kext across sleep/wake/reboot, and a menu-bar app shows state, live
frequency, and temperature. No password prompts after the one install.

## Install from a release (Intel Macs only)

1. Download `TurboBoostSwitcherPro-2.0.0-mac-intel.pkg` from Releases.
2. Double-click it (first time: right-click → Open, it's an ad-hoc signed
   community build). The Installer asks for your password once.
3. Look for `TB OFF` top-right. Sleep/wake to confirm: no prompt, ever.

Prefer Terminal? The `.zip` next to it contains the same payload with
`./install.sh` / `./uninstall.sh`.

## What this builds

Personal-use reimplementation of the *idea* behind Turbo Boost Switcher Pro's
"ask password once, never again" behavior. No Pro binary involved, no cracking:
a small root helper + XPC, built from scratch against the open-source free
app ([rugarciap/Turbo-Boost-Switcher](https://github.com/rugarciap/Turbo-Boost-Switcher), GPL-2.0).

## Why the free app prompts on every wake

The free app talks to the `DisableTurboBoost.kext` directly via the
deprecated `AuthorizationExecuteWithPrivileges` (`SystemCommands.m`). The
Turbo Boost MSR bit (0x1A0) is wiped every time the CPU loses power — i.e.
every sleep, not just reboot — so `AppDelegate -receiveWakeNote` must
unload + reload the kext after each wake, and each call re-prompts for admin.

Pro solves this with a privileged daemon installed once (password once),
after which the GUI sends it IPC messages instead of touching the kext
itself. That daemon is closed-source and NOT in the GitHub repo, so this
project rebuilds equivalent functionality from scratch.

## What this builds

- `Helper/` — root XPC helper (`com.local.TurboBoostSwitcher.helper`).
  Runs as root, owns all `kextload`/`kextunload` calls, persists the desired
  state, and re-applies it on boot AND on wake (via IOKit power
  notifications). Asks for no passwords itself — it is *already* root.
- `App/` — `HelperManager` drop-in for the forked app + Info.plist snippets
  + exact `AppDelegate` patch. Replaces every `AuthorizationRef` call site.
- `scripts/install-dev.sh` — one `sudo` install for testing (password once),
  then zero prompts. `scripts/uninstall.sh` fully reverts it.

## Design decisions

- Bundle IDs use `com.local.*`, NOT `rugarciap.com.*` — this is your own
  helper, signed with your own team. Rename to your own domain if you like.
- The kext is reused as-is (`com.rugarciap.DisableTurboBoost`, from the repo).
  It is already approved/loaded on this machine, so no new kext approval.
- New code is GPL-2.0 to match the upstream project.

## Build & install (summary)

1. `security find-identity -v -p codesigning` — you need an Apple
   Development identity (Xcode signs in with your Apple ID). Ours:
   `CL2J5F345D`.
2. Create a new Xcode Command Line Tool project for `Helper/`, set its team
   to yours, build it. Or compile directly (see README in `Helper/`).
3. Fork the app: copy `App/HelperManager.{h,m}` into the Xcode project,
   apply `App/AppDelegate-patch.md`, add `SMPrivilegedExecutables` from
   `App/InfoPlistAdditions.plist` (fill in signing requirements via
   `scripts/make-requirements.sh` once both are signed).
4. `sudo scripts/install-dev.sh` to test WITHOUT SMJobBless first, then
   sleep/wake-test. Move to `SMJobBless` once signing works.
5. Full steps + revert: see `scripts/` and `App/AppDelegate-patch.md`.

## Status

Scaffold + syntax/link-verified on Intel Sequoia. Sleep/wake + reboot
testing still needs to be done by you (requires real sleep cycles + sudo).
