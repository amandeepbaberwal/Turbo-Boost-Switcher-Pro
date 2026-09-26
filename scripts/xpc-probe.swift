// xpc-probe.swift — headless scenario-test client for the helper daemon.
// No auth, no sudo: talks XPC exactly like the menu does.
// Usage: xpc-probe <version|stats|getpl|setpl A B|getstate|setstate on|off>
// Exit: 0 reply-ok, 1 xpc-failure/timeout, 2 op-reported-failure.
import Foundation

@objc(TurboBoostHelperProtocol)
protocol HelperProtocol {
    func setTurboBoostDisabled(_ d: Bool, withReply reply: @escaping (Bool, String?) -> Void)
    func getTurboBoostDisabledWithReply(_ reply: @escaping (Bool) -> Void)
    func getStatsWithReply(_ reply: @escaping ([AnyHashable: Any]) -> Void)
    func getVersionWithReply(_ reply: @escaping (String) -> Void)
    func setPowerLimitsPL1(_ a: Int, PL2 b: Int, withReply reply: @escaping (Bool, String?) -> Void)
    func getPowerLimitsWithReply(_ reply: @escaping (Int, Int) -> Void)
}

let sem = DispatchSemaphore(value: 0)
var exitCode: Int32 = 1
let args = CommandLine.arguments.dropFirst()

func fail(_ m: String) -> Never { fputs("FAIL \(m)\n", stderr); Darwin.exit(1) }

let c = NSXPCConnection(machServiceName: "com.local.TurboBoostSwitcher.helper", options: .privileged)
c.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
c.resume()
let p = c.remoteObjectProxyWithErrorHandler { e in
    fputs("XPC-ERROR \(e)\n", stderr)
    sem.signal()
} as! HelperProtocol

func done(_ code: Int32) { exitCode = code; c.invalidate(); sem.signal() }
func show(_ s: Any) { print(s) }

guard let cmd = args.first else { fail("no command") }
switch cmd {
case "version":
    p.getVersionWithReply { v in show("version=\(v)"); done(0) }
case "stats":
    p.getStatsWithReply { s in
        for k in ["disabled","freqMaxMHz","freqAvgMHz","tempC","pkgW","pl1","pl2","vsKext","vsCLI","sip"] {
            show("\(k)=\(s[k] ?? "MISSING")")
        }
        let missing = ["disabled","freqMaxMHz","tempC","pkgW","pl1","pl2","vsKext","vsCLI","sip"].filter { s[$0] == nil }
        if missing.isEmpty { done(0) } else { fputs("MISSING-KEYS \(missing)\n", stderr); done(2) }
    }
case "getpl":
    p.getPowerLimitsWithReply { a, b in show("pl1=\(a) pl2=\(b)"); done(0) }
case "setpl":
    let rest = Array(args.dropFirst()).compactMap { Int($0) }
    guard rest.count == 2 else { fail("setpl needs A B") }
    p.setPowerLimitsPL1(rest[0], PL2: rest[1]) { ok, m in show("ok=\(ok) msg=\(m ?? "-")"); done(ok ? 0 : 2) }
case "getstate":
    p.getTurboBoostDisabledWithReply { d in show("disabled=\(d)"); done(0) }
case "setstate":
    guard let v = args.dropFirst().first, v == "on" || v == "off" else { fail("setstate on|off") }
    p.setTurboBoostDisabled(v == "off") { ok, m in show("ok=\(ok) msg=\(m ?? "-")"); done(ok ? 0 : 2) }
default:
    fail("unknown command")
}

if sem.wait(timeout: .now() + 20) == .timedOut { fail("timeout") }
Darwin.exit(exitCode)
