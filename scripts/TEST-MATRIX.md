# TEST MATRIX — automated + manual scenarios

Automated: `./scripts/test-scenarios.sh` (no sudo; restores state).
Last run on MBP15,1: **7 pass / 0 fail**.

| # | Scenario | How | Expect |
|---|----------|-----|--------|
| A1 | Helper alive | probe `version` | version string |
| A2 | Stats complete | probe `stats` | all 10 keys, no MISSING |
| A3 | PL round-trip | set 45/60 → get → restore | live matches, restore sticks |
| A4 | Turbo round-trip | flip → kextstat → restore | kext line appears/vanishes correctly |

Manual (needs hands/reboots — user runs):

| # | Scenario | How | Expect |
|---|----------|-----|--------|
| M1 | Helper uninstalled | Menu → Uninstall Helper… | Bar `TB ?`, state row names helper as required-for-all, toggle disabled, sliders gated with reason, install prompt offers reinstall |
| M2 | Reinstall from menu | Install System Helper… → Apple dialog | All green, no Terminal |
| M3 | Sleep/wake, turbo OFF | Unload kext manually, sleep, wake | Helper reloads, no prompt (`/var/log/tbhelper.log` shows reapply) |
| M4 | Sleep/wake, custom PL | Set 25/35, sleep, wake | PL re-asserted (Settings shows chip values) |
| M5 | Reboot | Restart | Turbo + PL restored at boot (~2s after login) |
| M6 | VS kext missing | `sudo kextunload -b com.sicreative.VoltageShift`, open Settings | Power row: "kext not loaded — open Power & Setup"; Apply blocked with reason; next boot/wake self-heals via ensureVSKext |
| M7 | Fresh machine | New .pkg install | Setup window: 3 dots red→green after Recovery+approval+reboot; sliders work only after green |
| M8 | PL floor hunt | Drag PL1 to 5, Apply | Window reports "Chip reports:" actual floor; machine stays usable |

Rule for new bugs: reproduce → add row here → automate if hands-free, else keep manual.
