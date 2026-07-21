import CoreGraphics

// Where the other windows go while one is fullscreen, and how they get back.
//
// Fullscreen sends every other window OUT OF VIEW rather than under the
// fullscreen one: a translucent window shows what is behind it, so covered is
// not hidden. Tiled windows are re-laid-out by the tiling pass when the
// fullscreen ends, so they need no memory - but a floating window is never
// repositioned by anything, which makes the frame recorded here the only
// record of where it belongs.
//
// Pure, and its own type, because the bug it exists to prevent is a lifetime
// one: this home used to share `stashedFrame` with the workspace switch, which
// overwrites that slot with wherever the window is NOW. During a fullscreen
// that is the 1px parking spot, so switching workspaces while fullscreen threw
// the real home away and the window came back stranded against the edge. One
// slot with two producers of different lifetimes is one slot too few.
enum FullscreenStash {
    // The frame to record as this window's home, or nil to record nothing.
    // Recording only ONCE is the whole point: on the second pass the window is
    // already parked, so recording again would save the parking spot as home.
    static func homeToRecord(isFloating: Bool, existingHome: CGRect?, currentFrame: CGRect) -> CGRect? {
        guard isFloating, existingHome == nil else { return nil }
        return currentFrame
    }

    // Parked: x at the far edge (the same 1px-in rule a column scrolled out of
    // the strip gets), everything else untouched, so the window comes back the
    // size and height it left at even if its home was never recorded.
    static func parked(_ frame: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(x: screenFrame.maxX - 1, y: frame.origin.y, width: frame.width, height: frame.height)
    }
}
