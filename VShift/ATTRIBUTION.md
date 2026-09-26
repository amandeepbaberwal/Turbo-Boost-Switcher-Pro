# Third-party code in VShift/

All files under `VShift/src/` and `VShift/prebuilt/` are from:

**VoltageShift** — https://github.com/sicreative/VoltageShift
"Undervoltage Tools for MacOS", GPL-3.0, by SC Lee (sicreative).
MSR kext driver modified from AnVMSR by Andy Vandijck (AnV Software).

- `src/main.mm` — the `voltageshift` CLI (60KB).
- `src/VoltageShfitAnVMSR.cpp`, `src/VoltageShiftAnVMSR.h` — the kext.
- `src/VoltageShift-Info.plist`, `src/VoltageShift-Prefix.pch` — kext build files.
- `prebuilt/voltageshift`, `prebuilt/VoltageShift.kext` — official 1.25
  binaries, shipped for machines that can't build a kext with modern Xcode.

Pinned to upstream master as of Sep 2026 (v1.25 era). No modifications.
Our own code merely *execs* the prebuilt CLI as root; it does not link it.

Because this component is GPL-3.0 and our app code carries the upstream
"GPL-2.0 or any later version" clause (rugarciap/Turbo-Boost-Switcher),
the combined work in this repository is distributed under **GPL-3.0**
(see LICENSE).
