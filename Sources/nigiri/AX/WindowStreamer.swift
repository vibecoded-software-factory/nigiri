import AppKit
import ScreenCaptureKit
import CoreMedia

// Live window previews, the way ScreenCaptureKit is meant to be used: ONE
// persistent SCStream per window, each frame arriving as an IOSurface that
// goes straight onto a CALayer.
//
// What this replaces: a screenshot per window per tick. Measured on this
// machine (macOS 26.5.2), capturing the same windows:
//
//     SCScreenshotManager.captureImage      9.9 ms per window, every tick
//     SCScreenshotManager.captureSampleBuffer 7.4 ms  (no CGImage)
//     20 persistent SCStreams               32 ms ONCE, then 3.5% of a core
//
// The difference is not the capture, it is the cadence. A stream is
// damage-driven: WindowServer sends a frame when the window's content
// actually changed and says `.idle` when it did not. Of 20 streams over
// live windows, 11 delivered no frames at all; a terminal delivered 3/s (its
// real print rate) and a playing video 29/s. The old loop paid full price for
// every window on every tick whether anything moved or not.
//
// The two things that had to be true for this to work here, both MEASURED
// rather than assumed, because the overview shows windows nobody can see:
//
//   - A window parked 1px off screen on another workspace keeps streaming.
//     Verified: a terminal printing every 0.3s, parked at x = maxX-1, kept
//     delivering 3 fps. (Apple's WWDC22 session says a WINDOW filter always
//     carries full content "even when completely off-screen"; a DISPLAY
//     filter drops it. Community reports that off-screen windows starve
//     unless the mouse moves did not reproduce on macOS 26.)
//   - A window hidden behind a tabbed column keeps streaming, for the same
//     reason: the filter is the window, not the screen.
//
// What a stream CANNOT do, per Apple: a MINIMIZED window pauses its stream.
// Those keep the still-capture path.
@available(macOS 14.0, *)
@MainActor
final class WindowStreamer {
    // The latest surface per window id, plus the buffer it belongs to. The
    // buffer must stay retained while the layer is showing it: the stream
    // recycles a pool of `queueDepth` surfaces, and releasing early lets
    // WindowServer draw into the one on screen.
    private final class Live {
        let stream: SCStream
        let sink: Sink
        init(stream: SCStream, sink: Sink) { self.stream = stream; self.sink = sink }
    }

    // The output object. NOT MainActor: SCStream delivers on its own queue,
    // and the whole point is that the main thread does nothing per frame
    // except swap a layer's contents.
    private final class Sink: NSObject, SCStreamOutput, SCStreamDelegate {
        let windowID: UInt64
        let onFrame: @MainActor (UInt64, IOSurface, CVPixelBuffer) -> Void
        let onStop: @MainActor (UInt64, String) -> Void

        init(
            windowID: UInt64,
            onFrame: @escaping @MainActor (UInt64, IOSurface, CVPixelBuffer) -> Void,
            onStop: @escaping @MainActor (UInt64, String) -> Void
        ) {
            self.windowID = windowID
            self.onFrame = onFrame
            self.onStop = onStop
        }

        func stream(
            _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
            of type: SCStreamOutputType
        ) {
            guard type == .screen else { return }
            // Only complete frames carry pixels. Without this check, `.idle`
            // notices look like frames: measured 70 real surfaces out of 174
            // callbacks on a busy window, 100% once filtered.
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                let raw = attachments.first?[.status] as? Int,
                let status = SCFrameStatus(rawValue: raw), status != .complete
            {
                return
            }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                let surfaceRef = CVPixelBufferGetIOSurface(pixelBuffer)
            else { return }
            let surface = unsafeBitCast(surfaceRef.takeUnretainedValue(), to: IOSurface.self)
            let id = windowID
            let handler = onFrame
            DispatchQueue.main.async { MainActor.assumeIsolated { handler(id, surface, pixelBuffer) } }
        }

        func stream(_ stream: SCStream, didStopWithError error: Error) {
            let id = windowID
            let handler = onStop
            let message = error.localizedDescription
            DispatchQueue.main.async { MainActor.assumeIsolated { handler(id, message) } }
        }
    }

    private var live: [UInt64: Live] = [:]
    // Held so the surface the layer is showing cannot be recycled underneath
    // it; replaced (and only then released) when the next frame lands.
    private var retained: [UInt64: CVPixelBuffer] = [:]
    private let frameQueue = DispatchQueue(label: "nigiri.streams", qos: .userInitiated)

    // Called on the main actor with a surface ready to be assigned to a
    // layer's `contents`.
    // The buffer travels with the surface so the caller can keep the last
    // frame of each window: that is what lets the NEXT overview open on real
    // pixels instead of on the app icon, which matters now that the animation
    // starts at zoom 1 (a card the size of the window showing an icon reads
    // as a placeholder; showing the window reads as the window).
    var onFrame: ((UInt64, IOSurface, CVPixelBuffer) -> Void)?
    // A stream died: the permission lapsed (macOS re-asks monthly since
    // Sequoia, and every stream fails at once with systemStoppedStream), the
    // window closed, or the app went away. The caller falls back to stills.
    var onStopped: ((UInt64) -> Void)?

    var streamedIDs: Set<UInt64> { Set(live.keys) }

    // Start a stream per window, sized to the tile it will be drawn in - the
    // capture pipeline scales in WindowServer, so asking for thumbnail pixels
    // means full-resolution ones are never rendered or transported.
    func start(_ windows: [(id: UInt64, window: SCWindow, size: CGSize)], fps: Int = 30) {
        for entry in windows where live[entry.id] == nil {
            let config = SCStreamConfiguration()
            config.width = max(1, Int(entry.size.width))
            config.height = max(1, Int(entry.size.height))
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
            // 3 is the documented minimum and the default. Each slot is a
            // full IOSurface per stream in WindowServer's memory, and we hold
            // one of them ourselves while it is on screen.
            config.queueDepth = 3
            config.showsCursor = false
            config.capturesAudio = false
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.ignoreShadowsSingleWindow = true
            config.ignoreGlobalClipSingleWindow = true
            let sink = Sink(
                windowID: entry.id,
                onFrame: { [weak self] id, surface, buffer in
                    guard let self else { return }
                    self.retained[id] = buffer
                    self.onFrame?(id, surface, buffer)
                },
                onStop: { [weak self] id, message in
                    print("[stream] \(id) stopped: \(message)")
                    self?.stop(id)
                    self?.onStopped?(id)
                })
            let stream = SCStream(
                filter: SCContentFilter(desktopIndependentWindow: entry.window),
                configuration: config, delegate: sink)
            do {
                try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: frameQueue)
            } catch {
                print("[stream] could not hook up the output: \(error.localizedDescription)")
                continue
            }
            live[entry.id] = Live(stream: stream, sink: sink)
            stream.startCapture { error in
                guard let error else { return }
                print("[stream] no arranco: \(error.localizedDescription)")
            }
        }
    }

    // Hand every retained frame to whoever is drawing now: a rebuilt panel
    // has empty layers, and the surfaces we are already holding are the
    // cheapest possible way to fill them - no capture, no copy, no cache of
    // CGImages on the side.
    func replay() {
        for (id, buffer) in retained {
            guard let surfaceRef = CVPixelBufferGetIOSurface(buffer) else { continue }
            onFrame?(id, unsafeBitCast(surfaceRef.takeUnretainedValue(), to: IOSurface.self), buffer)
        }
    }

    func stop(_ id: UInt64) {
        guard let entry = live.removeValue(forKey: id) else { return }
        retained.removeValue(forKey: id)
        entry.stream.stopCapture { _ in }
    }

    // Everything that is no longer on the panel. Cheap to re-create (32ms for
    // twenty), so there is no keep-alive: an overview that closed is done.
    func keepOnly(_ ids: Set<UInt64>) {
        for id in live.keys where !ids.contains(id) { stop(id) }
    }

    func stopAll() {
        for id in live.keys { stop(id) }
    }
}
