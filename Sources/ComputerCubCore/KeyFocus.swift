// Whether keys typed now would land in the element we mean. Keys go wherever the app's
// keyboard focus is, not to an element, so `type` asks this before sending any: in Slack,
// typing into a reply box that hadn't really taken focus sent the letters to the app as
// shortcuts (a file picker, the shortcuts panel and search all opened).
//
// The app's own focused element is the authority. An element's AXFocused can stay true
// after a web page has moved focus elsewhere, so it only counts when the app won't say
// what's focused. Focus inside the target (a rich editor's inner paragraph) counts as the
// target. Generic over the element type so tests don't need a live AX tree.
public enum KeyFocus {
    public static func holds<E>(
        target: E,
        appFocused: E?,
        targetSaysFocused: Bool,
        parent: (E) -> E?,
        same: (E, E) -> Bool
    ) -> Bool {
        guard var at = appFocused else { return targetSaysFocused }
        // A bounded walk: a broken tree can loop back on itself.
        for _ in 0..<12 {
            if same(at, target) { return true }
            guard let up = parent(at) else { return false }
            at = up
        }
        return false
    }
}
