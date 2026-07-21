import AppKit
import QuickLookThumbnailing

// What a card shows when there are no pixels of the real window: the app's
// icon, and - when the window is showing a document - a QuickLook thumbnail
// of that document.
//
// This is not only the no-permission fallback, though that is why it exists.
// macOS re-asks for Screen Recording every month since Sequoia (there is an
// entitlement to escape it and Apple does not hand it out), and when the
// grant lapses every live stream dies at once with `systemStoppedStream`. An
// overview that goes black at that moment, with no explanation, is worse than
// one that quietly falls back to icons.
//
// It also fills the gap before the first frame of a genuinely idle window: a
// stream only sends a frame when the content CHANGES, so a window that has
// been sitting still can legitimately never produce one.
//
// Neither half needs the Screen Recording grant:
//   - NSRunningApplication.icon is free and already in memory.
//   - kAXDocumentAttribute (Accessibility, which nigiri already holds) gives
//     the file a window is showing; QLThumbnailGenerator renders it. Many
//     apps return nothing here - terminals, browsers - and those keep the
//     icon. For an editor or a PDF the result is arguably better than a
//     200px screenshot: it is the document, sharp, at any size.
@MainActor
enum WindowStandIn {
    // Icons are per-app and never change; thumbnails are per-file and only
    // change when the file does. Both are cheap to keep and expensive enough
    // to be worth not recomputing per overview.
    private static var iconCache: [pid_t: NSImage] = [:]
    private static var documentCache: [String: NSImage] = [:]
    private static var pendingDocuments: Set<String> = []

    static func icon(forPid pid: pid_t) -> NSImage? {
        if let cached = iconCache[pid] { return cached }
        guard let icon = NSRunningApplication(processIdentifier: pid)?.icon else { return nil }
        iconCache[pid] = icon
        return icon
    }

    // The file this window is showing, if the app says so. Apps that do not
    // implement it (iTerm2, terminals in general, browsers) return nil, and
    // full-screen or tabbed documents are missing it even in apps that do.
    static func documentURL(of window: ManagedWindow) -> URL? {
        guard let path: String = AX.attribute(window.axElement, kAXDocumentAttribute as String) else {
            return nil
        }
        if path.hasPrefix("file://") { return URL(string: path) }
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil
    }

    // A QuickLook thumbnail, rendered once per file and handed back from the
    // cache afterwards. Asynchronous: the caller draws the icon now and gets
    // called back if the document render succeeds.
    static func documentThumbnail(for url: URL, size: CGSize, completion: @escaping (NSImage) -> Void) {
        let key = url.path
        if let cached = documentCache[key] { completion(cached); return }
        guard !pendingDocuments.contains(key) else { return }
        pendingDocuments.insert(key)
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: max(32, size.width), height: max(32, size.height)),
            scale: NSScreen.screens.first?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    pendingDocuments.remove(key)
                    guard let representation else { return }
                    let image = NSImage(
                        cgImage: representation.cgImage, size: representation.contentRect.size)
                    documentCache[key] = image
                    completion(image)
                }
            }
        }
    }

    // Files change; the cache is per overview session, like the frames.
    static func forgetDocuments() { documentCache.removeAll() }
}
