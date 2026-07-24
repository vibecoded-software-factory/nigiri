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
        c.width = .proportion(proportion)
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
            usableWidth: usableWidth)
        let four = ColumnLayoutEngine.columnPlacements(
            columns: (0..<4).map { _ in column(0.5) },
            usableWidth: usableWidth)
        expectEqual(two[0].width, 720, "two 1/2 columns are 720 wide")
        expectEqual(two[1].x, 730, "the second one starts after the gap")
        for i in 0..<2 {
            expectEqual(four[i].width, two[i].width, "the width does not depend on the column count")
            expectEqual(four[i].x, two[i].x, "the x does not depend on the column count")
        }

        let thirds = ColumnLayoutEngine.columnPlacements(
            columns: (0..<3).map { _ in column(1.0 / 3) },
            usableWidth: usableWidth)
        expectEqual(
            thirds.reduce(0) { $0 + $1.width } + 2 * ColumnLayoutEngine.gap, usableWidth,
            "three 1/3 columns fill the usable area exactly")

        let floored = ColumnLayoutEngine.columnPlacements(
            columns: [column(0.5, minWidth: 800), column(0.5)],
            usableWidth: usableWidth)
        expectEqual(floored[0].width, 800, "a discovered floor widens its own column")
        expectEqual(floored[1].x, 810, "and pushes the next one over")
        expectEqual(floored[1].width, 720, "without shrinking it")

        let maxedCols = [column(0.5), column(0.5)]
        maxedCols[1].isFullWidth = true
        let maxed = ColumnLayoutEngine.columnPlacements(
            columns: maxedCols, usableWidth: usableWidth)
        expectEqual(maxed[1].width, usableWidth, "a full-width column takes the whole usable width")
        // is_full_width is per COLUMN (scrolling.rs:170): two columns can
        // hold it at once - impossible under the old single-index model.
        let bothFull = [column(0.5), column(0.5)]
        bothFull.forEach { $0.isFullWidth = true }
        let bothPlaced = ColumnLayoutEngine.columnPlacements(
            columns: bothFull, usableWidth: usableWidth)
        expectEqual(bothPlaced[0].width, usableWidth, "several columns can be full-width at once (first)")
        expectEqual(bothPlaced[1].width, usableWidth, "several columns can be full-width at once (second)")

        // --- ColumnWidth::Fixed (audit LAY-6) -----------------------------
        // niri's resolve_column_width (scrolling.rs:4401-4411): fixed pixels
        // ARE the width - they do not re-derive from gaps or the view, so a
        // monitor or gap change leaves a fixed column alone while a
        // proportional one follows.
        let fixedWidthCol = column(0.5)
        fixedWidthCol.width = .fixed(800)
        let propCol = column(0.5)
        let mixedKinds = ColumnLayoutEngine.columnPlacements(
            columns: [fixedWidthCol, propCol], usableWidth: usableWidth)
        expectEqual(mixedKinds[0].width, 800, "a fixed column takes exactly its pixels")
        expectEqual(mixedKinds[1].width, 720, "next to a proportional one resolved by the formula")
        let savedGapForFixed = ColumnLayoutEngine.gap
        ColumnLayoutEngine.gap = 40
        let mixedWideGap = ColumnLayoutEngine.columnPlacements(
            columns: [fixedWidthCol, propCol], usableWidth: usableWidth)
        expectEqual(mixedWideGap[0].width, 800, "a gap change does not move a fixed width")
        expect(
            abs(mixedWideGap[1].width - ((usableWidth + 40) * 0.5 - 40)) < 0.01,
            "while the proportional neighbor re-resolves against the new gap")
        ColumnLayoutEngine.gap = savedGapForFixed
        expectEqual(
            ColumnLayoutEngine.resolveColumnWidth(.fixed(800), usableWidth: 300), 800,
            "fixed ignores the view width too - that is the whole point")
        // default-column-width {} (natural): the window's own width, stored
        // FIXED (resolve_scrolling_width, workspace.rs:890).
        expect(
            ColumnLayoutEngine.resolveDefaultWidth(.natural, windowWidth: 963) == .fixed(963),
            "an empty default-column-width stores the window's width as fixed")

        // --- rubber band (audit ANI-3) ------------------------------------
        // niri's rubber_band.rs, values computed by hand for c=0.5, d=0.05:
        // band(0.1) = (1 - 1/(0.1*0.5/0.05 + 1))*0.05 = 0.025;
        // derivative(0) = c = 0.5; derivative(0.1) = 0.5*0.05^2/(0.1)^2.
        let rb = RubberBand.workspaceGesture
        expectEqual(rb.band(0), 0, "no overshoot, no band")
        expect(abs(rb.band(0.1) - 0.025) < 1e-9, "band(0.1) = 0.025 exactly")
        expect(rb.band(1000) < rb.limit, "the band never exceeds its limit")
        expect(abs(rb.derivative(0) - 0.5) < 1e-9, "slope at the boundary is the stiffness")
        expect(abs(rb.derivative(0.1) - 0.125) < 1e-9, "derivative(0.1) = 0.125 exactly")
        expect(abs(rb.clamp(0, 1, 1.1) - 1.025) < 1e-9, "overshoot past max is banded, not cut")
        expect(abs(rb.clamp(0, 1, -0.1) - (-0.025)) < 1e-9, "and symmetric past min")
        expectEqual(rb.clamp(0, 1, 0.5), 0.5, "inside the range clamp is the identity")
        expectEqual(rb.clampDerivative(0, 1, 0.5), 1, "inside the range the slope is 1")
        expect(abs(rb.clampDerivative(0, 1, 1.1) - 0.125) < 1e-9, "outside it is the band's slope")
        expect(
            abs(RubberBand.interactiveMoveStart.band(1) - 1.0 / 3.0) < 1e-9,
            "the interactive-move threshold band (c=1, d=0.5): band(1) = 1/3")

        // niri's update_tile_sizes_with_transaction clamp: a fixed-size tile
        // (AX: size not settable, min == max) resolves its column to EXACTLY
        // its own width, whatever proportion was requested. REGRESSION: the
        // clamp only had the floor half, so a rule-tiled AWS VPN Client kept
        // a phantom 720px column around a 440px window and every decoration
        // animated toward frames that never matched reality.
        let fixedCol = column(0.5)
        let fixedWin = window()
        fixedWin.fixedSize = CGSize(width: 440, height: 388)
        fixedCol.setWindows([fixedWin])
        let fixedPlacements = ColumnLayoutEngine.columnPlacements(
            columns: [fixedCol, column(0.5)],
            usableWidth: usableWidth)
        expectEqual(fixedPlacements[0].width, 440, "a fixed-size window resolves its column to its own width")
        expectEqual(fixedPlacements[1].x, 450, "and the next column packs against the clamped width")
        expectEqual(
            ColumnLayoutEngine.naiveHeights(for: [fixedWin], usableHeight: 892)[0], 388,
            "an exact size constraint fixes the height like set-window-height")
        fixedCol.isFullWidth = true
        let maxedFixed = ColumnLayoutEngine.columnPlacements(
            columns: [fixedCol], usableWidth: usableWidth)
        expectEqual(maxedFixed[0].width, 440, "maximize cannot outgrow a fixed-size window either")
        fixedCol.isFullWidth = false

        // niri sizes decorations from the tile's ACTUAL geometry; an
        // animation target the app already refused is aimed at the app's
        // answer at the new origin, so ring and window stay one rectangle.
        let refused = (
            requested: CGRect(x: 10, y: 54, width: 710, height: 892),
            actual: CGRect(x: 10, y: 54, width: 800, height: 892)
        )
        expect(
            ColumnLayoutEngine.isClose(
                ColumnLayoutEngine.reachableTarget(
                    CGRect(x: 500, y: 54, width: 710, height: 892), memo: refused),
                CGRect(x: 500, y: 54, width: 800, height: 892)),
            "a refused size re-aims at the answer, translated to the new origin")
        expect(
            ColumnLayoutEngine.isClose(
                ColumnLayoutEngine.reachableTarget(
                    CGRect(x: 500, y: 54, width: 600, height: 892), memo: refused),
                CGRect(x: 500, y: 54, width: 600, height: 892)),
            "a DIFFERENT size request is not the memoized one - ask the app")
        expect(
            ColumnLayoutEngine.isClose(
                ColumnLayoutEngine.reachableTarget(
                    CGRect(x: 500, y: 54, width: 710, height: 892), memo: nil),
                CGRect(x: 500, y: 54, width: 710, height: 892)),
            "no memo, no substitution")

        // REGRESSION: four sites inverted the width with a different,
        // count-dependent formula, so a column's floor moved when an
        // unrelated column opened.
        for px in [CGFloat(200), 720, 1000, usableWidth] {
            let p = ColumnLayoutEngine.proportion(forWidth: px, usableWidth: usableWidth)
            expectEqual(
                ColumnLayoutEngine.width(forProportion: p, usableWidth: usableWidth), px,
                "pixels -> proportion -> pixels round-trips")
        }

        // --- the macOS x clamp ------------------------------------------
        // REGRESSION: asking for a fully-off-screen x makes macOS drag the
        // window 40px back IN, on top of the visible columns.
        expectEqual(
            ColumnLayoutEngine.grantedX(1470, width: 720, screenFrame: screen), 1469,
            "right edge: 1px inside")
        expectEqual(
            ColumnLayoutEngine.grantedX(1500, width: 720, screenFrame: screen), 1469,
            "past the edge as well")
        expectEqual(
            ColumnLayoutEngine.grantedX(-720, width: 720, screenFrame: screen), -719,
            "left edge: 1px inside")
        expectEqual(
            ColumnLayoutEngine.grantedX(10, width: 720, screenFrame: screen), 10, "a visible x is honored")

        // REGRESSION: with four columns, the ones out of view overlapped the
        // ones on screen.
        for offset in [CGFloat(0), 730, 1460] {
            let frames = ColumnLayoutEngine.targetFrames(
                columns: (0..<4).map { _ in column(0.5) },
                in: screen, viewOffset: offset)
            let onScreen = frames.map(\.frame).filter {
                min(screen.maxX, $0.maxX) - max(screen.minX, $0.minX) > 2
            }
            for (i, a) in onScreen.enumerated() {
                for b in onScreen[(i + 1)...] {
                    expect(
                        min(a.maxX, b.maxX) - max(a.minX, b.minX) <= 0.001,
                        "visible columns overlap at viewOffset \(Int(offset))")
                }
            }
        }

        // --- scroll offset ("never" recenters) ---------------------------
        expectEqual(
            ColumnLayoutEngine.scrollOffset(
                toShow: 1, placements: two, currentOffset: 0, usableWidth: usableWidth),
            0, "an already visible column does not scroll")
        let three = ColumnLayoutEngine.columnPlacements(
            columns: (0..<3).map { _ in column(0.5) },
            usableWidth: usableWidth)
        expectEqual(
            ColumnLayoutEngine.scrollOffset(
                toShow: 2, placements: three, currentOffset: 0, usableWidth: usableWidth),
            three[2].x + three[2].width - usableWidth, "clipped on the right: align that edge")
        expectEqual(
            ColumnLayoutEngine.scrollOffset(
                toShow: 0, placements: three, currentOffset: 900, usableWidth: usableWidth),
            three[0].x, "clipped on the left: align that edge")
        expectEqual(
            ColumnLayoutEngine.scrollOffset(
                toShow: 9, placements: three, currentOffset: 123, usableWidth: usableWidth),
            123, "an out-of-range index leaves the offset alone")

        // --- height split -------------------------------------------------
        let equalStack = (0..<3).map { _ in window() }
        expectEqual(
            ColumnLayoutEngine.naiveHeights(for: equalStack, usableHeight: 900)[0], 300,
            "three Auto windows split evenly")

        // REGRESSION: consuming/expelling re-equalized a stack the user had
        // deliberately made uneven (niri's Auto { weight }).
        let weighted = (0..<3).map { _ in window() }
        weighted[0].heightWeight = 2
        let wh = ColumnLayoutEngine.naiveHeights(for: weighted, usableHeight: 900)
        expectEqual(wh[0], 450, "weight 2 takes twice as much")
        expectEqual(wh[1], 225, "and the rest share what is left")

        let manual = (0..<3).map { _ in window() }
        manual[0].manualHeightPx = 400
        let mh = ColumnLayoutEngine.naiveHeights(for: manual, usableHeight: 900)
        expectEqual(mh[0], 400, "a manual height is exact")
        expectEqual(mh[1], 250, "and the Auto ones share the remainder")

        let overflowing = (0..<2).map { _ in window() }
        overflowing[0].manualHeightPx = 2000
        expect(
            ColumnLayoutEngine.naiveHeights(for: overflowing, usableHeight: 900)[1] >= 0,
            "a manual height taller than the column never leaves a negative one")

        // --- entering a column is auto_1 (audit LAY-3) --------------------
        // niri's add_tile (scrolling.rs:4297-4312): the arriving tile is
        // auto_1 - its old fixed height/weight does not travel - and the
        // existing members keep their weights (no re-equalization on
        // membership changes).
        let joiner = window()
        joiner.manualHeightPx = 500
        joiner.heightWeight = 3
        let joinedStack = Column()
        joinedStack.setWindows([window(), window()])
        joinedStack.windows[0].heightWeight = 2
        joinedStack.add(joiner)
        expect(
            joiner.manualHeightPx == nil && joiner.heightWeight == 1,
            "a consumed window enters as auto_1 - its old height does not travel")
        expectEqual(joinedStack.windows[0].heightWeight, 2, "and the existing members keep their weights")
        let expelled = window()
        expelled.manualHeightPx = 500
        let freshColumn = Column()
        freshColumn.setWindows([expelled])
        expect(
            expelled.manualHeightPx == nil,
            "an expelled window fills its fresh column instead of keeping its old fixed height")
        let reordered = window()
        let stack2 = Column()
        stack2.setWindows([reordered, window()])
        reordered.manualHeightPx = 500
        stack2.removeWindow(at: 0)
        stack2.reinsert(reordered, at: 1)
        expect(
            reordered.manualHeightPx == 500,
            "an in-column reorder keeps the height data - the window never left")

        // --- preset heights re-resolve every pass (audit LAY-8) -----------
        // niri stores WindowHeight::Preset(idx) and update_tile_sizes
        // re-resolves it (scrolling.rs:4533-4547): a monitor or gap change
        // re-applies the proportion. Materialized pixels kept the OLD size.
        let savedGapForPresets = ColumnLayoutEngine.gap
        let savedHeightPresets = ColumnLayoutEngine.presetWindowHeightSizes
        ColumnLayoutEngine.gap = 16
        ColumnLayoutEngine.presetWindowHeightSizes = [.proportion(1.0 / 3.0), .proportion(0.5)]
        let presetWindow = window()
        presetWindow.presetHeightIndex = 0
        let plainWindow = window()
        let tall = ColumnLayoutEngine.naiveHeights(for: [presetWindow, plainWindow], usableHeight: 890)
        // columnHeight = 890 + 16 = 906; preset 1/3 -> (906+16)/3 - 16 = 291.33
        expect(abs(tall[0] - ((906.0 + 16) / 3 - 16)) < 0.01, "a Preset height resolves via niri's formula")
        expect(abs(tall[0] + tall[1] - 890) < 0.01, "and the Auto sibling absorbs the rest")
        let short = ColumnLayoutEngine.naiveHeights(for: [presetWindow, plainWindow], usableHeight: 590)
        expect(
            abs(short[0] - ((606.0 + 16) / 3 - 16)) < 0.01,
            "a different column height RE-resolves the preset - it is not frozen pixels")
        presetWindow.setFixedHeight(400)
        expect(
            presetWindow.presetHeightIndex == nil && presetWindow.manualHeightPx == 400,
            "an explicit resize replaces the preset with Fixed, like set_window_height")
        ColumnLayoutEngine.gap = savedGapForPresets
        ColumnLayoutEngine.presetWindowHeightSizes = savedHeightPresets

        // --- convert-to-auto weighting (audit LAY-2) ----------------------
        // niri's convert_heights_to_auto: weights preserve apparent heights,
        // centered at the median (scrolling.rs:5070-5083).
        expectEqual(
            ColumnLayoutEngine.autoWeights(preserving: [300, 600, 300]), [1, 2, 1],
            "weights preserve apparent heights with the median at 1")
        expectEqual(
            ColumnLayoutEngine.autoWeights(preserving: [200, 400]), [0.5, 1],
            "an even count takes sorted[len/2] as the median, like upstream")

        // --- workspace invariants -----------------------------------------
        // is_full_width lives ON the column (scrolling.rs:170), so it needs
        // no re-anchoring: it survives removals, inserts and swaps by
        // construction - the flag travels with the object.
        let ws = Workspace()
        for _ in 0..<4 { ws.appendColumn(Column()) }
        let fullCol = ws.columns[2]
        fullCol.isFullWidth = true
        ws.removeColumn(at: 0)
        expect(
            ws.columns[1] === fullCol && fullCol.isFullWidth,
            "the full-width flag follows its column when an earlier one goes")
        ws.insertColumn(Column(), at: 0)
        ws.swapColumns(0, 2)
        expect(fullCol.isFullWidth, "and survives inserts and swaps - it is a property of the column")

        // --- SizeChange ----------------------------------------------------
        // REGRESSION: every form was treated as an adjustment, so
        // set-column-width "50%" GREW the column by half instead.
        if case .setProportion(let v)? = SizeChange.parse("50%") {
            expectEqual(v, 50, "50% sets")
        } else {
            failures.append("50% should be setProportion")
        }
        if case .adjustProportion(let v)? = SizeChange.parse("+10%") {
            expectEqual(v, 10, "+10% adjusts")
        } else {
            failures.append("+10% should be adjustProportion")
        }
        if case .setFixed(let v)? = SizeChange.parse("1000") {
            expectEqual(v, 1000, "1000 sets pixels")
        } else {
            failures.append("1000 should be setFixed")
        }
        if case .adjustFixed(let v)? = SizeChange.parse("-100") {
            expectEqual(v, -100, "-100 adjusts pixels")
        } else {
            failures.append("-100 should be adjustFixed")
        }
        expect(SizeChange.parse("abc") == nil, "an argument that is not a size is rejected")
        // REGRESSION (fidelity audit LAY-1): the floating path collapsed all
        // four forms into a delta, so set-column-width "50%" GREW a floating
        // window by half the screen instead of setting it to half - the same
        // bug the header of SizeChange.swift records as fixed for tiled.
        // Semantics per src/layout/floating.rs:744-830, working area 1000.
        expectEqual(
            SizeChange.setProportion(50).resolvedFloating(current: 800, available: 1000), 500,
            "floating SetProportion SETS to that share of the working area")
        expectEqual(
            SizeChange.setFixed(640).resolvedFloating(current: 800, available: 1000), 640,
            "floating SetFixed sets exact pixels")
        expectEqual(
            SizeChange.adjustFixed(-100).resolvedFloating(current: 800, available: 1000), 700,
            "floating AdjustFixed is a PIXEL delta, not a percent of the screen")
        expectEqual(
            SizeChange.adjustProportion(10).resolvedFloating(current: 800, available: 1000), 900,
            "floating AdjustProportion adds points of working-area proportion")
        expectEqual(
            SizeChange.adjustFixed(-2000).resolvedFloating(current: 800, available: 1000), 1,
            "the result clamps at 1px, like upstream's clamp(1., MAX_PX)")

        // --- niri Action decoding ------------------------------------------
        // REGRESSION: a bar clicking a workspace sends
        // {"Action":{"FocusWorkspace":{"reference":{"Id":5}}}}. The nested
        // reference used to be dropped, so the click resolved to a bare
        // focus-workspace and did nothing.
        func actionLine(_ json: String) -> String? {
            if case .action(let line) = NiriProtocol.parse(json).request { return line }
            return nil
        }
        expectEqual(
            actionLine("{\"Action\":{\"FocusColumnLeft\":{}}}"), "focus-column-left",
            "a no-arg Action decodes to its kebab line")
        expectEqual(
            actionLine("{\"Action\":{\"FocusWorkspace\":{\"reference\":{\"Id\":5}}}}"),
            "focus-workspace id=5", "FocusWorkspace by Id carries the reference as id=5")
        expectEqual(
            actionLine("{\"Action\":{\"FocusWorkspace\":{\"reference\":{\"Index\":2}}}}"),
            "focus-workspace index=2", "FocusWorkspace by Index carries index=2")
        // REGRESSION: {"id": N} used to flatten positionally ("close-window
        // 5"), the handler's kvArg("id") never saw it, and CloseWindow{id}
        // closed the FOCUSED window instead of window 5.
        expectEqual(
            actionLine("{\"Action\":{\"CloseWindow\":{\"id\":5}}}"), "close-window id=5",
            "CloseWindow carries its target as id=5")
        expectEqual(
            actionLine("{\"Action\":{\"CloseWindow\":{}}}"), "close-window",
            "CloseWindow with no id targets the focused window, like niri")
        expectEqual(
            actionLine("{\"Action\":{\"FocusWindow\":{\"id\":7}}}"), "focus-window id=7",
            "FocusWindow carries its target as id=7")
        // REGRESSION (fidelity audit IPC-3, verified empirically):
        // JSONSerialization's __NSCFBoolean matched `as? Int` BEFORE the Bool
        // branch, so focus:true flattened to a positional 1 and
        // MoveWindowToWorkspace{reference:{Index:2}, focus:true} moved the
        // window to workspace 1 - the wrong workspace, with an Ok reply.
        expectEqual(
            actionLine(
                "{\"Action\":{\"MoveWindowToWorkspace\":{\"window_id\":null,\"reference\":{\"Index\":2},\"focus\":true}}}"
            ),
            "move-window-to-workspace focus=true index=2",
            "a JSON bool stays a key=value flag, never a positional 1")
        expectEqual(
            actionLine("{\"Action\":{\"Quit\":{\"skip_confirmation\":true}}}"),
            "quit skip-confirmation=true",
            "snake_case payload fields flatten to the kebab spelling the handler reads")
        // REGRESSION (IPC-3): Spawn{command:[...]} is a JSON array; no branch
        // matched it, so `spawn` arrived bare and no-opped.
        expectEqual(
            actionLine("{\"Action\":{\"Spawn\":{\"command\":[\"open\",\"-a\",\"Safari\"]}}}"),
            "spawn open -a Safari", "Spawn's argv array survives")
        // REGRESSION (IPC-3): niri's SizeChange is a tagged enum on the wire;
        // it flattened to set-proportion=50.0, which SizeChange.parse read as
        // nil - a no-op with an Ok reply.
        expectEqual(
            actionLine("{\"Action\":{\"SetColumnWidth\":{\"change\":{\"SetProportion\":50.0}}}}"),
            "set-column-width 50%", "SetProportion becomes niri's own \"50%\" spelling")
        expectEqual(
            actionLine("{\"Action\":{\"SetWindowHeight\":{\"change\":{\"AdjustProportion\":-10.0}}}}"),
            "set-window-height -10%", "AdjustProportion keeps its sign")
        expectEqual(
            actionLine("{\"Action\":{\"SetColumnWidth\":{\"change\":{\"AdjustFixed\":100.0}}}}"),
            "set-column-width +100", "a positive adjust gains the + SizeChange.parse needs")

        // --- key combos ----------------------------------------------------
        // REGRESSION: virtual keycodes are physical POSITIONS. On Workman the
        // key that types "f" is where QWERTY has "u", so Mod+Shift+F fired
        // the bind registered for Mod+U.
        NigiriConfig.layoutKeyCodes = ["f": 0x20]
        expectEqual(
            Int(NigiriConfig.parseCombo("Mod+F")?.0 ?? 0), 0x20,
            "the combo uses the active layout, not the US position")
        expect(NigiriConfig.parseCombo("Mod+F")?.1 == [.command, .option], "Mod is Cmd+Opt")
        NigiriConfig.layoutKeyCodes = [:]
        expectEqual(
            Int(NigiriConfig.parseCombo("Mod+Left")?.0 ?? 0), 0x7B,
            "a key with no character falls back to the fixed table")
        // CFG-24: niri's modifier spellings only (input.rs:439-453). The
        // invented Hyper/Cmd/Opt words are gone; Super/Win is Command, Alt
        // is Option, ISO_Level3_Shift (AltGr) maps to Option.
        expect(
            NigiriConfig.parseCombo("Super+Alt+F19")?.1 == [.command, .option],
            "Super+Alt maps to Command+Option")
        expect(
            NigiriConfig.parseCombo("ISO_Level3_Shift+F19")?.1 == [.option],
            "ISO_Level3_Shift (AltGr) is Option on macOS")
        expect(
            NigiriConfig.parseCombo("Hyper+F19") == nil,
            "Hyper was invented vocabulary and is rejected, like niri would")
        expect(
            NigiriConfig.parseCombo("Cmd+F19") == nil,
            "Cmd was invented vocabulary; niri spells it Super/Win")
        expect(NigiriConfig.parseCombo("Garbage+A") == nil, "a nonexistent modifier is rejected")

        // niri's bind `repeat` (binds.rs): default true, opt-out per bind.
        let repeatConfig = NigiriConfig.parse(
            """
            binds {
                Mod+A { focus-column-left; }
                Mod+B repeat=false { focus-column-right; }
            }
            """)
        expect(repeatConfig.binds.first?.repeats == true, "binds repeat by default, like niri")
        expect(
            repeatConfig.binds.last?.repeats == false,
            "repeat=false opts a bind out of held-key re-fire")

        // --- spawns, gestures blocks, hot corners --------------------------
        // niri's spawn-at-startup is argv (misc.rs): quoting must survive,
        // and an unknown BLOCK inside gestures{} must be skipped as a block
        // (consumed as statements it corrupted everything after it).
        let spawnConfig = NigiriConfig.parse(
            """
            spawn-at-startup "open" "-a" "Google Chrome"
            spawn-sh-at-startup "sleep 1 && open -a Music"
            gestures {
                hot-corners {
                    top-right
                }
                dnd-edge-view-scroll {
                    trigger-width 30
                }
            }
            layout {
                gaps 33
            }
            """)
        expectEqual(
            spawnConfig.spawnAtStartup.first ?? [], ["open", "-a", "Google Chrome"],
            "spawn-at-startup keeps its argv - a quoted app name stays one arg")
        expectEqual(
            spawnConfig.spawnShAtStartup.first ?? "", "sleep 1 && open -a Music",
            "spawn-sh-at-startup carries the whole line for the shell")
        expect(spawnConfig.hotCornerTopRight, "hot-corners top-right parses")
        expect(!spawnConfig.hotCornersOff, "hot corners stay enabled unless `off`")
        expectEqual(
            Double(spawnConfig.gap), 33,
            "an unknown gestures block does not corrupt the sections after it")

        // --- window-rule niri syntax --------------------------------------
        let ruleConfig = NigiriConfig.parse(
            """
            window-rule {
                match app-id="org.example.app" is-focused="true"
                default-floating-position x=32 y=64 relative-to="bottom-right"
                open-maximized false
            }
            """)
        expectEqual(
            ruleConfig.rules.first?.defaultFloatingPosition ?? .zero, CGPoint(x: 32, y: 64),
            "default-floating-position parses niri's x=/y= property form")
        expectEqual(
            ruleConfig.rules.first?.defaultFloatingPositionRelativeTo ?? "", "bottom-right",
            "and carries the relative-to anchor")
        expect(
            ruleConfig.rules.first?.matchers.first?.isFocused == true,
            "is-focused is its own matcher, not an is-active alias")
        expect(
            ruleConfig.rules.first?.openMaximized == false,
            "open-maximized false is a real value, not merged away")
        expectEqual(
            NigiriConfig.wheelBindingKey(for: "Mod+WheelScrollDown") ?? "", "mod-down",
            "niri's wheel binds are accepted")
        expectEqual(
            NigiriConfig.wheelBindingKey(for: "Mod+Ctrl+WheelScrollLeft") ?? "", "mod-ctrl-left",
            "with extra modifiers")
        expect(NigiriConfig.wheelBindingKey(for: "Mod+T") == nil, "a plain bind is not a wheel bind")

        // --- config tokenizer ----------------------------------------------
        expect(
            NigiriConfig.tokenize("spawn open -a \"Google Chrome\"") == [
                "spawn", "open", "-a", "Google Chrome",
            ],
            "a quoted token keeps its spaces")
        expect(
            NigiriConfig.tokenize("width 4 // comment") == ["width", "4"], "comments are dropped")
        expect(
            NigiriConfig.tokenize("title \"a // b\"") == ["title", "a // b"], "but not inside quotes")
        expect(NigiriConfig.parseColor("#7355a6") != nil, "color with #")
        expect(NigiriConfig.parseColor("7355a6") != nil, "color without #")

        // REGRESSION: niri's real config writes `include "x.kdl" //comment`.
        // Trimming quotes off both ends left `x.kdl" //comment` and the include
        // silently failed - so nigiri reading niri's own config lost every file
        // it pulled in with a trailing comment (its window-rules, among others).
        let incDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("nigiri-inc-\(getpid())")
        try? FileManager.default.createDirectory(
            atPath: incDir, withIntermediateDirectories: true)
        try? "gaps 42".write(
            toFile: (incDir as NSString).appendingPathComponent("child.kdl"),
            atomically: true, encoding: .utf8)
        var incRead: Set<String> = []
        let incExpanded = NigiriConfig.expandIncludes(
            "include \"child.kdl\" //dms overrides", baseDir: incDir, read: &incRead)
        expect(
            incExpanded?.contains("gaps 42") ?? false,
            "an include with a trailing comment still resolves")
        // CFG-12: niri's include semantics (lib.rs:297-443).
        incRead = []
        expect(
            NigiriConfig.expandIncludes(
                "include \"missing.kdl\" optional=true", baseDir: incDir, read: &incRead) == "",
            "a missing OPTIONAL include is tolerated with a warning")
        incRead = []
        expect(
            NigiriConfig.expandIncludes(
                "include \"missing.kdl\"", baseDir: incDir, read: &incRead) == nil,
            "a missing REQUIRED include refuses the whole config, like niri")
        expect(
            incRead.contains { $0.hasSuffix("missing.kdl") },
            "the failed include is still collected for the watcher (upstream stores it too)")
        // The same child from two parents is legal (IncludeStack is per
        // branch); a global visited set used to silently drop the second.
        try? "include \"child.kdl\"".write(
            toFile: (incDir as NSString).appendingPathComponent("mid.kdl"),
            atomically: true, encoding: .utf8)
        incRead = []
        let incTwice = NigiriConfig.expandIncludes(
            "include \"child.kdl\"\ninclude \"mid.kdl\"", baseDir: incDir, read: &incRead)
        expect(
            (incTwice?.components(separatedBy: "gaps 42").count ?? 0) - 1 == 2,
            "the same file included from two parents lands twice, like niri's parts")
        // Self-recursion within a branch refuses the config.
        try? "include \"loop.kdl\"".write(
            toFile: (incDir as NSString).appendingPathComponent("loop.kdl"),
            atomically: true, encoding: .utf8)
        incRead = []
        expect(
            NigiriConfig.expandIncludes(
                "include \"loop.kdl\"", baseDir: incDir, read: &incRead) == nil,
            "a self-including file is recursion and refuses the config")
        // Includes are TOP-LEVEL only (lib.rs:297): inside a section the
        // line is ordinary content, not a directive.
        incRead = []
        let nested = NigiriConfig.expandIncludes(
            "layout {\n    include \"child.kdl\"\n}", baseDir: incDir, read: &incRead)
        expect(
            nested?.contains("gaps 42") == false,
            "an include inside a section is not expanded")
        try? FileManager.default.removeItem(atPath: incDir)

        // REGRESSION: the tokenizer eats the quotes, so the bind's action has
        // to survive re-quoting - `open -a Google Chrome` opens nothing.
        expect(
            TilingEngine.spawnArgv("open -a 'Google Chrome'") == ["open", "-a", "Google Chrome"],
            "spawn honors single quotes")
        expect(
            TilingEngine.spawnArgv("open -a \"Google Chrome\"") == ["open", "-a", "Google Chrome"],
            "and double ones")

        // --- spring ---------------------------------------------------------
        let spring = Spring(stiffness: 2200)
        expectEqual(CGFloat(spring.remainingFraction(at: 0)), 1, "starts at 1")
        var previous = 1.0
        var monotonic = true
        var nonNegative = true
        for step in 1...1000 {
            let v = spring.remainingFraction(at: Double(step) / 1000)
            if v > previous + 1e-9 { monotonic = false }
            if v < -1e-9 { nonNegative = false }
            previous = v
        }
        expect(monotonic, "the spring decays without overshooting")
        expect(nonNegative, "critically damped: it never crosses zero")
        expect(previous < 0.005, "it settles within the second")

        // --- decorations ------------------------------------------------------
        // REGRESSION: the border of a window parked 1px off-screen painted a
        // stripe across the window you CAN see.
        expect(
            TilingEngine.decorationIsVisible(CGRect(x: 10, y: 44, width: 720, height: 902), on: screen),
            "a visible window gets decoration")
        expect(
            !TilingEngine.decorationIsVisible(CGRect(x: 1469, y: 44, width: 720, height: 902), on: screen),
            "one parked on the right does not")
        expect(
            !TilingEngine.decorationIsVisible(CGRect(x: -719, y: 44, width: 720, height: 902), on: screen),
            "nor one parked on the left")

        // ===================== Tier 2 =====================

        // --- width currency, the acceptance test for the unification ------
        // A column with a discovered floor must render at exactly that
        // floor, whatever the column count: the old inverse used a
        // count-dependent denominator, so the floor drifted by a gap per
        // column.
        for count in [1, 2, 4, 6] {
            let cols = (0..<count).map { _ in column(0.5) }
            cols[0].cachedMinWidth = 800
            let p = ColumnLayoutEngine.columnPlacements(
                columns: cols, usableWidth: usableWidth)
            expectEqual(p[0].width, 800, "the 800px floor holds with \(count) column(s)")
        }
        // ...and the proportion that renders 800px is the same regardless.
        let pFor800 = ColumnLayoutEngine.proportion(forWidth: 800, usableWidth: usableWidth)
        expectEqual(
            ColumnLayoutEngine.width(forProportion: pFor800, usableWidth: usableWidth), 800,
            "the proportion for 800px maps back to 800px")

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
            columns: [tabbed], in: screen, viewOffset: 0)
        expectEqual(tabFrames.count, 3, "a tabbed column still reports all of its windows")
        let visible = tabFrames.filter { $0.frame.minX < screen.maxX - 2 }
        expectEqual(visible.count, 1, "only one stays on screen")
        expect(visible.first?.window === tabWindows[1], "the focused one")
        expectEqual(
            visible.first?.frame.height ?? 0, screen.height - 2 * ColumnLayoutEngine.gap,
            "and it takes the column's full height (the indicator goes outside)")
        for f in tabFrames where f.frame.minX >= screen.maxX - 2 {
            expectEqual(f.frame.minX, screen.maxX - 1, "the others sit 1px from the edge")
        }

        // --- the geometry both passes now share -----------------------------
        // columnGeometry is the single placement computation; targetFrames
        // must agree with it column by column (this is the invariant whose
        // absence let grantedX land in one pass and not the other).
        let mixed = [column(0.5), column(1.0 / 3), column(0.5, minWidth: 900)]
        for c in mixed { c.setWindows([window()]) }
        let geometries = ColumnLayoutEngine.columnGeometry(
            columns: mixed, in: screen, viewOffset: 300)
        let mixedFrames = ColumnLayoutEngine.targetFrames(
            columns: mixed, in: screen, viewOffset: 300)
        expectEqual(geometries.count, mixedFrames.count, "one geometry per single-window column")
        for (g, f) in zip(geometries, mixedFrames) {
            expectEqual(f.frame.minX, g.x, "targetFrames uses columnGeometry's x")
            expectEqual(f.frame.width, g.width, "and its width")
        }

        // --- workspace focus invariants -------------------------------------
        // The class of bug R4 makes unrepresentable: focus surviving past the
        // end of the array after a removal.
        let fws = Workspace()
        for _ in 0..<3 { fws.appendColumn(Column()) }
        fws.focus(column: 2)
        fws.removeColumn(at: fws.columns.count - 1)
        expectEqual(fws.focusedIndex, 1, "focus re-anchors when the last column is removed")
        fws.focus(column: 99)
        expectEqual(fws.focusedIndex, fws.columns.count - 1, "you cannot focus past the end")
        fws.focus(column: -5)
        expectEqual(fws.focusedIndex, 0, "nor before the beginning")
        fws.moveColumnFocus(by: 1)
        expectEqual(fws.focusedIndex, 1, "move one to the right")
        fws.moveColumnFocus(by: 99)
        expectEqual(fws.focusedIndex, fws.columns.count - 1, "and movement does not run off either")
        // The edge no-op the focus-column guard depends on: at the last column,
        // moving right leaves the index untouched, so focusColumn can detect
        // "nothing changed" by comparing before/after and skip the whole
        // re-activation (which used to re-raise the floating layer on every
        // press into the wall - reported live as focus crossing into the
        // floating window at the end of the strip). Same at the first column.
        let atEnd = fws.focusedIndex
        fws.moveColumnFocus(by: 1)
        expectEqual(fws.focusedIndex, atEnd, "moving right at the last column is a true no-op")
        fws.focus(column: 0)
        fws.moveColumnFocus(by: -1)
        expectEqual(fws.focusedIndex, 0, "and moving left at the first column is too")

        let emptyWs = Workspace()
        emptyWs.focus(column: 3)
        expectEqual(emptyWs.focusedIndex, 0, "an empty workspace always focuses 0")

        let fcol = Column()
        fcol.setWindows((0..<3).map { _ in window() })
        fcol.focus(row: 2)
        fcol.removeWindow(at: fcol.windows.count - 1)
        expectEqual(fcol.focusedWindowIndex, 1, "the row focus re-anchors too")
        expect(fcol.focus(window: fcol.windows[0]), "focusing by identity finds the window")
        expectEqual(fcol.focusedWindowIndex, 0, "and focuses it")
        expect(!fcol.focus(window: window()), "a window from elsewhere does not move the focus")

        // --- isFloatingActive cannot outlive the floating layer -------------
        let floatWs = Workspace()
        floatWs.floatingWindows = [window()]
        floatWs.isFloatingActive = true
        floatWs.floatingWindows = []
        floatWs.clampFocus()
        expect(!floatWs.isFloatingActive, "with no floating windows, floating focus turns off")

        // --- animation curves ----------------------------------------------
        // REGRESSION: only the critically damped case existed, so a
        // configured damping-ratio of 0.9 was unreachable.
        let critical = Spring(stiffness: 1100, dampingRatio: 1.0)
        expectEqual(CGFloat(critical.remainingFraction(at: 0)), 1, "the critical spring starts at 1")
        var everNegative = false
        for step in 0...500 where critical.remainingFraction(at: Double(step) / 500) < -1e-9 {
            everNegative = true
        }
        expect(!everNegative, "critically damped does not overshoot")

        let underdamped = Spring(stiffness: 1100, dampingRatio: 0.6)
        var overshot = false
        for step in 0...500 where underdamped.remainingFraction(at: Double(step) / 500) < -1e-6 {
            overshot = true
        }
        expect(overshot, "damping-ratio < 1 DOES overshoot - that is what the config asks for")
        expect(underdamped.hasSettled(at: 3), "and it still settles")
        expect(!underdamped.hasSettled(at: 0), "but not right away")

        let overdamped = Spring(stiffness: 1100, dampingRatio: 2.0)
        var overdampedNegative = false
        for step in 0...500 where overdamped.remainingFraction(at: Double(step) / 500) < -1e-9 {
            overdampedNegative = true
        }
        expect(!overdampedNegative, "overdamped does not overshoot either")
        expect(
            overdamped.remainingFraction(at: 0.1) > critical.remainingFraction(at: 0.1),
            "and it arrives later than the critical one")

        let easing = Easing(durationMs: 500, curve: .easeOutCubic)
        expectEqual(CGFloat(easing.remainingFraction(at: 0)), 1, "the easing starts at 1")
        expectEqual(CGFloat(easing.remainingFraction(at: 0.5)), 0, "and ends exactly at its duration")
        expect(easing.hasSettled(at: 0.5), "settled once the duration is up")
        expect(!easing.hasSettled(at: 0.25), "not before")
        expect(
            Easing(durationMs: 500, curve: .easeOutCubic).remainingFraction(at: 0.25)
                < Easing(durationMs: 500, curve: .linear).remainingFraction(at: 0.25),
            "ease-out moves faster than linear at the start")
        expect(Easing.Curve.named("ease-out-cubic") != nil, "niri's curves are recognized by name")
        expect(Easing.Curve.named("does-not-exist") == nil, "and an unknown one is rejected")

        expectEqual(CGFloat(AnimationCurve.off.remainingFraction(at: 0)), 0, "off lands immediately")
        expect(AnimationCurve.off.hasSettled(at: 0), "and is already settled")

        // --- window rules: niri's matcher semantics -------------------------
        // REGRESSION: matchers were case-insensitive SUBSTRINGS, so none of
        // niri's own rules (anchored regexes over reverse-DNS app-ids)
        // ported at all.
        let anchored = Regex("^com\\.mitchellh\\.ghostty$")
        expect(anchored.matches("com.mitchellh.ghostty"), "the anchored regex matches the exact bundle id")
        expect(!anchored.matches("com.mitchellh.ghostty.helper"), "and does not match a longer one")
        expect(Regex("^org\\.gnome\\.").matches("org.gnome.Nautilus"), "an anchored prefix matches")
        expect(!Regex("^org\\.gnome\\.").matches("com.org.gnome.fake"), "but not in the middle")
        expect(
            Regex("Picture-in-Picture").matches("Firefox Picture-in-Picture"),
            "unanchored, finding it anywhere is enough")
        expect(!Regex("[").matches("anything at all"), "an invalid pattern matches nothing (and warns)")
        // Case-SENSITIVE, like rust's regex::Regex (niri-config/src/utils.rs):
        // the forced .caseInsensitive made "Firefox" match app-ids niri's own
        // matcher would not. Opting out is spelled (?i) in both engines.
        expect(!Regex("firefox").matches("Firefox"), "matchers are case-sensitive, like niri")
        expect(Regex("(?i)firefox").matches("Firefox"), "(?i) opts into insensitivity, same as rust regex")

        var m = NigiriConfig.Matcher()
        expect(
            m.matches(
                app: "Chrome", bundleID: "com.google.Chrome", title: "x",
                isActive: false, isFloating: false, atStartup: false),
            "a matcher with no fields matches everything - that is how niri writes 'every window'")
        m.app = Regex("^com\\.google\\.Chrome$")
        expect(
            m.matches(
                app: "Google Chrome", bundleID: "com.google.Chrome", title: "x",
                isActive: false, isFloating: false, atStartup: false),
            "app-id resolves against the bundle id, which is the macOS equivalent")
        expect(
            !m.matches(
                app: "Alacritty", bundleID: "org.alacritty", title: "x",
                isActive: false, isFloating: false, atStartup: false),
            "and does not match another app")
        m = NigiriConfig.Matcher()
        m.isActive = true
        expect(
            m.matches(
                app: "a", bundleID: nil, title: "t", isActive: true, isFloating: false, atStartup: false),
            "is-active=true matches the focused one")
        expect(
            !m.matches(
                app: "a", bundleID: nil, title: "t", isActive: false, isFloating: false, atStartup: false),
            "and not one that is not")

        // --- items 57-60: hot pieces that had NO check at all
        // 57: with no screen the geometry is garbage, and that has to be detectable.
        expect(
            ColumnLayoutEngine.columnPlacements(columns: [column(0.5)], usableWidth: -20)
                .allSatisfy { $0.width >= 0 },
            "with a negative usable width no column comes out negative")

        // 58: index remapping when a workspace moves (remove + insert).
        expectEqual(TilingEngine.indexAfterMove(0, from: 2, to: 0), 1, "what was before shifts by one")
        expectEqual(TilingEngine.indexAfterMove(2, from: 2, to: 0), 0, "the moved one lands on its target")
        expectEqual(TilingEngine.indexAfterMove(3, from: 2, to: 0), 3, "anything beyond is untouched")
        expectEqual(TilingEngine.indexAfterMove(0, from: 0, to: 2), 2, "and the other way round too")
        expectEqual(TilingEngine.indexAfterMove(1, from: 0, to: 2), 0, "the ones in between shift back")

        // 59: the column under the cursor needs BOTH halves of the range.
        let dropCols = [
            CGRect(x: 0, y: 0, width: 300, height: 800),
            CGRect(x: 600, y: 0, width: 300, height: 800),
        ]
        expectEqual(TilingEngine.hoveredColumn(dropCols, x: 150) ?? -1, 0, "inside the first one")
        expectEqual(TilingEngine.hoveredColumn(dropCols, x: 700) ?? -1, 1, "inside the second one")
        expect(
            TilingEngine.hoveredColumn(dropCols, x: 1200) == nil,
            "past the end you are NOT over the last one: that means a new column, not stacking")
        expect(TilingEngine.hoveredColumn(dropCols, x: 450) == nil, "nor in the gap between two")

        // 60a: the compaction plan rewrites both indices on every relayout, and a
        // mistake there reads as "macOS switched my desktop on its own".
        let plan = TilingEngine.compactPlan(
            [
                (empty: false, named: false),
                (empty: true, named: false),
                (empty: false, named: false),
                (empty: true, named: false),
            ],
            active: 2, previous: 0, emptyAboveFirst: false)
        expectEqual(plan.keep, [0, 2, 3], "the empty one in the middle goes; the last stays as a target")
        expectEqual(plan.active, 1, "and the active index travels with its workspace")
        expectEqual(plan.previous, 0, "same for the previous one")
        expect(!plan.appendTrailing, "there is already an empty one at the end, no need for another")
        let named = TilingEngine.compactPlan(
            [
                (empty: true, named: true),
                (empty: false, named: false),
            ],
            active: 1, previous: 0, emptyAboveFirst: false)
        expectEqual(named.keep, [0, 1], "a named workspace is not deleted even when empty")
        expect(named.appendTrailing, "and since the last one has windows, a new one is appended")
        // 60c (audit ACT-12): niri's special case (monitor.rs:646-653) -
        // with empty-workspace-above-first and EVERYTHING empty, the two
        // empty workspaces collapse to one instead of showing a phantom pair.
        let collapsed = TilingEngine.compactPlan(
            [(empty: true, named: false), (empty: true, named: false)],
            active: 1, previous: 0, emptyAboveFirst: true)
        expectEqual(collapsed.keep, [0], "everything empty under empty-above-first keeps ONE workspace")
        expectEqual(collapsed.active, 0, "and the active index lands on it")
        expect(!collapsed.appendTrailing && !collapsed.insertLeading, "with nothing added around it")
        // ...and a NAMED empty pair does not collapse (names are persistent).
        let namedPair = TilingEngine.compactPlan(
            [(empty: true, named: true), (empty: true, named: false)],
            active: 0, previous: 0, emptyAboveFirst: true)
        expectEqual(namedPair.keep.count, 2, "a named workspace blocks the collapse")

        // 60b: the absence counter is the final judge of whether a LIVE window
        // gets deleted from the model, and it has regressed twice already.
        expectEqual(TilingEngine.purgeVerdict(scans: 0, verdict: .alive).scans, 0, "seeing it resets it")
        expect(!TilingEngine.purgeVerdict(scans: 2, verdict: .alive).dead, "and a window seen is not dead")
        expectEqual(
            TilingEngine.purgeVerdict(scans: 2, verdict: .alive).scans, 0, "even after two absences")
        expect(
            TilingEngine.purgeVerdict(scans: 0, verdict: .dead).dead, "a dead process needs no counter"
        )
        expect(
            !TilingEngine.purgeVerdict(scans: 0, verdict: .absentFromList).dead,
            "one absence alone is not enough")
        expect(!TilingEngine.purgeVerdict(scans: 1, verdict: .absentFromList).dead, "two are not either")
        expect(
            TilingEngine.purgeVerdict(scans: 2, verdict: .absentFromList).dead, "the third in a row is")

        // REGRESSION (item 46): in a tabbed column the only visible card IS the
        // active tab, so dropping above or below it means before or after THAT
        // tab. The gap contest could only answer row 0 or 1 before: the new tab
        // showed up at the very top, and the order is visible in the indicator.
        let tabbedFrames = [[CGRect(x: 10, y: 44, width: 700, height: 900)]]
        let overTab = CGPoint(x: 360, y: 700)  // below the center
        expect(
            ColumnLayoutEngine.insertPosition(
                columnFrames: tabbedFrames, point: overTab,
                screenFrame: screen, tabbed: [2]) == .inColumn(0, 3),
            "below the active tab (index 2) inserts after it")
        let aboveTab = CGPoint(x: 360, y: 200)  // above the center
        expect(
            ColumnLayoutEngine.insertPosition(
                columnFrames: tabbedFrames, point: aboveTab,
                screenFrame: screen, tabbed: [2]) == .inColumn(0, 2),
            "and above it, before")
        expect(
            ColumnLayoutEngine.insertPosition(
                columnFrames: tabbedFrames, point: overTab,
                screenFrame: screen, tabbed: [nil]) == .inColumn(0, 1),
            "a normal column still uses the gap between tiles")

        // REGRESSION (item 41): niri's activate_prev_column_on_removal. A new
        // window is inserted to the RIGHT of the focused one and takes focus;
        // when it closes, focus has to go back to the left, not stay on the
        // index - which is now a different column. Without this, closing the
        // window you just opened shifted the strip to the right.
        let prevWs = Workspace()
        let prevLeft = column(0.5)
        let prevRight = column(0.5)
        prevLeft.setWindows([window()]); prevRight.setWindows([window()])
        prevWs.appendColumn(prevLeft)
        prevWs.appendColumn(prevRight)
        prevWs.focus(column: 0)
        let colN = column(0.5)
        colN.setWindows([window()])
        prevWs.insertColumn(colN, at: 1, activating: true)  // the way a new window opens
        _ = prevWs.removeColumn(at: 1)  // and the way you close it
        expectEqual(prevWs.focusedIndex, 0, "focus returns to the column it came from")
        // An explicit focus move clears that memory.
        let plainWs = Workspace()
        let p1 = column(0.5)
        let p2 = column(0.5)
        let p3 = column(0.5)
        for c in [p1, p2, p3] { c.setWindows([window()]); plainWs.appendColumn(c) }
        plainWs.focus(column: 1)
        _ = plainWs.removeColumn(at: 1)
        expectEqual(plainWs.focusedIndex, 1, "without that memory it stays on the index, as it always did")

        // REGRESSION (item 42): with no stored index, the preset is picked by
        // comparing the current width - the first press on a new window gave
        // preset 0 instead of the first one larger than it. The comparison
        // runs in RESOLVED PIXELS with upstream's 1px fractional-scaling
        // allowance (scrolling.rs:4820-4838), not proportions.
        let presetList: [CGFloat] = [1.0 / 3.0, 0.5, 2.0 / 3.0].map { $0 * 1200 }
        expectEqual(
            ColumnLayoutEngine.presetIndex(after: 600, in: presetList, delta: 1, from: nil) ?? -1, 2,
            "from 1/2 forwards you get 2/3, not 1/3")
        expectEqual(
            ColumnLayoutEngine.presetIndex(after: 600, in: presetList, delta: -1, from: nil) ?? -1, 0,
            "and backwards, 1/3")
        expectEqual(
            ColumnLayoutEngine.presetIndex(after: 1080, in: presetList, delta: 1, from: nil) ?? -1, 0,
            "wider than all of them: wraps to the first")
        expectEqual(
            ColumnLayoutEngine.presetIndex(after: 120, in: presetList, delta: -1, from: nil) ?? -1, 2,
            "narrower than all of them going backwards: wraps to the last")
        expectEqual(
            ColumnLayoutEngine.presetIndex(after: 600, in: presetList, delta: 1, from: 0) ?? -1, 1,
            "with a stored index the index wins, which is niri's fast path")
        expectEqual(
            ColumnLayoutEngine.presetIndex(after: 600.5, in: presetList, delta: 1, from: nil) ?? -1, 2,
            "a sub-pixel overshoot does not count as wider - niri's 1px allowance")
        // REGRESSION (audit LAY-7): the floating width and height preset
        // cyclers seeded backward as firstWider-1 then +delta - between 1/3
        // and 1/2, back gave 2/3 where niri gives 1/3. Both now delegate to
        // presetIndex above; this pins the audit's exact case in px terms.
        expectEqual(
            ColumnLayoutEngine.presetIndex(
                after: 400, in: [1.0 / 3.0, 0.5, 2.0 / 3.0].map { $0 * 1000 }, delta: -1, from: nil) ?? -1, 0,
            "off-preset between 1/3 and 1/2, backward lands on 1/3 - niri's last-strictly-narrower")

        // --- per-animation defaults (audit ANI-1) --------------------------
        // niri-config/src/animations.rs:130-330: each animation carries its
        // OWN default. A universal spring(800) was right for exactly four
        // names and wrong for the rest - under a comment citing the line
        // that defines workspace-switch as stiffness 1000.
        if case .spring(let s)? = AnimationCurve.defaults["workspace-switch"] {
            expect(abs(s.omega0 * s.omega0 - 1000) < 0.001, "workspace-switch defaults to spring 1000")
        } else {
            failures.append("workspace-switch default should be a spring")
        }
        if case .easing(let e)? = AnimationCurve.defaults["window-close"] {
            expect(
                e.durationMs == 150 && e.curve == .easeOutQuad,
                "window-close defaults to 150ms ease-out-quad")
        } else {
            failures.append("window-close default should be an easing, not a spring")
        }
        if case .easing(let e)? = AnimationCurve.defaults["window-open"] {
            expect(
                e.durationMs == 150 && e.curve == .easeOutExpo,
                "window-open defaults to 150ms ease-out-expo")
        } else {
            failures.append("window-open default should be an easing, not a spring")
        }
        if case .spring(let s)? = AnimationCurve.defaults["window-movement"] {
            expect(abs(s.omega0 * s.omega0 - 800) < 0.001, "window-movement stays at spring 800")
        } else {
            failures.append("window-movement default should be a spring")
        }

        // --- animation parser merge semantics (audit CFG-11 / ANI-7) -------
        // niri's Anim decode (animations.rs:726-830): a half-specified
        // easing borrows the missing half from the animation's OWN default
        // easing, or 250ms/EaseOutCubic when the default is a spring; a
        // spring requires all three properties and validates ranges.
        let animCfg = NigiriConfig.parse(
            """
            animations {
                window-open { duration-ms 300; }
                window-movement { curve "ease-out-quad"; }
                window-close { curve "linear"; }
                workspace-switch { spring stiffness=1200; }
                overview-open-close { spring damping-ratio=99.0 stiffness=800 epsilon=0.0001; }
                horizontal-view-movement { spring damping-ratio=1.0 stiffness=850 epsilon=0.0001; }
                slowdown 0
            }
            """)
        if case .easing(let e)? = animCfg.animations["window-open"] {
            expect(
                e.durationMs == 300 && e.curve == .easeOutExpo,
                "duration-ms alone borrows the animation's default curve (ease-out-expo)")
        } else {
            failures.append("window-open with duration-ms alone should be an easing")
        }
        if case .easing(let e)? = animCfg.animations["window-movement"] {
            expect(
                e.durationMs == 250 && e.curve == .easeOutQuad,
                "curve alone over a spring default gets niri's generic 250ms")
        } else {
            failures.append("window-movement with curve alone should be an easing, not dropped")
        }
        if case .easing(let e)? = animCfg.animations["window-close"] {
            expect(
                e.durationMs == 150 && e.curve == .linear,
                "curve alone over an easing default borrows its 150ms duration")
        } else {
            failures.append("window-close with curve alone should be an easing, not dropped")
        }
        expect(
            animCfg.animations["workspace-switch"] == nil,
            "a spring missing required properties is dropped, not filled with invented defaults")
        expect(
            animCfg.animations["overview-open-close"] == nil,
            "a spring with damping-ratio out of 0.1...10 is rejected")
        if case .spring(let s)? = animCfg.animations["horizontal-view-movement"] {
            expect(abs(s.omega0 * s.omega0 - 850) < 0.001, "a complete, in-range spring is accepted")
        } else {
            failures.append("a valid spring should parse")
        }
        expectEqual(animCfg.animationSlowdown, 0, "slowdown 0 is legal, like niri (instant)")

        // --- cubic-bezier solves x, like CSS and niri (audit ANI-4) --------
        expect(
            abs(Easing.cubicBezierY(x1: 0.25, y1: 0.25, x2: 0.75, y2: 0.75, at: 0.3) - 0.3) < 1e-6,
            "control points on the diagonal give the identity curve")
        expect(
            abs(Easing.cubicBezierY(x1: 0.42, y1: 0, x2: 0.58, y2: 1, at: 0.5) - 0.5) < 1e-6,
            "a symmetric S-curve passes through (0.5, 0.5)")
        let steep = Easing.cubicBezierY(x1: 0.1, y1: 0.9, x2: 0.2, y2: 1, at: 0.3)
        expect(
            steep > 0.85 && steep < 0.93,
            "a steep ease-out is ~0.89 at x=0.3 - the old y(t) shortcut gave ~0.61")

        // --- spring settle and velocity (audit ANI-9) ----------------------
        // The overdamped solution decays much slower than its envelope
        // (spring.rs:73-76): the envelope check ended those springs early.
        let odSpring = Spring(stiffness: 800, dampingRatio: 3, epsilon: 0.0001)
        let envelopeEstimate = -log(0.0001) / (3 * odSpring.omega0)
        expect(
            odSpring.settleSeconds > envelopeEstimate * 5,
            "an overdamped spring settles far past its envelope estimate")
        expect(
            abs(odSpring.remainingFraction(at: odSpring.settleSeconds)) <= 0.0001 * 1.01,
            "and Newton's settle time is where the REAL oscillation crosses epsilon")
        expect(
            odSpring.remainingFraction(at: envelopeEstimate) > 0.01,
            "at the envelope time the overdamped spring is still visibly moving")
        let critSpring = Spring(stiffness: 800, dampingRatio: 1, epsilon: 0.0001)
        expect(
            abs(critSpring.settleSeconds - (-log(0.0001) / critSpring.omega0)) < 0.001,
            "critical/underdamped keep the envelope estimate, like upstream")
        // initial_velocity: the spring can start MOVING (spring.rs:145);
        // positive v0 pushes it away from the target first.
        let kicked = Spring(stiffness: 800, dampingRatio: 1, epsilon: 0.0001, initialVelocity: 40)
        expectEqual(kicked.remainingFraction(at: 0), 1, "any v0 still starts at the full displacement")
        expect(
            kicked.remainingFraction(at: 0.01) > critSpring.remainingFraction(at: 0.01),
            "a positive v0 overshoots outward before settling")
        // clamped_duration probes 1ms steps and gives up past 3000 like
        // upstream (spring.rs:109-137).
        if let clamped = critSpring.clampedSettleTime() {
            // For critical/underdamped springs duration() is deliberately
            // the ENVELOPE estimate (spring.rs:62-70, "general estimation"),
            // which undershoots the true epsilon crossing - so the clamped
            // duration lands at or past it, in 1ms steps.
            expect(
                clamped >= critSpring.settleSeconds && clamped < 1,
                "the true epsilon crossing sits at/past the envelope estimate")
        } else {
            failures.append("a critical spring at 800 must clamp-settle within 3s")
        }

        // --- insertPosition hovers the column to the LEFT (audit LAY-15) ---
        // niri's take_while(col_x <= x): a pointer in the horizontal gap
        // still contests that column's tile gaps; strict containment used
        // to answer newColumn for every gap point unconditionally.
        let gapCols: [[CGRect]] = [
            [CGRect(x: 0, y: 0, width: 400, height: 300), CGRect(x: 0, y: 310, width: 400, height: 300)],
            [CGRect(x: 420, y: 0, width: 400, height: 610)],
        ]
        // In the gap between the columns (x=410), level with col 0's TILE
        // boundary (y=305): the tile gap is closer than the column gap.
        if case .inColumn(let c, let r) = ColumnLayoutEngine.insertPosition(
            columnFrames: gapCols, point: CGPoint(x: 412, y: 305),
            screenFrame: CGRect(x: 0, y: 0, width: 900, height: 700))
        {
            expect(c == 0 && r == 1, "the gap point lands in column 0's tile boundary")
        } else {
            failures.append("a gap point at a tile boundary should answer inColumn, like niri")
        }

        // Popups from ACCESSORY apps (system permission prompts, the
        // "downloaded from the internet" warnings, password requests) have to
        // enter the model as floating windows: they used to escape the window
        // manager entirely. But most accessory windows are not that - a video
        // wallpaper, our own overlays, the Control Center panels. Measured
        // live, a real dialog has either a title or confirmation buttons, and
        // the rest have neither.
        expect(
            TilingEngine.isDialogLike(
                title: "Screen Recording", hasDefaultButton: true, hasCancelButton: false),
            "the system permission prompt is adopted")
        expect(
            TilingEngine.isDialogLike(title: "", hasDefaultButton: true, hasCancelButton: false),
            "and one with no title but a confirm button is too")
        expect(
            TilingEngine.isDialogLike(title: "Instalar", hasDefaultButton: false, hasCancelButton: false),
            "and one with a title and no buttons is too")
        expect(
            !TilingEngine.isDialogLike(title: "", hasDefaultButton: false, hasCancelButton: false),
            "a video wallpaper or one of our overlays - no title, no buttons - is not")
        // The same rule keeps a shell panel/bar out of the layout: a client's
        // borderless chrome reports subrole AXDialog with no title and no
        // buttons, so it is NOT dialog-like and must not be tiled or given an
        // inactive border (reported live: a reserved-zone panel wearing one).
        expect(
            !TilingEngine.isDialogLike(title: "", hasDefaultButton: false, hasCancelButton: false),
            "a borderless panel/bar (dialog subrole, no title, no buttons) is not adopted")

        // niri's center_preferring_top_left_in_area (src/utils/mod.rs:525-535).
        // A window that FITS is centered; one LARGER than the area pins its
        // top-left corner inside it, because each offset is clamped at zero.
        // The plain `mid - size/2` this replaced went negative on both axes
        // and pushed such a window off the top-left of the screen.
        let area = CGRect(x: 0, y: 25, width: 1470, height: 897)
        let fits = TilingEngine.centerPreferringTopLeft(
            size: CGSize(width: 600, height: 400), in: area)
        expect(
            abs(fits.x - 435) < 0.01 && abs(fits.y - 273.5) < 0.01,
            "a floating window that fits is centered in the working area")
        let oversized = TilingEngine.centerPreferringTopLeft(
            size: CGSize(width: 2000, height: 1200), in: area)
        expect(
            oversized.x == area.minX && oversized.y == area.minY,
            "one larger than the working area pins its top-left corner, never negative")
        // The area's origin is honoured, not assumed to be zero: the working
        // area starts below the menu bar and shrinks further under a strut.
        let offsetArea = TilingEngine.centerPreferringTopLeft(
            size: CGSize(width: 100, height: 100),
            in: CGRect(x: 200, y: 100, width: 300, height: 300))
        expect(
            offsetArea.x == 300 && offsetArea.y == 200,
            "centering is relative to the working area's origin")

        // REGRESSION (item 48) + audit LAY-4: fullscreen is a per-COLUMN
        // flag (is_pending_fullscreen, scrolling.rs:171-175), and the
        // workspace's fullscreenWindow is DERIVED from it - so pulling the
        // window out of the tiling cancels fullscreen structurally (the
        // Mod+F-then-Mod+V both-fullscreen-and-floating bug is now
        // unrepresentable), and the flag travels with the column.
        let fsWs = Workspace()
        let fsColumn = column(0.5)
        let fsWindow = window()
        fsColumn.setWindows([fsWindow])
        fsWs.appendColumn(fsColumn)
        fsColumn.isPendingFullscreen = true
        expect(
            fsWs.fullscreenWindow === fsWindow, "the flagged column's active tile IS the fullscreen window")
        expect(!fsWs.fullscreenToEdges, "pending fullscreen reads as the raw-output mode")
        fsColumn.isPendingMaximized = true
        expect(!fsWs.fullscreenToEdges, "and fullscreen wins over maximized when both are pending")
        fsColumn.isPendingFullscreen = false
        expect(fsWs.fullscreenToEdges, "maximized alone is the to-edges mode")
        fsColumn.isPendingFullscreen = true
        fsColumn.isPendingMaximized = false
        expect(fsWs.detachFromTiling(fsWindow), "the window was in a column, so it is pulled out")
        expect(fsWs.fullscreenWindow == nil, "and fullscreen is canceled along with it - by derivation")
        expectEqual(fsWs.columns.count, 0, "the empty column collapses")
        expect(!fsWs.detachFromTiling(window()), "one that is not tiled is not pulled out of anywhere")
        // The flag travels: a fullscreen column moved between workspaces
        // arrives still fullscreen - impossible under the per-workspace
        // window reference, which every mover had to cancel by hand.
        let fsA = Workspace()
        let fsB = Workspace()
        let travelCol = column(0.5)
        let travelWin = window()
        travelCol.setWindows([travelWin])
        fsA.appendColumn(travelCol)
        travelCol.isPendingFullscreen = true
        _ = fsA.removeColumn(at: 0)
        fsB.appendColumn(travelCol)
        expect(fsA.fullscreenWindow == nil, "the source workspace forgot it with the column")
        expect(fsB.fullscreenWindow === travelWin, "and the destination sees it fullscreen on arrival")

        // REGRESSION (item 39): resize-edge bumps the epoch too, so the floors
        // have to be captured before that. With an 800px floor, the trade with
        // the neighbor has to be done in effective pixels, not in proportions,
        // or the right edge of the pair drifts.
        let tradeUsable: CGFloat = 1450
        let floorPx: CGFloat = 800
        let restingProportion = ColumnLayoutEngine.proportion(forWidth: 700, usableWidth: tradeUsable)
        let effective = max(
            ColumnLayoutEngine.width(forProportion: restingProportion, usableWidth: tradeUsable), floorPx)
        expectEqual(
            effective, floorPx, "a column resting on its floor measures the floor, not its proportion")
        let ignoringFloor = ColumnLayoutEngine.width(
            forProportion: restingProportion, usableWidth: tradeUsable)
        expect(
            effective - ignoringFloor > 50,
            "and the difference is exactly what the pair lost when the floor read as nil")

        // REGRESSION (items 5 and 6): the key for a mouse/wheel bind is built by
        // BOTH sides of the lookup - the parser from the config text, the tap
        // from the live flags - and they built it differently: the parser kept
        // the written order, the tap emitted its own. Mod+Shift+Ctrl, which is
        // the order niri's configs use, was stored as "mod-shift-ctrl-..." and
        // looked up as "mod-ctrl-shift-...".
        expectEqual(
            NigiriConfig.mouseBindingKey(for: "Shift+Mod+MouseMiddle") ?? "", "mod-shift-middle",
            "the written order does not change the key")
        expectEqual(
            NigiriConfig.mouseBindingKey(for: "Mod+Shift+MouseMiddle") ?? "",
            NigiriConfig.mouseBindingKey(for: "Shift+Mod+MouseMiddle") ?? "x",
            "both spellings give the same key")
        expectEqual(
            NigiriConfig.wheelBindingKey(for: "Mod+Shift+Ctrl+WheelScrollDown") ?? "", "mod-ctrl-shift-down",
            "and the wheel uses the same canonical order as the tap")
        expectEqual(
            NigiriConfig.bindingKey(mods: ["shift", "ctrl", "mod"], suffix: "down"), "mod-ctrl-shift-down",
            "fixed order: mod, cmd, opt, ctrl, shift")
        expectEqual(
            NigiriConfig.wheelBindingKey(for: "WheelScrollUp") ?? "", "up",
            "a bare wheel bind stays bare - niri allows unmodified wheel binds")

        // niri writes wheel binds as ORDINARY binds (Mod+WheelScrollDown,
        // default-config.kdl:484-499); the invented wheel{} section is gone
        // (audit CFG-6) and these prove the real form still lands in the
        // same canonicalized table.
        let wheelCfg = NigiriConfig.parse(
            """
            binds {
                Mod+Shift+WheelScrollDown { focus-column-right; }
                Mod+Ctrl+WheelScrollUp { move-column-to-workspace-up; }
            }
            """)
        expectEqual(
            wheelCfg.wheelBindings["mod-shift-down"] ?? "", "focus-column-right",
            "a niri wheel bind canonicalizes into the wheel table")
        expectEqual(
            wheelCfg.wheelBindings["mod-ctrl-up"] ?? "", "move-column-to-workspace-up",
            "modifier order never changes the key")

        // REGRESSION (item 23): focus-ring { off } had been parsed ever since the
        // section existed and was never applied - the ring kept being drawn at
        // its width. "Off" is written as width 0, which is how every other
        // decoration says it.
        let ringOffCfg = NigiriConfig.parse(
            """
            layout { focus-ring { width 4; off } }
            """)
        expect(ringOffCfg.ringOff, "focus-ring { off } parses")
        expectEqual(ringOffCfg.ringOff ? 0 : ringOffCfg.ringWidth, 0, "and the effective width is 0")
        let ringOnCfg = NigiriConfig.parse(
            """
            layout { focus-ring { width 6 } }
            """)
        expectEqual(ringOnCfg.ringOff ? 0 : ringOnCfg.ringWidth, 6, "without off, the configured width wins")

        // --- decorations: one rule, shared by the settle and the tick
        // REGRESSION (items 12 and 13): the animator tick had its own copy of the
        // rule and had lost the minimized check (a ghost border over the hole
        // left by a minimized window, which survived the settle); and a floating
        // window was compared against a list that INCLUDED itself, so it
        // occluded itself and never got a border.
        let decoScreen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let tiled = CGRect(x: 20, y: 20, width: 300, height: 700)
        let dialog = CGRect(x: 400, y: 100, width: 300, height: 300)
        let minimizedFrame = CGRect(x: 700, y: 20, width: 200, height: 700)
        let decoStack = [
            WindowStacking.Entry(pid: 1, frame: dialog),
            WindowStacking.Entry(pid: 2, frame: tiled),
            WindowStacking.Entry(pid: 3, frame: minimizedFrame),
        ]
        let decorated = TilingEngine.decoratedFrames(
            [
                .init(frame: tiled, minimized: false, depth: 1),
                .init(frame: dialog, minimized: false, depth: 0),
                .init(frame: minimizedFrame, minimized: true, depth: 2),
            ], occluders: decoStack, screen: decoScreen)
        expectEqual(decorated.count, 2, "the minimized one gets no border; the tiled one and the dialog do")
        expect(decorated.contains(dialog), "a dialog does not occlude itself")
        expect(decorated.contains(tiled), "and the tiled one that is not under it keeps its own")
        let underDialog = CGRect(x: 420, y: 120, width: 200, height: 200)
        let covered = TilingEngine.decoratedFrames(
            [
                .init(frame: underDialog, minimized: false, depth: 1),
                .init(frame: dialog, minimized: false, depth: 0),
            ],
            occluders: [
                WindowStacking.Entry(pid: 1, frame: dialog),
                WindowStacking.Entry(pid: 2, frame: underDialog),
            ], screen: decoScreen)
        expect(!covered.contains(underDialog), "the one left under the dialog does lose its border")
        let offscreen = TilingEngine.decoratedFrames(
            [
                .init(frame: CGRect(x: 999, y: 20, width: 300, height: 700), minimized: false, depth: 0)
            ], occluders: [], screen: decoScreen)
        expectEqual(offscreen.count, 0, "and one scrolled out of view paints nothing either")

        // REGRESSION (reported live, off a recorded demo): the border of a
        // FLOATING window stayed visible even when a tiled window covered it
        // completely - Calculator floating behind Font Book, its border drawn
        // over Font Book's content, outlining a window nobody could see. The old
        // rule only hid a border if a FLOATING window covered it, assuming that
        // floating implies being in front: true in niri, false on macOS, where
        // activating an app raises all of its windows. The real stack decides
        // now.
        //
        // And the detail that made the FIRST attempt at the fix fail, measured
        // on screen rather than reasoned about: the window doing the covering is
        // the FOCUSED one, which is outside the candidate list because it wears
        // the ring instead of a border. Comparing candidates against each other
        // never saw it. The occluders are the whole stack.
        let floatingBehind = CGRect(x: 420, y: 120, width: 200, height: 200)
        let focusedInFront = CGRect(x: 400, y: 100, width: 400, height: 400)
        let realStack = [
            WindowStacking.Entry(pid: 1, frame: focusedInFront),
            WindowStacking.Entry(pid: 2, frame: floatingBehind),
        ]
        let byRealStack = TilingEngine.decoratedFrames(
            [.init(frame: floatingBehind, minimized: false, depth: 1)],
            occluders: realStack, screen: decoScreen)
        expect(
            byRealStack.isEmpty,
            "a floating window covered by the FOCUSED one loses its border even though it is no candidate")
        // An unmatched window keeps its border: losing it on a window the user is
        // looking at reads as nigiri having lost track of it, while painting one
        // too many is merely cosmetic.
        let unmatched = TilingEngine.decoratedFrames(
            [.init(frame: floatingBehind, minimized: false, depth: nil)],
            occluders: realStack, screen: decoScreen)
        expect(unmatched.contains(floatingBehind), "with no known depth, the border is kept")
        // Nobody covers the frontmost one.
        let frontmost = TilingEngine.decoratedFrames(
            [.init(frame: focusedInFront, minimized: false, depth: 0)],
            occluders: realStack, screen: decoScreen)
        expect(frontmost.contains(focusedInFront), "the front one keeps its own")

        // WindowStacking.depths: matching is by pid + frame because we have no
        // CGWindowID, and entries are claimed front to back - the windows of a
        // tabbed column share the EXACT same frame, and that order gives the
        // front to the visible one and the back to the ones behind it, which is
        // precisely the case where the border does not belong.
        let stackFrame = CGRect(x: 10, y: 10, width: 100, height: 100)
        let otherFrame = CGRect(x: 200, y: 10, width: 100, height: 100)
        let stack = [
            WindowStacking.Entry(pid: 7, frame: otherFrame),
            WindowStacking.Entry(pid: 5, frame: stackFrame),
            WindowStacking.Entry(pid: 5, frame: stackFrame),
        ]
        let assigned = WindowStacking.depths(
            of: [(pid: 5, stackFrame), (pid: 5, stackFrame), (pid: 7, otherFrame)], in: stack)
        expectEqual(assigned[2], 0, "the one from another app matches its own entry")
        expectEqual(assigned[0], 1, "two identical frames: the first claims the front entry")
        expectEqual(assigned[1], 2, "and the second the back one, which is the one that loses the border")
        let noMatch = WindowStacking.depths(
            of: [(pid: 9, stackFrame), (pid: 5, CGRect(x: 500, y: 500, width: 10, height: 10))], in: stack)
        expectEqual(noMatch[0], nil, "a different pid does not match")
        expectEqual(noMatch[1], nil, "same pid but a far-away frame does not either")
        let withinTolerance = WindowStacking.depths(
            of: [(pid: 5, stackFrame.offsetBy(dx: 1, dy: -1))], in: stack)
        expectEqual(withinTolerance[0], 1, "a 1pt difference is still the same window")

        // TilingEngine.candidates(from:in:): the animator hoists the AX read
        // (DecorationInfo) ONCE, then recomputes depths against a FRESH stack
        // each tick - because the real z-order changes AFTER the animation
        // starts (focusColumn runs the animation from reflow, then activates
        // and raises the floating layer). A frozen snapshot left a floating
        // window's border painted over the window just focused over it, the
        // "floating frame leaking while you move" reported under the keyboard.
        // This locks the pure half: same info, two different stacks, two
        // different depth verdicts.
        let floatInfo = TilingEngine.DecorationInfo(
            pid: 2, frame: CGRect(x: 420, y: 120, width: 200, height: 200), minimized: false)
        let tiledInfo = TilingEngine.DecorationInfo(
            pid: 1, frame: CGRect(x: 400, y: 100, width: 400, height: 400), minimized: false)
        let floatFront = [
            WindowStacking.Entry(pid: 2, frame: floatInfo.frame),
            WindowStacking.Entry(pid: 1, frame: tiledInfo.frame),
        ]
        let tiledFront = [
            WindowStacking.Entry(pid: 1, frame: tiledInfo.frame),
            WindowStacking.Entry(pid: 2, frame: floatInfo.frame),
        ]
        let whenFloatFront = TilingEngine.candidates(from: [floatInfo], in: floatFront)
        expectEqual(whenFloatFront.first?.depth, 0, "floating on top resolves to depth 0")
        let whenTiledFront = TilingEngine.candidates(from: [floatInfo], in: tiledFront)
        expectEqual(
            whenTiledFront.first?.depth, 1, "the same window, tiled now in front, resolves to depth 1")
        // And that verdict flips the border: shown when in front, hidden when
        // the tiled window is raised over it - which is what the per-tick
        // re-read delivers the instant macOS reorders.
        let decoScreen2 = CGRect(x: 0, y: 0, width: 1000, height: 800)
        expect(
            TilingEngine.decoratedFrames(whenTiledFront, occluders: tiledFront, screen: decoScreen2).isEmpty,
            "floating behind the raised tiled window drops its border")
        expect(
            !TilingEngine.decoratedFrames(whenFloatFront, occluders: floatFront, screen: decoScreen2).isEmpty,
            "and keeps it while it is genuinely on top")

        // REGRESSION (items 10 and 38): the pre-fullscreen home of a floating
        // window shared a slot with the workspace-switch stash, which overwrites
        // it with where the window is NOW - and during a fullscreen that is the
        // 1px parking spot, so it came back stranded against the edge.
        let fsScreen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let home = CGRect(x: 120, y: 90, width: 400, height: 300)
        expectEqual(
            FullscreenStash.homeToRecord(isFloating: true, existingHome: nil, currentFrame: home) ?? .zero,
            home, "the first time it records where the window was")
        let parkedSpot = FullscreenStash.parked(home, screenFrame: fsScreen)
        expectEqual(parkedSpot.minX, fsScreen.maxX - 1, "parked 1px from the edge")
        expectEqual(parkedSpot.height, home.height, "keeping its size and height")
        expect(
            FullscreenStash.homeToRecord(isFloating: true, existingHome: home, currentFrame: parkedSpot)
                == nil,
            "and the second time it is NOT rewritten: otherwise home becomes the parking spot")
        expect(
            FullscreenStash.homeToRecord(isFloating: false, existingHome: nil, currentFrame: home) == nil,
            "a tiled window needs no home: the layout places it again")

        // The two slots are independent, which is the fix for item 10.
        let stashed = window()
        stashed.fullscreenHome = home
        stashed.stashedFrame = parkedSpot  // what the workspace switch writes
        expectEqual(
            stashed.fullscreenHome ?? .zero, home,
            "the workspace switch no longer clobbers the fullscreen home"
        )
        stashed.stashedFrame = nil  // the switch clears its own on landing
        expectEqual(stashed.fullscreenHome ?? .zero, home, "and clearing one does not erase the other")

        // --- cache epochs ----------------------------------------------------
        // REGRESSION: a discovered floor and a refusal memo were believed
        // forever, so a column could get stuck at a width no key changed -
        // silently. Both are answers FROM AN APP, and apps change their mind.
        let epochColumn = column(0.5)
        epochColumn.cachedMinWidth = 800
        expectEqual(epochColumn.validMinWidth ?? 0, 800, "the floor holds within its epoch")
        ColumnLayoutEngine.newEpoch()
        expect(epochColumn.validMinWidth == nil, "and stops holding in the next one")
        let placedAfterEpoch = ColumnLayoutEngine.columnPlacements(
            columns: [epochColumn], usableWidth: usableWidth)
        expectEqual(placedAfterEpoch[0].width, 720, "so the column goes back to its proportion")

        let epochWindow = window()
        epochWindow.lastRequestedFrame = CGRect(x: 0, y: 0, width: 500, height: 500)
        epochWindow.lastActualFrame = CGRect(x: 0, y: 0, width: 800, height: 500)
        expect(epochWindow.refusalMemo != nil, "the memoized refusal holds within its epoch")
        ColumnLayoutEngine.newEpoch()
        expect(epochWindow.refusalMemo == nil, "and does not survive into the next one")

        // Re-recording inside the new epoch makes it valid again.
        epochWindow.lastRequestedFrame = CGRect(x: 0, y: 0, width: 500, height: 500)
        expect(epochWindow.refusalMemo != nil, "measuring again revalidates it")

        // REGRESSION (item 7): every width action starts with newEpoch(), which is
        // exactly what makes validMinWidth answer nil - so the discovered floor
        // was NEVER applied from the keyboard and its message had not been seen
        // even once. The action captures it before the bump.
        let floorProportion = ColumnLayoutEngine.proportion(forWidth: 800, usableWidth: usableWidth)
        expectEqual(
            ColumnLayoutEngine.clampProportion(0.1, minWidth: 800, maxWidth: nil, usableWidth: usableWidth),
            floorProportion, "a known floor raises the requested proportion")
        expectEqual(
            ColumnLayoutEngine.clampProportion(0.1, minWidth: nil, maxWidth: nil, usableWidth: usableWidth),
            0.1, "with no known floor it passes through, which is what it ALWAYS did")
        expectEqual(
            ColumnLayoutEngine.clampProportion(0.9, minWidth: nil, maxWidth: 400, usableWidth: usableWidth),
            ColumnLayoutEngine.proportion(forWidth: 400, usableWidth: usableWidth),
            "a rule's ceiling trims downwards")
        expectEqual(
            ColumnLayoutEngine.clampProportion(0.5, minWidth: 800, maxWidth: 400, usableWidth: usableWidth),
            floorProportion,
            "if ceiling and floor cross, the floor wins: an unreadable window is worse than a wide one")
        // niri's clamp is (0, 10000) (scrolling.rs, set_column_width): a
        // proportion past 1.0 is legal - the column grows wider than the
        // view and the view left-aligns it. The old cap at 1.0 encoded the
        // invented restriction this replaced (backlog item 19).
        expectEqual(
            ColumnLayoutEngine.clampProportion(2.0, minWidth: nil, maxWidth: nil, usableWidth: usableWidth),
            2.0, "a proportion wider than the view passes through, like niri")
        expectEqual(
            ColumnLayoutEngine.clampProportion(-0.5, minWidth: nil, maxWidth: nil, usableWidth: usableWidth),
            0.0, "the floor is zero, not an invented 5%")

        // REGRESSION (item 9): move-window-to-workspace put a floating window
        // inside a column of the destination workspace, breaking the invariant
        // that toggleWindowFloating does uphold. A dialog counts even when the
        // floating layer is not the active one: it rejects the writes a column
        // would make to it.
        expect(
            TilingEngine.landsFloating(floatingLayerActive: true, isDialog: false, inFloatingList: true),
            "one already floating keeps floating on the other side")
        expect(
            TilingEngine.landsFloating(floatingLayerActive: false, isDialog: true, inFloatingList: false),
            "a dialog is not tiled even when the tiled layer is the active one")
        expect(
            !TilingEngine.landsFloating(floatingLayerActive: false, isDialog: false, inFloatingList: false),
            "and an ordinary tiled window still goes into a column")

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
        // The declared ORDER is the cycle Mod+R walks: a single list.
        expectEqual(cfg.presetColumnSizes.count, 2, "both presets, in one single list")
        expect(cfg.presetColumnSizes[0] == .proportion(0.5), "the proportion first, as written")
        expect(cfg.presetColumnSizes[1] == .fixed(1200), "and the fixed one after it, not at the end")
        // REGRESSION (item 43): mixed together, the order was not preserved.
        let mixedPresets = NigiriConfig.parse(
            """
            layout { preset-column-widths { proportion 0.25; fixed 1920; proportion 0.75 } }
            """)
        expect(
            mixedPresets.presetColumnSizes == [.proportion(0.25), .fixed(1920), .proportion(0.75)],
            "a mixed list cycles in the written order, not proportions first")
        // REGRESSION (item 43b): a fixed-only list does not inherit the defaults.
        let onlyFixed = NigiriConfig.parse(
            """
            layout { preset-column-widths { fixed 1280; fixed 1920 } }
            """)
        expectEqual(onlyFixed.presetColumnSizes.count, 2, "two presets declared, two presets - not five")
        // REGRESSION (item 44): heights accept fixed, just like in niri.
        let heights = NigiriConfig.parse(
            """
            layout { preset-window-heights { fixed 400; proportion 0.5 } }
            """)
        expect(
            heights.presetWindowHeightSizes == [.fixed(400), .proportion(0.5)],
            "preset-window-heights { fixed N } is no longer discarded")
        expect(
            !NigiriConfig.parse("layout { }").presetWindowHeightSizes.isEmpty,
            "and if the list ends up empty there are defaults, as with the widths")
        // REGRESSION (item 45): the vertical formula is niri's, not p*height.
        let colH: CGFloat = 1000
        let heightThirds = (0..<3).map { _ in
            ColumnLayoutEngine.height(forProportion: 1.0 / 3.0, usableHeight: colH)
        }
        expectEqual(
            heightThirds.reduce(0, +) + 2 * ColumnLayoutEngine.gap, colH,
            "three windows at the 1/3 preset fit exactly, gaps included")
        // niri: "layout { shadow {} } still results in shadow = off, as it
        // should" (niri-config/src/lib.rs:252-258) - only an explicit `on`
        // enables. The previous check here asserted the INVERTED semantic.
        expect(!cfg.shadowOn, "shadow{} without `on` stays off, like niri")
        expect(
            NigiriConfig.parse("layout { shadow { on; } }").shadowOn,
            "shadow { on } enables")
        expectEqual(cfg.shadowSoftness, 40, "shadow softness")
        expectEqual(cfg.shadowOffset.height, 6, "shadow offset y")
        // niri's border special case (lib.rs:246-280): an empty border{}
        // block DOES enable (unlike shadow), `off` disables, and the active
        // color keys are valid config - they used to be rejected with a
        // lecture. Defaults per Border::default(): width 4, inactive
        // rgb(80,80,80) - not the invented Catppuccin #585B70.
        let borderCfg = NigiriConfig.parse("layout { border { } }")
        expect(borderCfg.borderOn, "border{} enables, niri's documented special case")
        expectEqual(borderCfg.borderWidth, 4, "border default width 4")
        expect(
            !NigiriConfig.parse("layout { border { off; } }").borderOn,
            "border { off } stays off")
        expect(
            NigiriConfig.parse("layout { border { active-color \"#ff0000\"; } }")
                .borderActiveColor.redComponent > 0.99,
            "border active-color is accepted, not lectured away")
        expectEqual(cfg.overviewZoom, 0.35, "overview zoom")
        // CFG-13: niri accepts the full 0..1 (FloatOrInt<0,1>); the old
        // [0.1, 0.95] clamp silently rewrote legal values.
        expectEqual(
            NigiriConfig.parse("overview { zoom 0.05; }").overviewZoom, 0.05,
            "zoom 0.05 is legal, not clamped up to 0.1")
        expectEqual(
            NigiriConfig.parse("overview { zoom 1.5; }").overviewZoom, 0.5,
            "zoom outside 0..1 is rejected and the default stays")
        // CFG-16: shadow defaults are niri's Shadow::default() - color
        // rgba(0,0,0,0x77), spread 5 - and spread parses instead of
        // vanishing.
        expect(
            abs(NigiriConfig().shadowColor.alphaComponent - 0x77 / 255.0) < 0.001,
            "default shadow alpha is 0x77/255, not the invented 0.45")
        expectEqual(
            NigiriConfig.parse("layout { shadow { on; spread 12; } }").shadowSpread, 12,
            "shadow spread is parsed, not discarded")
        // CFG-9: default-column-width's three shapes (layout.rs:146-147).
        if case .fixed(let px) = NigiriConfig.parse(
            "layout { default-column-width { fixed 1200; } }"
        ).defaultColumnWidth {
            expectEqual(px, 1200, "default-column-width fixed keeps its pixels")
        } else {
            failures.append("default-column-width { fixed } should parse as .fixed")
        }
        expect(
            NigiriConfig.parse("layout { default-column-width { } }").defaultColumnWidth
                == .natural,
            "the empty block means the window decides - niri's Some(None)")
        let ruleWidth = NigiriConfig.parse(
            """
            window-rule {
                match app-id="wezterm"
                default-column-width { }
            }
            """
        ).rules.first?.defaultWidth
        expect(ruleWidth == .natural, "the per-rule empty block parses too (WezTerm's own default rule)")
        // Resolution (LAY-6): fixed pixels STAY pixels (From<PresetSize>
        // for ColumnWidth, scrolling.rs:3912-3919); natural is the window's
        // own width, also fixed (resolve_scrolling_width, workspace.rs:890);
        // only nothing-known falls back to the plain proportion.
        expect(
            ColumnLayoutEngine.resolveDefaultWidth(.fixed(712), windowWidth: nil) == .fixed(712),
            "a fixed default stays fixed pixels - no proportion round-trip")
        expect(
            ColumnLayoutEngine.resolveDefaultWidth(.natural, windowWidth: 712) == .fixed(712),
            "natural resolves the window's own width, stored fixed")
        expect(
            ColumnLayoutEngine.resolveDefaultWidth(.natural, windowWidth: nil) == .proportion(0.5),
            "natural with no window falls back to the plain default")
        // CFG-8: open-on-workspace is a NAME (window_rule.rs:25-26) - a
        // numeric-looking argument is a workspace named "2", never index 2.
        expectEqual(
            NigiriConfig.parse(
                """
                window-rule {
                    match app-id="x"
                    open-on-workspace 2
                }
                """
            ).rules.first?.openOnWorkspaceName ?? "", "2",
            "open-on-workspace takes a name; the integer-index reading was invented")
        expectEqual(cfg.environment["TERM"] ?? "", "xterm", "environment")
        expect(cfg.screenshotPath.hasSuffix("shot-%Y.png"), "screenshot-path")
        // CFG-19: `K null` UNSETS the variable (misc.rs:158-164); an empty
        // string genuinely sets it empty - "empty = unset" was invented.
        let envCfg = NigiriConfig.parse("environment { GONE null; EMPTY \"\"; }")
        expect(
            envCfg.environment["GONE"] == String??.some(nil),
            "environment K null stores the unset marker")
        expect(
            envCfg.environment["EMPTY"] == String??.some(""),
            "an empty string sets an empty variable, it does not unset")
        // CFG-15: screenshot-path null disables saving (misc.rs:57); the
        // default is niri's ~/Pictures/Screenshots path (misc.rs:60-64).
        expectEqual(
            NigiriConfig.parse("screenshot-path null").screenshotPath, "",
            "screenshot-path null means clipboard only, not a file named null")
        expect(
            NigiriConfig().screenshotPath.contains("Pictures/Screenshots/Screenshot from"),
            "the default screenshot path is niri's, not the invented Desktop one")
        // CFG-18: niri's Flag type takes an explicit false (utils.rs:17-24).
        let flagCfg = NigiriConfig.parse(
            """
            layout {
                always-center-single-column false
                empty-workspace-above-first false
            }
            input { focus-follows-mouse false; warp-mouse-to-focus false; }
            """)
        expect(
            !flagCfg.alwaysCenterSingleColumn && !flagCfg.emptyWorkspaceAboveFirst
                && !flagCfg.focusFollowsMouse && !flagCfg.warpMouseToFocus,
            "an explicit false turns a Flag off instead of being ignored")
        expect(
            NigiriConfig.parse("input { workspace-auto-back-and-forth; }").workspaceAutoBackAndForth,
            "workspace-auto-back-and-forth parses (input.rs:23,51) - it fell to unknown before")
        // CFG-25: the pin's real spelling is input.keyboard.xkb.layout
        // (input.rs:131-144); binds-layout was an invented name.
        expectEqual(
            NigiriConfig.parse("input { keyboard { xkb { layout \"us,ru\"; } } }").bindsLayout ?? "",
            "us", "input.keyboard.xkb.layout parses, first of the comma list")
        // CFG-17: niri's colors go through csscolorparser - names, rgb(),
        // hsl(), and the four-numbers RGBA node form; only hex worked.
        let cssCfg = NigiriConfig.parse(
            """
            layout {
                focus-ring {
                    active-color "red"
                    inactive-color "rgb(80, 80, 80)"
                    urgent-color 155 0 0 255
                }
                shadow { on; color "hsl(0, 0%, 50%)"; }
            }
            """)
        expect(
            cssCfg.ringFrom.redComponent > 0.99 && cssCfg.ringFrom.greenComponent < 0.01,
            "a CSS named color parses (red)")
        expect(
            abs(cssCfg.ringInactiveColor.redComponent - 80.0 / 255) < 0.01,
            "rgb() with spaces parses through the token rejoin")
        expect(
            abs(cssCfg.ringUrgentColor.redComponent - 155.0 / 255) < 0.01
                && cssCfg.ringUrgentColor.greenComponent < 0.01,
            "the four-numbers RGBA node form parses (appearance.rs:798-815)")
        expect(
            abs(cssCfg.shadowColor.redComponent - 0.5) < 0.01
                && abs(cssCfg.shadowColor.greenComponent - 0.5) < 0.01,
            "hsl() parses to the CSS conversion")
        // CFG-27: the default config is niri's own keymap now - it must
        // parse cleanly and carry the signature niri binds.
        let defaults = NigiriConfig.parse(NigiriConfig.defaultConfigText)
        expect(defaults.binds.count > 80, "the ported niri keymap parses (\(defaults.binds.count) binds)")
        expect(
            defaults.binds.contains { $0.combo == "Mod+BracketLeft" },
            "niri's consume-or-expel brackets are present")
        expect(
            defaults.binds.contains { $0.combo == "Mod+Shift+Slash" },
            "show-hotkey-overlay sits on Mod+Shift+Slash, like niri")
        // CFG-20: niri's full tab-indicator vocabulary (appearance.rs:
        // 459-499) - every real key used to be rejected as unknown.
        let tabCfg = NigiriConfig.parse(
            """
            layout {
                tab-indicator {
                    hide-when-single-tab
                    place-within-column
                    gap 8
                    width 6
                    length total-proportion=0.8
                    position "right"
                    gaps-between-tabs 3
                    corner-radius 4
                }
            }
            """)
        expect(
            tabCfg.tabHideWhenSingleTab && tabCfg.tabPlaceWithinColumn && tabCfg.tabGap == 8
                && tabCfg.tabWidth == 6 && tabCfg.tabLengthProportion == 0.8
                && tabCfg.tabPosition == .right && tabCfg.tabGapsBetweenTabs == 3
                && tabCfg.tabCornerRadius == 4,
            "the full tab-indicator vocabulary parses")
        expect(
            NigiriConfig().tabActiveColor == nil,
            "unset tab colors stay nil so they can derive from the ring/border, like upstream")
        // CFG-21: urgent colors and any gradient angle parse (they used to
        // be rejected; angle only accepted 45).
        let ringCfg = NigiriConfig.parse(
            """
            layout {
                focus-ring {
                    active-gradient from="#ff0000" to="#0000ff" angle=90
                    urgent-color "#9b0000"
                    inactive-gradient from="#333333" to="#111111"
                }
            }
            """)
        expectEqual(ringCfg.ringAngle, 90, "any gradient angle is accepted, default 180 like niri")
        expect(ringCfg.ringUrgentColor.redComponent > 0.5, "urgent-color parses and is stored")
        expect(ringCfg.ringInactiveColor.redComponent < 0.3, "inactive-gradient takes its from stop")
        // ACT-16 config side: config-notification { disable-failed }.
        expect(
            NigiriConfig.parse("config-notification { disable-failed; }")
                .configNotificationDisableFailed,
            "config-notification disable-failed parses (misc.rs:87-102)")
        // ACT-10: the hotkey overlay is niri's CURATED list
        // (hotkey_overlay.rs:197-300), not the whole bind table.
        let curatedEntries = HotkeyOverlay.curated(
            binds: [
                ("Mod+Q", "close-window", nil, false),
                ("Mod+T", "spawn open -a Terminal", nil, false),
                ("Mod+Shift+E", "quit skip-confirmation=true", nil, false),
                ("Mod+X", "focus-column-left", "Custom Left", false),
                ("Mod+H", "focus-window-previous", nil, true),
                ("F5", "spawn volume-up", nil, false),
            ], hideNotBound: false)
        expect(
            curatedEntries.contains(HotkeyOverlay.Entry(combo: "Mod+Shift+E", title: "Exit nigiri")),
            "quit falls back to the skip-confirmation bind, upstream's preference order")
        expect(
            curatedEntries.contains(HotkeyOverlay.Entry(combo: "Mod+T", title: "Spawn open")),
            "a Mod+spawn bind appears named after its command")
        expect(
            !curatedEntries.contains { $0.combo == "F5" },
            "a spawn bind without Mod (volume keys) stays out")
        expect(
            !curatedEntries.contains { $0.title.contains("focus-window-previous") },
            "actions outside the curated set are not listed")
        expect(
            curatedEntries.contains(HotkeyOverlay.Entry(combo: "Mod+X", title: "Custom Left")),
            "hotkey-overlay-title renames the entry")
        expect(
            curatedEntries.contains(HotkeyOverlay.Entry(combo: "", title: "Maximize Column")),
            "an unbound curated action shows with an empty key column")
        let curatedBound = HotkeyOverlay.curated(
            binds: [("Mod+Q", "close-window", nil, false)], hideNotBound: true)
        expect(
            curatedBound == [HotkeyOverlay.Entry(combo: "Mod+Q", title: "Close Focused Window")],
            "hide-not-bound keeps only bound entries (misc.rs:78-85)")
        // ACT-15: the wallpaper behind the overview needs niri's own opt-in.
        expect(
            !NigiriConfig().backdropShowsWallpaper,
            "the default overview backdrop is the plain color, not the desktop")
        expect(
            NigiriConfig.parse(
                "layer-rule { match namespace=\"wallpaper\"; place-within-backdrop true; }"
            ).backdropShowsWallpaper,
            "layer-rule place-within-backdrop true opts the wallpaper in, like niri")
        // CFG-22: duplicate binds - a duplicate within one binds{} keeps the
        // FIRST (niri rejects the config outright, binds.rs:776-812); a bind
        // in a LATER section replaces the earlier one (lib.rs:219-231).
        NigiriConfig.layoutKeyCodes = ["a": 0x00, "b": 0x0B]
        let dupBinds = NigiriConfig.parse(
            """
            binds {
                Mod+A { focus-column-left; }
                Mod+A { focus-column-right; }
            }
            binds {
                Mod+A { close-window; }
            }
            """)
        expectEqual(dupBinds.binds.count, 1, "one combo, one bind - never two handlers per press")
        expectEqual(
            dupBinds.binds.first?.action ?? "", "close-window",
            "a later section REPLACES; within a section the first wins")
        // CFG-26: ranges and vocabulary - out-of-range gaps rejected, the
        // invented `gap` alias gone, a center-focused-column typo no longer
        // rewrites the policy, unknown animation names are not stored.
        expectEqual(
            NigiriConfig.parse("layout { gaps -5; }").gap, NigiriConfig().gap,
            "negative gaps are rejected (FloatOrInt<0,65535>), keeping the default")
        expectEqual(
            NigiriConfig.parse("layout { gap 33; }").gap, NigiriConfig().gap,
            "the `gap` alias was invented vocabulary and is no longer accepted")
        expect(
            NigiriConfig.parse("layout { center-focused-column \"alwys\"; }").centerFocusedColumn
                == NigiriConfig().centerFocusedColumn,
            "a center-focused-column typo reports instead of silently becoming `never`")
        expect(
            NigiriConfig.parse("animations { window-opeen { duration-ms 100; } }")
                .animations["window-opeen"] == nil,
            "an unknown animation name is reported and not stored")

        // --- KDL: the shapes the official suite covers (kdl-org/kdl,
        // tests/test_cases), written in the v1 dialect niri uses via knuffel.
        // Not one of these had a single check.
        //
        // 1) An unknown sub-block CANNOT abort its section: a niri config copied
        // verbatim carries input { touchpad { ... } } and the mod-key was lost
        // right there, leaving all 74 binds on the default.
        let sub = NigiriConfig.parse(
            """
            input {
                touchpad { natural-scroll true; accel-speed 0.2 }
                mod-key "Ctrl"
                focus-follows-mouse
            }
            """)
        expect(sub.modKey == [.control], "an unknown sub-block does not take the mod-key down with it")
        expect(sub.focusFollowsMouse, "nor the keys that come after it")

        // 2) skipUnknownBlock cannot eat the } of its parent section.
        let skipped = NigiriConfig.parse(
            """
            layout { unknown { x 1 } gaps 33 }
            binds { Mod+T { spawn "a"; } }
            """)
        expectEqual(skipped.gap, 33, "the key following the unknown block is applied")
        expectEqual(skipped.binds.count, 1, "and the binds{} after it is still alive")

        // 3) slashdash: node, argument and child block (commented_node,
        // commented_arg, commented_child from the official suite).
        let slash = NigiriConfig.parse(
            """
            layout {
                /- gaps 99
                gaps 7
            }
            /- window-rule { match app-id="x"; open-floating true }
            """)
        expectEqual(slash.gap, 7, "/- comments out the whole node")
        expectEqual(slash.rules.count, 0, "/- takes the node's child block with it")
        expectEqual(
            NigiriConfig.tokenize("node /- arg1 arg2"), ["node", "arg2"],
            "/- mid-line takes ONE argument")
        expectEqual(
            NigiriConfig.tokenize("node arg /- { inner }"), ["node", "arg"],
            "/- before { takes the block and leaves the node")

        // 4) block comments, nested and with a stray * inside.
        expectEqual(NigiriConfig.tokenize("node /* comment */ arg"), ["node", "arg"], "block comment")
        expectEqual(NigiriConfig.tokenize("node /* * */"), ["node"], "a stray * does not close the comment")
        expectEqual(
            NigiriConfig.tokenize("a /* x /* y */ z */ b"), ["a", "b"], "nested block comments")

        // 5) escapes inside a string: an escaped quote does NOT end it.
        expectEqual(
            NigiriConfig.tokenize("spawn \"say \\\"hello\\\"\""),
            ["spawn", "say \"hello\""], "an escaped quote inside the string")

        // 6) raw strings: no escapes inside, quotes allowed inside. Your
        // animations/glitch/animations.kdl uses them for the shaders.
        expectEqual(
            NigiriConfig.tokenize("shader r\"a \\n b\""), ["shader", "a \\n b"],
            "r\"...\" does not interpret escapes")
        expectEqual(
            NigiriConfig.tokenize("shader r#\"has a \" inside\"#"), ["shader", "has a \" inside"],
            "r#\"...\"# tolerates quotes inside")
        expectEqual(
            NigiriConfig.tokenize("shader #\"v2 form\"#"), ["shader", "v2 form"],
            "the KDL v2 form is accepted too")
        // Raw string in PROPERTY position - the exact shape niri's own
        // default config uses for window-rule regexes. The tokenizer only
        // recognized raw strings at the start of a token, so the pattern
        // reached the matcher as mangled garbage and the rule never fired.
        expectEqual(
            NigiriConfig.tokenize("match app-id=r#\"^org\\.wezfurlong\\.wezterm$\"#"),
            ["match", "app-id=^org\\.wezfurlong\\.wezterm$"],
            "a raw string after a property's = keeps its backslashes")
        expectEqual(
            NigiriConfig.tokenize("word=rest"), ["word=rest"],
            "an r after = that is not a raw string stays an identifier")
        let shaderCfg = NigiriConfig.parse(
            """
            animations {
                window-open {
                    duration-ms 500
                    custom-shader r"
                        // raw GLSL goes in here: braces, // and \\ that are not KDL syntax
                        vec4 open_color(vec3 c) { return vec4(1.0); }
                    "
                    curve "ease-out-cubic"
                }
            }
            """)
        expect(
            shaderCfg.animations["window-open"] != nil,
            "a shader in a raw string does not break its animation")

        // struts are subtracted from the usable area, never leaving it at zero.
        let savedStruts = ScreenGeometry.struts
        ScreenGeometry.struts = NSEdgeInsets(top: 30, left: 12, bottom: 4, right: 8)
        let strutted = ScreenGeometry.primaryScreenVisibleFrameInAXSpace()
        ScreenGeometry.struts = savedStruts
        let plain = ScreenGeometry.primaryScreenVisibleFrameInAXSpace()
        if plain.width > 100 {
            expectEqual(strutted.width, plain.width - 20, "struts trim the usable width")
            expectEqual(strutted.minY, plain.minY + 30, "struts trim from the top")
        }

        // --- center-focused-column ---
        // Widths of 0.5: two fit exactly, three do not - which is precisely the
        // condition on-overflow measures.
        let centerCols = [column(0.5), column(0.5), column(0.5)]
        let centerPlacements = ColumnLayoutEngine.columnPlacements(
            columns: centerCols, usableWidth: usableWidth)
        ColumnLayoutEngine.centerPolicy = .never
        expectEqual(
            ColumnLayoutEngine.scrollOffset(
                toShow: 0, placements: centerPlacements, currentOffset: 0, usableWidth: usableWidth), 0,
            "never: if it is already visible, the camera does not move")
        ColumnLayoutEngine.centerPolicy = .always
        let alwaysOffset = ColumnLayoutEngine.scrollOffset(
            toShow: 1, placements: centerPlacements, currentOffset: 0, usableWidth: usableWidth)
        expectEqual(
            alwaysOffset, centerPlacements[1].x + centerPlacements[1].width / 2 - usableWidth / 2,
            "always: centers the column")
        ColumnLayoutEngine.centerPolicy = .onOverflow
        expectEqual(
            ColumnLayoutEngine.scrollOffset(
                toShow: 1, placements: centerPlacements, currentOffset: 0, usableWidth: usableWidth,
                previousIndex: 0), 0,
            "on-overflow: if both fit, it does not center")
        let farOffset = ColumnLayoutEngine.scrollOffset(
            toShow: 2, placements: centerPlacements, currentOffset: 0, usableWidth: usableWidth,
            previousIndex: 0)
        expect(farOffset != 0, "on-overflow: if they do not fit together, it centers")
        ColumnLayoutEngine.centerPolicy = .never
        ColumnLayoutEngine.alwaysCenterSingleColumn = true
        let single = [column(1.0 / 3.0)]
        let singlePlacements = ColumnLayoutEngine.columnPlacements(
            columns: single, usableWidth: usableWidth)
        expectEqual(
            ColumnLayoutEngine.scrollOffset(
                toShow: 0, placements: singlePlacements, currentOffset: 0, usableWidth: usableWidth),
            singlePlacements[0].x + singlePlacements[0].width / 2 - usableWidth / 2,
            "always-center-single-column")
        ColumnLayoutEngine.alwaysCenterSingleColumn = false

        // default-column-display: every new column is born in that mode.
        Column.defaultTabbed = true
        expect(Column().isTabbed, "default-column-display reaches new columns")
        Column.defaultTabbed = false
        expect(!Column().isTabbed, "and they go back to normal when it is turned off")

        // --- binds: no modifier, mod-key, mouse buttons ---
        NigiriConfig.modKey = [.command, .option]
        expect(NigiriConfig.parseCombo("F13") != nil, "a bind with no modifier is legal")
        expect(NigiriConfig.parseCombo("F13")?.1.isEmpty == true, "and arrives with no modifiers")
        expect(NigiriConfig.parseCombo("Mod+DoesNotExist") == nil, "a nonexistent key is still an error")
        NigiriConfig.modKey = [.control]
        expect(NigiriConfig.parseCombo("Mod+Left")?.1 == [.control], "mod-key redefines what Mod is")
        NigiriConfig.modKey = [.command, .option]

        expectEqual(
            NigiriConfig.mouseBindingKey(for: "Mod+MouseMiddle") ?? "", "mod-middle",
            "mouse button bind")
        expectEqual(NigiriConfig.mouseBindingKey(for: "MouseBack") ?? "", "back", "button with no modifier")
        expect(NigiriConfig.mouseBindingKey(for: "Mod+M") == nil, "an ordinary key is not a button")

        let mouseCfg = NigiriConfig.parse(
            """
            input { mod-key "Ctrl" }
            binds {
                Mod+MouseMiddle { close-window; }
                F13 { open-overview; }
            }
            """)
        expectEqual(
            mouseCfg.mouseBindings["mod-middle"] ?? "", "close-window",
            "the mouse bind does not land in the keyboard binds{}")
        expect(
            mouseCfg.binds.contains { $0.combo == "F13" && $0.modifiers.isEmpty },
            "the modifier-less bind is registered")
        expect(mouseCfg.modKey == [.control], "mod-key reaches the config")
        NigiriConfig.modKey = [.command, .option]

        // --- IPC: niri's shape and the old one, on the same socket ---
        expect(NiriProtocol.parse("windows").legacy, "the old request answers flat")
        if case .windows = NiriProtocol.parse("\"Windows\"").request {
            expect(!NiriProtocol.parse("\"Windows\"").legacy, "niri's answers with an Ok/Err envelope")
        } else {
            expect(false, "\"Windows\" parses")
        }
        if case .action(let line) = NiriProtocol.parse("{\"Action\":{\"FocusColumnLeft\":{}}}").request {
            expectEqual(line, "focus-column-left", "the CamelCase action maps to the config line")
        } else {
            expect(false, "Action parses")
        }
        if case .action(let line) = NiriProtocol.parse("{\"Action\":{\"FocusColumn\":{\"index\":3}}}").request
        {
            expectEqual(line, "focus-column 3", "arguments travel on the line")
        } else {
            expect(false, "Action with arguments parses")
        }
        if case .action(let line) = NiriProtocol.parse("action move-column-to-workspace 2").request {
            expectEqual(line, "move-column-to-workspace 2", "the old action passes through unchanged")
        } else {
            expect(false, "action <line> parses")
        }
        // IPC-5: the request surface niri actually has - these fell to
        // "unknown request" before.
        if case .layers = NiriProtocol.parse("\"Layers\"").request {
        } else {
            failures.append("Layers should parse")
        }
        if case .keyboardLayouts = NiriProtocol.parse("\"KeyboardLayouts\"").request {
        } else {
            failures.append("KeyboardLayouts should parse")
        }
        if case .pickColor = NiriProtocol.parse("\"PickColor\"").request {
        } else {
            failures.append("PickColor should parse")
        }
        if case .returnError = NiriProtocol.parse("\"ReturnError\"").request {
        } else {
            failures.append("ReturnError should parse")
        }
        if case .casts = NiriProtocol.parse("\"Casts\"").request {
        } else {
            failures.append("Casts should parse")
        }
        if case .output(let name) = NiriProtocol.parse(
            "{\"Output\":{\"output\":\"DP-1\",\"action\":\"Off\"}}"
        ).request {
            expectEqual(name, "DP-1", "Output carries its target name")
        } else {
            failures.append("Output should parse")
        }
        if case .unknown = NiriProtocol.parse("{\"Nope\":{}}").request {
        } else {
            expect(false, "an unknown request is not made up")
        }
        expectEqual(
            NiriProtocol.kebab("MoveColumnToWorkspaceDown"), "move-column-to-workspace-down",
            "CamelCase -> kebab")

        // The ids are stable and are never recycled.
        let w1 = window()
        let w2 = window()
        expect(w1.id != w2.id, "every window has its own id")
        let wsA = Workspace()
        let wsB = Workspace()
        expect(wsA.id != wsB.id, "every workspace has its own")

        // --- insert-hint: niri's rule is the nearest gap ---
        // Two 700x800 columns, gap 10, starting at x=10.
        let colA = [CGRect(x: 10, y: 44, width: 700, height: 800)]
        let colB = [
            CGRect(x: 720, y: 44, width: 700, height: 400),
            CGRect(x: 720, y: 454, width: 700, height: 390),
        ]
        let grid = [colA, colB]
        // Near the left edge of the first one: a new column before it.
        expect(
            ColumnLayoutEngine.insertPosition(
                columnFrames: grid, point: CGPoint(x: 12, y: 400), screenFrame: screen) == .newColumn(0),
            "next to the left gap it goes in as a new column")
        // In the vertical middle of the second column, far from its side edges:
        // it lands INSIDE the stack, in the gap between its two tiles.
        expect(
            ColumnLayoutEngine.insertPosition(
                columnFrames: grid, point: CGPoint(x: 1070, y: 449), screenFrame: screen) == .inColumn(1, 1),
            "over the gap between two windows it goes into the stack")
        // Tie: the new column wins (niri: `if vert_dist <= hor_dist`).
        let tie = ColumnLayoutEngine.insertPosition(
            columnFrames: grid, point: CGPoint(x: 715, y: 449), screenFrame: screen)
        expect(tie == .newColumn(1), "a tie between the vertical and horizontal gap goes to the new column")
        // With no columns there is nowhere to land but the first position.
        expect(
            ColumnLayoutEngine.insertPosition(columnFrames: [], point: .zero, screenFrame: screen)
                == .newColumn(0),
            "an empty workspace takes column 0")

        // --- REGRESSION: the third column disappeared from the overview ---
        // Three columns at 50%: the third falls past the right edge, where
        // grantedX pinned it to the very pixel a parked tab waits on - and the
        // overview filter threw it out along with the parked ones.
        let overviewCols = [column(0.5), column(0.5), column(0.5)]
        for c in overviewCols { c.setWindows([window()]) }
        let overviewOut = ColumnLayoutEngine.overviewFrames(
            columns: overviewCols, in: screen)
        expectEqual(overviewOut.count, 3, "all three columns make it into the overview")
        expectEqual(
            overviewOut[2].frame.minX, screen.minX + 10 + 2 * (720 + 10),
            "the third keeps its virtual x, with no screen clamp")
        expect(
            overviewOut.allSatisfy { $0.frame.width > 2 && $0.frame.height > 2 },
            "and none comes out degenerate (which is the only thing the overview filters now)")
        // And with the clamp, which is what the old path did: the third one
        // sticks to the parking pixel.
        let clamped = ColumnLayoutEngine.targetFrames(
            columns: overviewCols, in: screen, viewOffset: 0)
        expectEqual(
            clamped[2].frame.minX, screen.maxX - 1,
            "targetFrames does clamp it: that is why the overview cannot use it")

        // --- overview geometry, niri's (monitor.rs) ---
        // A workspace is the SCREEN times the zoom, not the bounding box of its
        // windows fitted into a row: that was ours, and it squashed a strip
        // wider than the screen until it fit.
        OverviewPanel.zoom = 0.5
        let wsWindow = window()
        let onScreen = CGRect(x: screen.minX + 10, y: screen.minY + 10, width: 700, height: 800)
        // A second window scrolled out of view, two screens to the right of the
        // edge.
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
        expectEqual(oneWs.rows.count, 1, "one occupied workspace, one row")
        let canvas = oneWs.rows[0].canvas
        expectEqual(canvas.width, screen.width * 0.5, "the workspace is the screen times the zoom, in width")
        expectEqual(canvas.height, screen.height * 0.5, "and in height too")
        expectEqual(canvas.minX, screen.minX + screen.width * 0.25, "centered horizontally")
        expectEqual(canvas.minY, screen.minY + screen.height * 0.25, "and the active one centered vertically")
        expect(
            oneWs.rows[0].entries[1].box.minX > canvas.maxX,
            "the window scrolled out of view stays OUTSIDE the rectangle, not squashed inside it")
        expectEqual(
            oneWs.rows[0].entries[0].box.width, 700 * 0.5,
            "and the one that is in view measures its real size times the zoom")
        expectEqual(
            oneWs.rows[0].band.width, screen.width,
            "the clip is full width: the sideways overflow is exactly the point")
        expectEqual(
            oneWs.rows[0].band.height, canvas.height,
            "and exactly the workspace in height, so it does not invade its neighbor")

        // Two workspaces: spacing = workspace height + 10% of the screen height
        // times the zoom (niri: workspace_gap).
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
        expectEqual(pair.rows.count, 2, "two occupied workspaces, two rows")
        expectEqual(
            pair.rows[1].canvas.minY - pair.rows[0].canvas.minY,
            screen.height * 0.5 + screen.height * 0.1 * 0.5,
            "the step between workspaces is height + the 10% gap")
        expectEqual(
            pair.rows[0].canvas.height, pair.rows[1].canvas.height,
            "and they all measure the same: there is one zoom, not one per row")

        // REGRESSION (items 15 and 16): the focus-follows-mouse rule.
        expect(
            !TilingEngine.shouldFocusFollowMouse(
                overviewActive: true, transitioning: false,
                buttonsDown: 0, sinceLastTick: 1),
            "with the overview open it does NOT move focus: the panel drives its own selection")
        expect(
            !TilingEngine.shouldFocusFollowMouse(
                overviewActive: false, transitioning: true,
                buttonsDown: 0, sinceLastTick: 1),
            "nor in the middle of a workspace switch")
        expect(
            !TilingEngine.shouldFocusFollowMouse(
                overviewActive: false, transitioning: false,
                buttonsDown: 1, sinceLastTick: 1),
            "nor with a button held down (that is a drag)")
        expect(
            !TilingEngine.shouldFocusFollowMouse(
                overviewActive: false, transitioning: false,
                buttonsDown: 0, sinceLastTick: 0.05),
            "nor before the throttle")
        expect(
            TilingEngine.shouldFocusFollowMouse(
                overviewActive: false, transitioning: false,
                buttonsDown: 0, sinceLastTick: 1),
            "and yes in the normal case")

        // REGRESSION (item 17): in a tabbed column the parked windows live at
        // maxX-1, so the drop preview took them for "the column's frame" and
        // measured the gap against the right edge of the screen. Without them,
        // the first window of each column is the one you see.
        let tabbedDrag = column(0.5)
        tabbedDrag.setWindows([window(), window()])
        tabbedDrag.isTabbed = true
        let plainDrag = column(0.5)
        plainDrag.setWindows([window()])
        let previewFrames = ColumnLayoutEngine.targetFrames(
            columns: [tabbedDrag, plainDrag], in: screen, viewOffset: 0,
            includingParked: false)
        expectEqual(previewFrames.count, 2, "one entry per visible column, without the parked ones")
        expect(
            previewFrames.allSatisfy { $0.frame.minX < screen.maxX - 100 },
            "and none of them is the parking spot at the right edge")
        let withParked = ColumnLayoutEngine.targetFrames(
            columns: [tabbedDrag, plainDrag], in: screen, viewOffset: 0)
        expectEqual(
            withParked.count, 3, "the normal path does include them, which is what keeps them parked")

        // A tabbed column contributes ONE single card, not one per window.
        let tabbedCol = column(0.5)
        tabbedCol.setWindows([window(), window(), window()])
        tabbedCol.isTabbed = true
        expectEqual(
            ColumnLayoutEngine.overviewFrames(columns: [tabbedCol], in: screen).count, 1,
            "the tabbed column is one card")

        // --- REGRESSION: colors with alpha were dropped silently ---
        expect(NigiriConfig.parseColor("#7355a6") != nil, "6 digits")
        let withAlpha = NigiriConfig.parseColor("#00000070")
        expect(withAlpha != nil, "8 digits (rgba) - the only way to write a shadow")
        expectEqual(withAlpha?.alphaComponent ?? 0, 0x70 / 255.0, "and the alpha arrives")
        let shorthand = NigiriConfig.parseColor("#f0a")
        expect(shorthand != nil, "3 digits")
        expectEqual(shorthand?.redComponent ?? 0, 1, "the shorthand doubles each digit")
        expectEqual(
            NigiriConfig.parseColor("#f0a8")?.alphaComponent ?? 0, 0x88 / 255.0, "4 digits with alpha")
        expect(NigiriConfig.parseColor("#nope") == nil, "and invalid input is still nil (now with a warning)")

        // --- camera: niri's compute_new_view_offset ---
        // The only thing genuinely missing: a column WIDER than the view always
        // aligns to the left (it used to align to whichever edge it had been
        // clipped by, leaving its left half unreachable).
        expectEqual(
            ColumnLayoutEngine.fitOffset(x: 100, width: 2000, currentOffset: 0, usableWidth: usableWidth),
            100,
            "a column wider than the view aligns to the left")
        expectEqual(
            ColumnLayoutEngine.fitOffset(x: 100, width: 2000, currentOffset: 5000, usableWidth: usableWidth),
            100,
            "and it does not matter where the camera came from")
        // The rest is the usual rule, now written the way niri writes it: if it
        // already fits, do not move; otherwise the alignment that costs the least
        // movement wins.
        expectEqual(
            ColumnLayoutEngine.fitOffset(x: 20, width: 700, currentOffset: 0, usableWidth: usableWidth), 0,
            "if it already fits, the camera stays put")
        expectEqual(
            ColumnLayoutEngine.fitOffset(x: 1000, width: 700, currentOffset: 0, usableWidth: usableWidth),
            1000 + 700 - usableWidth, "clipped on the right: align that edge")
        expectEqual(
            ColumnLayoutEngine.fitOffset(x: 300, width: 700, currentOffset: 900, usableWidth: usableWidth),
            300,
            "clipped on the left: align that edge")

        // on-overflow measures against the target's NEIGHBOR on the side you
        // came from, not against the column you left: what matters is whether
        // the view can still hold the pair that is about to cross.
        ColumnLayoutEngine.centerPolicy = .onOverflow
        let halves = (0..<3).map { _ in column(0.5) }
        let halfPlacements = ColumnLayoutEngine.columnPlacements(
            columns: halves, usableWidth: usableWidth)
        // Three columns at 50%: every adjacent pair fits EXACTLY, so not even the
        // long jump from 0 to 2 centers - the neighbor of 2 coming from 0 is 1,
        // and 1+2 fit.
        expectEqual(
            ColumnLayoutEngine.scrollOffset(
                toShow: 2, placements: halfPlacements, currentOffset: 0, usableWidth: usableWidth,
                previousIndex: 0),
            halfPlacements[2].x + halfPlacements[2].width - usableWidth,
            "on-overflow: if the pair fits, it is a normal scroll even on a long jump")
        // At 66% no pair fits: that is when it centers.
        let wides = (0..<3).map { _ in column(0.66) }
        let widePlacements = ColumnLayoutEngine.columnPlacements(
            columns: wides, usableWidth: usableWidth)
        expectEqual(
            ColumnLayoutEngine.scrollOffset(
                toShow: 1, placements: widePlacements, currentOffset: 0, usableWidth: usableWidth,
                previousIndex: 0),
            widePlacements[1].x - (usableWidth - widePlacements[1].width) / 2,
            "on-overflow: if the pair does not fit, it centers")
        ColumnLayoutEngine.centerPolicy = .never

        // --- structural invariants (the debt that was left) ---
        // Inserting before the focused column does NOT steal focus: it travels
        // with the column, not with the index. This is the hole through which an
        // overview drop ended up focusing something else.
        let inv = Workspace()
        let marked = Column()
        inv.appendColumn(Column()); inv.appendColumn(marked); inv.appendColumn(Column())
        inv.focus(column: 1)
        inv.insertColumn(Column(), at: 0)
        expect(inv.columns[inv.focusedIndex] === marked, "inserting before does not move the column focus")
        inv.removeColumn(at: 0)
        expect(inv.columns[inv.focusedIndex] === marked, "removing an earlier one does not either")
        inv.swapColumns(inv.focusedIndex, 2)
        expect(inv.columns[inv.focusedIndex] === marked, "and a swap follows it")

        // Every mutation of the stack drops the height cache and re-anchors the
        // row: each call site used to do it by hand, and the ones that forgot
        // left stale heights or a focus past the end.
        let inc = Column()
        inc.setWindows([window(), window(), window()])
        inc.focus(row: 2)
        inc.cachedHeights = [100, 100, 100]
        inc.removeWindow(at: 0)
        expect(inc.cachedHeights == nil, "removing a window invalidates the height cache")
        expectEqual(inc.focusedWindowIndex, 1, "and re-anchors the focused row")
        inc.cachedHeights = [100, 100]
        expectEqual(
            inc.removeWindows(where: { _ in false }).count, 0,
            "a removeWindows that takes nothing out does not touch the cache")
        expect(
            inc.cachedHeights != nil, "because it runs on every relayout and re-probing would take forever")
        // REGRESSION: contains(where:) + removeAll(where:) ran the predicate
        // TWICE, and some call sites are not pure (demotion collects into an
        // array, the purge counts absences). The first match was duplicated: the
        // window ended up both tiled AND floating.
        let twice = Column()
        twice.setWindows([window(), window(), window()])
        var seen: [ManagedWindow] = []
        let gone = twice.removeWindows { w in
            seen.append(w); return true
        }
        expectEqual(seen.count, 3, "the predicate runs once per window, not twice")
        expectEqual(gone.count, 3, "and it returns what it removed, so nobody has to collect it inside")
        expectEqual(twice.windows.count, 0, "which is what lets the predicate be pure")
        inc.insert(window(), at: 99)
        expectEqual(inc.windows.count, 3, "inserting out of range clamps instead of crashing")
        expect(inc.removeWindow(at: 99) == nil, "and removing out of range returns nil")

        // An empty workspace can still be manipulated without stray indices.
        let empty = Workspace()
        expect(empty.removeColumn(at: 0) == nil, "removing from an empty workspace does not crash")
        expectEqual(empty.focusedIndex, 0, "and focus stays at 0")

        // --- touch mouse gestures ---
        expect(
            TrackpadGestures.isMouseFamily(112),
            "family 112 is a Magic Mouse (as reported by this machine's hardware)")
        expect(!TrackpadGestures.isMouseFamily(110), "and 110 is the built-in trackpad")
        // --- SwipeTracker (audit ANI-2) -----------------------------------
        // niri's swipe_tracker.rs, values computed by hand. 10px per 10ms
        // for 100ms: pos 100, velocity 100/0.09 (first-to-last timestamps).
        var tracker = SwipeTracker()
        for i in 0..<10 { tracker.push(10, timestamp: Double(i) * 0.010) }
        expectEqual(tracker.pos, 100, "pos accumulates the deltas")
        expect(abs(tracker.velocity() - 100.0 / 0.09) < 0.001, "velocity = sum/time over the history")
        // projected = pos - vel/(1000*ln(0.997))
        let expectedProjection = 100.0 - (100.0 / 0.09) / (1000.0 * log(0.997))
        expect(
            abs(tracker.projectedEndPos() - expectedProjection) < 0.001,
            "projection decelerates at 0.997/ms, upstream's touchpad rate")
        tracker.push(10, timestamp: 0.05)
        expectEqual(tracker.pos, 100, "an out-of-order timestamp is dropped, like upstream")
        // The 150ms history window: after a long idle push, old events fall
        // out and the velocity is computed over the recent window only.
        tracker.push(0, timestamp: 1.0)
        expectEqual(tracker.velocity(), 0, "idle time empties the history - velocity dies")
        expect(
            abs(tracker.projectedEndPos() - 100) < 0.001,
            "and the projection collapses to the current position")
        // Workspace-switch decision math (monitor.rs end): 300px per
        // workspace, clamped one either way, rounded.
        var wsGesture = WorkspaceSwitchGestureState(centerIdx: 1)
        wsGesture.tracker.push(200, timestamp: 0)
        expectEqual(
            wsGesture.endIdx(workspaceCount: 3), 2,
            "200px with no velocity rounds to the next workspace (200/300 > 0.5)")
        var wsShort = WorkspaceSwitchGestureState(centerIdx: 1)
        wsShort.tracker.push(100, timestamp: 0)
        expectEqual(
            wsShort.endIdx(workspaceCount: 3), 1,
            "100px stays put - under half a workspace of travel")
        var wsFar = WorkspaceSwitchGestureState(centerIdx: 1)
        wsFar.tracker.push(2000, timestamp: 0)
        expectEqual(
            wsFar.endIdx(workspaceCount: 5), 2,
            "the clamp caps a touchpad swipe at one workspace either way (is_clamped)")
        // View-offset snapping: nearest column alignment wins, clamped to
        // the first/last column.
        let snapCols = [column(0.5), column(0.5), column(0.5)]
        let snapPlacements = ColumnLayoutEngine.columnPlacements(
            columns: snapCols, usableWidth: usableWidth)
        let s = ViewGestureSnapping.snap(
            target: snapPlacements[1].x + 3, placements: snapPlacements, usableWidth: usableWidth)
        expectEqual(s?.viewPos ?? -1, snapPlacements[1].x, "a near-left-edge target snaps to it")
        expectEqual(s?.colIdx ?? -1, 1, "and activates that column")
        let sFar = ViewGestureSnapping.snap(
            target: 100000, placements: snapPlacements, usableWidth: usableWidth)
        expectEqual(
            sFar?.viewPos ?? -1, snapPlacements[2].x + snapPlacements[2].width - usableWidth,
            "past the end clamps to the last column's right alignment")
        // The invented gestures{} vocabulary is gone: those keys now fall
        // through to unknown-key (report-and-skip), not into config state.
        _ = NigiriConfig.parse("gestures { three-finger-left focus-column-right }")

        // Reserved screen-edge zones (the IPC reserve-zone command): the tiling
        // area shrinks by the strut, on the correct edge, in AX space (top-left
        // origin). This is the whole mechanism macOS lacks a compositor for.
        let strutScreen = CGRect(x: 100, y: 50, width: 1000, height: 800)
        let topStrut = ScreenStruts.inset(strutScreen, by: [ScreenStrut(edge: .top, size: 44)])
        expectEqual(
            topStrut, CGRect(x: 100, y: 94, width: 1000, height: 756),
            "a top strut moves the origin down and shrinks height")
        let bottomStrut = ScreenStruts.inset(strutScreen, by: [ScreenStrut(edge: .bottom, size: 30)])
        expectEqual(
            bottomStrut, CGRect(x: 100, y: 50, width: 1000, height: 770),
            "a bottom strut shrinks height without moving the origin")
        let leftStrut = ScreenStruts.inset(strutScreen, by: [ScreenStrut(edge: .left, size: 60)])
        expectEqual(
            leftStrut, CGRect(x: 160, y: 50, width: 940, height: 800),
            "a left strut moves the origin right and shrinks width")
        let stacked = ScreenStruts.inset(
            strutScreen,
            by: [
                ScreenStrut(edge: .top, size: 44), ScreenStrut(edge: .top, size: 20),
                ScreenStrut(edge: .right, size: 10),
            ])
        expectEqual(
            stacked, CGRect(x: 100, y: 114, width: 990, height: 736),
            "struts on the same edge stack; different edges combine")
        let noStrut = ScreenStruts.inset(strutScreen, by: [])
        expectEqual(noStrut, strutScreen, "no struts leaves the frame untouched")
        let overSized = ScreenStruts.inset(strutScreen, by: [ScreenStrut(edge: .top, size: 9999)])
        expectEqual(overSized.height, 0, "an over-large strut clamps to zero, never negative")
        let ignoredZero = ScreenStruts.inset(strutScreen, by: [ScreenStrut(edge: .top, size: 0)])
        expectEqual(ignoredZero, strutScreen, "a zero strut reserves nothing")
        expect(ScreenStrut.Edge(rawValue: "top") == .top, "edge parses from the IPC token")
        expect(ScreenStrut.Edge(rawValue: "nonsense") == nil, "a bad edge token is rejected")

        // System-inset vs reservation combination (effectiveInsets): per edge
        // the larger wins, never the sum - a reservation is measured from the
        // physical screen edge and the reserving panel covers the system strip
        // itself, so stacking would double-count (the 32pt dead gap between a
        // top bar and the first window).
        let sys = EdgeInsets(top: 32, bottom: 0, left: 0, right: 0)
        let barWins = ScreenStruts.effectiveInsets(
            system: sys, reserved: [ScreenStrut(edge: .top, size: 44)])
        expectEqual(barWins.top, 44, "a reservation larger than the system strip subsumes it")
        let systemWins = ScreenStruts.effectiveInsets(
            system: sys, reserved: [ScreenStrut(edge: .top, size: 20)])
        expectEqual(systemWins.top, 32, "a smaller reservation never lets windows under the strip")
        let unreserved = ScreenStruts.effectiveInsets(system: sys, reserved: [])
        expectEqual(unreserved.top, 32, "no reservation keeps the system inset as-is")
        let stackedThenMax = ScreenStruts.effectiveInsets(
            system: sys,
            reserved: [ScreenStrut(edge: .top, size: 20), ScreenStrut(edge: .top, size: 20)])
        expectEqual(stackedThenMax.top, 40, "same-edge reservations stack before the max")
        let otherEdge = ScreenStruts.effectiveInsets(
            system: EdgeInsets(top: 32, bottom: 70, left: 0, right: 0),
            reserved: [ScreenStrut(edge: .bottom, size: 30)])
        expectEqual(otherEdge.bottom, 70, "a Dock-sized system inset survives a smaller reservation")
        expectEqual(otherEdge.top, 32, "edges combine independently")

        // Refusal memoization gate (refusalVerdict): a busy app's stale
        // read-back must NOT latch as "the app's answer" on first sight -
        // that memorized lie froze visibly-wrong layouts until a restart.
        // Only the same divergent answer seen twice in a row is a refusal.
        let asked = CGRect(x: 10, y: 54, width: 720, height: 892)
        let agreedAnswer = CGRect(x: 10.4, y: 54, width: 719.6, height: 892)
        expect(
            ColumnLayoutEngine.refusalVerdict(target: asked, actual: agreedAnswer, candidate: nil)
                == .agreed,
            "an answer within tolerance is agreement, no memo churn")
        let staleAnswer = CGRect(x: 260, y: 54, width: 240, height: 892)
        expect(
            ColumnLayoutEngine.refusalVerdict(target: asked, actual: staleAnswer, candidate: nil)
                == .unconfirmed,
            "a first divergent answer is only a sighting - retry, don't latch")
        expect(
            ColumnLayoutEngine.refusalVerdict(
                target: asked, actual: staleAnswer, candidate: (asked, staleAnswer))
                == .confirmedRefusal,
            "the same divergent answer twice in a row latches as a real refusal")
        expect(
            ColumnLayoutEngine.refusalVerdict(
                target: asked, actual: CGRect(x: 10, y: 54, width: 500, height: 892),
                candidate: (asked, staleAnswer))
                == .unconfirmed,
            "a DIFFERENT divergent answer restarts confirmation instead of latching")
        expect(
            ColumnLayoutEngine.refusalVerdict(
                target: CGRect(x: 740, y: 54, width: 720, height: 892), actual: staleAnswer,
                candidate: (asked, staleAnswer))
                == .unconfirmed,
            "a candidate for another request never confirms this one")

        // Window broadcast diff: niri's WindowOpenedOrChanged fires for ANY
        // change of the fields its Window carries - the old title-only diff
        // silently swallowed workspace moves and floating flips.
        let snapA = WindowBroadcastSnapshot(
            title: "editor", workspaceId: 1, floating: false, column: 0, row: 0, frame: nil)
        let snapB = WindowBroadcastSnapshot(
            title: "browser", workspaceId: 1, floating: false, column: 1, row: 0, frame: nil)
        var wdiff = WindowBroadcastDiff.changes(old: [:], new: [1: snapA, 2: snapB])
        expectEqual(wdiff.changed, [1, 2], "every new window is a change")
        expectEqual(wdiff.closed, [], "nothing closed on first sight")
        wdiff = WindowBroadcastDiff.changes(old: [1: snapA, 2: snapB], new: [1: snapA, 2: snapB])
        expect(wdiff.changed.isEmpty && wdiff.closed.isEmpty, "identical state emits nothing")
        let movedWorkspace = WindowBroadcastSnapshot(
            title: "editor", workspaceId: 2, floating: false, column: 0, row: 0, frame: nil)
        wdiff = WindowBroadcastDiff.changes(old: [1: snapA], new: [1: movedWorkspace])
        expectEqual(wdiff.changed, [1], "a workspace move alone re-emits the window")
        let nowFloating = WindowBroadcastSnapshot(
            title: "editor", workspaceId: 1, floating: true, column: nil, row: nil, frame: nil)
        wdiff = WindowBroadcastDiff.changes(old: [1: snapA], new: [1: nowFloating])
        expectEqual(wdiff.changed, [1], "a floating flip alone re-emits the window")
        // IPC-8: a change in NOTHING BUT the frame batches into
        // WindowLayoutsChanged (server.rs:734-765) instead of a full
        // WindowOpenedOrChanged - the event never fired before.
        let geomA = [
            UInt64(1): WindowBroadcastSnapshot(
                title: "a", workspaceId: 1, floating: false, column: 0, row: 0,
                frame: CGRect(x: 0, y: 0, width: 700, height: 800))
        ]
        let geomB = [
            UInt64(1): WindowBroadcastSnapshot(
                title: "a", workspaceId: 1, floating: false, column: 0, row: 0,
                frame: CGRect(x: 0, y: 0, width: 900, height: 800))
        ]
        let gdiff = WindowBroadcastDiff.changes(old: geomA, new: geomB)
        expect(
            gdiff.changed.isEmpty && gdiff.layoutChanged == [1],
            "a geometry-only change is a WindowLayoutsChanged, never a full re-emit")
        wdiff = WindowBroadcastDiff.changes(old: [1: snapA, 2: snapB], new: [2: snapB])
        expectEqual(wdiff.closed, [1], "a vanished window closes")
        expect(wdiff.changed.isEmpty, "and the survivor stays quiet")

        // Owner-pid GC (dropStruts' rule): a reservation tagged with a client
        // pid is dropped when that process dies, so a crashed or killed panel
        // cannot leave the layout shrunk forever; unowned and other-owner zones
        // survive an unrelated death.
        let owned: [String: ScreenStrut] = [
            "a": ScreenStrut(edge: .top, size: 44, ownerPid: 100),
            "b": ScreenStrut(edge: .bottom, size: 20, ownerPid: 200),
            "c": ScreenStrut(edge: .left, size: 10),
        ]
        let afterDeath = owned.filter { $0.value.ownerPid != 100 }
        expectEqual(afterDeath.count, 2, "a dead owner's zone is dropped, the others kept")
        expect(afterDeath["a"] == nil, "the dead owner's own zone is gone")
        expect(afterDeath["b"] != nil, "another live owner's zone survives")
        expect(afterDeath["c"] != nil, "an unowned zone survives an unrelated death")

        if failures.isEmpty {
            print("selftest: \(checks) checks, all OK")
            exit(0)
        }
        print("selftest: \(failures.count) of \(checks) checks FAILED")
        for f in failures { print("  - \(f)") }
        exit(1)
    }
}
