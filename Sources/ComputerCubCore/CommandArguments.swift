public struct CommandArguments {
    public var pos: [String] = []
    public var flags: [String: String] = [:]
    public static let valued: Set<String> = ["wait", "max", "find"]

    public init(_ argv: [String]) {
        var i = 0
        var options = true
        while i < argv.count {
            let s = argv[i]
            if options && s == "--" {
                options = false
            } else if options && s.hasPrefix("--") && s != "--local" {
                // --local belongs before the command; here it is literal command data.
                let k = String(s.dropFirst(2))
                if Self.valued.contains(k), i + 1 < argv.count {
                    flags[k] = argv[i + 1]
                    i += 2
                    continue
                }
                flags[k] = ""
            } else {
                pos.append(s)
            }
            i += 1
        }
    }

    public func has(_ k: String) -> Bool { flags[k] != nil }
}
