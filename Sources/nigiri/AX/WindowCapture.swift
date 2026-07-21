import AppKit
import CoreMedia
import ScreenCaptureKit

// Per-window screenshots for the overview panel, via ScreenCaptureKit.
// desktopIndependentWindow captures a window's CONTENT wherever it is -
// including the 1px-corner-parked windows of inactive workspaces and
// tabbed columns, which is exactly what makes a thumbnail overview
// possible without moving anything.
//
// Needs the Screen Recording permission (a second, separate TCC grant
// from Accessibility). The caller preflights; the request dialog is
// rate-limited to once per boot, same policy as the Accessibility one -
// never a popup loop.
enum WindowCapture {
    static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    // Returns whether a request dialog was actually shown (at most once
    // per boot).
    @discardableResult
    static func requestPermissionOnce() -> Bool {
        let marker = "/tmp/nigiri-sr-prompted"
        guard !FileManager.default.fileExists(atPath: marker) else { return false }
        FileManager.default.createFile(atPath: marker, contents: nil)
        CGRequestScreenCaptureAccess()
        return true
    }

    // Captures every requested window, delivering [index: image] on the
    // main queue when all captures settled (failed ones just missing -
    // the panel shows a placeholder card).
    // The panel draws ~200px thumbnails, so capturing at the window's full
    // resolution was throwing away most of every frame it asked the GPU for.
    nonisolated static let thumbnailMaxSide: CGFloat = 480

    // The DESKTOP, with every application window excluded: what is left is
    // the wallpaper - whoever is drawing it. Reading the desktop picture from
    // disk instead (NSWorkspace.desktopImageURL) is wrong twice over: macOS
    // asks for "access data from other apps" when the file lives in another
    // app's container (verified live - a permission prompt), and a custom
    // wallpaper app paints a WINDOW, so the system's picture is not what is
    // actually on screen. This path reuses the Screen Recording grant the
    // overview already needs.
    @available(macOS 14.0, *)
    static func captureDesktop(size: CGSize, completion: @escaping (CGImage?) -> Void) {
        // excludingDesktopWindows: true leaves the wallpaper OUT of the window
        // list, so excluding that list keeps it in the picture.
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
            guard let content, let display = content.displays.first else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            // INCLUDING, not excluding: the wallpaper lives in a stack of
            // very deep windows, and both other approaches failed for a
            // reason worth recording.
            //
            //   - Excluding the app windows and capturing the display: the
            //     exclusion list is a SNAPSHOT, so nigiri's own panel (created
            //     a moment later) was not in it and got composited into its
            //     own backdrop - along with any window that moved meanwhile.
            //   - Capturing the wallpaper window on its own
            //     (desktopIndependentWindow, the path the thumbnails use):
            //     comes back BLANK. A wallpaper app does not expose its
            //     content that way.
            //
            // Measured layers on this machine:
            //     -2147483601 MyWallpaper 1370x822   <- what is on screen
            //     -2147483603 Finder / WindowManager <- desktop icons
            //     -2147483625 Wallpaper   1470x956   <- the system picture
            let desktop = content.windows.filter { $0.windowLayer < -1_000_000 }
            guard !desktop.isEmpty else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let filter = SCContentFilter(display: display, including: desktop)
            let config = SCStreamConfiguration()
            config.width = Int(size.width)
            config.height = Int(size.height)
            config.showsCursor = false
            // A wallpaper app that does not cover the whole display leaves the
            // SYSTEM picture showing around it - a dark band down one side of
            // the backdrop (reported live; the painter here is 1370x822 of a
            // 1470x922 display). Capture only what it paints and let the panel
            // scale that to fill: a backdrop is decoration, so cropping it is
            // free, while a seam is not.
            let furniture = ["Finder", "WindowManager", "Dock"]
            if let painter =
                desktop
                .filter({ !furniture.contains($0.owningApplication?.applicationName ?? "") })
                .max(by: { $0.windowLayer < $1.windowLayer }),
                painter.frame.width < display.frame.width - 1
                    || painter.frame.height < display.frame.height - 1
            {
                config.sourceRect = painter.frame
                config.width = Int(painter.frame.width)
                config.height = Int(painter.frame.height)
            }
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, _ in
                DispatchQueue.main.async { completion(image) }
            }
        }
    }

    // Match our AX windows to their SCWindows: by pid + frame (both are
    // top-left global coordinates), title as the tiebreaker for same-sized
    // siblings. This is the EXPENSIVE half - a system-wide window enumeration
    // over XPC - so it is its own call: measured at ~85ms of the ~115ms a
    // five-window refresh used to cost, repeated on every single tick for a
    // mapping that only changes when windows open, close or move.
    @available(macOS 14.0, *)
    static func resolve(
        _ requests: [(pid: pid_t, title: String, frame: CGRect)],
        completion: @escaping ([Int: SCWindow]) -> Void
    ) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
            guard let content else {
                print("[overview] shareable content failed: \(error?.localizedDescription ?? "?")")
                DispatchQueue.main.async { completion([:]) }
                return
            }
            var resolved: [Int: SCWindow] = [:]
            for (index, request) in requests.enumerated() {
                let candidates = content.windows.filter {
                    $0.owningApplication?.processID == request.pid
                        && abs($0.frame.origin.x - request.frame.origin.x) < 5
                        && abs($0.frame.origin.y - request.frame.origin.y) < 5
                        && abs($0.frame.width - request.frame.width) < 5
                }
                guard
                    let scWindow = candidates.first(where: { $0.title == request.title }) ?? candidates.first
                else { continue }
                resolved[index] = scWindow
            }
            let result = resolved
            DispatchQueue.main.async { completion(result) }
        }
    }

    // The cheap half, and it speaks the same language the streams do:
    // captureSampleBuffer, not captureImage. The buffer is IOSurface-backed,
    // so it goes onto a layer with no bitmap in between - captureImage's job
    // is to materialize a CGImage, which is work we then threw away.
    // Measured on the same window, same filter, 20 captures each:
    //     captureImage        9.9 ms
    //     captureSampleBuffer 7.4 ms   (25% less, and no CGImage)
    //
    // `sizes` is the tile each window will be drawn in, in pixels: the
    // capture pipeline scales inside WindowServer, so asking for thumbnail
    // pixels means the full-resolution ones are never rendered or moved.
    @available(macOS 14.0, *)
    static func capture(
        resolved: [Int: SCWindow], sizes: [Int: CGSize] = [:],
        completion: @escaping ([Int: CVPixelBuffer]) -> Void
    ) {
        guard !resolved.isEmpty else { completion([:]); return }
        // OFF the main thread: captureImage does its setup - including
        // building an SCStream, audio clock and all - synchronously on
        // whatever thread calls it. Measured at ~20ms per window, so a
        // five-window refresh was stalling the main thread for ~80ms at a
        // time, several times a second. That is the overview's stutter: not
        // the capture being slow, but the capture being in the way.
        captureQueue.async {
            let group = DispatchGroup()
            var buffers: [Int: CVPixelBuffer] = [:]
            let lock = NSLock()
            for (index, scWindow) in resolved {
                let config = SCStreamConfiguration()
                // The tile's pixel size when the caller knows it; otherwise the
                // window scaled to the thumbnail ceiling.
                if let size = sizes[index] {
                    config.width = max(1, Int(size.width))
                    config.height = max(1, Int(size.height))
                } else {
                    let scale = min(
                        1, WindowCapture.thumbnailMaxSide / max(scWindow.frame.width, scWindow.frame.height))
                    config.width = max(1, Int(scWindow.frame.width * scale))
                    config.height = max(1, Int(scWindow.frame.height * scale))
                }
                config.showsCursor = false
                // The window's shadow is a wide transparent margin around the
                // real pixels, and the global clip is what rounds the corners:
                // both waste tile area on nothing.
                config.ignoreShadowsSingleWindow = true
                config.ignoreGlobalClipSingleWindow = true
                config.pixelFormat = kCVPixelFormatType_32BGRA
                group.enter()
                SCScreenshotManager.captureSampleBuffer(
                    contentFilter: SCContentFilter(desktopIndependentWindow: scWindow),
                    configuration: config
                ) { sampleBuffer, _ in
                    if let sampleBuffer, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                        lock.lock()
                        buffers[index] = pixelBuffer
                        lock.unlock()
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) { completion(buffers) }
        }
    }

    private static let captureQueue = DispatchQueue(label: "nigiri.capture", qos: .userInitiated)
}
