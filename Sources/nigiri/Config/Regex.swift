import Foundation

// niri's window-rule matchers are regexes (its configs are full of
// `app-id="^org\\.gnome\\."`). nigiri matched a case-insensitive
// SUBSTRING, so none of them ported. Unanchored, like niri's: the pattern
// has to be FOUND in the string, not match it whole.
struct Regex {
    private let regex: NSRegularExpression?
    let pattern: String

    init(_ pattern: String) {
        self.pattern = pattern
        regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        if regex == nil { print("[config] invalid regex, ignored: \(pattern)") }
    }

    func matches(_ text: String) -> Bool {
        guard let regex else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
}
