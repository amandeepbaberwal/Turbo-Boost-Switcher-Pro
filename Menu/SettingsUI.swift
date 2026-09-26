// SettingsUI.swift — "Power & Setup" window: PL1/PL2 sliders + first-run
// Recovery/SIP guidance. All privileged work goes through the helper over
// XPC; the only unprivileged shell-out here is `csrutil status` (read-only).
import Cocoa

class SettingsWC: NSWindowController {
    weak var app: AppDelegate?
    var pl1Slider: NSSlider!
    var pl2Slider: NSSlider!
    var pl1Val: NSTextField!
    var pl2Val: NSTextField!
    var appliedLbl: NSTextField!
    var applyBtn: NSButton!
    var sipLbl: NSTextField!
    var kextLbl: NSTextField!
    var helperLbl: NSTextField!
    var bootLbl: NSTextField!
    var reinstallBtn: NSButton!
    var uninstallBtn: NSButton!
    var refreshSlider: NSSlider!
    var refreshVal: NSTextField!
    var curPL1 = 100
    var curPL2 = 125
    var vsOK = false

    convenience init(app: AppDelegate) {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 660),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Mac Turbo Disabler Settings"
        win.center()
        self.init(window: win)
        self.app = app
        build()
        refreshAll()
    }

    func label(_ text: String, bold: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = bold ? NSFont.boldSystemFont(ofSize: 13) : NSFont.systemFont(ofSize: 13)
        return l
    }

    func sectionBox(_ title: String) -> (NSBox, NSStackView) {
        let box = NSBox()
        box.title = title
        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 6
        inner.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: box.topAnchor, constant: 24),
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            inner.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            inner.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
        ])
        return (box, inner)
    }

    func hrow(_ views: NSView...) -> NSStackView {
        let r = NSStackView(views: views)
        r.orientation = .horizontal
        r.spacing = 8
        return r
    }

    func build() {
        guard let content = window?.contentView else { return }
        let outer = NSStackView()
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 10
        outer.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        outer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: content.topAnchor),
            outer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])

        // Box 1 — status + setup
        let (box1, s1) = sectionBox("System status")
        sipLbl = label("SIP kext allowance: …")
        kextLbl = label("VoltageShift kext: …")
        helperLbl = label("Helper daemon: …")
        bootLbl = label("Last boot restore: …")
        s1.addView(sipLbl, in: .leading)
        s1.addView(kextLbl, in: .leading)
        s1.addView(helperLbl, in: .leading)
        s1.addView(bootLbl, in: .leading)

        let how = NSTextView(frame: NSRect(x: 0, y: 0, width: 440, height: 118))
        how.string = """
        If rows above are red — one-time setup (Intel Macs only):

        1. Restart, hold Cmd+R → Utilities → Terminal, type:
           csrutil enable --without kext
           then Apple menu → Restart.
        2. Below → Reinstall Helper (Apple password dialog, once).
        3. If macOS reports blocked software: System Settings →
           Privacy & Security → Allow → Restart once more.
        4. Recheck. Undo anytime: Recovery → csrutil enable.
        """
        how.isEditable = false
        how.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        how.backgroundColor = NSColor.textBackgroundColor
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 448, height: 118))
        scroll.documentView = how
        scroll.hasVerticalScroller = true
        s1.addView(scroll, in: .leading)

        reinstallBtn = NSButton(title: "Reinstall Helper…", target: self, action: #selector(reinstallTapped))
        uninstallBtn = NSButton(title: "Remove Helper…", target: self, action: #selector(uninstallTapped))
        let removeAllBtn = NSButton(title: "Remove Everything…", target: self, action: #selector(uninstallEverything))
        removeAllBtn.bezelColor = NSColor.systemRed
        let recheck = NSButton(title: "Recheck", target: self, action: #selector(refreshAll))
        s1.addView(hrow(reinstallBtn, uninstallBtn, removeAllBtn, recheck), in: .leading)
        outer.addView(box1, in: .leading)

        // Box 2 — power limits
        let (box2, s2) = sectionBox("Power limits (watts)")
        pl1Slider = sliderRow(stack: s2, name: "PL1 sustained", min: 5, max: 100, valLbl: &pl1Val)
        pl2Slider = sliderRow(stack: s2, name: "PL2 burst", min: 10, max: 150, valLbl: &pl2Val)
        appliedLbl = label("Applied: …")
        s2.addView(appliedLbl, in: .leading)
        applyBtn = NSButton(title: "Apply", target: self, action: #selector(applyPL))
        let stock = NSButton(title: "Restore Stock Limits", target: self, action: #selector(restoreStock))
        s2.addView(hrow(applyBtn, stock), in: .leading)
        s2.addView(label("Lower = cooler + quieter, slower sustained. Bursts stay snappy.", bold: false), in: .leading)
        outer.addView(box2, in: .leading)

        // Box 3 — menu bar refresh
        let (box3, s3) = sectionBox("Menu bar live stats")
        refreshSlider = sliderRow(stack: s3, name: "Interval", min: 1, max: 60, valLbl: &refreshVal)
        refreshSlider.target = self
        refreshSlider.action = #selector(refreshMoved)
        refreshSlider.isContinuous = false
        s3.addView(label("1s = constant sampling (costs CPU); 5s default. Off unless the bar-stats checkbox is ticked.", bold: false), in: .leading)
        outer.addView(box3, in: .leading)
    }

    @objc func reinstallTapped() { app?.runAdminInstall() }
    @objc func uninstallTapped() { app?.uninstallHelper() }

    @objc func uninstallEverything() {
        let a = NSAlert()
        a.messageText = "Remove everything?"
        a.informativeText = "Removes the helper daemon, this menu app, the VoltageShift kext, all login items and settings. Turbo Boost returns to stock; power limits fully clear on next reboot. This cannot be undone — reinstall from the release .pkg to come back."
        a.addButton(withTitle: "Remove Everything")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        guard let app = app else { return }
        let sh = """
        set -e
        /sbin/kextunload -b com.rugarciap.DisableTurboBoost 2>/dev/null || true
        /sbin/kextunload -b com.sicreative.VoltageShift 2>/dev/null || true
        /bin/launchctl bootout system /Library/LaunchDaemons/com.local.TurboBoostSwitcher.helper.plist 2>/dev/null || true
        CU=$(stat -f%Su /dev/console 2>/dev/null || echo "")
        if [ -n "$CU" ] && [ "$CU" != "root" ]; then
          CUID=$(id -u "$CU" 2>/dev/null || echo "")
          if [ -n "$CUID" ]; then
            /bin/launchctl bootout "gui/$CUID/com.local.MacTurboDisabler" 2>/dev/null || true
            /bin/launchctl bootout "gui/$CUID/com.local.TurboBoostMenu" 2>/dev/null || true
          fi
          rm -f "/Users/$CU/Library/LaunchAgents/com.local.MacTurboDisabler.plist" "/Users/$CU/Library/LaunchAgents/com.local.TurboBoostMenu.plist"
        fi
        rm -f /Library/LaunchDaemons/com.local.TurboBoostSwitcher.helper.plist
        rm -f /Library/PrivilegedHelperTools/com.local.TurboBoostSwitcher.helper
        rm -rf "/Library/Application Support/TurboBoostSwitcher"
        rm -f /var/log/tbhelper.log
        rm -rf /Library/Extensions/VoltageShift.kext
        rm -f /Library/LaunchAgents/com.local.MacTurboDisabler.plist /Library/LaunchAgents/com.local.TurboBoostMenu.plist
        rm -rf /Applications/MacTurboDisabler.app /Applications/TurboMenu.app
        """
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("tbpro-nuke.sh")
        do { try sh.write(toFile: tmp, atomically: true, encoding: .utf8) }
        catch { app.showInfo("Cannot write removal script."); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "do shell script \"/bin/bash '\(tmp)'\" with administrator privileges"]
            do { try p.run() } catch {
                DispatchQueue.main.async { app.showInfo("Could not start removal.") }
                return
            }
            p.waitUntilExit()
            DispatchQueue.main.async {
                if p.terminationStatus == 0 {
                    app.showInfo("Everything removed. The menu will now quit; log out and back in to clear Login Items.")
                    NSApp.terminate(nil)
                } else {
                    app.showInfo("Removal cancelled or failed.")
                }
            }
        }
    }

    func sliderRow(stack: NSStackView, name: String, min: Double, max: Double, valLbl: inout NSTextField!) -> NSSlider {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        let n = label(name)
        n.preferredMaxLayoutWidth = 110
        n.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let s = NSSlider(value: min, minValue: min, maxValue: max, target: self, action: #selector(sliderMoved))
        s.widthAnchor.constraint(equalToConstant: 220).isActive = true
        valLbl = label("—")
        row.addView(n, in: .leading)
        row.addView(s, in: .leading)
        row.addView(valLbl, in: .leading)
        stack.addView(row, in: .leading)
        return s
    }

    @objc func sliderMoved() {
        pl1Val.stringValue = "\(Int(pl1Slider.doubleValue)) W"
        pl2Val.stringValue = "\(Int(pl2Slider.doubleValue)) W"
    }

    @objc func refreshMoved() {
        let v = refreshSlider.doubleValue
        refreshVal.stringValue = "\(Int(v))s"
        app?.setPollInterval(v)
    }

    func setDot(_ l: NSTextField, ok: Bool, text: String) {
        l.stringValue = (ok ? "● " : "○ ") + text
        l.textColor = ok ? NSColor.systemGreen : NSColor.systemRed
    }

    @objc func refreshAll() {
        if let app = app {
            refreshSlider.doubleValue = app.pollInterval
            refreshVal.stringValue = "\(Int(app.pollInterval))s"
            reinstallBtn.isEnabled = true
            uninstallBtn.isEnabled = app.helperInstalled
        }
        // 1. SIP kext exemption (unprivileged read)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/csrutil")
        p.arguments = ["status"]
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch { setDot(sipLbl, ok: false, text: "SIP check failed"); return }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let exempt = !out.contains("System Integrity Protection status: enabled.")
        setDot(sipLbl, ok: exempt, text: exempt ? "kext loading allowed" : "full SIP — kext will not load (see steps)")

        // 2+3. helper + kext + current PL via one stats call
        guard let app = app, app.helperInstalled else {
            setDot(kextLbl, ok: false, text: "helper missing — install it first")
            setDot(helperLbl, ok: false, text: "helper missing — install it first")
            vsOK = false
            return
        }
        let c = app.connect()
        app.proxy(c).getStatsWithReply { s in
            c.invalidate()
            DispatchQueue.main.async {
                let vs = (s["vsKext"] as? Bool) ?? false
                self.vsOK = vs
                self.setDot(self.kextLbl, ok: vs, text: vs ? "VoltageShift kext loaded" : "kext not loaded (install + reboot)")
                self.setDot(self.helperLbl, ok: true, text: "helper daemon reachable")
                if let br = s["bootRestore"] as? String {
                    self.bootLbl.stringValue = "Last boot restore: \(br)"
                }
                if let a = s["pl1"] as? Int, let b = s["pl2"] as? Int {
                    self.curPL1 = a; self.curPL2 = b
                    self.pl1Slider.doubleValue = Double(a)
                    self.pl2Slider.doubleValue = Double(b)
                    self.sliderMoved()
                    self.appliedLbl.stringValue = "Applied: PL1 \(a)W / PL2 \(b)W"
                }
            }
        }
    }

    @objc func applyPL() {
        apply(a: Int(pl1Slider.doubleValue), b: Int(pl2Slider.doubleValue))
    }

    @objc func restoreStock() {
        // Firmware stock on this chassis; other chips clamp + report truth.
        pl1Slider.doubleValue = 100
        pl2Slider.doubleValue = 125
        sliderMoved()
        apply(a: 100, b: 125)
    }

    func apply(a: Int, b: Int) {
        guard let app = app else { return }
        guard app.helperInstalled else {
            appliedLbl.stringValue = "Helper not installed — nothing can apply without it."
            return
        }
        guard vsOK else {
            appliedLbl.stringValue = "Kext not loaded — do the Setup steps above, then Recheck."
            return
        }
        applyBtn.isEnabled = false
        appliedLbl.stringValue = "Applying…"
        let c = app.connect()
        app.proxy(c).setPowerLimitsPL1(a, PL2: b) { ok, msg in
            c.invalidate()
            DispatchQueue.main.async {
                self.applyBtn.isEnabled = true
                if ok {
                    self.curPL1 = a; self.curPL2 = b
                    // Show what the chip actually accepted, not just what we asked.
                    let c2 = app.connect()
                    app.proxy(c2).getPowerLimitsWithReply { r1, r2 in
                        c2.invalidate()
                        DispatchQueue.main.async {
                            self.appliedLbl.stringValue = "Chip reports: PL1 \(r1)W / PL2 \(r2)W (persists across reboot)"
                        }
                    }
                    app.refresh()
                } else {
                    self.appliedLbl.stringValue = "Failed: \(msg ?? "kext missing? run Setup steps")"
                }
            }
        }
    }
}
