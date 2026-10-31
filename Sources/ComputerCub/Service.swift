import AppKit
import ApplicationServices

// macOS gives Accessibility and Screen Recording to the "responsible" process. A bare CLI
// run by an agent counts as part of whatever started it (Threadbear Runner, Terminal),
// so the grants would go to the wrong app. Instead the CLI hands each command to
// ComputerCub.app over a Unix socket, the way BrowserBear hands them to its service, and ComputerCub.app
// holds the grants under Mike's code signature.
// NSApplication holds its delegate weakly, so it lives here.
private let appDelegate = AppDelegate()

enum Service {
    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = appDelegate
        // Rather than firing macOS's prompts at launch, the setup window shows what's
        // missing and asks for each one from its own button.
        DispatchQueue.main.async { SetupWindowController.shared.showIfNeeded() }
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 2.0)
        Shot.sweep()
        do {
            try listen()
        } catch {
            FileHandle.standardError.write("computercub: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Commands.shared.tick()
            Shot.sweep()
        }
        app.run()
        exit(0)
    }

    private static func listen() throws {
        try FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        unlink(Paths.socket)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CubError("Couldn't make a socket.") }
        var addr = sockaddr_un(path: Paths.socket)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { throw CubError("Couldn't listen on \(Paths.socket): \(String(cString: strerror(errno)))") }
        // Only Mike's own processes can drive his Mac through this.
        chmod(Paths.socket, 0o600)
        Darwin.listen(fd, 16)
        Thread.detachNewThread {
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { continue }
                Thread.detachNewThread { serve(c) }
            }
        }
    }

    private static func serve(_ c: Int32) {
        defer { close(c) }
        var on: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        guard let line = Wire.readLine(c),
              let req = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let args = req["args"] as? [String] else { return }
        let reply = Commands.shared.run(args, agent: req["agent"] as? String)
        Wire.send(c, ["ok": reply.ok, "out": reply.out, "restart": reply.restart])
    }
}

enum Client {
    static func run(_ args: [String]) -> Int32 {
        if args.isEmpty || ["help", "-h", "--help"].contains(args[0]) {
            print(helpText)
            return 0
        }
        // A dev build outside the app bundle has no app to hold the grants, so it runs
        // in-process (and only works if whatever started it has them), unless a dev
        // `serve` with its own COMPUTERCUB_HOME is listening: then refs last between commands.
        guard let app = appBundle(), !args.contains("--local") else {
            if Paths.isDev, !args.contains("--local"), let reply = call(args, app: nil) { return finish(reply) }
            return finish(Commands.shared.run(args.filter { $0 != "--local" }, agent: Agent.current()))
        }
        guard var reply = call(args, app: app) else { return 1 }
        // Granting Screen Recording while the app is running doesn't reach it until it
        // restarts, so restart it once and try again before giving up.
        if !reply.ok && reply.restart {
            restart(app)
            guard let again = call(args, app: app) else { return 1 }
            reply = again
        }
        return finish(reply)
    }

    // Sends one command to ComputerCub.app, starting the app if it isn't running. With no
    // app, only to a service that's already up.
    private static func call(_ args: [String], app: URL?) -> Reply? {
        var fd = connect()
        if fd < 0 && app == nil { return nil }
        if fd < 0, let app {
            // `open` starts it through LaunchServices, so it's its own responsible process.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-g", "-a", app.path, "--args", "serve"]
            try? p.run()
            p.waitUntilExit()
            for _ in 0..<80 where fd < 0 {
                usleep(100_000)
                fd = connect()
            }
        }
        guard fd >= 0 else {
            FileHandle.standardError.write("computercub: couldn't start \(app?.path ?? "ComputerCub")\n".data(using: .utf8)!)
            return nil
        }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var req: [String: Any] = ["args": args, "cwd": FileManager.default.currentDirectoryPath]
        if let agent = Agent.current() { req["agent"] = agent }
        Wire.send(fd, req)
        guard let line = Wire.readLine(fd),
              let reply = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            // Almost always the app being stopped mid-command, by a reinstall or `computercub quit`.
            FileHandle.standardError.write("computercub: no answer from ComputerCub.app; it stopped before replying (a reinstall or `computercub quit` does that). The command may or may not have happened: snap to see, then retry.\n".data(using: .utf8)!)
            return nil
        }
        return Reply(ok: reply["ok"] as? Bool ?? false, out: reply["out"] as? String ?? "", restart: reply["restart"] as? Bool ?? false)
    }

    // Stops the running app and waits for it to go, so the next call starts a fresh one.
    private static func restart(_ app: URL) {
        _ = call(["quit"], app: app)
        for _ in 0..<40 {
            let fd = connect()
            if fd < 0 { return }
            close(fd)
            usleep(100_000)
        }
    }

    private static func finish(_ r: Reply) -> Int32 {
        if r.ok {
            print(r.out)
        } else {
            FileHandle.standardError.write("computercub: \(r.out)\n".data(using: .utf8)!)
        }
        return r.ok ? 0 : 1
    }

    private static func connect() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = sockaddr_un(path: Paths.socket)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if r != 0 {
            close(fd)
            return -1
        }
        return fd
    }

    // ~/.local/bin/computercub is a link into the bundle; follow it to find ComputerCub.app.
    private static func appBundle() -> URL? {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buf = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buf, &size) == 0 else { return nil }
        let exe = URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath()
        let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }
}

enum Wire {
    static func send(_ fd: Int32, _ obj: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0a)
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return }
                off += n
            }
        }
    }

    static func readLine(_ fd: Int32) -> Data? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            if let nl = buf[0..<n].firstIndex(of: 0x0a) {
                data.append(contentsOf: buf[0..<nl])
                return data
            }
            data.append(contentsOf: buf[0..<n])
        }
        return data.isEmpty ? nil : data
    }
}

extension sockaddr_un {
    init(path: String) {
        self.init()
        sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8.prefix(103))
        withUnsafeMutableBytes(of: &sun_path) { $0.copyBytes(from: bytes) }
    }
}
