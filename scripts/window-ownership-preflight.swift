// Read-only helper. Prefer the installed app's --window-ownership-preflight for its own AX trust identity.
// Compile with Sources/CodexSwoopCore/*.swift; never linked into the app.
import Foundation

@main
struct WindowOwnershipPreflight {
    static func main() async {
        exit(await EnvironmentWindowPreflight.run(arguments: Array(CommandLine.arguments.dropFirst())))
    }
}
