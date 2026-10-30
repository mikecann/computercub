import Foundation

// While the screen is locked, macOS stops giving out windows over Accessibility. An app's
// AXWindows still has the right number of entries, but each is the app element again, so
// every window looks like it's gone. Only the session dictionary says why.
public enum ScreenLock {
    // Takes CGSessionCopyCurrentDictionary's result; the key is only there while locked.
    public static func isLocked(session: [String: Any]?) -> Bool {
        guard let v = session?["CGSSessionScreenIsLocked"] else { return false }
        return (v as? NSNumber)?.boolValue ?? false
    }

    public static func refusal(user: String) -> String {
        """
        The screen is locked, so macOS hides every app's windows from Accessibility. The apps are fine and it isn't a Space problem; the windows come back when \(user) unlocks. Until then `computercub apps` and `computercub menu <app>` still answer, and scriptable apps still answer AppleScript from your own shell, e.g. osascript -e 'tell application "Google Chrome" to get id of windows'.
        """
    }
}
