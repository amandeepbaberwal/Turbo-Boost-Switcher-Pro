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
    var refreshSlider: NSSlider!
    var refreshVal: NSTextField!
    var curPL1 = 100
    var curPL2 = 125

    convenience init(app: AppDelegate) {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 560),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "TurboMenu Settings"
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

    func build() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])

        stack.addView(label("System status:", bold: true), in: .leading)
        sipLbl = label("SIP kext allowance: …")
        kextLbl = label("VoltageShift kext: …")
        helperLbl = label("Helper daemon: …")
        stack.addView(sipLbl, in: .leading)
        stack.addView(kextLbl, in: .leading)
        stack.addView(helperLbl, in: .leading)

        let how = NSTextView(frame: NSRect(x: 0, y: 0, width: 430, height: 150))
        how.string = """
        If rows above are red — one-time setup (Intel Macs only):

        1. Restart, hold Cmd+R → Utilities → Terminal, type:
           csrutil enable --without kext
           then Apple menu → Restart.
        2. Launch TurboMenu → Install System Helper… (Apple
           password dialog, once). The installer also stages the
           VoltageShift kext.
        3. If macOS reports blocked software: System Settings →
           Privacy & Security → Allow → Restart once more.
        4. Back here → Recheck. Undo anytime: Recovery →
           csrutil enable → Restart.
        """
        how.isEditable = false
        how.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        how.backgroundColor = NSColor.textBackgroundColor
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 438, height: 150))
        scroll.documentView = how
        scroll.hasVerticalScroller = true
        stack.addView(scroll, in: .leading)

        stack.addView(label("Power limits (watts):", bold: true), in: .leading)
        pl1Slider = sliderRow(stack: stack, name: "PL1 sustained", min: 5, max: 100, valLbl: &pl1Val)
        pl2Slider = sliderRow(stack: stack, name: "PL2 burst", min: 10, max: 150, valLbl: &pl2Val)
        appliedLbl = label("Applied: …")
        stack.addView(appliedLbl, in: .leading)

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        applyBtn = NSButton(title: "Apply", target: self, action: #selector(applyPL))
        row.addView(applyBtn, in: .leading)
        let recheck = NSButton(title: "Recheck", target: self, action: #selector(refreshAll))
        row.addView(recheck, in: .leading)
        stack.addView(row, in: .leading)
        stack.addView(label("Lower = cooler + quieter, slower sustained. Bursts stay snappy.", bold: false), in: .leading)
        stack.addView(label("Menu bar live stats refresh:", bold: true), in: .leading)
        refreshSlider = sliderRow(stack: stack, name: "Interval", min: 1, max: 60, valLbl: &refreshVal)
        refreshSlider.target = self
        refreshSlider.action = #selector(refreshMoved)
        refreshSlider.isContinuous = false
        stack.addView(label("1s = constant sampling (costs CPU); 5s default. Off unless the bar-stats checkbox is ticked.", bold: false), in: .leading)
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
        }
        // 1. SIP kext exemption (unprivileged read)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/csrutil")
        p.arguments = ["status"]
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch { setDot(sipLbl, ok: false, text: "SIP check failed"); return }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let exempt = !out.contains("System Integrity Protection status: enabled.")
        setDot(sipLbl, ok: exempt, text: exempt ? "kext loading allowed" : "full SIP — kext will not load (see steps)")

        // 2+3. helper + kext + current PL via one stats call
        guard let app = app else { return }
        let c = app.connect()
        app.proxy(c).getStatsWithReply { s in
            c.invalidate()
            DispatchQueue.main.async {
                let vs = (s["vsKext"] as? Bool) ?? false
                self.setDot(self.kextLbl, ok: vs, text: vs ? "VoltageShift kext loaded" : "kext not loaded (install + reboot)")
                self.setDot(self.helperLbl, ok: true, text: "helper daemon reachable")
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
        guard let app = app else { return }
        let a = Int(pl1Slider.doubleValue), b = Int(pl2Slider.doubleValue)
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
