// TurboMenu.swift — menu-bar client for the TB privileged helper.
// Shows state + current max CPU freq + temp, all fetched over XPC.
// Never touches auth: powermetrics/kext work happens root-side in the helper.
import Cocoa

@objc(TurboBoostHelperProtocol)
protocol HelperProtocol {
    func setTurboBoostDisabled(_ disabled: Bool, withReply reply: @escaping (Bool, String?) -> Void)
    func getTurboBoostDisabledWithReply(_ reply: @escaping (Bool) -> Void)
    func getStatsWithReply(_ reply: @escaping ([AnyHashable: Any]) -> Void)
}

let kMachService = "com.local.TurboBoostSwitcher.helper"

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var menu: NSMenu!
    var toggleItem: NSMenuItem!
    var showStatsItem: NSMenuItem!
    var stateItem: NSMenuItem!
    var pollTimer: Timer?
    // Default: bar shows only TB ON/OFF; stats live in the dropdown and
    // refresh only on open. Checkbox below opts into bar stats + polling.
    var showStatsInBar = UserDefaults.standard.object(forKey: "showStatsInBar") as? Bool ?? false
    var freqItem: NSMenuItem!
    var tempItem: NSMenuItem!
    var disabled = false
    var freqMax = -1
    var freqAvg = -1
    var tempC = -1.0
    var known = false
    let nominalMHz = AppDelegate.nominalClockMHz()

    static func nominalClockMHz() -> Int {
        var v: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        if sysctlbyname("hw.cpufrequency", &v, &size, nil, 0) == 0, v > 0 {
            return Int(v / 1_000_000)
        }
        return 2600 // i7-8850H fallback
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "TB ?"
        statusItem.button?.toolTip = "Turbo Boost state (via helper daemon)"
        menu = NSMenu()
        menu.delegate = self
        stateItem = NSMenuItem(title: "State: …", action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        freqItem = NSMenuItem(title: "Freq: …", action: nil, keyEquivalent: "")
        freqItem.isEnabled = false
        tempItem = NSMenuItem(title: "Temp: …", action: nil, keyEquivalent: "")
        tempItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(freqItem)
        menu.addItem(tempItem)
        menu.addItem(NSMenuItem.separator())
        toggleItem = NSMenuItem(title: "Toggle Turbo Boost", action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(NSMenuItem.separator())
        showStatsItem = NSMenuItem(title: "Show freq/temp in menu bar", action: #selector(toggleShowStats), keyEquivalent: "")
        showStatsItem.target = self
        showStatsItem.state = showStatsInBar ? .on : .off
        menu.addItem(showStatsItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Menu", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        queryStateOnly()
        updateTimer()
    }

    @objc func toggleShowStats() {
        showStatsInBar.toggle()
        UserDefaults.standard.set(showStatsInBar, forKey: "showStatsInBar")
        showStatsItem.state = showStatsInBar ? .on : .off
        updateTimer()
        if showStatsInBar { refresh() } else { renderTitle() }
    }

    func updateTimer() {
        pollTimer?.invalidate()
        pollTimer = nil
        if showStatsInBar {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in self.refresh() }
        }
    }

    // Menu delegate: fetch fresh stats only when the user opens the menu.
    // No background polling — powermetrics never runs unless you're looking.
    func menuWillOpen(_ menu: NSMenu) {
        stateItem.title = "State: …"
        freqItem.title = "Freq: …"
        tempItem.title = "Temp: …"
        refresh()
    }

    // Cheap state-only check at launch so the title is right without
    // paying for a powermetrics sample.
    func queryStateOnly() {
        let c = connect()
        proxy(c).getTurboBoostDisabledWithReply { d in
            c.invalidate()
            DispatchQueue.main.async {
                self.disabled = d
                self.known = true
                self.renderTitle()
            }
        }
    }

    func connect() -> NSXPCConnection {
        let c = NSXPCConnection(machServiceName: kMachService, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        c.resume()
        return c
    }

    func proxy(_ c: NSXPCConnection) -> HelperProtocol {
        return c.remoteObjectProxyWithErrorHandler { err in
            NSLog("[TBMenu] xpc error: %@", err as NSError)
            DispatchQueue.main.async { self.statusItem.button?.title = "TB ?" }
            c.invalidate()
        } as! HelperProtocol
    }

    func refresh() {
        let c = connect()
        proxy(c).getStatsWithReply { s in
            c.invalidate()
            DispatchQueue.main.async {
                if let d = s["disabled"] as? Bool { self.disabled = d }
                if let m = s["freqMaxMHz"] as? Int { self.freqMax = m }
                if let a = s["freqAvgMHz"] as? Int { self.freqAvg = a }
                if let t = s["tempC"] as? Double { self.tempC = t }
                self.known = true
                self.render()
            }
        }
    }

    func ghz(_ mhz: Int) -> String { String(format: "%.2f GHz", Double(mhz) / 1000.0) }

    func renderTitle() {
        guard known else { statusItem.button?.title = "TB ?"; return }
        var title = disabled ? "TB OFF" : "TB ON"
        if showStatsInBar {
            if freqMax > 0 { title += String(format: " %.1fG", Double(freqMax) / 1000.0) }
            if tempC >= 0 { title += String(format: " %.0f°", tempC) }
        }
        statusItem.button?.title = title
    }

    func render() {
        renderTitle()
        guard known else { return }
        stateItem.title = disabled ? "State: Turbo OFF (kext loaded)" : "State: Turbo ON (kext unloaded)"
        if freqMax > 0 {
            freqItem.title = "Freq: max \(ghz(freqMax))" +
                (freqAvg > 0 ? "  avg \(ghz(freqAvg))" : "") +
                "  (base \(ghz(nominalMHz)))"
        } else {
            freqItem.title = "Freq: unreadable (see log)"
        }
        tempItem.title = tempC >= 0 ? String(format: "CPU temp: %.1f °C", tempC) : "CPU temp: n/a"
        toggleItem.title = disabled ? "Enable Turbo Boost" : "Disable Turbo Boost"
    }

    @objc func toggle() {
        // Chain off a fresh read: the menu-open refresh may still be in
        // flight (powermetrics ~1s), so never trust last-known state here.
        let c = connect()
        proxy(c).getStatsWithReply { s in
            c.invalidate()
            let fresh = (s["disabled"] as? Bool) ?? self.disabled
            let c2 = self.connect()
            self.proxy(c2).setTurboBoostDisabled(!fresh) { ok, msg in
                NSLog("[TBMenu] toggle -> %d %@", ok, msg ?? "-")
                c2.invalidate()
                self.queryStateOnly()
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
