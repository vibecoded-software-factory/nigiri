import AppKit
import ApplicationServices

// `nigiri selftest` - the pure logic (geometry, spring, config parsing)
// checked without a WindowServer, an AX grant, or any window on screen.
//
// Not XCTest: this machine has Command Line Tools without Xcode, where the
// XCTest module does not exist, so a .testTarget cannot build at all. A
// subcommand of the binary itself needs no extra target, no public
// annotations, and runs the same code the window manager runs.
//
// Every case below states the behaviour it locks down; the ones marked
// REGRESSION reproduce a bug that actually shipped.
enum SelfTest {
    nonisolated(unsafe) static var failures: [String] = []
    nonisolated(unsafe) static var checks = 0

    static func expect(_ condition: Bool, _ what: String) {
        checks += 1
        if !condition { failures.append(what) }
    }
    static func expectEqual(_ a: CGFloat, _ b: CGFloat, _ what: String, accuracy: CGFloat = 0.001) {
        checks += 1
        if abs(a - b) > accuracy { failures.append("\(what): \(a) != \(b)") }
    }
    static func expectEqual<T: Equatable>(_ a: T, _ b: T, _ what: String) {
        checks += 1
        if a != b { failures.append("\(what): \(a) != \(b)") }
    }

    // The measured machine: 1470x922 usable, 10px gaps => usableWidth 1450.
    static let screen = CGRect(x: 0, y: 34, width: 1470, height: 922)
    static let usableWidth: CGFloat = 1450

    static func column(_ proportion: CGFloat, minWidth: CGFloat? = nil) -> Column {
        let c = Column()
        c.widthProportion = proportion
        c.cachedMinWidth = minWidth
        return c
    }
    static func window() -> ManagedWindow {
        ManagedWindow(axElement: AXUIElementCreateApplication(getpid()), pid: getpid(), title: "w")
    }

    static func run() -> Never {
        ColumnLayoutEngine.gap = 10

        // --- column placement -------------------------------------------
        // REGRESSION: a column's width is a property of the column ALONE.
        // The formula that split the leftover space among the current
        // columns agreed with niri at exactly two columns and drifted
        // everywhere else, so opening an unrelated window resized the ones
        // already on screen.
        let two = ColumnLayoutEngine.columnPlacements(
            columns: [column(0.5), column(0.5)],
            usableWidth: usableWidth, maximizedIndex: nil)
        let four = ColumnLayoutEngine.columnPlacements(
            columns: (0..<4).map { _ in column(0.5) },
            usableWidth: usableWidth, maximizedIndex: nil)
        expectEqual(two[0].width, 720, "dos columnas de 1/2 miden 720")
        expectEqual(two[1].x, 730, "la segunda arranca despues del gap")
        for i in 0..<2 {
            expectEqual(four[i].width, two[i].width, "el ancho no depende de cuantas columnas hay")
            expectEqual(four[i].x, two[i].x, "la x no depende de cuantas columnas hay")
        }

        let thirds = ColumnLayoutEngine.columnPlacements(
            columns: (0..<3).map { _ in column(1.0 / 3) },
            usableWidth: usableWidth, maximizedIndex: nil)
        expectEqual(
            thirds.reduce(0) { $0 + $1.width } + 2 * ColumnLayoutEngine.gap, usableWidth,
            "tres columnas de 1/3 llenan el area util exacto")

        let floored = ColumnLayoutEngine.columnPlacements(
            columns: [column(0.5, minWidth: 800), column(0.5)],
            usableWidth: usableWidth, maximizedIndex: nil)
        expectEqual(floored[0].width, 800, "un minimo descubierto ensancha su propia columna")
        expectEqual(floored[1].x, 810, "y desplaza a la siguiente")
        expectEqual(floored[1].width, 720, "sin encogerla")

        let maxed = ColumnLayoutEngine.columnPlacements(
            columns: [column(0.5), column(0.5)],
            usableWidth: usableWidth, maximizedIndex: 1)
        expectEqual(maxed[1].width, usableWidth, "la columna maximizada toma todo el ancho util")

        // REGRESSION: four sites inverted the width with a different,
        // count-dependent formula, so a column's floor moved when an
        // unrelated column opened.
        for px in [CGFloat(200), 720, 1000, usableWidth] {
            let p = ColumnLayoutEngine.proportion(forWidth: px, usableWidth: usableWidth)
            expectEqual(
                ColumnLayoutEngine.width(forProportion: p, usableWidth: usableWidth), px,
                "pixeles -> proporcion -> pixeles va y vuelve")
        }

        // --- the macOS x clamp ------------------------------------------
        // REGRESSION: asking for a fully-off-screen x makes macOS drag the
        // window 40px back IN, on top of the visible columns.
        expectEqual(
            ColumnLayoutEngine.grantedX(1470, width: 720, screenFrame: screen), 1469,
            "borde derecho: 1px adentro")
        expectEqual(
            ColumnLayoutEngine.grantedX(1500, width: 720, screenFrame: screen), 1469,
            "mas alla del borde tambien")
        expectEqual(
            ColumnLayoutEngine.grantedX(-720, width: 720, screenFrame: screen), -719,
            "borde izquierdo: 1px adentro")
        expectEqual(
            ColumnLayoutEngine.grantedX(10, width: 720, screenFrame: screen), 10, "una x visible se respeta")

        // REGRESSION: with four columns, the ones out of view overlapped the
        // ones on screen.
        for offset in [CGFloat(0), 730, 1460] {
            let frames = ColumnLayoutEngine.targetFrames(
                columns: (0..<4).map { _ in column(0.5) },
                in: screen, maximizedIndex: nil, viewOffset: offset)
            let onScreen = frames.map(\.frame).filter {
                min(screen.maxX, $0.maxX) - max(screen.minX, $0.minX) > 2
            }
            for (i, a) in onScreen.enumerated() {
                for b in onScreen[(i + 1)...] {
                    expect(
                        min(a.maxX, b.maxX) - max(a.minX, b.minX) <= 0.001,
                        "columnas visibles superpuestas con viewOffset \(Int(offset))")
                }
            }
        }

        // --- scroll offset ("never" recenters) ---------------------------
        expectEqual(
            ColumnLayoutEngine.scrollOffset(
                toShow: 1, placements: two, currentOffset: 0, usableWidth: usableWidth),
            0, "una columna ya visible no scrollea")
        let three = ColumnLayoutEngine.columnPlacements(
            columns: (0..<3).map { _ in column(0.5) },
            usableWidth: usableWidth, maximizedIndex: nil)
        expectEqual(
            ColumnLayoutEngine.scrollOffset(
                toShow: 2, placements: three, currentOffset: 0, usableWidth: usableWidth),
            three[2].x + three[2].width - usableWidth, "clipeada a la derecha: alinea ese borde")
        expectEqual(
            ColumnLayoutEngine.scrollOffset(
                toShow: 0, placements: three, currentOffset: 900, usableWidth: usableWidth),
            three[0].x, "clipeada a la izquierda: alinea ese borde")
        expectEqual(
            ColumnLayoutEngine.scrollOffset(
                toShow: 9, placements: three, currentOffset: 123, usableWidth: usableWidth),
            123, "un indice fuera de rango deja el offset como esta")

        // --- height split -------------------------------------------------
        let equalStack = (0..<3).map { _ in window() }
        expectEqual(
            ColumnLayoutEngine.naiveHeights(for: equalStack, usableHeight: 900)[0], 300,
            "tres Auto se reparten igual")

        // REGRESSION: consuming/expelling re-equalized a stack the user had
        // deliberately made uneven (niri's Auto { weight }).
        let weighted = (0..<3).map { _ in window() }
        weighted[0].heightWeight = 2
        let wh = ColumnLayoutEngine.naiveHeights(for: weighted, usableHeight: 900)
        expectEqual(wh[0], 450, "el peso 2 se lleva el doble")
        expectEqual(wh[1], 225, "y el resto se reparte lo que queda")

        let manual = (0..<3).map { _ in window() }
        manual[0].manualHeightPx = 400
        let mh = ColumnLayoutEngine.naiveHeights(for: manual, usableHeight: 900)
        expectEqual(mh[0], 400, "una altura manual es exacta")
        expectEqual(mh[1], 250, "y las Auto se reparten el resto")

        let overflowing = (0..<2).map { _ in window() }
        overflowing[0].manualHeightPx = 2000
        expect(
            ColumnLayoutEngine.naiveHeights(for: overflowing, usableHeight: 900)[1] >= 0,
            "una altura manual mayor que la columna nunca deja una negativa")

        // --- workspace invariants -----------------------------------------
        let ws = Workspace()
        for _ in 0..<4 { ws.appendColumn(Column()) }
        ws.maximizedIndex = 2
        ws.removeColumn(at: 0)
        expectEqual(ws.maximizedIndex ?? -1, 1, "el maximizado sigue a su columna al quitar una anterior")
        ws.maximizedIndex = 2
        ws.removeColumn(at: 2)
        expect(ws.maximizedIndex == nil, "quitar la columna maximizada apaga el maximizado")
        let ws2 = Workspace()
        for _ in 0..<4 { ws2.appendColumn(Column()) }
        ws2.maximizedIndex = 2
        ws2.insertColumn(Column(), at: 0)
        expectEqual(ws2.maximizedIndex ?? -1, 3, "insertar antes corre el maximizado")
        ws2.swapColumns(3, 0)
        expectEqual(ws2.maximizedIndex ?? -1, 0, "y el swap tambien lo sigue")

        // --- SizeChange ----------------------------------------------------
        // REGRESSION: every form was treated as an adjustment, so
        // set-column-width "50%" AGRANDABA la columna a la mitad.
        if case .setProportion(let v)? = SizeChange.parse("50%") {
            expectEqual(v, 50, "50% fija")
        } else {
            failures.append("50% deberia ser setProportion")
        }
        if case .adjustProportion(let v)? = SizeChange.parse("+10%") {
            expectEqual(v, 10, "+10% ajusta")
        } else {
            failures.append("+10% deberia ser adjustProportion")
        }
        if case .setFixed(let v)? = SizeChange.parse("1000") {
            expectEqual(v, 1000, "1000 fija pixeles")
        } else {
            failures.append("1000 deberia ser setFixed")
        }
        if case .adjustFixed(let v)? = SizeChange.parse("-100") {
            expectEqual(v, -100, "-100 ajusta pixeles")
        } else {
            failures.append("-100 deberia ser adjustFixed")
        }
        expect(SizeChange.parse("abc") == nil, "un argumento que no es un tamano se rechaza")

        // --- key combos ----------------------------------------------------
        // REGRESSION: virtual keycodes are physical POSITIONS. On Workman the
        // key that types "f" is where QWERTY has "u", so Mod+Shift+F fired
        // the bind registered for Mod+U.
        NigiriConfig.layoutKeyCodes = ["f": 0x20]
        expectEqual(
            Int(NigiriConfig.parseCombo("Mod+F")?.0 ?? 0), 0x20,
            "el combo usa el layout activo, no la posicion US")
        expect(NigiriConfig.parseCombo("Mod+F")?.1 == [.command, .option], "Mod es Cmd+Opt")
        NigiriConfig.layoutKeyCodes = [:]
        expectEqual(
            Int(NigiriConfig.parseCombo("Mod+Left")?.0 ?? 0), 0x7B,
            "una tecla sin caracter cae a la tabla fija")
        expect(
            NigiriConfig.parseCombo("Hyper+F19")?.1 == [.command, .option, .control, .shift],
            "Hyper son los cuatro")
        expect(NigiriConfig.parseCombo("Garbage+A") == nil, "un modificador inexistente se rechaza")
        expectEqual(
            NigiriConfig.wheelBindingKey(for: "Mod+WheelScrollDown") ?? "", "mod-down",
            "los binds de rueda de niri se aceptan")
        expectEqual(
            NigiriConfig.wheelBindingKey(for: "Mod+Ctrl+WheelScrollLeft") ?? "", "mod-ctrl-left",
            "con modificadores extra")
        expect(NigiriConfig.wheelBindingKey(for: "Mod+T") == nil, "un bind normal no es de rueda")

        // --- config tokenizer ----------------------------------------------
        expect(
            NigiriConfig.tokenize("spawn open -a \"Google Chrome\"") == [
                "spawn", "open", "-a", "Google Chrome",
            ],
            "un token entre comillas conserva sus espacios")
        expect(
            NigiriConfig.tokenize("width 4 // comentario") == ["width", "4"], "los comentarios se descartan")
        expect(
            NigiriConfig.tokenize("title \"a // b\"") == ["title", "a // b"], "pero no adentro de comillas")
        expect(NigiriConfig.parseColor("#7355a6") != nil, "color con #")
        expect(NigiriConfig.parseColor("7355a6") != nil, "color sin #")

        // REGRESSION: the tokenizer eats the quotes, so the bind's action has
        // to survive re-quoting - `open -a Google Chrome` opens nothing.
        expect(
            TilingEngine.spawnArgv("open -a 'Google Chrome'") == ["open", "-a", "Google Chrome"],
            "spawn respeta las comillas simples")
        expect(
            TilingEngine.spawnArgv("open -a \"Google Chrome\"") == ["open", "-a", "Google Chrome"],
            "y las dobles")

        // --- spring ---------------------------------------------------------
        let spring = Spring(stiffness: 2200)
        expectEqual(CGFloat(spring.remainingFraction(at: 0)), 1, "arranca en 1")
        var previous = 1.0
        var monotonic = true
        var nonNegative = true
        for step in 1...1000 {
            let v = spring.remainingFraction(at: Double(step) / 1000)
            if v > previous + 1e-9 { monotonic = false }
            if v < -1e-9 { nonNegative = false }
            previous = v
        }
        expect(monotonic, "el spring decae sin sobrepasar")
        expect(nonNegative, "criticamente amortiguado: nunca cruza el cero")
        expect(previous < 0.005, "asienta dentro del segundo")

        // --- decorations ------------------------------------------------------
        // REGRESSION: the border of a window parked 1px off-screen painted a
        // stripe across the window you CAN see.
        expect(
            TilingEngine.decorationIsVisible(CGRect(x: 10, y: 44, width: 720, height: 902), on: screen),
            "una ventana visible lleva decoracion")
        expect(
            !TilingEngine.decorationIsVisible(CGRect(x: 1469, y: 44, width: 720, height: 902), on: screen),
            "una estacionada a la derecha no")
        expect(
            !TilingEngine.decorationIsVisible(CGRect(x: -719, y: 44, width: 720, height: 902), on: screen),
            "una estacionada a la izquierda tampoco")

        // ===================== Tier 2 =====================

        // --- the FIFO's line framing (CommandPipe) ------------------------
        // Chunks arrive split at arbitrary boundaries; a partial tail must
        // stay buffered instead of being dispatched as an action.
        var buffer = Data("focus-column-right\nfocus-col".utf8)
        var lines = CommandPipe.takeLines(from: &buffer)
        expect(lines == ["focus-column-right"], "solo se despacha la linea completa")
        buffer.append(contentsOf: Array("umn-left\n".utf8))
        lines = CommandPipe.takeLines(from: &buffer)
        expect(lines == ["focus-column-left"], "la cola parcial se completa con el chunk siguiente")
        expect(buffer.isEmpty, "y el buffer queda vacio")

        buffer = Data("  set-column-width 50%  \n\n\n".utf8)
        lines = CommandPipe.takeLines(from: &buffer)
        expect(lines == ["set-column-width 50%"], "se recortan espacios y se descartan lineas vacias")

        // --- width currency, the acceptance test for the unification ------
        // A column with a discovered floor must render at exactly that
        // floor, whatever the column count: the old inverse used a
        // count-dependent denominator, so the floor drifted by a gap per
        // column.
        for count in [1, 2, 4, 6] {
            let cols = (0..<count).map { _ in column(0.5) }
            cols[0].cachedMinWidth = 800
            let p = ColumnLayoutEngine.columnPlacements(
                columns: cols, usableWidth: usableWidth, maximizedIndex: nil)
            expectEqual(p[0].width, 800, "el piso de 800px se respeta con \(count) columna(s)")
        }
        // ...and the proportion that renders 800px is the same regardless.
        let pFor800 = ColumnLayoutEngine.proportion(forWidth: 800, usableWidth: usableWidth)
        expectEqual(
            ColumnLayoutEngine.width(forProportion: pFor800, usableWidth: usableWidth), 800,
            "la proporcion de 800px vuelve a 800px")

        // --- tabbed columns ------------------------------------------------
        // One window on screen at full column height, the rest parked at the
        // granted edge - and the parked ones keep their own y (see
        // parkedOffScreen: hiding is purely horizontal).
        let tabbed = column(0.5)
        let tabWindows = (0..<3).map { _ in window() }
        tabbed.setWindows(tabWindows)
        tabbed.isTabbed = true
        tabbed.focus(row: 1)
        let tabFrames = ColumnLayoutEngine.targetFrames(
            columns: [tabbed], in: screen, maximizedIndex: nil, viewOffset: 0)
        expectEqual(tabFrames.count, 3, "una columna tabeada sigue reportando todas sus ventanas")
        let visible = tabFrames.filter { $0.frame.minX < screen.maxX - 2 }
        expectEqual(visible.count, 1, "solo una queda en pantalla")
        expect(visible.first?.window === tabWindows[1], "la que esta enfocada")
        expectEqual(
            visible.first?.frame.height ?? 0, screen.height - 2 * ColumnLayoutEngine.gap,
            "y toma el alto completo de la columna (el indicador va afuera)")
        for f in tabFrames where f.frame.minX >= screen.maxX - 2 {
            expectEqual(f.frame.minX, screen.maxX - 1, "las otras quedan a 1px del borde")
        }

        // --- the geometry both passes now share -----------------------------
        // columnGeometry is the single placement computation; targetFrames
        // must agree with it column by column (this is the invariant whose
        // absence let grantedX land in one pass and not the other).
        let mixed = [column(0.5), column(1.0 / 3), column(0.5, minWidth: 900)]
        for c in mixed { c.setWindows([window()]) }
        let geometries = ColumnLayoutEngine.columnGeometry(
            columns: mixed, in: screen, maximizedIndex: nil, viewOffset: 300)
        let mixedFrames = ColumnLayoutEngine.targetFrames(
            columns: mixed, in: screen, maximizedIndex: nil, viewOffset: 300)
        expectEqual(geometries.count, mixedFrames.count, "una geometria por columna de una ventana")
        for (g, f) in zip(geometries, mixedFrames) {
            expectEqual(f.frame.minX, g.x, "targetFrames usa la x de columnGeometry")
            expectEqual(f.frame.width, g.width, "y su ancho")
        }

        // --- workspace focus invariants -------------------------------------
        // The class of bug R4 makes unrepresentable: focus surviving past the
        // end of the array after a removal.
        let fws = Workspace()
        for _ in 0..<3 { fws.appendColumn(Column()) }
        fws.focus(column: 2)
        fws.removeColumn(at: fws.columns.count - 1)
        expectEqual(fws.focusedIndex, 1, "el foco se re-ancla al quitar la ultima columna")
        fws.focus(column: 99)
        expectEqual(fws.focusedIndex, fws.columns.count - 1, "no se puede enfocar mas alla del final")
        fws.focus(column: -5)
        expectEqual(fws.focusedIndex, 0, "ni antes del principio")
        fws.moveColumnFocus(by: 1)
        expectEqual(fws.focusedIndex, 1, "moverse una a la derecha")
        fws.moveColumnFocus(by: 99)
        expectEqual(fws.focusedIndex, fws.columns.count - 1, "y el movimiento tampoco se sale")

        let emptyWs = Workspace()
        emptyWs.focus(column: 3)
        expectEqual(emptyWs.focusedIndex, 0, "un workspace vacio siempre enfoca 0")

        let fcol = Column()
        fcol.setWindows((0..<3).map { _ in window() })
        fcol.focus(row: 2)
        fcol.removeWindow(at: fcol.windows.count - 1)
        expectEqual(fcol.focusedWindowIndex, 1, "el foco de fila tambien se re-ancla")
        expect(fcol.focus(window: fcol.windows[0]), "enfocar por identidad encuentra la ventana")
        expectEqual(fcol.focusedWindowIndex, 0, "y la enfoca")
        expect(!fcol.focus(window: window()), "una ventana ajena no cambia el foco")

        // --- isFloatingActive cannot outlive the floating layer -------------
        let floatWs = Workspace()
        floatWs.floatingWindows = [window()]
        floatWs.isFloatingActive = true
        floatWs.floatingWindows = []
        floatWs.clampFocus()
        expect(!floatWs.isFloatingActive, "sin ventanas flotantes, el foco flotante se apaga")

        // --- animation curves ----------------------------------------------
        // REGRESSION: only the critically damped case existed, so a
        // configured damping-ratio of 0.9 was unreachable.
        let critical = Spring(stiffness: 1100, dampingRatio: 1.0)
        expectEqual(CGFloat(critical.remainingFraction(at: 0)), 1, "el spring critico arranca en 1")
        var everNegative = false
        for step in 0...500 where critical.remainingFraction(at: Double(step) / 500) < -1e-9 {
            everNegative = true
        }
        expect(!everNegative, "criticamente amortiguado no sobrepasa")

        let underdamped = Spring(stiffness: 1100, dampingRatio: 0.6)
        var overshot = false
        for step in 0...500 where underdamped.remainingFraction(at: Double(step) / 500) < -1e-6 {
            overshot = true
        }
        expect(overshot, "damping-ratio < 1 SI sobrepasa - eso es lo que pide la config")
        expect(underdamped.hasSettled(at: 3), "y aun asi asienta")
        expect(!underdamped.hasSettled(at: 0), "pero no de entrada")

        let overdamped = Spring(stiffness: 1100, dampingRatio: 2.0)
        var overdampedNegative = false
        for step in 0...500 where overdamped.remainingFraction(at: Double(step) / 500) < -1e-9 {
            overdampedNegative = true
        }
        expect(!overdampedNegative, "sobreamortiguado tampoco sobrepasa")
        expect(
            overdamped.remainingFraction(at: 0.1) > critical.remainingFraction(at: 0.1),
            "y llega mas tarde que el critico")

        let easing = Easing(durationMs: 500, curve: .easeOutCubic)
        expectEqual(CGFloat(easing.remainingFraction(at: 0)), 1, "el easing arranca en 1")
        expectEqual(CGFloat(easing.remainingFraction(at: 0.5)), 0, "y termina exactamente en su duracion")
        expect(easing.hasSettled(at: 0.5), "asentado al cumplirse la duracion")
        expect(!easing.hasSettled(at: 0.25), "no antes")
        expect(
            Easing(durationMs: 500, curve: .easeOutCubic).remainingFraction(at: 0.25)
                < Easing(durationMs: 500, curve: .linear).remainingFraction(at: 0.25),
            "ease-out avanza mas rapido que lineal al principio")
        expect(Easing.Curve.named("ease-out-cubic") != nil, "las curvas de niri se reconocen por nombre")
        expect(Easing.Curve.named("no-existe") == nil, "y una desconocida se rechaza")

        expectEqual(CGFloat(AnimationCurve.off.remainingFraction(at: 0)), 0, "off aterriza de entrada")
        expect(AnimationCurve.off.hasSettled(at: 0), "y ya esta asentada")

        // --- window rules: niri's matcher semantics -------------------------
        // REGRESSION: matchers were case-insensitive SUBSTRINGS, so none of
        // niri's own rules (anchored regexes over reverse-DNS app-ids)
        // ported at all.
        let anchored = Regex("^com\\.mitchellh\\.ghostty$")
        expect(anchored.matches("com.mitchellh.ghostty"), "el regex anclado matchea el bundle id exacto")
        expect(!anchored.matches("com.mitchellh.ghostty.helper"), "y no matchea uno mas largo")
        expect(Regex("^org\\.gnome\\.").matches("org.gnome.Nautilus"), "un prefijo anclado matchea")
        expect(!Regex("^org\\.gnome\\.").matches("com.org.gnome.fake"), "pero no en el medio")
        expect(
            Regex("Picture-in-Picture").matches("Firefox Picture-in-Picture"),
            "sin anclar, alcanza con encontrarlo")
        expect(!Regex("[").matches("cualquier cosa"), "un patron invalido no matchea nada (y avisa)")

        var m = NigiriConfig.Matcher()
        expect(
            m.matches(
                app: "Chrome", bundleID: "com.google.Chrome", title: "x",
                isActive: false, isFloating: false, atStartup: false),
            "un matcher sin campos matchea todo - asi escribe niri 'para toda ventana'")
        m.app = Regex("^com\\.google\\.Chrome$")
        expect(
            m.matches(
                app: "Google Chrome", bundleID: "com.google.Chrome", title: "x",
                isActive: false, isFloating: false, atStartup: false),
            "app-id resuelve contra el bundle id, que es el equivalente macOS")
        expect(
            !m.matches(
                app: "Alacritty", bundleID: "org.alacritty", title: "x",
                isActive: false, isFloating: false, atStartup: false),
            "y no matchea otra app")
        m = NigiriConfig.Matcher()
        m.isActive = true
        expect(
            m.matches(
                app: "a", bundleID: nil, title: "t", isActive: true, isFloating: false, atStartup: false),
            "is-active=true matchea la enfocada")
        expect(
            !m.matches(
                app: "a", bundleID: nil, title: "t", isActive: false, isFloating: false, atStartup: false),
            "y no la que no lo esta")

        // --- items 57-60: piezas calientes que no tenian NINGUNA comprobacion
        // 57: sin pantalla la geometria es basura, y hay que poder detectarlo.
        expect(
            ColumnLayoutEngine.columnPlacements(columns: [column(0.5)], usableWidth: -20, maximizedIndex: nil)
                .allSatisfy { $0.width >= 0 },
            "con ancho util negativo ninguna columna sale con ancho negativo")

        // 58: remapeo de indices al mover un workspace (remove + insert).
        expectEqual(TilingEngine.indexAfterMove(0, from: 2, to: 0), 1, "lo que estaba antes se corre uno")
        expectEqual(TilingEngine.indexAfterMove(2, from: 2, to: 0), 0, "el que se movio va a su destino")
        expectEqual(TilingEngine.indexAfterMove(3, from: 2, to: 0), 3, "lo de mas alla no se toca")
        expectEqual(TilingEngine.indexAfterMove(0, from: 0, to: 2), 2, "y al reves tambien")
        expectEqual(TilingEngine.indexAfterMove(1, from: 0, to: 2), 0, "los del medio se corren hacia atras")

        // 59: la columna bajo el cursor necesita las DOS mitades del rango.
        let dropCols = [
            CGRect(x: 0, y: 0, width: 300, height: 800),
            CGRect(x: 600, y: 0, width: 300, height: 800),
        ]
        expectEqual(TilingEngine.hoveredColumn(dropCols, x: 150) ?? -1, 0, "adentro de la primera")
        expectEqual(TilingEngine.hoveredColumn(dropCols, x: 700) ?? -1, 1, "adentro de la segunda")
        expect(
            TilingEngine.hoveredColumn(dropCols, x: 1200) == nil,
            "pasado el final NO se esta sobre la ultima: ahi va columna nueva, no apilar")
        expect(TilingEngine.hoveredColumn(dropCols, x: 450) == nil, "ni en el hueco entre dos")

        // 60a: el plan de compactacion reescribe los dos indices en cada
        // relayout, y una equivocacion ahi se lee como "macOS me cambio de
        // escritorio solo".
        let plan = TilingEngine.compactPlan(
            [
                (empty: false, named: false),
                (empty: true, named: false),
                (empty: false, named: false),
                (empty: true, named: false),
            ],
            active: 2, previous: 0, emptyAboveFirst: false)
        expectEqual(plan.keep, [0, 2, 3], "el vacio del medio se va; el ultimo se queda como destino")
        expectEqual(plan.active, 1, "y el activo viaja con su workspace")
        expectEqual(plan.previous, 0, "igual que el anterior")
        expect(!plan.appendTrailing, "ya hay un vacio al final, no hace falta otro")
        let named = TilingEngine.compactPlan(
            [
                (empty: true, named: true),
                (empty: false, named: false),
            ],
            active: 1, previous: 0, emptyAboveFirst: false)
        expectEqual(named.keep, [0, 1], "un workspace con nombre no se borra aunque este vacio")
        expect(named.appendTrailing, "y como el ultimo tiene ventanas, se agrega uno nuevo al final")

        // 60b: el contador de ausencias es el juez final de si se borra una
        // ventana VIVA del modelo, y ya regreso dos veces.
        expectEqual(TilingEngine.purgeVerdict(scans: 0, verdict: .alive).scans, 0, "verla la resetea")
        expect(!TilingEngine.purgeVerdict(scans: 2, verdict: .alive).dead, "y una vista no esta muerta")
        expectEqual(
            TilingEngine.purgeVerdict(scans: 2, verdict: .alive).scans, 0, "aunque venga de dos ausencias")
        expect(
            TilingEngine.purgeVerdict(scans: 0, verdict: .dead).dead, "un proceso muerto no necesita contador"
        )
        expect(
            !TilingEngine.purgeVerdict(scans: 0, verdict: .absentFromList).dead,
            "una ausencia sola no alcanza")
        expect(!TilingEngine.purgeVerdict(scans: 1, verdict: .absentFromList).dead, "dos tampoco")
        expect(
            TilingEngine.purgeVerdict(scans: 2, verdict: .absentFromList).dead, "la tercera consecutiva si")

        // REGRESSION (item 46): en una columna tabbed la unica tarjeta visible
        // ES la pestaña activa, asi que soltar arriba o abajo de ella
        // significa antes o despues de ESA pestaña. Antes el contest de
        // huecos solo podia contestar fila 0 o 1: la pestaña nueva aparecia
        // arriba de todo, y el orden se ve en el indicador.
        let tabbedFrames = [[CGRect(x: 10, y: 44, width: 700, height: 900)]]
        let overTab = CGPoint(x: 360, y: 700)  // debajo del centro
        expect(
            ColumnLayoutEngine.insertPosition(
                columnFrames: tabbedFrames, point: overTab,
                screenFrame: screen, tabbed: [2]) == .inColumn(0, 3),
            "abajo de la pestaña activa (indice 2) entra despues de ella")
        let aboveTab = CGPoint(x: 360, y: 200)  // arriba del centro
        expect(
            ColumnLayoutEngine.insertPosition(
                columnFrames: tabbedFrames, point: aboveTab,
                screenFrame: screen, tabbed: [2]) == .inColumn(0, 2),
            "y arriba, antes")
        expect(
            ColumnLayoutEngine.insertPosition(
                columnFrames: tabbedFrames, point: overTab,
                screenFrame: screen, tabbed: [nil]) == .inColumn(0, 1),
            "una columna normal sigue usando el hueco entre tiles")

        // REGRESSION (item 41): niri's activate_prev_column_on_removal. Una
        // ventana nueva se inserta a la DERECHA de la enfocada y toma el
        // foco; al cerrarla el foco tiene que volver a la izquierda, no
        // quedarse en el indice - que ahora es otra columna. Sin esto,
        // cerrar la ventana que acabas de abrir corria el strip a la derecha.
        let prevWs = Workspace()
        let prevLeft = column(0.5)
        let prevRight = column(0.5)
        prevLeft.setWindows([window()]); prevRight.setWindows([window()])
        prevWs.appendColumn(prevLeft)
        prevWs.appendColumn(prevRight)
        prevWs.focus(column: 0)
        let colN = column(0.5)
        colN.setWindows([window()])
        prevWs.insertColumn(colN, at: 1, activating: true)  // como abre una ventana nueva
        _ = prevWs.removeColumn(at: 1)  // y como la cerras
        expectEqual(prevWs.focusedIndex, 0, "el foco vuelve a la columna de la que salio")
        // Un movimiento de foco explicito cancela esa memoria.
        let plainWs = Workspace()
        let p1 = column(0.5)
        let p2 = column(0.5)
        let p3 = column(0.5)
        for c in [p1, p2, p3] { c.setWindows([window()]); plainWs.appendColumn(c) }
        plainWs.focus(column: 1)
        _ = plainWs.removeColumn(at: 1)
        expectEqual(plainWs.focusedIndex, 1, "sin esa memoria, se queda en el indice, que es lo de siempre")

        // REGRESSION (item 42): sin indice guardado, el preset se elige
        // comparando el ancho actual - la primera pulsacion sobre una ventana
        // nueva daba el preset 0 en vez del primero mas grande.
        let presetList: [CGFloat] = [1.0 / 3.0, 0.5, 2.0 / 3.0]
        expectEqual(
            ColumnLayoutEngine.presetIndex(after: 0.5, in: presetList, delta: 1, from: nil) ?? -1, 2,
            "desde 0.5 hacia adelante toca 2/3, no 1/3")
        expectEqual(
            ColumnLayoutEngine.presetIndex(after: 0.5, in: presetList, delta: -1, from: nil) ?? -1, 0,
            "y hacia atras, 1/3")
        expectEqual(
            ColumnLayoutEngine.presetIndex(after: 0.9, in: presetList, delta: 1, from: nil) ?? -1, 0,
            "mas ancha que todos: envuelve al primero")
        expectEqual(
            ColumnLayoutEngine.presetIndex(after: 0.1, in: presetList, delta: -1, from: nil) ?? -1, 2,
            "mas angosta que todos hacia atras: envuelve al ultimo")
        expectEqual(
            ColumnLayoutEngine.presetIndex(after: 0.5, in: presetList, delta: 1, from: 0) ?? -1, 1,
            "con indice guardado manda el indice, que es el camino rapido de niri")

        // Los popups de apps ACCESORIAS (los permisos del sistema, las
        // advertencias de "descargado de internet", los pedidos de
        // contraseña) tienen que entrar al modelo como flotantes: antes se
        // escapaban del window manager por completo. Pero la mayoria de las
        // ventanas accesorias no son eso - un wallpaper de video, nuestros
        // propios overlays, los paneles del Centro de Control. Medido en
        // vivo, un dialogo de verdad tiene titulo o botones de confirmacion,
        // y los demas no tienen ninguno de los dos.
        expect(
            TilingEngine.isDialogLike(
                title: "Screen Recording", hasDefaultButton: true, hasCancelButton: false),
            "el prompt de permisos del sistema se adopta")
        expect(
            TilingEngine.isDialogLike(title: "", hasDefaultButton: true, hasCancelButton: false),
            "y uno sin titulo pero con boton de confirmar, tambien")
        expect(
            TilingEngine.isDialogLike(title: "Instalar", hasDefaultButton: false, hasCancelButton: false),
            "y uno con titulo y sin botones, tambien")
        expect(
            !TilingEngine.isDialogLike(title: "", hasDefaultButton: false, hasCancelButton: false),
            "un wallpaper de video o un overlay nuestro -sin titulo y sin botones- no")

        // REGRESSION (item 48): sacar una ventana del tiling cancela el
        // fullscreen. fullscreenWindow y floatingWindows eran dos banderas que
        // nadie cruzaba: Mod+F y despues Mod+V dejaba una ventana que era las
        // dos cosas, y de ahi en mas cada reflow entraba a la rama de
        // fullscreen, no la encontraba entre las tileadas, la agregaba a
        // tamano de pantalla crudo y mandaba a todas las demas al parkeo.
        let fsWs = Workspace()
        let fsColumn = column(0.5)
        let fsWindow = window()
        fsColumn.setWindows([fsWindow])
        fsWs.appendColumn(fsColumn)
        fsWs.fullscreenWindow = fsWindow
        expect(fsWs.detachFromTiling(fsWindow), "la ventana estaba en una columna, asi que se saca")
        expect(fsWs.fullscreenWindow == nil, "y el fullscreen se cancela con ella")
        expectEqual(fsWs.columns.count, 0, "la columna vacia se colapsa")
        expect(!fsWs.detachFromTiling(window()), "una que no esta tileada no se saca de ningun lado")

        // REGRESSION (item 39): resize-edge tambien bumpea la epoca, asi que
        // los pisos hay que capturarlos antes. Con un piso de 800px el
        // intercambio con el vecino tiene que hacerse en pixeles efectivos,
        // no en proporciones, o el borde derecho del par se corre.
        let tradeUsable: CGFloat = 1450
        let floorPx: CGFloat = 800
        let restingProportion = ColumnLayoutEngine.proportion(forWidth: 700, usableWidth: tradeUsable)
        let effective = max(
            ColumnLayoutEngine.width(forProportion: restingProportion, usableWidth: tradeUsable), floorPx)
        expectEqual(effective, floorPx, "una columna apoyada en su piso mide el piso, no su proporcion")
        let ignoringFloor = ColumnLayoutEngine.width(
            forProportion: restingProportion, usableWidth: tradeUsable)
        expect(
            effective - ignoringFloor > 50,
            "y la diferencia es justo lo que el par perdia cuando el piso se leia como nil")

        // REGRESSION (items 5 y 6): la clave de un bind de mouse/rueda la
        // arman los DOS lados del lookup - el parser desde el texto de la
        // config, el tap desde los flags en vivo - y la armaban distinto: el
        // parser respetaba el orden escrito, el tap emitia el suyo. Mod+Shift+
        // Ctrl, que es el orden que usan las configs de niri, se guardaba como
        // "mod-shift-ctrl-..." y se buscaba como "mod-ctrl-shift-...".
        expectEqual(
            NigiriConfig.mouseBindingKey(for: "Shift+Mod+MouseMiddle") ?? "", "mod-shift-middle",
            "el orden escrito no cambia la clave")
        expectEqual(
            NigiriConfig.mouseBindingKey(for: "Mod+Shift+MouseMiddle") ?? "",
            NigiriConfig.mouseBindingKey(for: "Shift+Mod+MouseMiddle") ?? "x",
            "las dos formas dan la misma clave")
        expectEqual(
            NigiriConfig.wheelBindingKey(for: "Mod+Shift+Ctrl+WheelScrollDown") ?? "", "mod-ctrl-shift-down",
            "y la rueda usa el mismo orden canonico que el tap")
        expectEqual(
            NigiriConfig.bindingKey(mods: ["shift", "ctrl", "mod"], suffix: "down"), "mod-ctrl-shift-down",
            "orden fijo: mod, cmd, opt, ctrl, shift")
        expectEqual(
            NigiriConfig.wheelBindingKey(for: "WheelScrollUp") ?? "", "mod-up",
            "una rueda sin modificador se lee como Mod (una rueda pelada es scrollear)")

        // La seccion wheel{} se escribe con la clave interna a mano, que es
        // justo donde se cuela un orden distinto: tambien se canonicaliza.
        let wheelCfg = NigiriConfig.parse(
            """
            wheel {
                shift-mod-down focus-column-right
                ctrl-up move-column-to-workspace-up
            }
            """)
        expectEqual(
            wheelCfg.wheelBindings["mod-shift-down"] ?? "", "focus-column-right",
            "el orden escrito a mano no cambia la clave")
        expectEqual(
            wheelCfg.wheelBindings["mod-ctrl-up"] ?? "", "move-column-to-workspace-up",
            "y sin mod se asume mod, como en el otro camino")

        // REGRESSION (item 23): focus-ring { off } se parseaba desde que
        // existe la seccion y no se aplicaba nunca - el anillo seguia
        // dibujandose con su ancho. "Apagado" se escribe ancho 0, que es como
        // lo dicen todas las demas decoraciones.
        let ringOffCfg = NigiriConfig.parse(
            """
            layout { focus-ring { width 4; off } }
            """)
        expect(ringOffCfg.ringOff, "focus-ring { off } se parsea")
        expectEqual(ringOffCfg.ringOff ? 0 : ringOffCfg.ringWidth, 0, "y el ancho efectivo es 0")
        let ringOnCfg = NigiriConfig.parse(
            """
            layout { focus-ring { width 6 } }
            """)
        expectEqual(ringOnCfg.ringOff ? 0 : ringOnCfg.ringWidth, 6, "sin off, manda el ancho configurado")

        // --- decoraciones: una sola regla, compartida por el settle y el tick
        // REGRESSION (items 12 y 13): el tick del animador tenia su propia
        // copia de la regla y se le habia caido el chequeo de minimizada (un
        // borde fantasma sobre el hueco de una ventana minimizada, que
        // sobrevivia al settle); y una flotante se comparaba contra una lista
        // que la INCLUIA a ella misma, asi que se tapaba sola y nunca recibia
        // borde.
        let decoScreen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let tiled = CGRect(x: 20, y: 20, width: 300, height: 700)
        let dialog = CGRect(x: 400, y: 100, width: 300, height: 300)
        let minimizedFrame = CGRect(x: 700, y: 20, width: 200, height: 700)
        let decorated = TilingEngine.decoratedFrames(
            [
                .init(frame: tiled, minimized: false, isFloating: false),
                .init(frame: dialog, minimized: false, isFloating: true),
                .init(frame: minimizedFrame, minimized: true, isFloating: false),
            ], screen: decoScreen)
        expectEqual(decorated.count, 2, "la minimizada no lleva borde; la tileada y el dialogo si")
        expect(decorated.contains(dialog), "un dialogo no se tapa a si mismo")
        expect(decorated.contains(tiled), "y la tileada que no esta debajo de el conserva el suyo")
        let underDialog = CGRect(x: 420, y: 120, width: 200, height: 200)
        let covered = TilingEngine.decoratedFrames(
            [
                .init(frame: underDialog, minimized: false, isFloating: false),
                .init(frame: dialog, minimized: false, isFloating: true),
            ], screen: decoScreen)
        expect(!covered.contains(underDialog), "la que queda debajo del dialogo si pierde el borde")
        let offscreen = TilingEngine.decoratedFrames(
            [
                .init(
                    frame: CGRect(x: 999, y: 20, width: 300, height: 700), minimized: false, isFloating: false
                )
            ], screen: decoScreen)
        expectEqual(offscreen.count, 0, "y una scrolleada fuera de vista tampoco pinta nada")

        // REGRESSION (items 10 y 38): el hogar pre-fullscreen de una flotante
        // compartia slot con el stash del cambio de workspace, que lo pisa con
        // donde esta la ventana AHORA - y durante un fullscreen eso es el
        // parkeo de 1px, asi que volvia varada contra el borde.
        let fsScreen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let home = CGRect(x: 120, y: 90, width: 400, height: 300)
        expectEqual(
            FullscreenStash.homeToRecord(isFloating: true, existingHome: nil, currentFrame: home) ?? .zero,
            home, "la primera vez se guarda donde estaba")
        let parkedSpot = FullscreenStash.parked(home, screenFrame: fsScreen)
        expectEqual(parkedSpot.minX, fsScreen.maxX - 1, "parkeada a 1px del borde")
        expectEqual(parkedSpot.height, home.height, "conservando tamano y altura")
        expect(
            FullscreenStash.homeToRecord(isFloating: true, existingHome: home, currentFrame: parkedSpot)
                == nil,
            "y la segunda vez NO se reescribe: si no, el hogar pasa a ser el parkeo")
        expect(
            FullscreenStash.homeToRecord(isFloating: false, existingHome: nil, currentFrame: home) == nil,
            "una tileada no necesita hogar: la vuelve a colocar el layout")

        // Los dos slots son independientes, que es el arreglo del item 10.
        let stashed = window()
        stashed.fullscreenHome = home
        stashed.stashedFrame = parkedSpot  // lo que escribe el cambio de workspace
        expectEqual(
            stashed.fullscreenHome ?? .zero, home, "el cambio de workspace ya no pisa el hogar del fullscreen"
        )
        stashed.stashedFrame = nil  // el switch limpia el suyo al aterrizar
        expectEqual(stashed.fullscreenHome ?? .zero, home, "y limpiar uno no borra el otro")

        // --- cache epochs ----------------------------------------------------
        // REGRESSION: a discovered floor and a refusal memo were believed
        // forever, so a column could get stuck at a width no key changed -
        // silently. Both are answers FROM AN APP, and apps change their mind.
        let epochColumn = column(0.5)
        epochColumn.cachedMinWidth = 800
        expectEqual(epochColumn.validMinWidth ?? 0, 800, "el piso vale dentro de su epoca")
        ColumnLayoutEngine.newEpoch()
        expect(epochColumn.validMinWidth == nil, "y deja de valer en la siguiente")
        let placedAfterEpoch = ColumnLayoutEngine.columnPlacements(
            columns: [epochColumn], usableWidth: usableWidth, maximizedIndex: nil)
        expectEqual(placedAfterEpoch[0].width, 720, "asi que la columna vuelve a su proporcion")

        let epochWindow = window()
        epochWindow.lastRequestedFrame = CGRect(x: 0, y: 0, width: 500, height: 500)
        epochWindow.lastActualFrame = CGRect(x: 0, y: 0, width: 800, height: 500)
        expect(epochWindow.refusalMemo != nil, "el rechazo memorizado vale dentro de su epoca")
        ColumnLayoutEngine.newEpoch()
        expect(epochWindow.refusalMemo == nil, "y no sobrevive a la siguiente")

        // Re-recording inside the new epoch makes it valid again.
        epochWindow.lastRequestedFrame = CGRect(x: 0, y: 0, width: 500, height: 500)
        expect(epochWindow.refusalMemo != nil, "volver a medir lo revalida")

        // REGRESSION (item 7): toda accion de ancho arranca con newEpoch(),
        // que es justo lo que hace que validMinWidth conteste nil - asi que el
        // piso descubierto NUNCA se aplicaba desde el teclado y su mensaje no
        // se habia visto una sola vez. La accion lo captura antes del bump.
        let floorProportion = ColumnLayoutEngine.proportion(forWidth: 800, usableWidth: usableWidth)
        expectEqual(
            ColumnLayoutEngine.clampProportion(0.1, minWidth: 800, maxWidth: nil, usableWidth: usableWidth),
            floorProportion, "un piso conocido levanta la proporcion pedida")
        expectEqual(
            ColumnLayoutEngine.clampProportion(0.1, minWidth: nil, maxWidth: nil, usableWidth: usableWidth),
            0.1, "sin piso conocido pasa tal cual, que es lo que hacia SIEMPRE")
        expectEqual(
            ColumnLayoutEngine.clampProportion(0.9, minWidth: nil, maxWidth: 400, usableWidth: usableWidth),
            ColumnLayoutEngine.proportion(forWidth: 400, usableWidth: usableWidth),
            "el techo de una regla recorta hacia abajo")
        expectEqual(
            ColumnLayoutEngine.clampProportion(0.5, minWidth: 800, maxWidth: 400, usableWidth: usableWidth),
            floorProportion,
            "si techo y piso se cruzan, gana el piso: una ventana ilegible es peor que una ancha")
        expectEqual(
            ColumnLayoutEngine.clampProportion(2.0, minWidth: nil, maxWidth: nil, usableWidth: usableWidth),
            1.0, "nada pasa del ancho util")

        // REGRESSION (item 9): move-window-to-workspace metia una flotante
        // dentro de una columna del workspace destino, rompiendo la invariante
        // que toggleWindowFloating si cuida. Un dialog cuenta aunque la capa
        // flotante no sea la activa: rechaza las escrituras que una columna le
        // haria.
        expect(
            TilingEngine.landsFloating(floatingLayerActive: true, isDialog: false, inFloatingList: true),
            "la que ya estaba flotando sigue flotando del otro lado")
        expect(
            TilingEngine.landsFloating(floatingLayerActive: false, isDialog: true, inFloatingList: false),
            "un dialog no se tilea aunque la capa activa sea la tileada")
        expect(
            !TilingEngine.landsFloating(floatingLayerActive: false, isDialog: false, inFloatingList: false),
            "y una tileada comun sigue yendo a una columna")

        // --- config sections that used to be skipped as "unknown" ---
        let cfg = NigiriConfig.parse(
            """
            layout {
                struts { left 12; right 8; top 30; bottom 4; }
                center-focused-column "on-overflow"
                always-center-single-column
                empty-workspace-above-first
                default-column-display "tabbed"
                preset-column-widths { proportion 0.5; fixed 1200; }
                shadow { softness 40; offset x=2 y=6; }
            }
            overview { zoom 0.35; backdrop-color "#101010"; }
            environment { DISPLAY ":1"; TERM "xterm"; }
            screenshot-path "~/Pictures/shot-%Y.png"
            """)
        expectEqual(cfg.struts.left, 12, "struts left")
        expectEqual(cfg.struts.bottom, 4, "struts bottom")
        expect(
            cfg.centerFocusedColumn == NigiriConfig.CenterFocusedColumn.onOverflow,
            "center-focused-column on-overflow")
        expect(cfg.alwaysCenterSingleColumn, "always-center-single-column")
        expect(cfg.emptyWorkspaceAboveFirst, "empty-workspace-above-first")
        expect(cfg.defaultColumnTabbed, "default-column-display tabbed")
        // El ORDEN declarado es el ciclo que camina Mod+R: una sola lista.
        expectEqual(cfg.presetColumnSizes.count, 2, "los dos presets, en una sola lista")
        expect(cfg.presetColumnSizes[0] == .proportion(0.5), "primero la proporcion, como se escribio")
        expect(cfg.presetColumnSizes[1] == .fixed(1200), "y despues el fixed, no al final de la lista")
        // REGRESSION (item 43): mezclados, el orden se conservaba mal.
        let mixedPresets = NigiriConfig.parse(
            """
            layout { preset-column-widths { proportion 0.25; fixed 1920; proportion 0.75 } }
            """)
        expect(
            mixedPresets.presetColumnSizes == [.proportion(0.25), .fixed(1920), .proportion(0.75)],
            "una lista mezclada cicla en el orden escrito, no proporciones primero")
        // REGRESSION (item 43b): una lista solo-fixed no hereda los defaults.
        let onlyFixed = NigiriConfig.parse(
            """
            layout { preset-column-widths { fixed 1280; fixed 1920 } }
            """)
        expectEqual(onlyFixed.presetColumnSizes.count, 2, "dos presets declarados, dos presets - no cinco")
        // REGRESSION (item 44): las alturas aceptan fixed, como en niri.
        let heights = NigiriConfig.parse(
            """
            layout { preset-window-heights { fixed 400; proportion 0.5 } }
            """)
        expect(
            heights.presetWindowHeightSizes == [.fixed(400), .proportion(0.5)],
            "preset-window-heights { fixed N } ya no se descarta")
        expect(
            !NigiriConfig.parse("layout { }").presetWindowHeightSizes.isEmpty,
            "y si la lista queda vacia hay defaults, como en los anchos")
        // REGRESSION (item 45): la formula vertical es la de niri, no p*alto.
        let colH: CGFloat = 1000
        let heightThirds = (0..<3).map { _ in
            ColumnLayoutEngine.height(forProportion: 1.0 / 3.0, usableHeight: colH)
        }
        expectEqual(
            heightThirds.reduce(0, +) + 2 * ColumnLayoutEngine.gap, colH,
            "tres ventanas al preset 1/3 entran exactamente, gaps incluidos")
        expect(cfg.shadowOn, "shadow{} lo enciende")
        expectEqual(cfg.shadowSoftness, 40, "shadow softness")
        expectEqual(cfg.shadowOffset.height, 6, "shadow offset y")
        expectEqual(cfg.overviewZoom, 0.35, "overview zoom")
        expectEqual(cfg.environment["TERM"] ?? "", "xterm", "environment")
        expect(cfg.screenshotPath.hasSuffix("shot-%Y.png"), "screenshot-path")

        // --- KDL: las formas que cubre la suite oficial (kdl-org/kdl,
        // tests/test_cases), escritas en el dialecto v1 que usa niri via
        // knuffel. Ninguna de estas tenia una sola comprobacion.
        //
        // 1) Un sub-bloque desconocido NO puede abortar su seccion: una config
        // de niri copiada tal cual trae input { touchpad { ... } } y ahi se
        // perdia el mod-key, dejando los 74 binds en el default.
        let sub = NigiriConfig.parse(
            """
            input {
                touchpad { natural-scroll true; accel-speed 0.2 }
                mod-key "Ctrl"
                focus-follows-mouse
            }
            """)
        expect(sub.modKey == [.control], "un sub-bloque desconocido no se lleva puesto el mod-key")
        expect(sub.focusFollowsMouse, "ni las claves que vienen despues")

        // 2) skipUnknownBlock no puede comerse el } de su seccion padre.
        let skipped = NigiriConfig.parse(
            """
            layout { desconocido { x 1 } gaps 33 }
            binds { Mod+T { spawn "a"; } }
            """)
        expectEqual(skipped.gap, 33, "la clave que sigue al bloque desconocido se aplica")
        expectEqual(skipped.binds.count, 1, "y el binds{} de despues sigue vivo")

        // 3) slashdash: nodo, argumento y bloque hijo (commented_node,
        // commented_arg, commented_child de la suite oficial).
        let slash = NigiriConfig.parse(
            """
            layout {
                /- gaps 99
                gaps 7
            }
            /- window-rule { match app-id="x"; open-floating true }
            """)
        expectEqual(slash.gap, 7, "/- comenta el nodo entero")
        expectEqual(slash.rules.count, 0, "/- se lleva tambien el bloque hijo del nodo")
        expectEqual(
            NigiriConfig.tokenize("node /- arg1 arg2"), ["node", "arg2"],
            "/- en medio de una linea se lleva UN argumento")
        expectEqual(
            NigiriConfig.tokenize("node arg /- { inner }"), ["node", "arg"],
            "/- antes de { se lleva el bloque y deja el nodo")

        // 4) comentarios de bloque, anidados y con un * suelto adentro.
        expectEqual(NigiriConfig.tokenize("node /* comment */ arg"), ["node", "arg"], "comentario de bloque")
        expectEqual(NigiriConfig.tokenize("node /* * */"), ["node"], "un * suelto no cierra el comentario")
        expectEqual(
            NigiriConfig.tokenize("a /* x /* y */ z */ b"), ["a", "b"], "comentarios de bloque anidados")

        // 5) escapes dentro de un string: la comilla escapada NO lo termina.
        expectEqual(
            NigiriConfig.tokenize("spawn \"say \\\"hola\\\"\""),
            ["spawn", "say \"hola\""], "comilla escapada dentro del string")

        // 6) raw strings: sin escapes adentro, con comillas adentro. Tu
        // animations/glitch/animations.kdl las usa para los shaders.
        expectEqual(
            NigiriConfig.tokenize("shader r\"a \\n b\""), ["shader", "a \\n b"],
            "r\"...\" no interpreta escapes")
        expectEqual(
            NigiriConfig.tokenize("shader r#\"tiene \" adentro\"#"), ["shader", "tiene \" adentro"],
            "r#\"...\"# aguanta comillas adentro")
        expectEqual(
            NigiriConfig.tokenize("shader #\"forma v2\"#"), ["shader", "forma v2"],
            "la forma de KDL v2 tambien se acepta")
        let shaderCfg = NigiriConfig.parse(
            """
            animations {
                window-open {
                    duration-ms 500
                    custom-shader r"
                        // adentro va GLSL crudo: llaves, // y \\ que no son sintaxis KDL
                        vec4 open_color(vec3 c) { return vec4(1.0); }
                    "
                    curve "ease-out-cubic"
                }
            }
            """)
        expect(shaderCfg.animations["window-open"] != nil, "un shader en raw string no rompe su animacion")

        // struts se restan del area util, nunca la dejan en cero.
        let savedStruts = ScreenGeometry.struts
        ScreenGeometry.struts = NSEdgeInsets(top: 30, left: 12, bottom: 4, right: 8)
        let strutted = ScreenGeometry.primaryScreenVisibleFrameInAXSpace()
        ScreenGeometry.struts = savedStruts
        let plain = ScreenGeometry.primaryScreenVisibleFrameInAXSpace()
        if plain.width > 100 {
            expectEqual(strutted.width, plain.width - 20, "struts recortan el ancho util")
            expectEqual(strutted.minY, plain.minY + 30, "struts recortan desde arriba")
        }

        // --- center-focused-column ---
        // Anchos de 0.5: dos entran justo, tres no - que es exactamente la
        // condicion que on-overflow mide.
        let centerCols = [column(0.5), column(0.5), column(0.5)]
        let centerPlacements = ColumnLayoutEngine.columnPlacements(
            columns: centerCols, usableWidth: usableWidth, maximizedIndex: nil)
        ColumnLayoutEngine.centerPolicy = .never
        expectEqual(
            ColumnLayoutEngine.scrollOffset(
                toShow: 0, placements: centerPlacements, currentOffset: 0, usableWidth: usableWidth), 0,
            "never: si ya se ve, no se mueve la camara")
        ColumnLayoutEngine.centerPolicy = .always
        let alwaysOffset = ColumnLayoutEngine.scrollOffset(
            toShow: 1, placements: centerPlacements, currentOffset: 0, usableWidth: usableWidth)
        expectEqual(
            alwaysOffset, centerPlacements[1].x + centerPlacements[1].width / 2 - usableWidth / 2,
            "always: centra la columna")
        ColumnLayoutEngine.centerPolicy = .onOverflow
        expectEqual(
            ColumnLayoutEngine.scrollOffset(
                toShow: 1, placements: centerPlacements, currentOffset: 0, usableWidth: usableWidth,
                previousIndex: 0), 0,
            "on-overflow: si entran las dos, no centra")
        let farOffset = ColumnLayoutEngine.scrollOffset(
            toShow: 2, placements: centerPlacements, currentOffset: 0, usableWidth: usableWidth,
            previousIndex: 0)
        expect(farOffset != 0, "on-overflow: si no entran juntas, centra")
        ColumnLayoutEngine.centerPolicy = .never
        ColumnLayoutEngine.alwaysCenterSingleColumn = true
        let single = [column(1.0 / 3.0)]
        let singlePlacements = ColumnLayoutEngine.columnPlacements(
            columns: single, usableWidth: usableWidth, maximizedIndex: nil)
        expectEqual(
            ColumnLayoutEngine.scrollOffset(
                toShow: 0, placements: singlePlacements, currentOffset: 0, usableWidth: usableWidth),
            singlePlacements[0].x + singlePlacements[0].width / 2 - usableWidth / 2,
            "always-center-single-column")
        ColumnLayoutEngine.alwaysCenterSingleColumn = false

        // default-column-display: toda columna nueva nace en ese modo.
        Column.defaultTabbed = true
        expect(Column().isTabbed, "default-column-display alcanza a las columnas nuevas")
        Column.defaultTabbed = false
        expect(!Column().isTabbed, "y vuelve a normal al desactivarlo")

        // --- binds: sin modificador, mod-key, botones del mouse ---
        NigiriConfig.modKey = [.command, .option]
        expect(NigiriConfig.parseCombo("F13") != nil, "un bind sin modificador es legal")
        expect(NigiriConfig.parseCombo("F13")?.1.isEmpty == true, "y llega sin modificadores")
        expect(NigiriConfig.parseCombo("Mod+NoExiste") == nil, "una tecla inexistente sigue siendo un error")
        NigiriConfig.modKey = [.control]
        expect(NigiriConfig.parseCombo("Mod+Left")?.1 == [.control], "mod-key redefine que es Mod")
        NigiriConfig.modKey = [.command, .option]

        expectEqual(
            NigiriConfig.mouseBindingKey(for: "Mod+MouseMiddle") ?? "", "mod-middle",
            "bind de boton del mouse")
        expectEqual(NigiriConfig.mouseBindingKey(for: "MouseBack") ?? "", "back", "boton sin modificador")
        expect(NigiriConfig.mouseBindingKey(for: "Mod+M") == nil, "una tecla normal no es un boton")

        let mouseCfg = NigiriConfig.parse(
            """
            input { mod-key "Ctrl" }
            binds {
                Mod+MouseMiddle { close-window; }
                F13 { open-overview; }
            }
            gestures { four-finger-up open-overview }
            """)
        expectEqual(
            mouseCfg.mouseBindings["mod-middle"] ?? "", "close-window",
            "el bind de mouse no entra en binds{} de teclado")
        expect(
            mouseCfg.binds.contains { $0.combo == "F13" && $0.modifiers.isEmpty },
            "el bind sin modificador se registra")
        expect(mouseCfg.modKey == [.control], "mod-key llega a la config")
        expectEqual(mouseCfg.gestureFourUp, "open-overview", "swipe de 4 dedos")
        NigiriConfig.modKey = [.command, .option]

        // --- IPC: la forma de niri y la vieja, en el mismo socket ---
        expect(NiriProtocol.parse("windows").legacy, "la peticion vieja contesta plano")
        if case .windows = NiriProtocol.parse("\"Windows\"").request {
            expect(!NiriProtocol.parse("\"Windows\"").legacy, "la de niri contesta con sobre Ok/Err")
        } else {
            expect(false, "\"Windows\" se parsea")
        }
        if case .action(let line) = NiriProtocol.parse("{\"Action\":{\"FocusColumnLeft\":{}}}").request {
            expectEqual(line, "focus-column-left", "la accion CamelCase se traduce a la linea del config")
        } else {
            expect(false, "Action se parsea")
        }
        if case .action(let line) = NiriProtocol.parse("{\"Action\":{\"FocusColumn\":{\"index\":3}}}").request
        {
            expectEqual(line, "focus-column 3", "los argumentos viajan en la linea")
        } else {
            expect(false, "Action con argumentos se parsea")
        }
        if case .action(let line) = NiriProtocol.parse("action move-column-to-workspace 2").request {
            expectEqual(line, "move-column-to-workspace 2", "la accion vieja pasa tal cual")
        } else {
            expect(false, "action <linea> se parsea")
        }
        if case .unknown = NiriProtocol.parse("{\"Nope\":{}}").request {
        } else {
            expect(false, "una peticion desconocida no se inventa")
        }
        expectEqual(
            NiriProtocol.kebab("MoveColumnToWorkspaceDown"), "move-column-to-workspace-down",
            "CamelCase -> kebab")

        // Los ids son estables y no se reciclan.
        let w1 = window()
        let w2 = window()
        expect(w1.id != w2.id, "cada ventana tiene su id")
        let wsA = Workspace()
        let wsB = Workspace()
        expect(wsA.id != wsB.id, "cada workspace tiene el suyo")

        // --- insert-hint: la regla de niri es el hueco mas cercano ---
        // Dos columnas de 700x800, gap 10, empezando en x=10.
        let colA = [CGRect(x: 10, y: 44, width: 700, height: 800)]
        let colB = [
            CGRect(x: 720, y: 44, width: 700, height: 400),
            CGRect(x: 720, y: 454, width: 700, height: 390),
        ]
        let grid = [colA, colB]
        // Cerca del borde izquierdo de la primera: columna nueva antes.
        expect(
            ColumnLayoutEngine.insertPosition(
                columnFrames: grid, point: CGPoint(x: 12, y: 400), screenFrame: screen) == .newColumn(0),
            "junto al hueco izquierdo entra como columna nueva")
        // En el medio vertical de la segunda columna, lejos de sus bordes
        // laterales: cae DENTRO de la pila, en el hueco entre sus dos tiles.
        expect(
            ColumnLayoutEngine.insertPosition(
                columnFrames: grid, point: CGPoint(x: 1070, y: 449), screenFrame: screen) == .inColumn(1, 1),
            "sobre el hueco entre dos ventanas entra en la pila")
        // Empate: gana columna nueva (niri: `if vert_dist <= hor_dist`).
        let tie = ColumnLayoutEngine.insertPosition(
            columnFrames: grid, point: CGPoint(x: 715, y: 449), screenFrame: screen)
        expect(tie == .newColumn(1), "el empate entre hueco vertical y horizontal lo gana la columna nueva")
        // Sin columnas no hay a donde caer salvo la primera posicion.
        expect(
            ColumnLayoutEngine.insertPosition(columnFrames: [], point: .zero, screenFrame: screen)
                == .newColumn(0),
            "un workspace vacio recibe la columna 0")

        // --- REGRESSION: la tercera columna desaparecia del overview ---
        // Tres columnas al 50%: la tercera cae mas alla del borde derecho,
        // donde grantedX la pegaba al mismo pixel en el que un tab parkeado
        // espera - y el filtro del overview la tiraba junto con los parkeados.
        let overviewCols = [column(0.5), column(0.5), column(0.5)]
        for c in overviewCols { c.setWindows([window()]) }
        let overviewOut = ColumnLayoutEngine.overviewFrames(
            columns: overviewCols, in: screen, maximizedIndex: nil)
        expectEqual(overviewOut.count, 3, "las tres columnas entran al overview")
        expectEqual(
            overviewOut[2].frame.minX, screen.minX + 10 + 2 * (720 + 10),
            "la tercera conserva su x virtual, sin el clamp de pantalla")
        expect(
            overviewOut.allSatisfy { $0.frame.width > 2 && $0.frame.height > 2 },
            "y ninguna sale degenerada (que es lo unico que el overview filtra ahora)")
        // Y con clamp, que es lo que hacia el camino viejo: la tercera se
        // pega al pixel de parkeo.
        let clamped = ColumnLayoutEngine.targetFrames(
            columns: overviewCols, in: screen, maximizedIndex: nil, viewOffset: 0)
        expectEqual(
            clamped[2].frame.minX, screen.maxX - 1,
            "targetFrames si la clampea: por eso el overview no puede usarlo")

        // --- geometria del overview, la de niri (monitor.rs) ---
        // Un workspace es la PANTALLA por el zoom, no el bounding box de sus
        // ventanas ajustado a una fila: eso era nuestro y aplastaba un strip
        // mas ancho que la pantalla hasta que entrara.
        OverviewPanel.zoom = 0.5
        let wsWindow = window()
        let onScreen = CGRect(x: screen.minX + 10, y: screen.minY + 10, width: 700, height: 800)
        // Una segunda ventana scrolleada fuera de vista, dos pantallas a la
        // derecha del borde.
        let offView = CGRect(x: screen.minX + 2 * screen.width, y: screen.minY + 10, width: 700, height: 800)
        let oneWs = OverviewPanel.computeRows(
            [
                OverviewPanel.WorkspaceInput(
                    wsIndex: 0, active: true,
                    windows: [
                        (window: wsWindow, layoutFrame: onScreen, captureFrame: onScreen),
                        (window: window(), layoutFrame: offView, captureFrame: offView),
                    ])
            ], screenFrame: screen)
        expectEqual(oneWs.rows.count, 1, "un workspace ocupado, una fila")
        let canvas = oneWs.rows[0].canvas
        expectEqual(canvas.width, screen.width * 0.5, "el workspace mide la pantalla por el zoom, a lo ancho")
        expectEqual(canvas.height, screen.height * 0.5, "y tambien a lo alto")
        expectEqual(canvas.minX, screen.minX + screen.width * 0.25, "centrado en horizontal")
        expectEqual(canvas.minY, screen.minY + screen.height * 0.25, "y el activo centrado en vertical")
        expect(
            oneWs.rows[0].entries[1].box.minX > canvas.maxX,
            "la ventana scrolleada fuera de vista queda FUERA del rectangulo, no aplastada adentro")
        expectEqual(
            oneWs.rows[0].entries[0].box.width, 700 * 0.5,
            "y la que si esta a la vista mide su tamano real por el zoom")
        expectEqual(
            oneWs.rows[0].band.width, screen.width,
            "el recorte es de ancho completo: el desborde lateral es justamente el punto")
        expectEqual(
            oneWs.rows[0].band.height, canvas.height,
            "y de alto exactamente el workspace, para no invadir al vecino")

        // Dos workspaces: separacion = alto del workspace + 10% del alto de
        // pantalla por el zoom (niri: workspace_gap).
        let pair = OverviewPanel.computeRows(
            [
                OverviewPanel.WorkspaceInput(
                    wsIndex: 0, active: true,
                    windows: [
                        (window: window(), layoutFrame: onScreen, captureFrame: onScreen)
                    ]),
                OverviewPanel.WorkspaceInput(
                    wsIndex: 1, active: false,
                    windows: [
                        (window: window(), layoutFrame: onScreen, captureFrame: onScreen)
                    ]),
            ], screenFrame: screen)
        expectEqual(pair.rows.count, 2, "dos workspaces ocupados, dos filas")
        expectEqual(
            pair.rows[1].canvas.minY - pair.rows[0].canvas.minY,
            screen.height * 0.5 + screen.height * 0.1 * 0.5,
            "el paso entre workspaces es alto + hueco del 10%")
        expectEqual(
            pair.rows[0].canvas.height, pair.rows[1].canvas.height,
            "y todos miden lo mismo: el zoom es uno solo, no uno por fila")

        // REGRESSION (items 15 y 16): la regla de focus-follows-mouse.
        expect(
            !TilingEngine.shouldFocusFollowMouse(
                overviewActive: true, transitioning: false,
                buttonsDown: 0, sinceLastTick: 1),
            "con el overview abierto NO mueve el foco: el panel maneja su propia seleccion")
        expect(
            !TilingEngine.shouldFocusFollowMouse(
                overviewActive: false, transitioning: true,
                buttonsDown: 0, sinceLastTick: 1),
            "ni en medio de un cambio de workspace")
        expect(
            !TilingEngine.shouldFocusFollowMouse(
                overviewActive: false, transitioning: false,
                buttonsDown: 1, sinceLastTick: 1),
            "ni con un boton apretado (eso es un drag)")
        expect(
            !TilingEngine.shouldFocusFollowMouse(
                overviewActive: false, transitioning: false,
                buttonsDown: 0, sinceLastTick: 0.05),
            "ni antes del throttle")
        expect(
            TilingEngine.shouldFocusFollowMouse(
                overviewActive: false, transitioning: false,
                buttonsDown: 0, sinceLastTick: 1),
            "y si en el caso normal")

        // REGRESSION (item 17): en una columna tabbed las aparcadas viven en
        // maxX-1, asi que la vista previa del drop las tomaba como "el frame
        // de la columna" y medaba el hueco contra el borde derecho de la
        // pantalla. Sin ellas, la primera de cada columna es la que se ve.
        let tabbedDrag = column(0.5)
        tabbedDrag.setWindows([window(), window()])
        tabbedDrag.isTabbed = true
        let plainDrag = column(0.5)
        plainDrag.setWindows([window()])
        let previewFrames = ColumnLayoutEngine.targetFrames(
            columns: [tabbedDrag, plainDrag], in: screen,
            maximizedIndex: nil, viewOffset: 0,
            includingParked: false)
        expectEqual(previewFrames.count, 2, "una entrada por columna visible, sin las aparcadas")
        expect(
            previewFrames.allSatisfy { $0.frame.minX < screen.maxX - 100 },
            "y ninguna es el punto de parkeo del borde derecho")
        let withParked = ColumnLayoutEngine.targetFrames(
            columns: [tabbedDrag, plainDrag], in: screen,
            maximizedIndex: nil, viewOffset: 0)
        expectEqual(
            withParked.count, 3, "el camino normal si las incluye, que es lo que las mantiene aparcadas")

        // Una columna tabbed aporta UNA sola tarjeta, no una por ventana.
        let tabbedCol = column(0.5)
        tabbedCol.setWindows([window(), window(), window()])
        tabbedCol.isTabbed = true
        expectEqual(
            ColumnLayoutEngine.overviewFrames(columns: [tabbedCol], in: screen, maximizedIndex: nil).count, 1,
            "la columna tabbed es una tarjeta")

        // --- REGRESSION: los colores con alpha se caian en silencio ---
        expect(NigiriConfig.parseColor("#7355a6") != nil, "6 digitos")
        let withAlpha = NigiriConfig.parseColor("#00000070")
        expect(withAlpha != nil, "8 digitos (rgba) - el unico modo de escribir una sombra")
        expectEqual(withAlpha?.alphaComponent ?? 0, 0x70 / 255.0, "y el alpha llega")
        let shorthand = NigiriConfig.parseColor("#f0a")
        expect(shorthand != nil, "3 digitos")
        expectEqual(shorthand?.redComponent ?? 0, 1, "el shorthand duplica cada digito")
        expectEqual(
            NigiriConfig.parseColor("#f0a8")?.alphaComponent ?? 0, 0x88 / 255.0, "4 digitos con alpha")
        expect(NigiriConfig.parseColor("#nope") == nil, "y lo invalido sigue siendo nil (ahora con aviso)")

        // --- camara: compute_new_view_offset de niri ---
        // Lo unico que faltaba de verdad: una columna MAS ANCHA que la vista
        // se alinea a la izquierda siempre (antes se alineaba al borde por
        // el que hubiera quedado clipeada, dejando su mitad izquierda
        // inalcanzable).
        expectEqual(
            ColumnLayoutEngine.fitOffset(x: 100, width: 2000, currentOffset: 0, usableWidth: usableWidth),
            100,
            "una columna mas ancha que la vista se alinea a la izquierda")
        expectEqual(
            ColumnLayoutEngine.fitOffset(x: 100, width: 2000, currentOffset: 5000, usableWidth: usableWidth),
            100,
            "y da igual de donde venga la camara")
        // El resto es la regla de siempre, ahora escrita como la de niri:
        // si ya entra, no se mueve; si no, gana la alineacion que menos
        // movimiento cuesta.
        expectEqual(
            ColumnLayoutEngine.fitOffset(x: 20, width: 700, currentOffset: 0, usableWidth: usableWidth), 0,
            "si ya entra, la camara se queda quieta")
        expectEqual(
            ColumnLayoutEngine.fitOffset(x: 1000, width: 700, currentOffset: 0, usableWidth: usableWidth),
            1000 + 700 - usableWidth, "clipeada a la derecha: alinea ese borde")
        expectEqual(
            ColumnLayoutEngine.fitOffset(x: 300, width: 700, currentOffset: 900, usableWidth: usableWidth),
            300,
            "clipeada a la izquierda: alinea ese borde")

        // on-overflow mide contra el VECINO del destino del lado del que
        // venias, no contra la columna de la que saliste: lo que importa es
        // si la vista todavia puede sostener el par que va a cruzar.
        ColumnLayoutEngine.centerPolicy = .onOverflow
        let halves = (0..<3).map { _ in column(0.5) }
        let halfPlacements = ColumnLayoutEngine.columnPlacements(
            columns: halves, usableWidth: usableWidth, maximizedIndex: nil)
        // Tres columnas al 50%: cada par adyacente entra JUSTO, asi que ni
        // el salto largo de 0 a 2 centra - el vecino de 2 viniendo de 0 es
        // la 1, y 1+2 entran.
        expectEqual(
            ColumnLayoutEngine.scrollOffset(
                toShow: 2, placements: halfPlacements, currentOffset: 0, usableWidth: usableWidth,
                previousIndex: 0),
            halfPlacements[2].x + halfPlacements[2].width - usableWidth,
            "on-overflow: si el par entra, es un scroll normal aunque el salto sea largo")
        // Al 66% ningun par entra: ahi si centra.
        let wides = (0..<3).map { _ in column(0.66) }
        let widePlacements = ColumnLayoutEngine.columnPlacements(
            columns: wides, usableWidth: usableWidth, maximizedIndex: nil)
        expectEqual(
            ColumnLayoutEngine.scrollOffset(
                toShow: 1, placements: widePlacements, currentOffset: 0, usableWidth: usableWidth,
                previousIndex: 0),
            widePlacements[1].x - (usableWidth - widePlacements[1].width) / 2,
            "on-overflow: si el par no entra, centra")
        ColumnLayoutEngine.centerPolicy = .never

        // --- invariantes de estructura (la deuda que quedaba) ---
        // Insertar antes de la columna enfocada NO roba el foco: viaja con
        // la columna, no con el indice. Es el agujero por el que el drop del
        // overview salia enfocando otra cosa.
        let inv = Workspace()
        let marked = Column()
        inv.appendColumn(Column()); inv.appendColumn(marked); inv.appendColumn(Column())
        inv.focus(column: 1)
        inv.insertColumn(Column(), at: 0)
        expect(inv.columns[inv.focusedIndex] === marked, "insertar antes no mueve el foco de columna")
        inv.removeColumn(at: 0)
        expect(inv.columns[inv.focusedIndex] === marked, "quitar una anterior tampoco")
        inv.swapColumns(inv.focusedIndex, 2)
        expect(inv.columns[inv.focusedIndex] === marked, "y el swap lo sigue")

        // Toda mutacion de la pila tira el cache de alturas y re-ancla la
        // fila: antes cada call site lo hacia a mano, y los que se olvidaban
        // dejaban alturas viejas o el foco pasando el final.
        let inc = Column()
        inc.setWindows([window(), window(), window()])
        inc.focus(row: 2)
        inc.cachedHeights = [100, 100, 100]
        inc.removeWindow(at: 0)
        expect(inc.cachedHeights == nil, "quitar una ventana invalida el cache de alturas")
        expectEqual(inc.focusedWindowIndex, 1, "y re-ancla la fila enfocada")
        inc.cachedHeights = [100, 100]
        expectEqual(
            inc.removeWindows(where: { _ in false }).count, 0,
            "un removeWindows que no saca nada no toca el cache")
        expect(inc.cachedHeights != nil, "porque corre en cada relayout y re-probar seria eterno")
        // REGRESSION: contains(where:) + removeAll(where:) corria el predicado
        // DOS veces, y hay call sites que no son puros (la democion junta en un
        // array, el purgado cuenta ausencias). La primera coincidencia se
        // duplicaba: la ventana terminaba tileada Y flotante.
        let twice = Column()
        twice.setWindows([window(), window(), window()])
        var seen: [ManagedWindow] = []
        let gone = twice.removeWindows { w in
            seen.append(w); return true
        }
        expectEqual(seen.count, 3, "el predicado corre una vez por ventana, no dos")
        expectEqual(gone.count, 3, "y devuelve las que saco, para no tener que juntarlas adentro")
        expectEqual(twice.windows.count, 0, "que es lo que hace que el predicado pueda ser puro")
        inc.insert(window(), at: 99)
        expectEqual(inc.windows.count, 3, "insertar fuera de rango se clampea, no revienta")
        expect(inc.removeWindow(at: 99) == nil, "y quitar fuera de rango devuelve nil")

        // Un workspace vacio se puede seguir manipulando sin indices sueltos.
        let empty = Workspace()
        expect(empty.removeColumn(at: 0) == nil, "quitar de un workspace vacio no revienta")
        expectEqual(empty.focusedIndex, 0, "y el foco queda en 0")

        // --- gestos del mouse tactil ---
        expect(
            TrackpadGestures.isMouseFamily(112),
            "family 112 es un Magic Mouse (lo reporta el hardware de esta maquina)")
        expect(!TrackpadGestures.isMouseFamily(110), "y 110 es el trackpad interno")
        let gcfg = NigiriConfig.parse(
            """
            gestures {
                mouse-two-finger-left focus-column-right
                mouse-one-finger-up open-overview
            }
            """)
        expectEqual(gcfg.gestureMouseTwo[.left] ?? "", "focus-column-right", "swipe de 2 dedos del mouse")
        expectEqual(gcfg.gestureMouseOne[.up] ?? "", "open-overview", "swipe de 1 dedo del mouse")
        expect(gcfg.gestureMouseTwo[.right] == nil, "y lo que no se ato queda sin atar")

        if failures.isEmpty {
            print("selftest: \(checks) comprobaciones, todo OK")
            exit(0)
        }
        print("selftest: \(failures.count) de \(checks) comprobaciones FALLARON")
        for f in failures { print("  - \(f)") }
        exit(1)
    }
}
