import ApplicationServices
import Darwin
import Foundation

enum Permissions {
    static func ensureAccessibilityTrusted(prompt: Bool) -> Bool {
        // The permission dialog appears at most ONCE per boot for the agent:
        // KeepAlive retries every few seconds, and an unconditional prompt
        // turns that into a popup firehose (lived through, never again).
        // Interactive runs (a human at a terminal) may always prompt; the
        // agent prompts once, drops a marker, and afterwards just logs and
        // waits for the System Settings toggle in silence.
        let marker = "/tmp/nigiri-ax-prompted"
        let interactive = isatty(STDIN_FILENO) == 1
        let shouldPrompt = prompt && (interactive || !FileManager.default.fileExists(atPath: marker))
        if shouldPrompt, !interactive {
            FileManager.default.createFile(atPath: marker, contents: nil)
        }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: shouldPrompt] as CFDictionary)
    }
}
