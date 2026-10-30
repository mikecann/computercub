import AppKit

let argv = Array(CommandLine.arguments.dropFirst())

// Started by `open` (or a double-click), Mr Clicky.app runs as the background service that
// holds the Accessibility and Screen Recording grants. Anything else is the CLI.
if argv.first == "serve" || (argv.isEmpty && getppid() == 1) {
    Service.run()
}
exit(Client.run(argv))
