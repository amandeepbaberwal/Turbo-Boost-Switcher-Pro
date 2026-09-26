// TurboMenu.swift — menu-bar client for the TB privileged helper.
// Shows state + current max CPU freq + temp, all fetched over XPC.
// Never touches auth: powermetrics/kext work happens root-side in the helper.
import Cocoa

@objc(TurboBoostHelperProtocol)
protocol HelperProtocol {
    func setTurboBoostDisabled(_ disabled: Bool, withReply reply: @escaping (Bool, String?) -> Void)
    func getTurboBoostDisabledWithReply(_ reply: @escaping (Bool) -> Void)
    func getStatsWithReply(_ reply: @escaping ([AnyHashable: Any]) -> Void)
    func getVersionWithReply(_ reply: @escaping (String) -> Void)
    func setPowerLimitsPL1(_ pl1: Int, PL2 pl2: Int, withReply reply: @escaping (Bool, String?) -> Void)
    func getPowerLimitsWithReply(_ reply: @escaping (Int, Int) -> Void)
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
    var installItem: NSMenuItem!
    var uninstallItem: NSMenuItem!
    var settingsWC: SettingsWC?
    var helperInstalled = false
    var didPromptInstall = false
    var freqItem: NSMenuItem!
    var tempItem: NSMenuItem!
    var powerItem: NSMenuItem!
    var disabled = false
    var freqMax = -1
    var freqAvg = -1
    var tempC = -1.0
    var pkgW = -1.0
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
        powerItem = NSMenuItem(title: "Power: …", action: nil, keyEquivalent: "")
        powerItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(freqItem)
        menu.addItem(tempItem)
        menu.addItem(powerItem)
        menu.addItem(NSMenuItem.separator())
        toggleItem = NSMenuItem(title: "Toggle Turbo Boost", action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(NSMenuItem.separator())
        showStatsItem = NSMenuItem(title: "Show stats in menu bar", action: #selector(toggleShowStats), keyEquivalent: "")
        showStatsItem.target = self
        showStatsItem.state = showStatsInBar ? .on : .off
        menu.addItem(showStatsItem)
        menu.addItem(NSMenuItem.separator())
        installItem = NSMenuItem(title: "Install System Helper…", action: #selector(runAdminInstall), keyEquivalent: "")
        installItem.target = self
        menu.addItem(installItem)
        uninstallItem = NSMenuItem(title: "Uninstall Helper…", action: #selector(uninstallHelper), keyEquivalent: "")
        uninstallItem.target = self
        menu.addItem(uninstallItem)
        let settingsItem = NSMenuItem(title: "Power & Setup…", action: #selector(showSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Menu", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        checkHelper()
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
        powerItem.title = "Power: …"
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
                if let w = s["pkgW"] as? Double { self.pkgW = w }
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
            if pkgW >= 0 { title += String(format: " %.0fW", pkgW) }
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
        powerItem.title = pkgW >= 0 ? String(format: "Package power: %.1f W", pkgW) : "Package power: n/a"
        toggleItem.title = disabled ? "Enable Turbo Boost" : "Disable Turbo Boost"
    }

    // MARK: - Self-install (drag-and-drop distribution)

    // First launch on a fresh Mac: helper isn't there, so offer the one-time
    // install via Apple's own admin dialog (osascript). No bundled passwords,
    // no custom auth code — the system prompt does the work exactly once.
    func checkHelper() {
        let c = connect()
        var settled = false
        let watchdog = DispatchWorkItem {
            if !settled {
                settled = true
                c.invalidate()
                DispatchQueue.main.async { self.helperMissing() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: watchdog)
        proxy(c).getVersionWithReply { _ in
            if !settled {
                settled = true
                watchdog.cancel()
                c.invalidate()
                DispatchQueue.main.async {
                    self.helperInstalled = true
                    self.installItem.title = "Reinstall System Helper…"
                    self.toggleItem.isEnabled = true
                    self.uninstallItem.isEnabled = true
                    self.queryStateOnly()
                    self.updateTimer()
                }
            }
        }
    }

    func helperMissing() {
        helperInstalled = false
        known = false
        pollTimer?.invalidate()
        pollTimer = nil
        statusItem.button?.title = "TB ?"
        stateItem.title = "Helper not installed"
        freqItem.title = "Freq: —"
        tempItem.title = "Temp: —"
        powerItem.title = "Power: —"
        toggleItem.isEnabled = false
        installItem.title = "Install System Helper…"
        uninstallItem.isEnabled = false
        if !didPromptInstall {
            didPromptInstall = true
            let a = NSAlert()
            a.messageText = "Install system helper?"
            a.informativeText = "TurboMenu needs a one-time helper install (Apple system password dialog). After that it never asks again."
            a.addButton(withTitle: "Install")
            a.addButton(withTitle: "Later")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertFirstButtonReturn { runAdminInstall() }
        }
    }

    func helperResourcePaths() -> (String, String)? {
        guard let res = Bundle.main.resourcePath else { return nil }
        let h = (res as NSString).appendingPathComponent("tbhelper")
        let p = (res as NSString).appendingPathComponent("LaunchDaemon.plist")
        let fm = FileManager.default
        return (fm.isExecutableFile(atPath: h) && fm.fileExists(atPath: p)) ? (h, p) : nil
    }

    func showInfo(_ text: String) {
        let a = NSAlert()
        a.messageText = "TurboMenu"
        a.informativeText = text
        a.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    func vsResourcePaths() -> (String, String)? {
        guard let res = Bundle.main.resourcePath else { return nil }
        let cli = (res as NSString).appendingPathComponent("voltageshift")
        let kx = (res as NSString).appendingPathComponent("VoltageShift.kext")
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.isExecutableFile(atPath: cli),
              fm.fileExists(atPath: kx, isDirectory: &isDir), isDir.boolValue else { return nil }
        return (cli, kx)
    }

    @objc func runAdminInstall() {
        guard let r = helperResourcePaths() else {
            showInfo("Install files missing inside the app. Re-download the release.")
            return
        }
        let vs = vsResourcePaths() // optional: power-limit engine; helper-only install proceeds without it
        var sh = """
        set -e
        SUP='/Library/Application Support/TurboBoostSwitcher'
        BIN='/Library/PrivilegedHelperTools/com.local.TurboBoostSwitcher.helper'
        PL='/Library/LaunchDaemons/com.local.TurboBoostSwitcher.helper.plist'
        mkdir -p "$SUP"
        [ -f "$SUP/wanted-state.plist" ] || printf '%s\\n' '<?xml version="1.0" encoding="UTF-8"?>' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' '<plist version="1.0"><dict><key>disabled</key><true/></dict></plist>' > "$SUP/wanted-state.plist"
        cp -f '\(r.0)' "$BIN"
        chown root:wheel "$BIN" "$SUP" "$SUP/wanted-state.plist"
        chmod 544 "$BIN"; chmod 755 "$SUP"; chmod 644 "$SUP/wanted-state.plist"
        cp -f '\(r.1)' "$PL"
        chown root:wheel "$PL"; chmod 644 "$PL"
        launchctl bootout system "$PL" 2>/dev/null || true
        launchctl bootstrap system "$PL"
        """
        if let v = vs {
            sh += """
            \ncp -f '\(v.0)' "$SUP/voltageshift"
            chown root:wheel "$SUP/voltageshift"; chmod 755 "$SUP/voltageshift"
            rm -rf '/Library/Extensions/VoltageShift.kext'
            cp -R '\(v.1)' '/Library/Extensions/VoltageShift.kext'
            chown -R root:wheel '/Library/Extensions/VoltageShift.kext'
            chmod -R 755 '/Library/Extensions/VoltageShift.kext'
            /usr/bin/kextutil '/Library/Extensions/VoltageShift.kext' 2>/dev/null || true
            """
        }
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("tbpro-install.sh")
        do { try sh.write(toFile: tmp, atomically: true, encoding: .utf8) }
        catch { showInfo("Cannot write installer script."); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "do shell script \"/bin/bash '\(tmp)'\" with administrator privileges"]
            do { try p.run() } catch {
                DispatchQueue.main.async { self.showInfo("Could not start the installer.") }
                return
            }
            p.waitUntilExit()
            DispatchQueue.main.async {
                if p.terminationStatus == 0 {
                    self.didPromptInstall = false
                    self.checkHelper()
                    self.showInfo("Helper installed. Toggle away — no more passwords.")
                } else {
                    self.showInfo("Install cancelled or failed.")
                }
            }
        }
    }

    @objc func uninstallHelper() {
        let a = NSAlert()
        a.messageText = "Uninstall helper?"
        a.informativeText = "Removes the system daemon. Turbo Boost returns to stock behavior; the menu keeps running."
        a.addButton(withTitle: "Uninstall")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let sh = """
        set -e
        PL='/Library/LaunchDaemons/com.local.TurboBoostSwitcher.helper.plist'
        launchctl bootout system "$PL" 2>/dev/null || true
        rm -f "$PL" '/Library/PrivilegedHelperTools/com.local.TurboBoostSwitcher.helper'
        rm -rf '/Library/Application Support/TurboBoostSwitcher'
        """
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("tbpro-uninstall.sh")
        do { try sh.write(toFile: tmp, atomically: true, encoding: .utf8) }
        catch { showInfo("Cannot write uninstall script."); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "do shell script \"/bin/bash '\(tmp)'\" with administrator privileges"]
            do { try p.run() } catch {
                DispatchQueue.main.async { self.showInfo("Could not start the uninstaller.") }
                return
            }
            p.waitUntilExit()
            DispatchQueue.main.async {
                self.didPromptInstall = true // don't instantly re-prompt
                self.helperMissing()
            }
        }
    }

    @objc func showSettings() {
        if settingsWC == nil { settingsWC = SettingsWC(app: self) }
        settingsWC?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWC?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func toggle() {
        guard helperInstalled else { helperMissing(); return }
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
