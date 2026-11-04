import AppKit
import ComputerCubCore
import Foundation
import UniformTypeIdentifiers

// Mike's iPhone driven through WebDriverAgent, Apple's UI-testing runner, which Phonebooth
// (~/dev/me/mikerosoft-tools/phonebooth) builds, signs and installs on the phone. It runs on
// the phone itself and takes taps, swipes and typing over Xcode's tunnel to it, on Wi-Fi as
// well as the cable. Nothing goes through the Mac's mouse, keyboard or windows, which is why
// it's here: iPhone Mirroring kept tempting agents into borrowing Mike's pointer.
//
// The catch is the opposite of iPhone Mirroring's: the phone has to be unlocked (Mirroring
// only connects while it's locked), and what the agent does shows on its screen.
//
// Commands name the phone as `phone`: `computercub shot phone`, `click phone x y`, and so on.
// They run on the service's work queue, one at a time, so the plain blocking calls here are
// fine.
final class Phone {
    static let shared = Phone()

    struct Device {
        let name: String
        let udid: String
        let tunnel: String?
        let transport: String?
    }

    private var device: Device?
    private var base: URL?
    private var session: String?
    // The phone's screen in points and the active app's UIInterfaceOrientation (1 is
    // portrait), which touches are placed in. Read at each shot, since that's slow-ish.
    private var points: CGSize = .zero
    private var orientation = 1
    // Picture pixels per phone point in the last shot, and the picture's size.
    private var shot: (scale: CGFloat, size: CGSize)?
    private var helper: Process?
    private var lastUse = Date()
    private let helperLog = Paths.cache.appendingPathComponent("phone-helper.log")

    // MARK: Commands

    func run(_ cmd: String, _ a: Args) throws -> String {
        lastUse = Date()
        switch cmd {
        case "phone":
            switch a.pos.first ?? "status" {
            case "status": return try status()
            case "stop": return stop()
            default: throw CubError("`computercub phone status` or `computercub phone stop`.")
            }
        case "shot": return try takeShot(max: Int(a.flags["max"] ?? "") ?? 1600)
        case "click":
            let v = try numbers(a, 2, "`computercub click phone 120 340`")
            let p = try phonePoint(v[0], v[1])
            try ready()
            if a.has("long") {
                try touch([p], hold: 1.0)
            } else {
                try touch([p], hold: 0.05)
                if a.has("double") { usleep(80_000); try touch([p], hold: 0.05) }
            }
            return "\(a.has("long") ? "Long-pressed" : a.has("double") ? "Double-tapped" : "Tapped") \(fmt(v[0])),\(fmt(v[1])) on the phone. Take a shot to see what it did."
        case "swipe":
            let v = try numbers(a, 4, "`computercub swipe phone 300 900 300 300`")
            let from = try phonePoint(v[0], v[1]), to = try phonePoint(v[2], v[3])
            try ready()
            try touch(line(from, to, seconds: 0.25), hold: 0)
            return "Swiped \(fmt(v[0])),\(fmt(v[1])) to \(fmt(v[2])),\(fmt(v[3])) on the phone."
        case "scroll":
            guard let dir = a.pos.dropFirst().first, dir == "up" || dir == "down" else { throw CubError("`computercub scroll phone down` (or up).") }
            try ready()
            // A drag that holds still before lifting, so the list moves exactly that far
            // instead of flinging on. Down means the content moves up under the finger.
            let x = points.width / 2
            let (low, high) = (points.height * 0.70, points.height * 0.30)
            let from = CGPoint(x: x, y: dir == "down" ? low : high), to = CGPoint(x: x, y: dir == "down" ? high : low)
            try touch(line(from, to, seconds: 0.4), hold: 0.25)
            return "Scrolled \(dir) about 40% of the screen on the phone."
        case "type":
            guard let text = a.pos.dropFirst().first else { throw CubError("`computercub type phone \"text\" [--submit]`, after tapping the field.") }
            try ready()
            try keys(text + (a.has("submit") ? "\n" : ""))
            return "Typed it on the phone\(a.has("submit") ? " and pressed Return" : ""). Nothing can read it back, so take a shot to check."
        case "press":
            let combos = Array(a.pos.dropFirst())
            guard !combos.isEmpty else { throw CubError("`computercub press phone home` (or return, delete, tab).") }
            try ready()
            for c in combos {
                switch c.lowercased() {
                // cmd+1 is iPhone Mirroring's Home, so it works here too.
                case "home", "cmd+1": _ = try call("POST", "wda/homescreen", [:])
                case "return", "enter": try keys("\n")
                case "delete", "backspace": try keys("\u{8}")
                case "tab": try keys("\t")
                default: throw CubError("The phone takes home, return, delete and tab. For the rest, tap the button on screen.")
                }
            }
            return "Pressed \(combos.joined(separator: " ")) on the phone."
        default:
            throw CubError("The phone takes shot, click, swipe, scroll, type and press. It has no refs, so snap and read don't work: take a shot.")
        }
    }

    // MARK: Looking

    private func status() throws -> String {
        guard let d = findDevice() else { return "No paired iPhone that Xcode can see. Is it on the same Wi-Fi, or plugged in?" }
        var out = ["\(d.name) over \(d.transport == "wired" ? "the cable" : d.transport == "localNetwork" ? "Wi-Fi" : d.transport ?? "nothing")"]
        if let base, (try? call("GET", "status", nil, timeout: 3, at: base)) != nil {
            let locked = (try? call("GET", "wda/locked"))?["value"] as? Bool ?? false
            out.append(locked ? "helper running, phone locked" : "helper running, phone unlocked: ready")
        } else {
            out.append("helper not running; any phone command starts it (about 10 seconds, with the phone unlocked)")
        }
        return out.joined(separator: "\n")
    }

    private func takeShot(max: Int) throws -> String {
        try ready()
        try refreshScreen()
        let r = try call("GET", "screenshot", nil, timeout: 30)
        guard let b64 = r["value"] as? String, let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let full = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw CubError("The phone helper didn't send a screenshot back.")
        }
        // The picture comes at the phone's full resolution (1290×2796 on a 15 Pro Max),
        // which costs a lot of tokens to look at, so it's shrunk to fit --max.
        let side = CGFloat(Swift.max(full.width, full.height))
        let k = Swift.min(1, CGFloat(Swift.max(200, max)) / side)
        let w = Int((CGFloat(full.width) * k).rounded()), h = Int((CGFloat(full.height) * k).rounded())
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CubError("Couldn't shrink the phone's screenshot.")
        }
        ctx.interpolationQuality = .high
        ctx.draw(full, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let image = ctx.makeImage() else { throw CubError("Couldn't shrink the phone's screenshot.") }
        // Positions in later commands come from this picture's pixels.
        let pw = points.width > 0 ? points.width : CGFloat(full.width) / 3
        shot = (CGFloat(w) / pw, CGSize(width: w, height: h))

        Shot.sweep()
        try FileManager.default.createDirectory(at: Paths.shots, withIntermediateDirectories: true)
        let url = Paths.shots.appendingPathComponent("iphone-\(Shot.stamp()).png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CubError("Couldn't write \(url.path).")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CubError("Couldn't write \(url.path).") }
        return "\(url.path) (\(w)×\(h))"
    }

    // MARK: Getting the helper going

    // The helper running, its session open, and the phone unlocked, or a reason why not.
    private func ready() throws {
        if base == nil || (try? call("GET", "status", nil, timeout: 3)) == nil {
            try start()
        }
        if (try? call("GET", "wda/locked"))?["value"] as? Bool == true {
            throw CubError(lockedMessage)
        }
        if points == .zero { try refreshScreen() }
    }

    private var lockedMessage: String {
        "The phone is locked, so taps would do nothing. Unlocking needs \(userName)'s passcode or face: ask him, or, "
            + "if he's busy, use iPhone Mirroring instead (it only connects while the phone is locked)."
    }

    private func start() throws {
        guard var d = findDevice() else {
            throw CubError("Xcode can't see a paired iPhone. It needs to be on the same Wi-Fi as the Mac, or plugged in, with Developer Mode on.")
        }
        // Xcode only opens its tunnel to the phone when something asks for it.
        if d.tunnel == nil {
            _ = shell("/usr/bin/xcrun", ["devicectl", "device", "info", "details", "--device", d.udid], timeout: 40)
            d = findDevice() ?? d
        }
        guard let tunnel = d.tunnel, let url = URL(string: "http://[\(tunnel)]:8100/") else {
            throw CubError("Couldn't open Xcode's connection to \(d.name). Is it nearby and on the same Wi-Fi?")
        }
        device = d
        base = url
        session = nil
        points = .zero
        // Phonebooth may already have one going over the cable.
        if (try? call("GET", "status", nil, timeout: 3)) != nil { return try openSession() }

        guard let script = agentScript() else {
            throw CubError("Phonebooth isn't installed, and its helper is what drives the phone. Set it up from ~/dev/me/mikerosoft-tools/phonebooth (`bash setup_mac.sh`).")
        }
        helper?.terminate()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script, "run", d.udid]
        try? FileManager.default.createDirectory(at: Paths.cache, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: helperLog.path, contents: nil)
        let out = try FileHandle(forWritingTo: helperLog)
        p.standardOutput = out
        p.standardError = out
        try p.run()
        helper = p
        // About 10 seconds over Wi-Fi once it's built.
        for _ in 0..<90 {
            usleep(500_000)
            if (try? call("GET", "status", nil, timeout: 2)) != nil { return try openSession() }
            let log = (try? String(contentsOf: helperLog, encoding: .utf8)) ?? ""
            if log.contains("to Continue") || log.contains("is locked") {
                p.terminate()
                helper = nil
                throw CubError(lockedMessage)
            }
            if !p.isRunning {
                helper = nil
                // iOS asks for Face ID before a test runner may drive the phone, and a phone
                // lying on the desk can't see a face, so the ask times out as "cancelled".
                if log.contains("Failed to initialize for UI testing"), log.contains("LocalAuthentication") {
                    throw CubError("The phone asked for Face ID to let the helper control it, and nobody answered. "
                        + "Ask \(userName) to pick the phone up and look at it, then run the command again.")
                }
                let line = log.split(separator: "\n").last { $0.contains("Testing failed") || $0.contains("encountered an error") || $0.contains("ERROR") }
                    .map { $0.trimmingCharacters(in: .whitespaces) } ?? "it stopped"
                if p.terminationStatus == 3 || log.lowercased().contains("provisioning") || log.lowercased().contains("signature") {
                    throw CubError("The phone helper needs building for this phone first (about a minute): open Phonebooth with the phone unlocked, or run `bash \(script) build \(d.udid)`. \(line)")
                }
                throw CubError("The phone helper didn't start: \(line). Its output is in \(helperLog.path).")
            }
        }
        p.terminate()
        helper = nil
        throw CubError("The phone helper didn't answer within 45 seconds. Its output is in \(helperLog.path).")
    }

    private func openSession() throws {
        let r = try call("POST", "session", ["capabilities": ["alwaysMatch": ["shouldWaitForQuiescence": false]]])
        let v = r["value"] as? [String: Any]
        guard let id = (v?["sessionId"] ?? r["sessionId"]) as? String else { throw CubError("The phone helper didn't open a session.") }
        session = id
        _ = try? call("POST", "session/\(id)/appium/settings", ["settings": ["waitForIdleTimeout": 0, "animationCoolOffTimeout": 0]])
        lastUse = Date()
    }

    private func refreshScreen() throws {
        if session == nil { try openSession() }
        let r = try call("GET", "session/\(session!)/window/size")
        if let v = r["value"] as? [String: Any], let w = (v["width"] as? NSNumber)?.doubleValue, let h = (v["height"] as? NSNumber)?.doubleValue {
            points = CGSize(width: w, height: h)
        }
        orientation = ((try? call("GET", "phonebooth/orientation"))?["value"] as? NSNumber)?.intValue ?? 1
    }

    // The helper keeps the phone's test runner going, so it's stopped after 15 quiet
    // minutes. Called from the service's timer, on the work queue.
    func tick() {
        if helper != nil, Date().timeIntervalSince(lastUse) > 15 * 60 { _ = stop() }
    }

    private func stop() -> String {
        let had = helper != nil
        helper?.terminate()
        helper = nil
        base = nil
        session = nil
        return had ? "Stopped the phone helper." : "The phone helper wasn't running from here."
    }

    private func agentScript() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/Applications/Phonebooth.app/Contents/Resources/agent.sh",
                "\(home)/dev/me/mikerosoft-tools/phonebooth/agent.sh"]
            .first { FileManager.default.isExecutableFile(atPath: $0) || FileManager.default.fileExists(atPath: $0) }
    }

    // The paired iPhone Xcode can reach, preferring one whose tunnel is already open, then the
    // cable. COMPUTERCUB_PHONE picks one by name.
    private func findDevice() -> Device? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cub-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = shell("/usr/bin/xcrun", ["devicectl", "list", "devices", "--json-output", tmp.path], timeout: 20)
        guard let data = try? Data(contentsOf: tmp),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = (root["result"] as? [String: Any])?["devices"] as? [[String: Any]] else { return nil }
        let want = ProcessInfo.processInfo.environment["COMPUTERCUB_PHONE"]
        let phones: [Device] = list.compactMap { d in
            let hw = d["hardwareProperties"] as? [String: Any] ?? [:]
            let c = d["connectionProperties"] as? [String: Any] ?? [:]
            guard hw["reality"] as? String == "physical", hw["deviceType"] as? String == "iPhone",
                  c["pairingState"] as? String == "paired",
                  let name = (d["deviceProperties"] as? [String: Any])?["name"] as? String,
                  let udid = hw["udid"] as? String else { return nil }
            let transport = c["transportType"] as? String
            guard transport != nil || want == name else { return nil }
            return Device(name: name, udid: udid, tunnel: c["tunnelState"] as? String == "connected" ? c["tunnelIPAddress"] as? String : nil, transport: transport)
        }
        let pool = want.map { w in phones.filter { $0.name == w } } ?? phones
        return pool.first { $0.tunnel != nil } ?? pool.first { $0.transport == "wired" } ?? pool.first
    }

    // MARK: Touches and keys

    private func touch(_ path: [CGPoint], hold: Double) throws {
        // Points from `line` are a 16 ms frame apart.
        let pts = path.enumerated().map { i, p in ["x": Double(p.x), "y": Double(p.y), "t": 0.016 * Double(i)] }
        _ = try call("POST", "phonebooth/touch", ["points": pts, "hold": hold, "orientation": orientation])
    }

    // A straight finger path taking about `seconds`, a point per 16 ms frame.
    private func line(_ a: CGPoint, _ b: CGPoint, seconds: Double) -> [CGPoint] {
        let steps = Swift.max(2, Int(seconds / 0.016))
        return (0...steps).map { i in
            let t = CGFloat(i) / CGFloat(steps)
            return CGPoint(x: (a.x + (b.x - a.x) * t).rounded(), y: (a.y + (b.y - a.y) * t).rounded())
        }
    }

    private func keys(_ text: String) throws {
        if session == nil { try openSession() }
        do {
            _ = try call("POST", "session/\(session!)/wda/keys", ["value": [text]])
        } catch {
            // A session can go stale when the phone switches apps; one fresh try.
            try openSession()
            _ = try call("POST", "session/\(session!)/wda/keys", ["value": [text]])
        }
    }

    private func numbers(_ a: Args, _ n: Int, _ example: String) throws -> [Double] {
        let v = a.pos.dropFirst().compactMap(Double.init)
        guard v.count == n, a.pos.count == n + 1 else { throw CubError("Give positions from the phone's last shot: \(example).") }
        return v
    }

    // A spot in the last shot's pixels, as phone points.
    private func phonePoint(_ x: Double, _ y: Double) throws -> CGPoint {
        guard let shot else { throw CubError("Positions come from the phone's last shot, and there isn't one. Run `computercub shot phone` first.") }
        guard x >= 0, y >= 0, CGFloat(x) < shot.size.width, CGFloat(y) < shot.size.height else {
            throw CubError("\(fmt(x)),\(fmt(y)) is outside the last shot, which is \(Int(shot.size.width))×\(Int(shot.size.height)).")
        }
        return CGPoint(x: (CGFloat(x) / shot.scale).rounded(), y: (CGFloat(y) / shot.scale).rounded())
    }

    private func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }

    // MARK: Plumbing

    private func call(_ method: String, _ path: String, _ body: [String: Any]? = nil, timeout: TimeInterval = 20, at url: URL? = nil) throws -> [String: Any] {
        guard let root = url ?? base, let u = URL(string: path, relativeTo: root) else { throw CubError("The phone helper isn't running.") }
        var req = URLRequest(url: u, timeoutInterval: timeout)
        req.httpMethod = method
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let done = DispatchSemaphore(value: 0)
        var result: Result<[String: Any], Error> = .failure(CubError("No answer from the phone helper."))
        URLSession.shared.dataTask(with: req) { data, response, error in
            defer { done.signal() }
            if let error { result = .failure(error); return }
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            if let code = (response as? HTTPURLResponse)?.statusCode, code >= 400 {
                let msg = ((json["value"] as? [String: Any])?["message"] as? String) ?? "HTTP \(code)"
                result = .failure(CubError("The phone helper said: \(msg)"))
                return
            }
            result = .success(json)
        }.resume()
        done.wait()
        return try result.get()
    }

    @discardableResult
    private func shell(_ exe: String, _ args: [String], timeout: TimeInterval) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(100_000) }
        if p.isRunning { p.terminate() }
        return p.isRunning ? -1 : p.terminationStatus
    }
}
