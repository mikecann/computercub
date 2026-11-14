import Foundation

public struct ClientArguments {
    public let isLocal: Bool
    public let command: [String]

    public init(_ arguments: [String]) {
        // Only a leading client option can select another execution context.
        // A command's text or a flag's value may itself be "--local".
        isLocal = arguments.first == "--local"
        command = isLocal ? Array(arguments.dropFirst()) : arguments
    }
}

public struct ClientReply {
    public var ok: Bool
    public var out: String
    public var restart: Bool

    public init(ok: Bool, out: String, restart: Bool = false) {
        self.ok = ok
        self.out = out
        self.restart = restart
    }
}

/// Routes real client requests; tests supply callbacks that cannot launch apps or use AX.
public enum ClientSession {
    public static func run(
        _ request: ClientArguments,
        isPrivate: Bool,
        app: URL?,
        call: ([String], URL?) -> ClientReply?,
        local: ([String]) -> ClientReply,
        restart: (URL) -> Void
    ) -> ClientReply? {
        if request.isLocal { return local(request.command) }
        // An app path must never enable launch or restart in a private session.
        if isPrivate { return call(request.command, nil) }
        guard let app else { return local(request.command) }
        guard var reply = call(request.command, app) else { return nil }
        if !reply.ok && reply.restart {
            restart(app)
            guard let again = call(request.command, app) else { return nil }
            reply = again
        }
        return reply
    }
}
