import AppKit

// Overview v2: a full-screen panel of window THUMBNAILS (ScreenCaptureKit
// screenshots) - the real windows never move. One row per occupied
// workspace; each thumbnail keeps its window's aspect ratio, rendered bare
// like niri's overview (no titles, no labels - niri draws none). Click
// hit-testing is the mouse tap's job (the panel itself is click-through like
// every overlay here) - hitTest(_:) answers which entry a global point lands
// on.
final class OverviewPanel {
    struct Entry {
        let title: String
        let box: CGRect  // AX-space rect the thumbnail occupies
        // Whose window this card shows. Frames are addressed by id, never by
        // position: the slot index is renumbered by every rebuild, which is
        // how a capture in flight ended up painted into another card.
        let windowID: UInt64
    }

    // One workspace's real geometry, handed to computeRows to be scaled
    // into the overview. layoutFrame is where the window sits in the real
    // tiled layout (columns/stacks); captureFrame is its current on-screen
    // frame, used only to match the ScreenCaptureKit screenshot.
    struct WorkspaceInput {
        let wsIndex: Int
        let active: Bool
        // The workspace's own scroll position: its windows already carry it,
        // but the panel needs it on its own to animate the camera when it
        // moves (niri animates the view offset with horizontal-view-movement).
        var viewOffset: CGFloat = 0
        let windows: [(window: ManagedWindow, layoutFrame: CGRect, captureFrame: CGRect)]
    }

    // One workspace as the panel draws it. A struct, not a 5-tuple: it grew
    // one field per niri detail (canvas, clip band, camera) and the tuple was
    // being spelled out at six call sites.
    struct Row {
        let wsIndex: Int
        let active: Bool
        // The workspace's own rectangle at this zoom: the whole screen scaled
        // down, not the bounding box of its windows.
        let canvas: CGRect
        // What its contents are clipped to: canvas height, full screen width,
        // since a column strip wider than the screen bleeds sideways in niri
        // instead of being squeezed to fit.
        let band: CGRect
        // Where the camera sits, in panel pixels - the scroll position scaled.
        let cameraX: CGFloat
        let entries: [Entry]
    }
    struct ComputedRows {
        let rows: [Row]
        let selection: [(window: ManagedWindow, wsIndex: Int)]
        let requests: [(pid: pid_t, title: String, frame: CGRect)]

    }

    // niri's overview { zoom }: the fraction of real size a workspace is
    // drawn at, clamped exactly like niri's compute_overview_zoom
    // (0.0001...0.75).
    nonisolated(unsafe) static var zoom: CGFloat = 0.5

    // niri's overview geometry, ported from monitor.rs. The whole thing is one
    // uniform scale of the SCREEN - there is no fit-to-content anywhere in
    // niri, which is what this used to do:
    //
    //   workspace_size(zoom)      = view_size * zoom          (the OUTPUT
    //                               size, not the working area, not a
    //                               bounding box of the windows)
    //   workspace_gap(zoom)       = view_size.h * 0.1 * zoom
    //   workspaces_render_geo()   = one vertical column, x constant and
    //                               centered, pitch = ws_h + gap, offset so
    //                               the ACTIVE workspace is centered
    //
    // The consequence the fit-to-row version got wrong: a workspace whose
    // column strip is wider than the screen does NOT get squeezed until it
    // fits. It is drawn at its own scroll position and simply bleeds past the
    // sides of its rectangle - off-view columns stay off-view, just smaller
    // (niri crops to infinite bounds horizontally on purpose, monitor.rs:
    // "HACK: crop to infinite bounds at least horizontally"). Vertically it IS
    // cropped, to its own band, so nothing bleeds into the neighbouring
    // workspace. `band` carries that clip rect.
    static func computeRows(_ inputs: [WorkspaceInput], screenFrame: CGRect) -> ComputedRows {
        let scale = min(0.75, max(0.0001, zoom))
        let wsSize = CGSize(width: screenFrame.width * scale, height: screenFrame.height * scale)
        let gap = screenFrame.height * 0.1 * scale
        let pitch = wsSize.height + gap
        // Centered on the active workspace: niri's static_offset, plus a
        // first_ws_y of -active_index * pitch.
        let activeRow = inputs.firstIndex { $0.active } ?? 0
        let originX = screenFrame.minX + (screenFrame.width - wsSize.width) / 2
        let activeY = screenFrame.minY + (screenFrame.height - wsSize.height) / 2
        var rows: [Row] = []
        var selection: [(window: ManagedWindow, wsIndex: Int)] = []
        var requests: [(pid: pid_t, title: String, frame: CGRect)] = []
        for (rowIndex, input) in inputs.enumerated() {
            let canvas = CGRect(
                x: originX,
                y: activeY + CGFloat(rowIndex - activeRow) * pitch,
                width: wsSize.width, height: wsSize.height)
            // niri drops a workspace whose rectangle does not intersect the
            // output at all (workspaces_with_render_geo's filter).
            guard canvas.intersects(screenFrame) else { continue }
            // The window's own position inside its workspace's viewport,
            // scaled - not repacked. A window at x = 2 screens along the strip
            // lands 2 scaled screens to the right of the canvas, i.e. off it.
            func project(_ f: CGRect) -> CGRect {
                CGRect(
                    x: canvas.minX + (f.minX - screenFrame.minX) * scale,
                    y: canvas.minY + (f.minY - screenFrame.minY) * scale,
                    width: f.width * scale, height: f.height * scale)
            }
            var entries: [Entry] = []
            for item in input.windows {
                entries.append(
                    Entry(
                        title: item.window.title, box: project(item.layoutFrame),
                        windowID: item.window.id))
                requests.append((item.window.pid, item.window.title, item.captureFrame))
                selection.append((item.window, input.wsIndex))
            }
            // Horizontally the band is the whole screen (that bleed is the
            // point); vertically it is exactly the workspace's own rectangle.
            let band = CGRect(
                x: screenFrame.minX, y: canvas.minY,
                width: screenFrame.width, height: canvas.height)
            rows.append(
                Row(
                    wsIndex: input.wsIndex, active: input.active, canvas: canvas,
                    band: band, cameraX: input.viewOffset * scale, entries: entries))
        }
        return ComputedRows(rows: rows, selection: selection, requests: requests)
    }

    private let window: NSWindow
    private var entryBoxes: [CGRect] = []
    // Each card's frame in the content view's (bottom-left) coordinates,
    // flattened entry order - so the selection ring can be positioned over
    // the selected card without recomputing the AX->view transform.
    private var cardFrames: [CGRect] = []
    // The thumbnail image views in flattened entry order - kept so the
    // refresh timer can swap just the images (no subview teardown/rebuild,
    // which flickered and looked frame-y). Same order as the caller's
    // entries / selection list.
    private var thumbnailViews: [NSView] = []
    // The same views, addressed by window id - what a live stream frame needs
    // in order to land on the right card no matter how the panel was rebuilt.
    private var thumbnailsByWindow: [UInt64: NSView] = [:]
    // The card container views (parents of the thumbnails), same order -
    // kept so a mouse drag can lift one card and slide it under the cursor.
    private var cardViews: [NSView] = []
    // The workspace plates, kept so their shadow can fade with the progress -
    // niri's only fade.
    private var plateViews: [NSView] = []
    // Each card's clipping band origin in content coordinates: cards live
    // inside their workspace's band, so anything working in content space (the
    // selection ring, a drag) has to cross that offset.
    private var cardOrigins: [CGPoint] = []
    // Where each workspace's camera was on the previous build, so a rebuild
    // that moved it can animate the difference instead of snapping.
    private var previousCamera: [Int: CGFloat] = [:]
    // Per workspace: the view every card of that workspace rides on, and the
    // slice of the flattened entry list it owns. A pan moves ONE view and
    // shifts that slice's geometry - rebuilding the whole panel per scroll
    // event would re-request every thumbnail capture at wheel speed.
    private var strips: [Int: NSView] = [:]
    private var stripRanges: [Int: Range<Int>] = [:]
    // The AX-space screen frame of the current panel, for converting the
    // drag's AX cursor point into content-view coordinates.
    private var screenFrameAX: CGRect = .zero
    private var draggedIndex: Int?
    // The moving selection frame (niri's overview highlights the focused
    // window). A bright-purple ring reusing the focus-ring accent, floated
    // above every card and repositioned as navigation moves the selection.
    private let selectionView = NSView()
    // Drop hint shown while dragging: niri paints a filled, semi-transparent
    // rounded region the exact shape/size of where the window will land - a
    // tall column-shaped slab for "new column", a short column-wide band for
    // "stack into column". A region, not a thin line, so the two drop kinds
    // read differently at a glance.
    private let dropIndicator = NSView()
    var isVisible: Bool { window.isVisible }

    // Config-driven style. The backdrop is the panel's own background; the
    // zoom is static because computeRows is pure.
    //
    // niri's overview backdrop is the plain backdrop-color - gray 0.15 by
    // default (appearance.rs:12). The wallpaper appears behind it ONLY when
    // a layer-rule says place-within-backdrop (that is how the Linux DMS
    // setup gets its blurred wallpaper there); defaulting to a captured
    // desktop was invented. The panel is opaque by construction - the real
    // windows still sit behind it - so when that rule is present the
    // desktop is drawn INTO it. The selection ring wears the focus-ring's
    // own colors (the overview shows the real ring scaled, not a glow of
    // its own), and the drop indicator the insert-hint's.
    func applyStyle(
        zoom: CGFloat, backdrop: NSColor, useWallpaper: Bool,
        ringColor: NSColor, ringWidth: CGFloat, insertHintColor: NSColor
    ) {
        Self.zoom = zoom
        backdropColor = backdrop
        self.useWallpaper = useWallpaper
        window.contentView?.layer?.backgroundColor = backdrop.cgColor
        selectionView.layer?.borderColor = ringColor.cgColor
        selectionView.layer?.borderWidth = max(1, ringWidth * min(0.75, max(0.0001, zoom)) * 2)
        dropIndicator.layer?.backgroundColor = insertHintColor.cgColor
    }
    private var backdropColor = NSColor(calibratedWhite: 0.15, alpha: 1)
    private var useWallpaper = false
    private var backdropImage: CGImage?
    private let backdropView = NSView()
    private let backdropTint = NSView()

    // The captured desktop, as it is. There is no blur knob: niri does not
    // blur its backdrop, and on the Linux setup this was ported from the blur
    // comes from the SHELL - DankMaterialShell publishes a separately blurred
    // wallpaper layer (`dms:blurwallpaper`) and niri is only told which layer
    // to place within the backdrop. Reimplementing that here would be
    // inventing a compositor feature that does not exist, which is the one
    // thing this port is not for.
    func setBackdrop(_ desktop: CGImage?) {
        guard let desktop else {
            print("[overview] backdrop: the desktop capture came back empty")
            backdropImage = nil
            return
        }
        debugLog("[overview] backdrop: \(desktop.width)x\(desktop.height) captured")
        backdropImage = desktop
        // The capture is async: if the panel is already up, swap it in.
        if window.isVisible { backdropView.layer?.contents = backdropImage }
    }

    init() {
        window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        window.level = ChromeLevel.panel
        window.collectionBehavior = [.stationary, .ignoresCycle]
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = backdropColor.cgColor
        window.contentView = view

        // The selection ring is the focus ring at overview scale, nothing
        // more: niri has no overview-specific ring, the real focus ring
        // just scales with the window. The glow it used to wear was
        // invented (audit ACT-15); colors/width come from the config via
        // applyStyle.
        selectionView.wantsLayer = true
        selectionView.layer?.borderWidth = 2
        selectionView.layer?.borderColor =
            NSColor(calibratedRed: 127 / 255.0, green: 200 / 255.0, blue: 255 / 255.0, alpha: 1).cgColor
        selectionView.layer?.cornerRadius = 10
        selectionView.layer?.backgroundColor = NSColor.clear.cgColor
        selectionView.isHidden = true

        // The drop indicator is the insert hint at overview scale: niri's
        // flat rgba(127,200,255,128) (appearance.rs:586-594), no glow.
        dropIndicator.wantsLayer = true
        dropIndicator.layer?.backgroundColor =
            NSColor(calibratedRed: 127 / 255.0, green: 200 / 255.0, blue: 255 / 255.0, alpha: 128 / 255.0)
            .cgColor
        dropIndicator.layer?.cornerRadius = 7
        dropIndicator.layer?.shadowOffset = .zero
        dropIndicator.isHidden = true
    }

    // Refresh just the thumbnail images in place (the boxes/titles/chips
    // don't move between captures) - no teardown, so live content updates
    // without the rebuild flicker. `images` is keyed by flattened entry
    // index, matching show()'s order.
    // A live frame. The IOSurface goes onto the layer as-is: Core Animation
    // binds it as a texture in the render server, so there is no bitmap, no
    // copy and no redraw on our side - the whole per-frame cost is this
    // assignment. Contents must be re-assigned every frame (mutating the
    // surface in place does not redraw), and actions are disabled or every
    // frame would cross-fade into the next.
    func setThumbnail(_ surface: IOSurface, forWindow id: UInt64) {
        guard let view = thumbnailsByWindow[id], let layer = view.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // A stand-in may have left the gravity centered.
        layer.contentsGravity = .resizeAspectFill
        layer.contents = surface
        CATransaction.commit()
    }

    // The stand-in for a card with no pixels of its own: the app icon (or a
    // document thumbnail) centered, never stretched, over a dark plate. A
    // real frame overwrites it whenever one arrives.
    func setStandIn(_ image: NSImage?, forWindow id: UInt64) {
        guard let view = thumbnailsByWindow[id], let layer = view.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // resizeAspect, not resizeAspectFill: an icon blown up to fill a card
        // is a blurry mess, and a document page must not be cropped.
        layer.contentsGravity = .resizeAspect
        layer.contents = image
        CATransaction.commit()
    }

    // Back to cropping-to-fill for real window pixels.
    func setThumbnailGravityForFrames(_ id: UInt64) {
        thumbnailsByWindow[id]?.layer?.contentsGravity = .resizeAspectFill
    }

    // Which windows currently have a card, and how big it is drawn - the
    // capture is asked for exactly those pixels rather than the window's own
    // resolution.
    func thumbnailTargets(scale: CGFloat) -> [(id: UInt64, size: CGSize)] {
        thumbnailsByWindow.map { id, view in
            (id, CGSize(width: max(1, view.bounds.width * scale), height: max(1, view.bounds.height * scale)))
        }
    }

    func show(
        screenFrame: CGRect,
        rows: [Row],
        animation: AnimationCurve = .off,
        cameraAnimation: AnimationCurve = .off
    ) {
        guard let content = window.contentView else { return }
        // Every in-overview move rebuilds the panel through here; only the
        // transition from NOT being on screen is an opening.
        let opening = !window.isVisible || closing
        content.subviews.forEach { $0.removeFromSuperview() }
        entryBoxes = []
        cardFrames = []
        thumbnailViews = []
        thumbnailsByWindow = [:]
        cardViews = []
        plateViews = []
        cardOrigins = []
        strips = [:]
        stripRanges = [:]
        draggedIndex = nil
        screenFrameAX = screenFrame
        window.setFrame(ScreenGeometry.axFrameToAppKit(screenFrame), display: false)
        content.frame = CGRect(origin: .zero, size: screenFrame.size)

        // niri's `layer-rule { place-within-backdrop true }`: the wallpaper
        // layer is drawn INSIDE the overview backdrop, which is why an
        // overview there shows the desktop instead of the flat backdrop
        // colour. This config opts into exactly that, so the desktop fills
        // the backdrop and `backdrop-color` becomes the tint over it (and
        // the opaque base under it: a wallpaper app that does not cover the
        // whole screen leaves transparent edges, and the real windows showed
        // through them).
        content.layer?.backgroundColor = backdropColor.cgColor
        if useWallpaper, let wallpaper = backdropImage {
            let full = CGRect(origin: .zero, size: screenFrame.size)
            backdropView.frame = full
            backdropView.wantsLayer = true
            backdropView.layer?.contents = wallpaper
            backdropView.layer?.contentsGravity = .resizeAspectFill
            backdropView.layer?.masksToBounds = true
            content.addSubview(backdropView)
            // No tint: niri's backdrop under place-within-backdrop IS the
            // wallpaper, at full strength. The dark wash over it was ours.
            backdropTint.frame = full
            backdropTint.wantsLayer = true
            backdropTint.layer?.backgroundColor = NSColor.clear.cgColor
            content.addSubview(backdropTint)
        }

        // Converts an AX-space rect into this content view's (bottom-left)
        // coordinates.
        func viewRect(_ axRect: CGRect) -> CGRect {
            CGRect(
                x: axRect.origin.x - screenFrame.minX,
                y: screenFrame.maxY - axRect.maxY,
                width: axRect.width, height: axRect.height)
        }

        for row in rows {
            // The workspace's own rectangle: what its screen would look like
            // at this zoom. niri draws the workspace background there with a
            // drop shadow, which is what separates one workspace from the
            // next now that nothing is fit into a row.
            let plate = NSView(frame: viewRect(row.canvas))
            plate.wantsLayer = true
            // Only the shadow, no fill: niri renders a workspace SHADOW
            // (render_workspace_shadows), never a dark rectangle over the
            // wallpaper.
            plate.layer?.backgroundColor = NSColor.clear.cgColor
            plate.layer?.cornerRadius = 12
            plate.layer?.shadowColor = NSColor.black.cgColor
            plate.layer?.shadowOpacity = 0.55
            plate.layer?.shadowRadius = 18
            plate.layer?.shadowOffset = CGSize(width: 0, height: -4)
            // With no shadowPath, Core Animation re-derives the shadow from
            // the layer's alpha channel every frame - offscreen work on a
            // half-screen layer, on every frame of every pan.
            plate.layer?.shadowPath = CGPath(
                roundedRect: CGRect(origin: .zero, size: plate.frame.size),
                cornerWidth: 12, cornerHeight: 12, transform: nil)
            content.addSubview(plate)
            plateViews.append(plate)

            // ...and its contents are clipped to the band: full screen width,
            // because a strip wider than the screen bleeds sideways instead of
            // being squeezed, but exactly the workspace's height, so it never
            // bleeds into its neighbour.
            let bandRect = viewRect(row.band)
            let band = NSView(frame: bandRect)
            band.wantsLayer = true
            band.layer?.masksToBounds = true
            content.addSubview(band)
            let toBand = CGPoint(x: bandRect.minX, y: bandRect.minY)
            // The cards ride on a strip inside the band, so a camera move can
            // be animated as ONE transform instead of animating every card:
            // niri does not jump the view offset, it runs it through
            // horizontal-view-movement, and the whole strip travels together.
            let strip = NSView(frame: CGRect(origin: .zero, size: bandRect.size))
            band.addSubview(strip)
            strips[row.wsIndex] = strip
            let firstEntry = entryBoxes.count
            if let previous = previousCamera[row.wsIndex], abs(previous - row.cameraX) > 0.5,
                let slide = cameraAnimation.coreAnimation(keyPath: "transform")
            {
                _ = Self.cameraKey
                // Start where the camera WAS (content further right by however
                // much the camera advanced) and travel to where it is now.
                slide.fromValue = CATransform3DMakeTranslation(row.cameraX - previous, 0, 0)
                slide.toValue = CATransform3DIdentity
                strip.layer?.add(slide, forKey: Self.cameraKey)
            }
            previousCamera[row.wsIndex] = row.cameraX

            for entry in row.entries {
                entryBoxes.append(entry.box)
                cardFrames.append(viewRect(entry.box))
                cardOrigins.append(toBand)
                let inBand = viewRect(entry.box).offsetBy(dx: -toBand.x, dy: -toBand.y)
                let card = NSView(frame: inBand)
                card.wantsLayer = true
                card.layer?.backgroundColor = NSColor(calibratedWhite: 0.15, alpha: 1).cgColor
                card.layer?.cornerRadius = 8
                card.layer?.borderWidth = 1.5
                card.layer?.borderColor = NSColor(calibratedWhite: 0.3, alpha: 1).cgColor

                // Always create the thumbnail view (even before its first
                // capture lands) so updateImages has a stable slot to fill.
                // Layer-backed with resizeAspectFill (object-fit: cover): the
                // shot fills the tile and overflow is clipped, so a window
                // whose real aspect differs from its tile - e.g. a wide window
                // shown in a half-height STACKED slot - never letterboxes into
                // big grey bars; it just crops.
                // No title label: niri's overview renders the zoomed windows
                // bare - no text on or under them (same verification as the
                // workspace chip below). The label was ours, not a port.
                let thumb = NSView(
                    frame: CGRect(
                        x: 4, y: 4, width: card.bounds.width - 8,
                        height: card.bounds.height - 8))
                thumb.wantsLayer = true
                thumb.layer?.contentsGravity = .resizeAspectFill
                thumb.layer?.masksToBounds = true
                thumb.layer?.cornerRadius = 6
                thumb.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1).cgColor
                card.addSubview(thumb)
                thumbnailViews.append(thumb)
                thumbnailsByWindow[entry.windowID] = thumb
                cardViews.append(card)
                strip.addSubview(card)
            }

            stripRanges[row.wsIndex] = firstEntry..<entryBoxes.count

            // No workspace chip: niri does not label its workspaces in the
            // overview (verified in its source - nothing under src/ui/ or
            // layout/workspace.rs renders a name - and live on the user's own
            // Linux machine). "Workspace 1" was ours, not a port. A NAMED
            // workspace is a different question, and niri leaves that to the
            // bar over IPC, which nigiri already publishes.
        }
        // Selection ring + drop bar last, so they float above every card.
        selectionView.isHidden = true
        dropIndicator.isHidden = true
        content.addSubview(selectionView)
        content.addSubview(dropIndicator)
        for row in rows {
            debugLog(
                "[overview-geo] ws=\(row.wsIndex) canvas=\(Int(row.canvas.minX)),\(Int(row.canvas.minY)) \(Int(row.canvas.width))x\(Int(row.canvas.height)) camera=\(Int(row.cameraX))"
            )
            for e in row.entries {
                debugLog(
                    "[overview-geo]   card \(Int(e.box.minX)),\(Int(e.box.minY)) \(Int(e.box.width))x\(Int(e.box.height)) \(e.title.prefix(28))"
                )
            }
        }
        prepareEntrance()
        // 0.99, and it isn't cosmetic: a fully opaque panel covering the
        // screen makes macOS mark every window underneath as OCCLUDED, and an
        // occluded app stops drawing. The streams kept delivering 30 frames
        // per second - of the SAME stale content, because nobody was painting
        // anything new. Measured: with the panel opaque, the checksum of the
        // delivered pixels froze after a few seconds and never moved again; at
        // 99% it changes on every sample. 1% of transparency over a dark
        // backdrop is invisible, and it's the only thing we have to tell the
        // system that the windows behind are still in view - occlusion is
        // WindowServer's call and it only looks at whether something opaque
        // covers them.
        window.alphaValue = 0.99
        window.orderFrontRegardless()
        if opening { playOpen(animation) }
    }

    // Pan one workspace's strip by `dx` panel pixels, right now and without
    // animation: a pan tracks the fingers, so anything smoothed would lag
    // behind them. The cards' recorded geometry travels with the view - the
    // hit test, the selection ring and the drag all read those boxes, and a
    // strip that moved without them would answer for where it used to be.
    func panCamera(wsIndex: Int, by dx: CGFloat, selected: Int?, animation: AnimationCurve = .off) {
        guard let strip = strips[wsIndex], let range = stripRanges[wsIndex] else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strip.frame.origin.x += dx
        CATransaction.commit()
        // A camera move the KEYBOARD caused travels on niri's view-offset
        // curve; a pan tracks the fingers and gets none.
        if let slide = animation.coreAnimation(keyPath: "transform") {
            slide.fromValue = CATransform3DMakeTranslation(-dx, 0, 0)
            slide.toValue = CATransform3DIdentity
            strip.layer?.add(slide, forKey: Self.cameraKey)
        }
        for i in range where entryBoxes.indices.contains(i) {
            entryBoxes[i].origin.x += dx
            cardFrames[i].origin.x += dx
        }
        previousCamera[wsIndex] = (previousCamera[wsIndex] ?? 0) - dx
        setSelectedIndex(selected)
    }

    // Show the drop hint region. `axRect` is the landing footprint in AX
    // space (tall column slab for new-column, short column-wide band for
    // stack-into-column). Hidden with nil.
    func setDropHint(_ axRect: CGRect?) {
        guard let axRect else { dropIndicator.isHidden = true; return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dropIndicator.frame = CGRect(
            x: axRect.minX - screenFrameAX.minX,
            y: screenFrameAX.maxY - axRect.maxY,
            width: axRect.width, height: axRect.height)
        CATransaction.commit()
        dropIndicator.isHidden = false
    }

    // Move (and show) the selection ring around the card at `index`, or hide
    // it when index is nil / out of range. Called by the engine as overview
    // navigation changes which window is selected.
    func setSelectedIndex(_ index: Int?) {
        guard let index, cardFrames.indices.contains(index) else {
            selectionView.isHidden = true
            return
        }
        // No implicit position animation - snap the ring like the real one.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionView.frame = cardFrames[index].insetBy(dx: -3, dy: -3)
        selectionView.layer?.shadowPath = CGPath(
            roundedRect: selectionView.bounds, cornerWidth: 10, cornerHeight: 10, transform: nil)
        CATransaction.commit()
        selectionView.isHidden = false
    }

    // ---- mouse drag: lift a card and slide it under the cursor ----

    // Convert an AX-space point (top-left origin, Y down) to the content
    // view's bottom-left coordinates.
    private func viewPoint(_ ax: CGPoint) -> CGPoint {
        CGPoint(x: ax.x - screenFrameAX.minX, y: screenFrameAX.maxY - ax.y)
    }

    // Begin dragging the card at `index`: raise it above its siblings, fade
    // it slightly, and hide the selection ring while it's in flight.
    func beginCardDrag(_ index: Int) {
        guard cardViews.indices.contains(index) else { return }
        draggedIndex = index
        let card = cardViews[index]
        // OUT of its band, into the content view: each workspace row is
        // clipped (masksToBounds, so its strip can bleed sideways without
        // invading the neighbour), and a card dragged towards ANOTHER
        // workspace's row - a drop the engine fully supports - simply
        // vanished the moment it crossed its own band's edge. zPosition does
        // not escape a mask. Reparenting keeps its on-screen position because
        // the frame is converted, and it also drops the strip's pan offset,
        // which dragCard never accounted for.
        if let content = window.contentView, card.superview !== content {
            let inContent = card.convert(card.bounds, to: content)
            card.removeFromSuperview()
            card.frame = inContent
            content.addSubview(card)
        }
        card.layer?.zPosition = 100
        card.alphaValue = 0.75  // niri's INTERACTIVE_MOVE_ALPHA
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.5
        card.layer?.shadowRadius = 14
        card.layer?.shadowOffset = .zero
        selectionView.isHidden = true
    }

    // Center the lifted card on the AX cursor point.
    func dragCard(toAXPoint ax: CGPoint) {
        guard let i = draggedIndex, cardViews.indices.contains(i) else { return }
        // Content coordinates throughout: beginCardDrag reparented the card
        // there, so neither the band origin nor the strip's pan offset is in
        // play any more.
        let p = viewPoint(ax)
        let card = cardViews[i]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.setFrameOrigin(
            CGPoint(
                x: p.x - card.frame.width / 2,
                y: p.y - card.frame.height / 2))
        CATransaction.commit()
    }

    // The card stays in the content view: the drop is applied by rebuilding
    // the panel from the model, so this view is about to be thrown away.
    func endCardDrag() {
        if let i = draggedIndex, cardViews.indices.contains(i) {
            let card = cardViews[i]
            card.alphaValue = 1
            card.layer?.zPosition = 0
            card.layer?.shadowOpacity = 0
        }
        draggedIndex = nil
    }

    // Which entry (index into the flattened row order) a global AX-space
    // point lands on - the same order the caller supplied entries in.
    func hitTest(_ point: CGPoint) -> Int? {
        entryBoxes.firstIndex { $0.contains(point) }
    }

    func hide(animation: AnimationCurve = .off) {
        entryBoxes = []
        // A camera position only means something within one overview session.
        previousCamera = [:]
        guard let layer = window.contentView?.layer,
            let transform = animation.coreAnimation(keyPath: "transform"),
            let fade = animation.coreAnimation(keyPath: "opacity")
        else {
            closing = false
            window.orderOut(nil)
            return
        }
        // The reverse: the layout zooms back to 1, where every card lands
        // exactly on the real window it was showing - which never moved. The
        // backdrop fades out over it, so the last frame IS the screen.
        closing = true
        transform.fromValue = CATransform3DIdentity
        transform.toValue = entranceTransform
        transform.fillMode = .forwards
        transform.isRemovedOnCompletion = false
        fade.fromValue = 1
        fade.toValue = 0
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.closing else { return }
            self.closing = false
            self.window.orderOut(nil)
            layer.removeAnimation(forKey: Self.zoomKey)
            layer.removeAnimation(forKey: Self.fadeKey)
        }
        layer.add(transform, forKey: Self.zoomKey)
        layer.add(fade, forKey: Self.fadeKey)
        CATransaction.commit()
    }

    // ---- open/close animation (niri's `overview-open-close`) ----

    private static let cameraKey = "nigiri.overview.camera"
    private static let zoomKey = "nigiri.overview.zoom"
    private static let fadeKey = "nigiri.overview.fade"
    private static let shadowKey = "nigiri.overview.shadow"
    // Set while a close is in flight: the panel is still on screen, so a
    // re-open has to cancel the pending orderOut instead of being ordered out
    // from under itself a moment later.
    private var closing = false
    // Where the picture starts: the whole layout blown up so the active
    // workspace fills the screen exactly - which is niri's zoom = 1.
    private var entranceTransform = CATransform3DIdentity

    // niri's overview animation, ported from the source rather than invented.
    // compute_overview_zoom (layout/mod.rs):
    //
    //     (1. - p * (1. - zoom)).max(0.0001)
    //
    // so the zoom goes from 1 to the configured value, LINEAR in the
    // animation's progress. And workspaces_render_geo centres the active
    // workspace at every zoom (`static_offset = (view_size - ws_size) / 2`,
    // `ws_size = view_size * zoom`) with the gap scaled by zoom too - every
    // term proportional to it. So the whole thing, all the workspaces at
    // once, is a uniform SCALE ABOUT THE SCREEN CENTRE from 1 down to `zoom`,
    // and nothing translates independently.
    //
    // Two consequences worth stating, because our previous animation had
    // neither: at progress 0 the cards sit exactly where the real windows are
    // and at their size (zoom 1 IS the screen), and the workspace contents do
    // NOT fade - the only thing in niri that fades with the progress is the
    // workspace shadow (render_workspace_shadows: `let alpha = progress`).
    // A matrix interpolated by CASpringAnimation is linear in the animation's
    // progress, and s = z/zoom is affine in z, so the spring reproduces
    // niri's curve exactly instead of approximating it.
    private func prepareEntrance() {
        let start = 1 / min(0.75, max(0.0001, Self.zoom))
        guard let layer = window.contentView?.layer else {
            entranceTransform = CATransform3DMakeScale(start, start, 1)
            return
        }
        // About the SCREEN CENTRE, composed explicitly. `layer.transform` is
        // applied about the layer's anchorPoint, and an NSView's backing
        // layer anchors at a CORNER - so a bare scale sent the whole picture
        // off diagonally instead of shrinking it in place. That was the
        // difference against the real thing: niri's static_offset keeps the
        // active workspace centred at every zoom, which is only a plain scale
        // if the anchor is the centre.
        // Written anchor-agnostically: the centre expressed relative to
        // whatever anchor the layer happens to have.
        let anchor = layer.anchorPoint
        let cx = layer.bounds.width * (0.5 - anchor.x)
        let cy = layer.bounds.height * (0.5 - anchor.y)
        var t = CATransform3DMakeTranslation(cx, cy, 0)
        t = CATransform3DScale(t, start, start, 1)
        t = CATransform3DTranslate(t, -cx, -cy, 0)
        entranceTransform = t
    }

    private func playOpen(_ curve: AnimationCurve) {
        guard let layer = window.contentView?.layer else { return }
        closing = false
        layer.removeAnimation(forKey: Self.zoomKey)
        layer.removeAnimation(forKey: Self.fadeKey)
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
        guard let transform = curve.coreAnimation(keyPath: "transform") else { return }
        transform.fromValue = entranceTransform
        transform.toValue = CATransform3DIdentity
        layer.add(transform, forKey: Self.zoomKey)
        // NOTHING fades in. Compared frame by frame against a recording of
        // the user's own niri: from the very first frame of the transition
        // the plain wallpaper is already visible in the margins, and the
        // windows simply shrink over it. Our version faded a dark blurred
        // curtain in over ~300ms, which is what made it read as "a panel
        // appearing" instead of "the windows shrinking" - the one thing that
        // still gave us away next to the real thing.
        // niri's render_workspace_shadows: alpha = progress. The only fade in
        // its overview.
        for plate in plateViews {
            guard let fade = curve.coreAnimation(keyPath: "shadowOpacity") else { break }
            fade.fromValue = 0
            fade.toValue = plate.layer?.shadowOpacity ?? 0.55
            plate.layer?.add(fade, forKey: Self.shadowKey)
        }
    }

}
