import AppKit

/// A question asked of a bitmap's pixels once per distinct pixel value, not once per pixel
/// through `colorAt(x:y:)`. `colorAt` builds an `NSColor` and looks up the colour space on every
/// call, and render suites scanning every pixel on the main actor held up other main-actor waits.
///
/// Exact, not approximate: `colorAt`'s answer depends only on the pixel's bytes and the bitmap's
/// format, so the first pixel with each value is asked through `colorAt` and its answer stands for
/// the rest. A bitmap that can't be keyed (planar, or over eight bytes a pixel) is asked per pixel.
final class PixelMemo<Answer> {
    let rep: NSBitmapImageRep
    let pixelsWide: Int
    let pixelsHigh: Int
    private let question: (NSColor?) -> Answer
    private var answers: [UInt64: Answer] = [:]
    private var last: (key: UInt64, answer: Answer)?

    /// Read on first use rather than at `init`, so a memo made before `cacheDisplay` draws into
    /// the bitmap still reads the drawn bytes.
    private lazy var layout: (base: UnsafeMutablePointer<UInt8>, bytesPerRow: Int, bytesPerPixel: Int)? = {
        let bytesPerPixel = rep.bitsPerPixel / 8
        guard !rep.isPlanar, rep.bitsPerPixel % 8 == 0, (1...8).contains(bytesPerPixel),
              let base = rep.bitmapData else { return nil }
        return (base, rep.bytesPerRow, bytesPerPixel)
    }()

    init(_ rep: NSBitmapImageRep, _ question: @escaping (NSColor?) -> Answer) {
        self.rep = rep
        pixelsWide = rep.pixelsWide
        pixelsHigh = rep.pixelsHigh
        self.question = question
    }

    /// The pixel's bytes as one number, equal exactly when the bytes are — `nil` outside the
    /// bitmap, or for a layout that cannot be keyed.
    func key(_ x: Int, _ y: Int) -> UInt64? {
        guard let layout, x >= 0, y >= 0, x < pixelsWide, y < pixelsHigh else { return nil }
        let pixel = layout.base + y * layout.bytesPerRow + x * layout.bytesPerPixel
        switch layout.bytesPerPixel {
        case 4: return UInt64(UnsafeRawPointer(pixel).loadUnaligned(as: UInt32.self))
        case 8: return UnsafeRawPointer(pixel).loadUnaligned(as: UInt64.self)
        default:
            var key: UInt64 = 0
            for i in 0..<layout.bytesPerPixel { key = key << 8 | UInt64(pixel[i]) }
            return key
        }
    }

    /// Whether row `y` holds the same bytes, pixel for pixel, as the same row of `other`. A match
    /// means the same colours only between bitmaps that share a format — see `sameFormat(as:)`.
    func rowMatches(_ y: Int, in other: PixelMemo) -> Bool {
        guard let mine = layout, let theirs = other.layout, y >= 0, y < pixelsHigh, y < other.pixelsHigh,
              pixelsWide == other.pixelsWide, mine.bytesPerPixel == theirs.bytesPerPixel else { return false }
        return memcmp(mine.base + y * mine.bytesPerRow, theirs.base + y * theirs.bytesPerRow,
                      pixelsWide * mine.bytesPerPixel) == 0
    }

    /// Whether equal bytes in this bitmap and in `other` are the same colour: same sample layout,
    /// same colour space.
    func sameFormat<Other>(as other: PixelMemo<Other>) -> Bool {
        rep.bitmapFormat == other.rep.bitmapFormat && rep.bitsPerPixel == other.rep.bitsPerPixel
            && rep.samplesPerPixel == other.rep.samplesPerPixel && rep.bitsPerSample == other.rep.bitsPerSample
            && rep.colorSpace == other.rep.colorSpace
    }

    /// `question(rep.colorAt(x: x, y: y))`, asked once per distinct pixel value.
    func callAsFunction(_ x: Int, _ y: Int) -> Answer {
        guard let key = key(x, y) else { return question(rep.colorAt(x: x, y: y)) }
        if let last, last.key == key { return last.answer }
        let answer: Answer
        if let known = answers[key] {
            answer = known
        } else {
            answer = question(rep.colorAt(x: x, y: y))
            answers[key] = answer
        }
        last = (key, answer)
        return answer
    }
}
