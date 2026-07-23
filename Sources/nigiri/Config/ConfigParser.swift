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
            // A raw string only ever STARTS a token: `r` glued to the end of an
            // identifier is just an identifier.
            if current.isEmpty, c == "r" || c == "#", let (value, next) = readRawString(chars, from: i) {
                current += value
                // An empty raw string still produced a token: "" is a value.
                if value.isEmpty { tokens.append("") }
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
    // niri's `include "other.kdl"`: expand includes textually before
    // tokenizing, so nested sections parse as if inlined. Paths are
    // relative to the including file's directory; a depth cap and a
    // visited set stop runaway/cyclic includes.
    static func expandIncludes(
        _ text: String, baseDir: String, depth: Int = 0, visited: inout Set<String>
    ) -> String {
        guard depth < 20 else { return "" }
        var out: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("include ") || trimmed.hasPrefix("include\t") {
                // include "path" - the path is the FIRST double-quoted token.
                // Extract it by delimiters, not by trimming quotes off both
                // ends: niri's real config writes `include "x.kdl" //comment`,
                // and stripping surrounding quotes leaves `x.kdl" //comment`.
                let inner = trimmed.dropFirst("include".count).trimmingCharacters(in: .whitespaces)
                guard let open = inner.firstIndex(of: "\""),
                    let close = inner[inner.index(after: open)...].firstIndex(of: "\"")
                else {
                    print("[config] malformed include: \(inner)")
                    continue
                }
                let rel = String(inner[inner.index(after: open)..<close])
                let resolved =
                    (rel as NSString).isAbsolutePath ? rel : (baseDir as NSString).appendingPathComponent(rel)
                let real =
                    (try? FileManager.default.destinationOfSymbolicLink(atPath: resolved)).map {
                        ($0 as NSString).isAbsolutePath
                            ? $0 : (baseDir as NSString).appendingPathComponent($0)
                    } ?? resolved
                if visited.contains(real) { print("[config] skipping already-included \(rel)"); continue }
                visited.insert(real)
                guard let included = try? String(contentsOfFile: real, encoding: .utf8) else {
                    print("[config] include not found: \(rel)")
                    continue
                }
                out.append(
                    expandIncludes(
                        included, baseDir: (real as NSString).deletingLastPathComponent, depth: depth + 1,
                        visited: &visited))
            } else {
                out.append(String(line))
            }
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
        var visited: Set<String> = [realPath]
        let text = expandIncludes(
            rawText, baseDir: (realPath as NSString).deletingLastPathComponent, visited: &visited)
        return parse(text)
    }

    // The parser proper, over already-included text. Split out from load()
    // so it can be exercised without a file on disk.
    static func parse(_ text: String) -> NigiriConfig {
        // What the keyboard types right now - resolved before any combo is
        // parsed (see NigiriConfig.layoutKeyCodes). binds-layout is read in a
        // pre-pass: parseCombo resolves at parse time, so a pin declared
        // AFTER the binds block would otherwise be ignored for every bind.
        let pinnedLayout = tokenize(text).enumerated().first { $0.element == "binds-layout" }
            .flatMap { idx, _ -> String? in
                let all = tokenize(text)
                return idx + 1 < all.count ? all[idx + 1] : nil
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
        func inlineProportion() -> CGFloat? {
            guard next() == "{" else { return nil }
            i += 1
            var value: CGFloat?
            while let t = advance(), t != "}" {
                if t == "proportion", let raw = advance(), let v = Double(raw) { value = CGFloat(v) }
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
                        // angle: only niri's 45 is implemented; stated, not silent
                        if k == "angle", v != "45" {
                            print("[config] active-gradient angle: only 45 is implemented")
                        }
                    }
                case "active-color":
                    if let c = parseColor(parts.last ?? "") { config.ringFrom = c; config.ringTo = c }
                case "inactive-color":
                    if let c = parseColor(parts.last ?? "") { config.ringInactiveColor = c }
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
                    if let v = Double(parts.last ?? "") { config.animationSlowdown = max(0.01, v) }
                    continue
                default: break
                }
                // A named animation block.
                guard next() == "{" else {
                    print("[config] unknown animations key: \(t)")
                    _ = statement(firstToken: t)
                    continue
                }
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
                        var stiffness: Double = 1000
                        var damping: Double = 1
                        var epsilon: Double = 0.0001
                        for (k, v) in keyValues(parts) {
                            switch k {
                            case "stiffness": stiffness = Double(v) ?? stiffness
                            case "damping-ratio": damping = Double(v) ?? damping
                            case "epsilon": epsilon = Double(v) ?? epsilon
                            default: break
                            }
                        }
                        curve = .spring(Spring(stiffness: stiffness, dampingRatio: damping, epsilon: epsilon))
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
                if isOff {
                    config.animations[t] = .off
                } else if let curve {
                    config.animations[t] = curve
                } else if let durationMs {
                    config.animations[t] = .easing(
                        Easing(durationMs: durationMs, curve: namedCurve ?? .easeOutCubic))
                } else if namedCurve != nil {
                    // A curve with no duration cannot become an animation:
                    // there is no default-duration table here (niri's lives in
                    // its own Default impls). Say so instead of dropping the
                    // whole block without a word.
                    print("[config] \(t): curve without duration-ms, ignored")
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
                    let parts = statement(firstToken: t)
                    if let v = Double(parts.last ?? "") {
                        config.overviewZoom = CGFloat(min(0.95, max(0.1, v)))
                    }
                case "backdrop-color":
                    let parts = statement(firstToken: t)
                    if let c = parseColor(parts.last ?? "") {
                        config.overviewBackdrop = c
                        config.overviewBackdropSet = true
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
                case "color": if let c = parseColor(parts.last ?? "") { config.insertHintColor = c }
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
            config.shadowOn = true
            while let t = advance() {
                if t == "\n" || t == ";" { continue }
                if t == "}" { return }
                let parts = statement(firstToken: t)
                switch parts[0] {
                case "off": config.shadowOn = false
                case "on": config.shadowOn = true
                case "softness": if let v = Double(parts.last ?? "") { config.shadowSoftness = CGFloat(v) }
                case "spread": break  // folded into softness by CALayer's model
                case "offset":
                    var dx: CGFloat = 0
                    var dy: CGFloat = 0
                    for (k, v) in keyValues(parts) {
                        if k == "x", let n = Double(v) { dx = CGFloat(n) }
                        if k == "y", let n = Double(v) { dy = CGFloat(n) }
                    }
                    config.shadowOffset = CGSize(width: dx, height: dy)
                case "color": if let c = parseColor(parts.last ?? "") { config.shadowColor = c }
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
                if parts.count >= 2 { config.environment[parts[0]] = parts[1] }
            }
        }

        func parseTabIndicator() {
            while let t = advance() {
                if t == "\n" || t == ";" { continue }
                if t == "}" { return }
                let parts = statement(firstToken: t)
                switch parts[0] {
                // A single strip can't hold a gradient the way niri's can;
                // the `to` colour is the visible one, so that is what a
                // segment takes.
                case "active-gradient":
                    for (k, v) in keyValues(parts) where k == "to" || k == "from" {
                        if let c = parseColor(v) { config.tabActiveColor = c }
                    }
                case "active-color": if let c = parseColor(parts.last ?? "") { config.tabActiveColor = c }
                case "inactive-color": if let c = parseColor(parts.last ?? "") { config.tabInactiveColor = c }
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
            while let t = advance() {
                if t == "\n" || t == ";" { continue }
                if t == "}" { return }
                let parts = statement(firstToken: t)
                switch parts[0] {
                case "off": config.borderWidth = 0
                case "width": if let v = Double(parts.last ?? "") { config.borderWidth = CGFloat(v) }
                case "inactive-color":
                    if let c = parseColor(parts.last ?? "") { config.borderInactiveColor = c }
                case "active-color", "active-gradient":
                    print("[config] border: the ACTIVE window wears the focus-ring - configure that instead")
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
                case "binds-layout", "keyboard-layout":
                    config.bindsLayout = parts.last
                    NigiriConfig.refreshLayoutKeyCodes(preferring: parts.last)
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
                case "focus-follows-mouse": config.focusFollowsMouse = true
                case "warp-mouse-to-focus": config.warpMouseToFocus = true
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
                let parts = statement(firstToken: t)
                let action = parts.dropFirst().joined(separator: " ")
                switch parts[0] {
                case "mouse-one-finger-left": config.gestureMouseOne[.left] = action
                case "mouse-one-finger-right": config.gestureMouseOne[.right] = action
                case "mouse-one-finger-up": config.gestureMouseOne[.up] = action
                case "mouse-one-finger-down": config.gestureMouseOne[.down] = action
                case "mouse-two-finger-left": config.gestureMouseTwo[.left] = action
                case "mouse-two-finger-right": config.gestureMouseTwo[.right] = action
                case "mouse-two-finger-up": config.gestureMouseTwo[.up] = action
                case "mouse-two-finger-down": config.gestureMouseTwo[.down] = action
                case "four-finger-left": config.gestureFourLeft = action
                case "four-finger-right": config.gestureFourRight = action
                case "four-finger-up": config.gestureFourUp = action
                case "four-finger-down": config.gestureFourDown = action
                case "three-finger-left": config.gestureSwipeLeft = action
                case "three-finger-right": config.gestureSwipeRight = action
                case "three-finger-up": config.gestureSwipeUp = action
                case "three-finger-down": config.gestureSwipeDown = action
                default: print("[config] unknown gestures key: \(parts[0])")
                }
            }
        }

        func parseWheel() {
            while let t = advance() {
                if t == "\n" || t == ";" { continue }
                if t == "}" { return }
                let parts = statement(firstToken: t)
                let action = parts.dropFirst().joined(separator: " ")
                guard !action.isEmpty else { continue }
                // Through the same canonicalizer as the niri-shaped
                // `Mod+WheelScrollDown` binds: this section is written with
                // the internal key directly ("mod-shift-down"), and hand-
                // written keys are exactly where a different modifier order
                // slips in and silently never fires.
                let written = parts[0].lowercased().split(separator: "-").map(String.init)
                guard let direction = written.last,
                    ["up", "down", "left", "right"].contains(direction)
                else {
                    print("[config] wheel: \(parts[0]) does not end in up/down/left/right - ignored")
                    continue
                }
                let mods = Set(written.dropLast().compactMap { NigiriConfig.canonicalModifier($0) })
                config.wheelBindings[NigiriConfig.bindingKey(mods: mods.union(["mod"]), suffix: direction)] =
                    action
            }
        }

        func parseLayout() {
            while let t = advance() {
                if t == "\n" || t == ";" { continue }
                if t == "}" { return }
                switch t {
                case "gaps", "gap":
                    let parts = statement(firstToken: t)
                    if let v = Double(parts.last ?? "") { config.gap = CGFloat(v) }
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
                    default: config.centerFocusedColumn = .never
                    }
                case "always-center-single-column": config.alwaysCenterSingleColumn = true
                case "empty-workspace-above-first": config.emptyWorkspaceAboveFirst = true
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
                    if let v = inlineProportion() { config.defaultColumnWidth = v }
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
                        case "is-active", "is-focused": matcher.isActive = (v == "true")
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
                    let parts = statement(firstToken: t)
                    let arg = parts.dropFirst().first ?? ""
                    if let n = Int(arg) {
                        rule.openOnWorkspace = n
                    } else if !arg.isEmpty {
                        rule.openOnWorkspaceName = arg
                    }
                case "open-maximized":
                    let parts = statement(firstToken: t)
                    rule.openMaximized = parts.last == "true"
                case "open-fullscreen":
                    let parts = statement(firstToken: t)
                    rule.openFullscreen = parts.last == "true"
                case "default-floating-position":
                    let parts = statement(firstToken: t)
                    let nums = parts.dropFirst().compactMap { Double($0) }
                    if nums.count == 2 { rule.defaultFloatingPosition = CGPoint(x: nums[0], y: nums[1]) }
                case "min-width":
                    let parts = statement(firstToken: t)
                    rule.minWidthPx = Double(parts.last ?? "").map { CGFloat($0) }
                case "max-width":
                    let parts = statement(firstToken: t)
                    rule.maxWidthPx = Double(parts.last ?? "").map { CGFloat($0) }
                case "default-column-width":
                    rule.defaultWidthProportion = inlineProportion()
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
                    default: break  // repeat / allow-when-locked / allow-inhibiting: inert on macOS
                    }
                }
                config.binds.append(bind)
            }
        }

        while let t = advance() {
            if t == "\n" || t == ";" { continue }
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
            case "environment":
                if next() == "{" { i += 1; parseEnvironment() }
            case "screenshot-path":
                let parts = statement(firstToken: t)
                if let p = parts.last { config.screenshotPath = p }
            case "animations":
                if next() == "{" { i += 1; parseAnimations() }
            case "wheel":
                if next() == "{" { i += 1; parseWheel() }
            default:
                if next() == "{" {
                    i += 1; skipUnknownBlock(named: t, context: "top-level section")
                } else {
                    print("[config] unknown top-level line: \(t)"); _ = statement(firstToken: t)
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
