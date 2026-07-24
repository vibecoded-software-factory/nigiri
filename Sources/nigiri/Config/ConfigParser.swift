import AppKit
import Carbon

// KDL-subset parser: tokenizer (quotes/braces/semicolons/comments) + a
// cursor parser producing a NigiriConfig. Unknown lines report and skip.
extension NigiriConfig {
    // The KDL features niri's own configs actually use. niri parses with
    // knuffel 3.2 (KDL v1), so `r"..."` is a raw string here - in KDL v2 that
    // spelling is legacy and `#"..."#` took its place, and both are accepted
    // below. There is no usable Swift KDL library to lean on instead: the only
    // implementations are kdl-swift (6 stars, no LICENSE file, so not legally
    // vendorable) and a one-star mirror, and knuffel is Rust - a Rust
    // toolchain plus FFI to read a config file, in a binary that has to start
    // at login. So this stays hand-written, and the shapes below are the ones
    // the official KDL test suite covers, checked in SelfTest:
    //
    //   /- node          drops the node (and its children block)
    //   node /- arg1 arg2  drops ONE argument   -> node arg2
    //   node arg /- { … }  drops the children block, keeps the node
    //   /* … */          block comment, nestable, may contain '*'
    //   "a \"b\""        escapes inside a quoted string
    //   r"…" r#"…"#      raw strings, no escapes, may contain quotes
    //
    // Not supported yet, and unused by niri's configs: escline (`\` at end of
    // line), \u{…} escapes, type annotations `(u8)1`.
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        let chars = Array(text)
        var i = 0
        func flush() { if !current.isEmpty { tokens.append(current); current = "" } }
        func lineOf(_ index: Int) -> Int { chars[..<min(index, chars.count)].filter { $0 == "\n" }.count + 1 }
        while i < chars.count {
            let c = chars[i]
            // A raw string starts a token OR follows a property's `=`
            // (app-id=r#"…"# - exactly how niri's own default config writes
            // its window-rule regexes). Anywhere else, `r` glued to an
            // identifier is just an identifier - readRawString's quote check
            // rejects those.
            if current.isEmpty || current.hasSuffix("="),
                c == "r" || c == "#", let (value, next) = readRawString(chars, from: i)
            {
                current += value
                // An empty raw string still produced a token: "" is a value.
                // (In property position `current` holds the key, so flush
                // emits it either way.)
                if current.isEmpty { tokens.append("") }
                i = next
                continue
            }
            if c == "\"" {
                let (value, next, terminated) = readQuoted(chars, from: i)
                if !terminated {
                    print(
                        "[config] unterminated quote on line \(lineOf(i)): discarding the rest of the file"
                    )
                }
                current += value
                if value.isEmpty { tokens.append("") }
                i = next
                continue
            }
            if c == "/", i + 1 < chars.count {
                let d = chars[i + 1]
                if d == "/" {
                    while i < chars.count, chars[i] != "\n" { i += 1 }
                    continue
                }
                if d == "*" {
                    // Nestable, per the spec, and it may contain a bare '*'.
                    var depth = 1
                    i += 2
                    while i < chars.count, depth > 0 {
                        if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                            depth += 1; i += 2; continue
                        }
                        if chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "/" {
                            depth -= 1; i += 2; continue
                        }
                        i += 1
                    }
                    if depth > 0 { print("[config] unterminated /* comment on line \(lineOf(i)))") }
                    flush()
                    continue
                }
                if d == "-" {
                    flush(); tokens.append(slashdash); i += 2; continue
                }
            }
            if c == "\n" {
                flush(); tokens.append("\n")
            } else if c == "{" || c == "}" || c == ";" {
                flush(); tokens.append(String(c))
            } else if c == " " || c == "\t" || c == "\r" {
                flush()
            } else {
                current.append(c)
            }
            i += 1
        }
        flush()
        return applySlashdash(tokens)
    }

    // The marker the tokenizer leaves for `/-`; never a legal identifier.
    private static let slashdash = "\u{0}slashdash"

    // A quoted string, with KDL's escapes. Returns the value, the index after
    // the closing quote, and whether it WAS closed - an unterminated quote used
    // to swallow the rest of the file with no message at all.
    private static func readQuoted(_ chars: [Character], from start: Int) -> (String, Int, Bool) {
        var value = ""
        var i = start + 1
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                switch chars[i + 1] {
                case "n": value.append("\n")
                case "t": value.append("\t")
                case "r": value.append("\r")
                case "\"": value.append("\"")
                case "\\": value.append("\\")
                case "/": value.append("/")
                case "b": value.append("\u{8}")
                case "f": value.append("\u{c}")
                default: value.append(chars[i + 1])
                }
                i += 2
                continue
            }
            if c == "\"" { return (value, i + 1, true) }
            value.append(c)
            i += 1
        }
        return (value, chars.count, false)
    }

    // r"…", r#"…"# (KDL v1, what niri writes) and #"…"# (v2). No escapes
    // inside, so a shader full of quotes and backslashes survives intact.
    private static func readRawString(_ chars: [Character], from start: Int) -> (String, Int)? {
        var i = start
        if chars[i] == "r" { i += 1 }
        var hashes = 0
        while i < chars.count, chars[i] == "#" { hashes += 1; i += 1 }
        guard i < chars.count, chars[i] == "\"" else { return nil }
        // A bare `#` with no quote is not a raw string; and `r` alone is a word.
        if start == i { return nil }
        i += 1
        let closing = "\"" + String(repeating: "#", count: hashes)
        var value = ""
        while i < chars.count {
            if chars[i] == "\"" {
                let end = i + closing.count
                if end <= chars.count, String(chars[i..<end]) == closing { return (value, end) }
            }
            value.append(chars[i])
            i += 1
        }
        print("[config] unterminated raw string: discarding the rest of the file")
        return (value, chars.count)
    }

    // KDL's slashdash: `/-` comments out the next thing. Which thing depends on
    // where it sits - as the first token of a line it takes the whole node
    // (children block included), mid-line it takes exactly one argument, and
    // before a `{` it takes just that block. Applied over the token stream
    // because "the next thing" is a structural question, not a lexical one.
    private static func applySlashdash(_ tokens: [String]) -> [String] {
        func endOfBlock(_ from: Int) -> Int {
            var depth = 0
            var i = from
            while i < tokens.count {
                if tokens[i] == "{" { depth += 1 }
                if tokens[i] == "}" { depth -= 1; if depth == 0 { return i + 1 } }
                i += 1
            }
            return tokens.count
        }
        var out: [String] = []
        var i = 0
        var atLineStart = true
        while i < tokens.count {
            let t = tokens[i]
            guard t == slashdash else {
                atLineStart = (t == "\n" || t == ";" || t == "{" || t == "}")
                out.append(t)
                i += 1
                continue
            }
            i += 1
            while i < tokens.count, tokens[i] == "\n" { i += 1 }  // `/-` on its own line
            if i < tokens.count, tokens[i] == "{" {
                i = endOfBlock(i)
            } else if atLineStart {
                while i < tokens.count, tokens[i] != "\n", tokens[i] != ";" {
                    i = tokens[i] == "{" ? endOfBlock(i) : i + 1
                }
            } else if i < tokens.count {
                i += 1
            }
        }
        return out
    }

    // Cursor parser. Unknown lines/sections are reported and skipped,
    // never fatal - a config with one typo must not silently revert
    // EVERYTHING to defaults. Returns nil only if the file is unreadable.
    // niri's `include` semantics (lib.rs:297-443), expanded textually
    // before tokenizing so nested sections parse as if inlined:
    // - TOP-LEVEL only (lib.rs:297): an include inside a section is not a
    //   directive - it used to expand anywhere;
    // - `optional=true` tolerates a missing file with a warning
    //   (lib.rs:317-332, 433-436); a missing REQUIRED include FAILS the
    //   whole load (437-443) - the previous config stays applied and the
    //   error banner shows, instead of a print-and-continue;
    // - `~` expands (346-357);
    // - the same file may be included from two different parents; only
    //   true self-recursion within the current BRANCH is an error
    //   (IncludeStack is cloned per branch, 384-392) - the global visited
    //   set silently dropped legal second includes;
    // - the depth cap is 10, like upstream's, and exceeding it fails.
    // `read` collects every path this expansion touched (even failed ones:
    // upstream stores them "so it gets watched") for the live reload.
    static func expandIncludes(
        _ text: String, baseDir: String, depth: Int = 0, stack: [String] = [],
        read: inout Set<String>
    ) -> String? {
        guard depth <= 10 else {
            print("[config] includes nested deeper than 10 - refusing the config, like niri")
            return nil
        }
        var out: [String] = []
        var braceDepth = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let atTopLevel = braceDepth == 0
            // Track nesting OUTSIDE quoted strings, so a `spawn-sh "a { b"`
            // does not skew the include-position check.
            var inQuote = false
            for ch in line {
                if ch == "\"" { inQuote.toggle() }
                if !inQuote {
                    if ch == "{" { braceDepth += 1 }
                    if ch == "}" { braceDepth = max(0, braceDepth - 1) }
                }
            }
            guard atTopLevel, trimmed.hasPrefix("include ") || trimmed.hasPrefix("include\t") else {
                out.append(String(line))
                continue
            }
            // include "path" [optional=true] - the path is the FIRST
            // double-quoted token (niri's real config writes
            // `include "x.kdl" //comment`).
            let inner = trimmed.dropFirst("include".count).trimmingCharacters(in: .whitespaces)
            guard let open = inner.firstIndex(of: "\""),
                let close = inner[inner.index(after: open)...].firstIndex(of: "\"")
            else {
                print("[config] malformed include: \(inner)")
                return nil
            }
            let optional = inner[close...].contains("optional=true")
            var rel = String(inner[inner.index(after: open)..<close])
            if rel.hasPrefix("~") { rel = (rel as NSString).expandingTildeInPath }
            let resolved =
                (rel as NSString).isAbsolutePath ? rel : (baseDir as NSString).appendingPathComponent(rel)
            let real =
                (try? FileManager.default.destinationOfSymbolicLink(atPath: resolved)).map {
                    ($0 as NSString).isAbsolutePath
                        ? $0 : (baseDir as NSString).appendingPathComponent($0)
                } ?? resolved
            read.insert(real)
            if stack.contains(real) {
                print("[config] include recursion: \(rel) includes itself - refusing the config")
                return nil
            }
            guard let included = try? String(contentsOfFile: real, encoding: .utf8) else {
                if optional {
                    print("[config] optional include not found, skipping: \(rel)")
                    continue
                }
                print("[config] include not found: \(rel) - refusing the config, like niri")
                return nil
            }
            guard
                let expanded = expandIncludes(
                    included, baseDir: (real as NSString).deletingLastPathComponent,
                    depth: depth + 1, stack: stack + [real], read: &read)
            else { return nil }
            out.append(expanded)
        }
        return out.joined(separator: "\n")
    }

    static func load() -> NigiriConfig? {
        guard let rawText = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        // Resolve includes relative to the config's real directory (follow
        // the symlink so dotfiles-hosted configs resolve their siblings).
        let realPath =
            (try? FileManager.default.destinationOfSymbolicLink(atPath: path)).map {
                ($0 as NSString).isAbsolutePath
                    ? $0
                    : ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent($0)
            } ?? path
        var read: Set<String> = [realPath]
        let expanded = expandIncludes(
            rawText, baseDir: (realPath as NSString).deletingLastPathComponent,
            stack: [realPath], read: &read)
        // Everything the live reload has to watch: the read set is the
        // authoritative list of files this parse actually touched (includes
        // resolved through symlinks, FAILED ones included - upstream stores
        // even those "so it gets watched"). niri reloads on changes to any
        // of the config set; watching only config.kdl left edits to an
        // included file (gestures.kdl, dms/windowrules.kdl) silently
        // un-applied.
        lastLoadedFiles = Array(read)
        // A failed include refuses the whole config, like niri: the caller
        // keeps the previous configuration and shows the error banner.
        guard let text = expanded else { return nil }
        return parse(text)
    }

    // The files the most recent load() read - config.kdl plus every include.
    nonisolated(unsafe) static var lastLoadedFiles: [String] = []

    // The parser proper, over already-included text. Split out from load()
    // so it can be exercised without a file on disk.
    static func parse(_ text: String) -> NigiriConfig {
        // What the keyboard types right now - resolved before any combo is
        // parsed (see NigiriConfig.layoutKeyCodes). binds-layout is read in a
        // pre-pass: parseCombo resolves at parse time, so a pin declared
        // AFTER the binds block would otherwise be ignored for every bind.
        // The pin lives at niri's input.keyboard.xkb.layout; scanning for
        // the xkb token avoids colliding with the layout SECTION.
        let allTokens = tokenize(text)
        let pinnedLayout = allTokens.enumerated().first { $0.element == "xkb" }
            .flatMap { idx, _ -> String? in
                var j = idx + 1
                while j < allTokens.count, j < idx + 8, allTokens[j] != "}" {
                    if allTokens[j] == "layout", j + 1 < allTokens.count {
                        return allTokens[j + 1].split(separator: ",").first.map(String.init)
                    }
                    j += 1
                }
                return nil
            }
        NigiriConfig.refreshLayoutKeyCodes(preferring: pinnedLayout)
        var config = NigiriConfig()
        config.presetColumnSizes = []
        // A reload must not inherit the previous file's Mod.
        NigiriConfig.modKey = [.command, .option]
        let tokens = tokenize(text)
        var i = 0

        func next() -> String? { i < tokens.count ? tokens[i] : nil }
        func advance() -> String? { defer { i += 1 }; return next() }
        // One statement: tokens up to newline / ; / } (the } is pushed back
        // for the section parser to consume).
        func statement(firstToken: String) -> [String] {
            var parts = [firstToken]
            while let t = next() {
                if t == "\n" || t == ";" { i += 1; break }
                // Both are pushed back for the caller: `}` ends the section,
                // and `{` opens this node's children block - a statement can
                // never contain either. Swallowing the `{` is what made an
                // unknown sub-block (`input { touchpad { … } mod-key … }`)
                // abort its whole section: the caller's "does a block follow?"
                // check then saw the block's CONTENTS, the block's `}` ended
                // the section early, and every key after it was dropped -
                // including mod-key, leaving all 74 binds on the default.
                if t == "}" || t == "{" { break }
                parts.append(t)
                i += 1
            }
            return parts
        }
        // `name { proportion 0.5; }` - niri's inline value blocks.
        // default-column-width's three shapes (layout.rs:146-147): the
        // EMPTY block means "the window decides" (Some(None) upstream -
        // exactly what niri's own default config uses for WezTerm), `fixed`
        // is pixels, `proportion` a share. fixed and {} used to be
        // swallowed silently.
        // A color NODE's value: one argument (hex, CSS name, or an
        // rgb()/hsl() function - rejoined, since the tokenizer splits on
        // the spaces inside "rgb(1, 2, 3)"), or niri's four-numbers RGBA
        // form (appearance.rs:798-815), which only hex survived before.
        func nodeColor(_ parts: [String]) -> NSColor? {
            let args = Array(parts.dropFirst())
            if args.count == 4, let r = Double(args[0]), let g = Double(args[1]),
                let b = Double(args[2]), let a = Double(args[3])
            {
                return NSColor(
                    calibratedRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                    blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
            }
            return parseColor(args.joined())
        }

        func inlineDefaultWidth() -> NigiriConfig.DefaultWidth? {
            guard next() == "{" else { return nil }
            i += 1
            var value: NigiriConfig.DefaultWidth = .natural
            while let t = advance(), t != "}" {
                if t == "proportion", let raw = advance(), let v = Double(raw) {
                    value = .proportion(CGFloat(v))
                }
                if t == "fixed", let raw = advance(), let v = Double(raw) {
                    value = .fixed(CGFloat(v))
                }
            }
            return value
        }
        func skipUnknownBlock(named name: String, context: String) {
            print("[config] unknown \(context) \"\(name)\" - skipping block")
            var depth = 1
            // depth FIRST: `while let t = advance(), depth > 0` evaluates the
            // advance before the check, so it ate one token past the closing
            // brace - at worst the parent section's `}`, taking a whole
            // `binds { … }` with it.
            while depth > 0, let t = advance() {
                if t == "{" { depth += 1 }
                if t == "}" { depth -= 1 }
            }
        }
        func keyValues(_ parts: [String]) -> [(String, String)] {
            parts.compactMap {
                let kv = $0.split(separator: "=", maxSplits: 1).map(String.init)
                return kv.count == 2 ? (kv[0], kv[1]) : nil
            }
        }

        func parseFocusRing() {
            while let t = advance() {
                if t == "\n" || t == ";" { continue }
                if t == "}" { return }
                let parts = statement(firstToken: t)
                switch parts[0] {
                case "width": if let v = Double(parts.last ?? "") { config.ringWidth = CGFloat(v) }
                // macOS-only, no niri counterpart: how round the ring's (and
                // the inactive border's) corners are, to match whatever this
                // macOS version rounds its windows by. Live-reloadable
                // precisely so it can be eyeballed/measured against a real
                // window instead of guessed.
                case "corner-radius": if let v = Double(parts.last ?? "") { config.cornerRadius = CGFloat(v) }
                case "active-gradient":
                    for (k, v) in keyValues(parts) {
                        if k == "from", let c = parseColor(v) { config.ringFrom = c }
                        if k == "to", let c = parseColor(v) { config.ringTo = c }
                        // Any CSS angle, like niri (default 180): the old
                        // parser accepted only 45.
                        if k == "angle", let a = Double(v) { config.ringAngle = CGFloat(a) }
                        // relative-to spans the gradient over the workspace
                        // view; per-window overlays can't share one gradient.
                        if k == "relative-to" {
                            print("[config] active-gradient relative-to: rendered per window here")
                        }
                    }
                case "active-color":
                    if let c = nodeColor(parts) { config.ringFrom = c; config.ringTo = c }
                case "inactive-color":
                    if let c = nodeColor(parts) { config.ringInactiveColor = c }
                // The inactive decoration is a single stroke; a gradient's
                // `from` stop is what it can honour.
                case "inactive-gradient":
                    for (k, v) in keyValues(parts) where k == "from" {
                        if let c = parseColor(v) { config.ringInactiveColor = c }
                    }
                // Parsed and stored (appearance.rs:250); dormant until
                // urgency machinery exists.
                case "urgent-color":
                    if let c = nodeColor(parts) { config.ringUrgentColor = c }
                case "urgent-gradient":
                    for (k, v) in keyValues(parts) where k == "from" {
                        if let c = parseColor(v) { config.ringUrgentColor = c }
                    }
                case "off": config.ringOff = true
                default: print("[config] unknown focus-ring key: \(parts[0])")
                }
            }
        }

        // animations { slowdown 2; off; <name> { spring ... | duration-ms N; curve "..." } }
        func parseAnimations() {
            while let t = advance() {
                if t == "\n" || t == ";" { continue }
                if t == "}" { return }
                switch t {
                case "off":
                    config.animationsOff = true
                    continue
                case "slowdown":
                    let parts = statement(firstToken: t)
                    // niri allows 0 (instant); only negatives are invalid
                    // (animations.rs:50-51). The 0.01 floor was invented.
                    if let v = Double(parts.last ?? ""), v >= 0 { config.animationSlowdown = v }
                    continue
                default: break
                }
                // A named animation block. The name must be one of
                // niri's (animations.rs:17-21 - the same set the defaults
                // table carries); an unknown one used to be accepted and
                // stored without a word.
                guard next() == "{" else {
                    print("[config] unknown animations key: \(t)")
                    _ = statement(firstToken: t)
                    continue
                }
                let knownAnimation = AnimationCurve.defaults[t] != nil
                if !knownAnimation { print("[config] unknown animation name: \(t)") }
                i += 1
                var curve: AnimationCurve? = nil
                var durationMs: Double? = nil
                var namedCurve: Easing.Curve? = nil
                var isOff = false
                while let inner = advance() {
                    if inner == "\n" || inner == ";" { continue }
                    if inner == "}" { break }
                    let parts = statement(firstToken: inner)
                    switch parts[0] {
                    case "off": isOff = true
                    case "spring":
                        // niri REQUIRES all three properties (DecodeError::
                        // missing, animations.rs:808-813) and validates the
                        // ranges (815-829). A spring that fails either is
                        // reported and dropped - the animation then falls to
                        // its default, the closest report-and-skip gets to
                        // niri's hard config error. The old defaults for
                        // absent properties were invented.
                        var stiffness: Double?
                        var damping: Double?
                        var epsilon: Double?
                        for (k, v) in keyValues(parts) {
                            switch k {
                            case "stiffness": stiffness = Double(v)
                            case "damping-ratio": damping = Double(v)
                            case "epsilon": epsilon = Double(v)
                            default: print("[config] \(t): unknown spring property \(k)")
                            }
                        }
                        guard let s = stiffness, let d = damping, let e = epsilon else {
                            print("[config] \(t): spring requires damping-ratio, stiffness and epsilon")
                            continue
                        }
                        guard (0.1...10).contains(d) else {
                            print("[config] \(t): damping-ratio must be between 0.1 and 10.0")
                            continue
                        }
                        guard s >= 1 else {
                            print("[config] \(t): stiffness must be >= 1")
                            continue
                        }
                        guard (0.00001...0.1).contains(e) else {
                            print("[config] \(t): epsilon must be between 0.00001 and 0.1")
                            continue
                        }
                        curve = .spring(Spring(stiffness: s, dampingRatio: d, epsilon: e))
                    case "duration-ms":
                        durationMs = Double(parts.last ?? "")
                    case "curve":
                        let raw = parts.last ?? ""
                        if let named = Easing.Curve.named(raw) {
                            namedCurve = named
                        } else if raw == "cubic-bezier", parts.count >= 5 {
                            let n = parts.suffix(4).compactMap(Double.init)
                            if n.count == 4 { namedCurve = .cubicBezier(n[0], n[1], n[2], n[3]) }
                        } else {
                            print("[config] unknown curve: \(raw)")
                        }
                    // Shaders are compositor rendering; niri's own configs
                    // carry them, and skipping the block quietly is right.
                    case "custom-shader":
                        if next() == "{" {
                            i += 1; skipUnknownBlock(named: "custom-shader", context: "animation")
                        }
                    default: break
                    }
                }
                if !knownAnimation {
                    // consumed above; never stored
                } else if isOff {
                    config.animations[t] = .off
                } else if let curve {
                    config.animations[t] = curve
                } else if durationMs != nil || namedCurve != nil {
                    // niri's merge (animations.rs:726-748): a half-specified
                    // easing borrows the missing half from THIS animation's
                    // default easing - or 250ms/EaseOutCubic when the default
                    // is a spring. `duration-ms` alone used to force
                    // easeOutCubic and `curve` alone was dropped entirely.
                    let fallback: Easing
                    if case .easing(let e)? = AnimationCurve.defaults[t] {
                        fallback = e
                    } else {
                        fallback = Easing(durationMs: 250, curve: .easeOutCubic)
                    }
                    config.animations[t] = .easing(
                        Easing(
                            durationMs: durationMs ?? fallback.durationMs,
                            curve: namedCurve ?? fallback.curve))
                }
            }
        }

        func parseInsetBlock(_ apply: (String, CGFloat) -> Void) {
            while let t = advance() {
                if t == "\n" || t == ";" { continue }
                if t == "}" { return }
                let parts = statement(firstToken: t)
                if let v = Double(parts.last ?? "") { apply(parts[0], CGFloat(v)) }
            }
        }

        // niri's overview { zoom; backdrop-color; workspace-shadow { off } }
        func parseOverview() {
            while let t = advance() {
                if t == "\n" || t == ";" { continue }
                if t == "}" { return }
                switch t {
                case "zoom":
                    // niri accepts 0..1 (FloatOrInt<0,1>, misc.rs:140-141)
                    // and errors outside; the [0.1, 0.95] clamp was
                    // invented. The RENDER-side clamp (0.0001..0.75,
                    // mod.rs:5014-5022) lives in the overview, like upstream.
                    let parts = statement(firstToken: t)
                    if let v = Double(parts.last ?? ""), (0...1).contains(v) {
                        config.overviewZoom = CGFloat(v)
                    } else {
                        print("[config] overview zoom must be between 0 and 1")
                    }
                case "backdrop-color":
                    let parts = statement(firstToken: t)
                    if let c = nodeColor(parts) {
                        config.overviewBackdrop = c
                    }
                case "workspace-shadow":
                    // Compositor rendering; skipped, not an error.
                    if next() == "{" {
                        i += 1; skipUnknownBlock(named: t, context: "overview")
                    } else {
                        _ = statement(firstToken: t)
                    }
                default:
                    print("[config] unknown overview key: \(t)")
                    _ = statement(firstToken: t)
                }
            }
        }

        // niri's shadow section. There is no way to draw a shadow BEHIND
        // another app's window (macOS draws its own), so these values drive
        // the one shadow nigiri renders: the focus ring's glow.
        func parseInsertHint() {
            while let t = advance() {
                if t == "\n" || t == ";" { continue }
                if t == "}" { return }
                let parts = statement(firstToken: t)
                switch parts[0] {
                case "off": config.insertHintOff = true
                case "color": if let c = nodeColor(parts) { config.insertHintColor = c }
                case "gradient":
                    // One flat colour here: the hint is a plain layer, so the
                    // gradient's first stop is what it can honour.
                    for (k, v) in keyValues(parts) where k == "from" {
                        if let c = parseColor(v) { config.insertHintColor = c }
                    }
                default: print("[config] unknown insert-hint key: \(parts[0])")
                }
            }
        }

        func parseShadow() {
            // Unlike border, `shadow {}` does NOT enable: niri documents that
            // "layout { shadow {} } still results in shadow = off, as it
            // should" (niri-config/src/lib.rs:252-258, Shadow::default().on
            // == false). Only an explicit `on` turns it on. This used to
            // enable on mere presence - an inverted semantic.
            while let t = advance() {
                if t == "\n" || t == ";" { continue }
                if t == "}" { return }
                let parts = statement(firstToken: t)
                switch parts[0] {
                case "off": config.shadowOn = false
                case "on": config.shadowOn = true
                case "softness": if let v = Double(parts.last ?? "") { config.shadowSoftness = CGFloat(v) }
                case "spread":
                    // CALayer has no true spread; it folds into the blur
                    // radius at render (FocusRingOverlay.applyShadow).
                    if let v = Double(parts.last ?? "") { config.shadowSpread = CGFloat(v) }
                case "offset":
                    var dx: CGFloat = 0
                    var dy: CGFloat = 0
                    for (k, v) in keyValues(parts) {
                        if k == "x", let n = Double(v) { dx = CGFloat(n) }
                        if k == "y", let n = Double(v) { dy = CGFloat(n) }
                    }
                    config.shadowOffset = CGSize(width: dx, height: dy)
                case "color": if let c = nodeColor(parts) { config.shadowColor = c }
                case "draw-behind-window": break  // always true here: it is a glow
                default: print("[config] unknown shadow key: \(parts[0])")
                }
            }
        }

        func parseEnvironment() {
            while let t = advance() {
                if t == "\n" || t == ";" { continue }
                if t == "}" { return }
                let parts = statement(firstToken: t)
                // `K null` UNSETS (misc.rs:158-164). The tokenizer cannot
                // tell the bare null literal from the string "null"; the
                // literal reading wins, like knuffel's.
                if parts.count >= 2 {
                    config.environment[parts[0]] = parts[1] == "null" ? String?.none : parts[1]
                }
            }
        }

        // niri's full tab-indicator vocabulary (appearance.rs:459-499);
        // every real key used to be rejected as "unknown".
        func parseTabIndicator() {
            while let t = advance() {
                if t == "\n" || t == ";" { continue }
                if t == "}" { return }
                let parts = statement(firstToken: t)
                switch parts[0] {
                case "off": config.tabIndicatorOff = true
                case "on": config.tabIndicatorOff = false
                case "hide-when-single-tab":
                    config.tabHideWhenSingleTab = parts.dropFirst().first != "false"
                case "place-within-column":
                    config.tabPlaceWithinColumn = parts.dropFirst().first != "false"
                case "gap": if let v = Double(parts.last ?? "") { config.tabGap = CGFloat(v) }
                case "width": if let v = Double(parts.last ?? "") { config.tabWidth = CGFloat(v) }
                case "length":
                    for (k, v) in keyValues(parts) where k == "total-proportion" {
                        if let p = Double(v) { config.tabLengthProportion = CGFloat(p) }
                    }
                case "position":
                    if let pos = NigiriConfig.TabPosition(rawValue: parts.last ?? "") {
                        config.tabPosition = pos
                    } else {
                        print("[config] tab-indicator position: left/right/top/bottom")
                    }
                case "gaps-between-tabs":
                    if let v = Double(parts.last ?? "") { config.tabGapsBetweenTabs = CGFloat(v) }
                case "corner-radius":
                    if let v = Double(parts.last ?? "") { config.tabCornerRadius = CGFloat(v) }
                // A single strip can't hold a gradient the way niri's can;
                // the `to` colour is the visible one, so that is what a
                // segment takes.
                case "active-gradient":
                    for (k, v) in keyValues(parts) where k == "to" || k == "from" {
                        if let c = parseColor(v) { config.tabActiveColor = c }
                    }
                case "active-color": if let c = nodeColor(parts) { config.tabActiveColor = c }
                case "inactive-color": if let c = nodeColor(parts) { config.tabInactiveColor = c }
                case "inactive-gradient":
                    for (k, v) in keyValues(parts) where k == "to" || k == "from" {
                        if let c = parseColor(v) { config.tabInactiveColor = c }
                    }
                case "urgent-color": if let c = nodeColor(parts) { config.tabUrgentColor = c }
                case "urgent-gradient":
                    for (k, v) in keyValues(parts) where k == "to" || k == "from" {
                        if let c = parseColor(v) { config.tabUrgentColor = c }
                    }
                default: print("[config] unknown tab-indicator key: \(parts[0])")
                }
            }
        }

        func parsePresetHeights() {
            while let t = advance() {
                if t == "\n" || t == ";" { continue }
                if t == "}" { return }
                let parts = statement(firstToken: t)
                // `fixed <px>` too: niri's preset_window_heights is the same
                // Vec<PresetSize> as the widths, and a config copied from it
                // used to leave the list EMPTY - with no fallback, unlike the
                // widths - so switch-preset-window-height did nothing for the
                // whole session and said nothing at press time either.
                if parts.first == "proportion", let v = Double(parts.last ?? "") {
                    config.presetWindowHeightSizes.append(.proportion(CGFloat(v)))
                } else if parts.first == "fixed", let px = Double(parts.last ?? "") {
                    config.presetWindowHeightSizes.append(.fixed(CGFloat(px)))
                } else {
                    print("[config] unknown preset-window-heights line: \(parts.joined(separator: " "))")
                }
            }
        }

        func parsePresetWidths() {
            while let t = advance() {
                if t == "\n" || t == ";" { continue }
                if t == "}" { return }
                let parts = statement(firstToken: t)
                if parts.first == "proportion", let v = Double(parts.last ?? "") {
                    config.presetColumnSizes.append(.proportion(CGFloat(v)))
                } else if parts.first == "fixed", let px = Double(parts.last ?? "") {
                    // niri's fixed presets are pixels; the model speaks
                    // proportions, and the conversion is exact both ways -
                    // but the ORDER is preserved, so the cycle is the one
                    // that was written.
                    config.presetColumnSizes.append(.fixed(CGFloat(px)))
                } else {
                    print("[config] unknown preset-column-widths line: \(parts.joined(separator: " "))")
                }
            }
        }

        func parseBorder() {
            // niri's special case (niri-config/src/lib.rs:246-280): a
            // `border {}` block with neither `on` nor `off` turns the border
            // ON - the one section in niri where mere presence enables. An
            // explicit `off` below undoes this.
            config.borderOn = true
            while let t = advance() {
                if t == "\n" || t == ";" { continue }
                if t == "}" { return }
                let parts = statement(firstToken: t)
                switch parts[0] {
                case "off": config.borderOn = false
                case "on": config.borderOn = true
                case "width": if let v = Double(parts.last ?? "") { config.borderWidth = CGFloat(v) }
                case "inactive-color":
                    if let c = nodeColor(parts) { config.borderInactiveColor = c }
                // niri draws the border on the ACTIVE window too (it is a
                // separate decoration from the focus ring); rejecting these
                // keys refused valid upstream config.
                case "active-color":
                    if let c = nodeColor(parts) { config.borderActiveColor = c }
                case "active-gradient":
                    // One flat colour: the overlay is a plain stroke, so the
                    // gradient's first stop is what it can honour.
                    for (k, v) in keyValues(parts) where k == "from" {
                        if let c = parseColor(v) { config.borderActiveColor = c }
                    }
                default: print("[config] unknown border key: \(parts[0])")
                }
            }
        }

        func parseInput() {
            while let t = advance() {
                if t == "\n" || t == ";" { continue }
                if t == "}" { return }
                let parts = statement(firstToken: t)
                switch parts[0] {
                // niri's real form is input { keyboard { xkb { layout } } }
                // (input.rs:131-144); binds-layout/keyboard-layout were
                // invented names for the same pin.
                case "keyboard":
                    if next() == "{" {
                        i += 1
                        while let kb = advance() {
                            if kb == "\n" || kb == ";" { continue }
                            if kb == "}" { break }
                            if kb == "xkb", next() == "{" {
                                i += 1
                                while let xkb = advance() {
                                    if xkb == "\n" || xkb == ";" { continue }
                                    if xkb == "}" { break }
                                    let xkbParts = statement(firstToken: xkb)
                                    if xkbParts[0] == "layout" {
                                        // niri's layout is a comma-separated
                                        // xkb list; the FIRST one is what
                                        // binds resolve against.
                                        let first = (xkbParts.last ?? "").split(separator: ",")
                                            .first.map(String.init)
                                        config.bindsLayout = first
                                        NigiriConfig.refreshLayoutKeyCodes(preferring: first)
                                    }
                                    // variant/options/model: xkb details
                                    // with no macOS counterpart.
                                }
                            } else if kb != "{" {
                                // repeat-delay/repeat-rate/numlock/track-layout:
                                // the system owns these on macOS.
                                _ = statement(firstToken: kb)
                            }
                        }
                    }
                case "mod-key":
                    // Read in the same pre-pass as binds-layout would want,
                    // but the input section is parsed before binds in every
                    // config niri ships, and a late declaration warns rather
                    // than silently applying to half the binds.
                    if let mods = NigiriConfig.parseModifiers([(parts.last ?? "").lowercased()]) {
                        config.modKey = mods
                        NigiriConfig.modKey = mods
                        if !config.binds.isEmpty {
                            print(
                                "[config] mod-key declared after binds{}: the ones already parsed kept the old one"
                            )
                        }
                    } else {
                        print("[config] unknown mod-key: \(parts.last ?? "")")
                    }
                // niri's Flag type (utils.rs:17-24): present = true,
                // unless the argument is an explicit false - which used to
                // be ignored, leaving the flag stuck on.
                case "workspace-auto-back-and-forth":
                    config.workspaceAutoBackAndForth = parts.dropFirst().first != "false"
                case "focus-follows-mouse":
                    config.focusFollowsMouse = parts.dropFirst().first != "false"
                case "warp-mouse-to-focus":
                    config.warpMouseToFocus = parts.dropFirst().first != "false"
                default:
                    if next() == "{" {
                        i += 1; skipUnknownBlock(named: parts[0], context: "input section")
                    } else {
                        print("[config] unknown input key: \(parts[0])")
                    }
                }
            }
        }

        // niri's gestures.hot_corners (niri-config/gestures.rs, HotCorners):
        // bare boolean children. When no corner is set explicitly, top-left
        // is the default (niri.rs, is_inside_hot_corner).
        func parseHotCorners() {
            while let t = advance() {
                if t == "\n" || t == ";" { continue }
                if t == "}" { return }
                switch t {
                case "off": config.hotCornersOff = true
                case "top-left": config.hotCornerTopLeft = true
                case "top-right": config.hotCornerTopRight = true
                case "bottom-left": config.hotCornerBottomLeft = true
                case "bottom-right": config.hotCornerBottomRight = true
                default: print("[config] unknown hot-corners key: \(t)")
                }
            }
        }

        func parseGestures() {
            while let t = advance() {
                if t == "\n" || t == ";" { continue }
                if t == "}" { return }
                // Block children first: niri's real gestures section is made
                // of them (hot-corners, dnd-edge-*), and an unskipped unknown
                // block used to be consumed as statements - corrupting the
                // parse of everything after it in a genuine niri config.
                if next() == "{" {
                    i += 1
                    switch t {
                    case "hot-corners": parseHotCorners()
                    case "dnd-edge-view-scroll", "dnd-edge-workspace-switch":
                        // Real niri children (gestures.rs); drag-and-drop
                        // edge scrolling has no macOS counterpart yet.
                        skipUnknownBlock(named: t, context: "gestures (no macOS counterpart)")
                    default:
                        skipUnknownBlock(named: t, context: "gestures section")
                    }
                    continue
                }
                // niri's gestures section has NO per-direction action
                // keys: the 3-/4-finger swipes are hardcoded continuous
                // gestures (input/mod.rs), never configurable. The
                // three-finger-*/four-finger-*/mouse-* vocabulary was
                // invented here (audit CFG-7) and is gone.
                let parts = statement(firstToken: t)
                print("[config] unknown gestures key: \(parts[0])")
            }
        }

        func parseLayout() {
            while let t = advance() {
                if t == "\n" || t == ";" { continue }
                if t == "}" { return }
                switch t {
                // `gaps` only: the `gap` alias was invented vocabulary.
                // Range per upstream's FloatOrInt<0, 65535> (layout.rs:123).
                case "gaps":
                    let parts = statement(firstToken: t)
                    if let v = Double(parts.last ?? ""), (0...65535).contains(v) {
                        config.gap = CGFloat(v)
                    } else {
                        print("[config] gaps must be between 0 and 65535")
                    }
                case "preset-column-widths":
                    if next() == "{" { i += 1; parsePresetWidths() }
                case "tab-indicator":
                    if next() == "{" { i += 1; parseTabIndicator() }
                case "struts":
                    if next() == "{" {
                        i += 1
                        parseInsetBlock { key, value in
                            switch key {
                            case "left": config.struts.left = value
                            case "right": config.struts.right = value
                            case "top": config.struts.top = value
                            case "bottom": config.struts.bottom = value
                            default: break
                            }
                        }
                    }
                case "center-focused-column":
                    let parts = statement(firstToken: t)
                    switch parts.last ?? "" {
                    case "always": config.centerFocusedColumn = .always
                    case "on-overflow": config.centerFocusedColumn = .onOverflow
                    case "never": config.centerFocusedColumn = .never
                    default:
                        // niri errors on an unknown value; silently falling
                        // to `never` rewrote a typo into a policy change.
                        print("[config] center-focused-column: never/always/on-overflow")
                    }
                // niri's Flag type (utils.rs:17-24): an explicit false
                // argument turns the flag off; presence alone is true.
                case "always-center-single-column":
                    let parts = statement(firstToken: t)
                    config.alwaysCenterSingleColumn = parts.dropFirst().first != "false"
                case "empty-workspace-above-first":
                    let parts = statement(firstToken: t)
                    config.emptyWorkspaceAboveFirst = parts.dropFirst().first != "false"
                case "default-column-display":
                    let parts = statement(firstToken: t)
                    config.defaultColumnTabbed = (parts.last == "tabbed")
                case "shadow":
                    if next() == "{" { i += 1; parseShadow() }
                case "insert-hint":
                    if next() == "{" { i += 1; parseInsertHint() }
                case "preset-window-heights":
                    if next() == "{" { i += 1; config.presetWindowHeightSizes = []; parsePresetHeights() }
                case "default-column-width":
                    if let v = inlineDefaultWidth() { config.defaultColumnWidth = v }
                case "focus-ring":
                    if next() == "{" { i += 1; parseFocusRing() }
                case "border":
                    if next() == "{" { i += 1; parseBorder() }
                default:
                    if next() == "{" {
                        i += 1; skipUnknownBlock(named: t, context: "layout section")
                    } else {
                        print("[config] unknown layout key: \(t)"); _ = statement(firstToken: t)
                    }
                }
            }
        }

        func parseWindowRule() {
            var rule = Rule()
            while let t = advance() {
                if t == "\n" || t == ";" { continue }
                if t == "}" { break }
                switch t {
                case "match", "exclude":
                    let parts = statement(firstToken: t)
                    var matcher = Matcher()
                    for (k, v) in keyValues(parts) {
                        switch k {
                        case "app-id", "app": matcher.app = Regex(v)
                        case "title": matcher.title = Regex(v)
                        case "is-active": matcher.isActive = (v == "true")
                        case "is-focused": matcher.isFocused = (v == "true")
                        case "is-active-in-column": matcher.isActiveInColumn = (v == "true")
                        case "is-urgent": matcher.isUrgent = (v == "true")
                        case "is-floating": matcher.isFloating = (v == "true")
                        case "at-startup": matcher.atStartup = (v == "true")
                        default: print("[config] unknown window-rule matcher: \(k)")
                        }
                    }
                    if t == "match" { rule.matchers.append(matcher) } else { rule.excludes.append(matcher) }
                case "open-floating":
                    let parts = statement(firstToken: t)
                    rule.openFloating = parts.last == "true"
                case "open-on-workspace":
                    // A workspace NAME, always (window_rule.rs:25-26) - a
                    // numeric-looking name like "2" is still a name. The
                    // integer-index reading was invented.
                    let parts = statement(firstToken: t)
                    let arg = parts.dropFirst().first ?? ""
                    if !arg.isEmpty { rule.openOnWorkspaceName = arg }
                case "open-maximized":
                    let parts = statement(firstToken: t)
                    rule.openMaximized = parts.last == "true"
                case "open-fullscreen":
                    let parts = statement(firstToken: t)
                    rule.openFullscreen = parts.last == "true"
                case "default-floating-position":
                    // niri's syntax is x=... y=... relative-to=...
                    // (window_rule.rs); the bare "x y" form is kept for
                    // configs already written against it. The property form
                    // used to be dropped SILENTLY (compactMap over "x=100").
                    let parts = statement(firstToken: t)
                    let props = Dictionary(
                        uniqueKeysWithValues: keyValues(parts).map { ($0.0, $0.1) })
                    if let x = props["x"].flatMap(Double.init),
                        let y = props["y"].flatMap(Double.init)
                    {
                        rule.defaultFloatingPosition = CGPoint(x: x, y: y)
                        rule.defaultFloatingPositionRelativeTo = props["relative-to"]
                    } else {
                        let nums = parts.dropFirst().compactMap { Double($0) }
                        if nums.count == 2 {
                            rule.defaultFloatingPosition = CGPoint(x: nums[0], y: nums[1])
                        }
                    }
                case "min-width":
                    let parts = statement(firstToken: t)
                    rule.minWidthPx = Double(parts.last ?? "").map { CGFloat($0) }
                case "max-width":
                    let parts = statement(firstToken: t)
                    rule.maxWidthPx = Double(parts.last ?? "").map { CGFloat($0) }
                case "default-column-width":
                    rule.defaultWidth = inlineDefaultWidth()
                default:
                    // A block value (niri's per-rule border{}, shadow{},
                    // focus-ring{}...) must be skipped as a BLOCK: consumed
                    // as statements it corrupted the parse of every rule
                    // after it in a genuine niri config.
                    if next() == "{" {
                        i += 1
                        skipUnknownBlock(named: t, context: "window-rule key")
                    } else {
                        print("[config] unknown window-rule key: \(t)")
                        _ = statement(firstToken: t)
                    }
                }
            }
            config.rules.append(rule)
        }

        func parseBinds() {
            // niri rejects a duplicate key WITHIN one binds{} section as a
            // config error (binds.rs:776-812) - reported and dropped here,
            // keeping the first; ACROSS config parts a later bind REPLACES
            // the earlier one with the same key (lib.rs:219-231). It used
            // to accumulate both, so one press fired two handlers.
            var seenInSection: Set<String> = []
            while let t = advance() {
                if t == "\n" || t == ";" { continue }
                if t == "}" { return }
                // niri bind shape: Combo [prop=val ...] { action args...; }
                // Read any per-bind properties between the combo and the {.
                var props: [String] = []
                // Stops at the line end: unbounded, a bind written without
                // braces swallowed tokens until the NEXT bind's "{" and stole
                // its action.
                while let n = next(), n != "{", n != "\n", n != ";" {
                    if n == "\n" || n == ";" { i += 1; continue }
                    props.append(n); i += 1
                }
                guard next() == "{" else {
                    print("[config] bind \"\(t)\" needs { action; }")
                    continue
                }
                i += 1
                var actionParts: [String] = []
                while let a = advance(), a != "}" {
                    if a == "\n" || a == ";" { continue }
                    actionParts.append(a)
                }
                // niri writes wheel bindings as ordinary binds -
                // `Mod+WheelScrollDown { ... }` - so they live here, not in
                // a section of our own invention. A config copied from niri
                // has to work as written.
                if let mouseKey = mouseBindingKey(for: t) {
                    let rejoinedMouse = actionParts.joined(separator: " ")
                    if !rejoinedMouse.isEmpty { config.mouseBindings[mouseKey] = rejoinedMouse }
                    continue
                }
                if let wheelKey = wheelBindingKey(for: t) {
                    let rejoinedWheel = actionParts.joined(separator: " ")
                    if !rejoinedWheel.isEmpty { config.wheelBindings[wheelKey] = rejoinedWheel }
                    continue
                }
                guard let (keyCode, mods) = parseCombo(t) else {
                    print("[config] cannot parse combo: \(t)")
                    continue
                }
                guard !actionParts.isEmpty else {
                    print("[config] bind \(t) has no action")
                    continue
                }
                // Re-quote before joining: the tokenizer drops the quote
                // characters, so `spawn open -a "Google Chrome"` collapsed to
                // `open -a Google Chrome`, which opens nothing. A token that
                // contains whitespace was quoted in the config and has to
                // stay one argument.
                let rejoined = actionParts.map { part -> String in
                    guard part.contains(" ") || part.contains("\t") else { return part }
                    return "'" + part.replacingOccurrences(of: "'", with: "'\\''") + "'"
                }.joined(separator: " ")
                if mods.isEmpty {
                    print(
                        "[config] bind \(t) has no modifier: that key is taken system-wide")
                }
                var bind = Bind(combo: t, keyCode: keyCode, modifiers: mods, action: rejoined)
                for p in props {
                    let kv = p.split(separator: "=", maxSplits: 1).map(String.init)
                    guard kv.count == 2 else { continue }
                    switch kv[0] {
                    case "cooldown-ms": bind.cooldownMs = Int(kv[1])
                    // niri: hotkey-overlay-title=null HIDES the bind from
                    // the overlay. It used to be stored verbatim, so the
                    // overlay listed the literal word "null" as the title.
                    case "hotkey-overlay-title":
                        if kv[1] == "null" { bind.hiddenFromOverlay = true } else { bind.title = kv[1] }
                    case "repeat": bind.repeats = (kv[1] == "true")
                    default: break  // allow-when-locked / allow-inhibiting: inert on macOS
                    }
                }
                if seenInSection.contains(t) {
                    print(
                        "[config] duplicate bind \(t) in one binds section - niri rejects this; keeping the first"
                    )
                    continue
                }
                seenInSection.insert(t)
                config.binds.removeAll { $0.combo == t }
                config.binds.append(bind)
            }
        }

        // niri rejects a section declared twice within one FILE
        // (lib.rs:158-177); across config parts the sections merge. The
        // includes are expanded inline before this loop, so the file
        // boundary is gone - merge like parts do, but say so, because the
        // single-file duplicate niri would reject is invisible otherwise.
        var seenSections: Set<String> = []
        let singletonSections: Set<String> = [
            "layout", "input", "overview", "animations", "gestures",
            "hotkey-overlay", "config-notification", "environment",
        ]
        while let t = advance() {
            if t == "\n" || t == ";" { continue }
            if singletonSections.contains(t), !seenSections.insert(t).inserted {
                print(
                    "[config] section \(t) appears more than once - merging like niri's config parts (niri rejects a duplicate within one file)"
                )
            }
            switch t {
            case "layout": if next() == "{" { i += 1; parseLayout() }
            case "binds": if next() == "{" { i += 1; parseBinds() }
            case "window-rule": if next() == "{" { i += 1; parseWindowRule() }
            case "input": if next() == "{" { i += 1; parseInput() }
            case "spawn-at-startup":
                // niri's spawn-at-startup is argv, no shell (misc.rs) -
                // joining into one /bin/sh line collapsed quoted args
                // ("Google Chrome" became two shell words) and let a missing
                // binary fail INSIDE sh, undetectably.
                let parts = statement(firstToken: t)
                let argv = Array(parts.dropFirst())
                if !argv.isEmpty { config.spawnAtStartup.append(argv) }
            case "spawn-sh-at-startup":
                // niri's shell twin (misc.rs), previously unparsed.
                let parts = statement(firstToken: t)
                let command = parts.dropFirst().joined(separator: " ")
                if !command.isEmpty { config.spawnShAtStartup.append(command) }
            case "workspace":
                let parts = statement(firstToken: t)
                if let name = parts.dropFirst().first, !name.isEmpty { config.namedWorkspaces.append(name) }
            case "gestures":
                if next() == "{" { i += 1; parseGestures() }
            case "overview":
                if next() == "{" { i += 1; parseOverview() }
            case "hotkey-overlay":
                // misc.rs:67-85. skip-at-startup and hide-not-bound are
                // niri's Flag type: presence = true, explicit false = off.
                if next() == "{" {
                    i += 1
                    while let inner = advance() {
                        if inner == "\n" || inner == ";" { continue }
                        if inner == "}" { break }
                        let parts = statement(firstToken: inner)
                        switch parts[0] {
                        case "skip-at-startup":
                            config.hotkeyOverlaySkipAtStartup = parts.dropFirst().first != "false"
                        case "hide-not-bound":
                            config.hotkeyOverlayHideNotBound = parts.dropFirst().first != "false"
                        default: print("[config] unknown hotkey-overlay key: \(parts[0])")
                        }
                    }
                }
            case "layer-rule":
                // Layer rules are Wayland layer-shell vocabulary; the one
                // knob with a rendering counterpart here is
                // place-within-backdrop (what puts the wallpaper behind
                // niri's overview). The rest of the block is skipped.
                if next() == "{" {
                    i += 1
                    var depth = 1
                    while let inner = advance(), depth > 0 {
                        if inner == "{" { depth += 1 }
                        if inner == "}" { depth -= 1 }
                        if inner == "place-within-backdrop", let v = advance(), v == "true" {
                            config.backdropShowsWallpaper = true
                        }
                    }
                }
            case "config-notification":
                // niri's config-notification { disable-failed } (misc.rs:
                // 87-102) - the section used to fall to "unknown".
                if next() == "{" {
                    i += 1
                    while let inner = advance() {
                        if inner == "\n" || inner == ";" { continue }
                        if inner == "}" { break }
                        let parts = statement(firstToken: inner)
                        if parts[0] == "disable-failed" {
                            config.configNotificationDisableFailed = parts.dropFirst().first != "false"
                        } else {
                            print("[config] unknown config-notification key: \(parts[0])")
                        }
                    }
                }
            case "environment":
                if next() == "{" { i += 1; parseEnvironment() }
            case "screenshot-path":
                // `screenshot-path null` disables saving to disk
                // (misc.rs:57, default-config.kdl:293-294); it used to be
                // stored as the literal path "null".
                let parts = statement(firstToken: t)
                if let p = parts.last { config.screenshotPath = p == "null" ? "" : p }
            case "animations":
                if next() == "{" { i += 1; parseAnimations() }
            default:
                if next() == "{" {
                    i += 1; skipUnknownBlock(named: t, context: "top-level section")
                } else {
                    // A section with arguments before its brace - niri's
                    // `output "name" { ... }` - eats the argument line as a
                    // statement, but the block still has to be skipped AS A
                    // BLOCK: parsed as top-level lines, its children spilled
                    // into the config (seen live with outputs.kdl - the same
                    // corruption class as the gestures fix).
                    let parts = statement(firstToken: t)
                    if parts.last == "{" {
                        skipUnknownBlock(named: t, context: "top-level section")
                    } else if next() == "{" {
                        i += 1
                        skipUnknownBlock(named: t, context: "top-level section")
                    } else {
                        print("[config] unknown top-level line: \(t)")
                    }
                }
            }
        }
        // Only when the WHOLE list is empty, like niri (layout.rs): it used
        // to check the proportions alone, so a fixed-only list got the three
        // defaults injected on top of it.
        if config.presetColumnSizes.isEmpty {
            config.presetColumnSizes = [.proportion(1.0 / 3.0), .proportion(0.5), .proportion(2.0 / 3.0)]
        }
        if config.presetWindowHeightSizes.isEmpty {
            config.presetWindowHeightSizes = [
                .proportion(1.0 / 3.0), .proportion(0.5), .proportion(2.0 / 3.0),
            ]
        }
        return config
    }

    // First run: materialize the defaults as a real, commented file, so
    // "edit the config" never starts from a blank page. Everything in it
    // reproduces the previous hardcoded behavior exactly.
}
