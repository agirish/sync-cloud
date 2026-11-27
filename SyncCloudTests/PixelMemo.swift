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
    /// Row `y` as 32-bit words, for a scan's inner loop: nil unless every pixel is four aligned
    /// bytes, or outside the bitmap.
    func words(_ y: Int) -> UnsafePointer<UInt32>? {
        guard let layout, layout.bytesPerPixel == 4, layout.bytesPerRow % 4 == 0,
              Int(bitPattern: layout.base) % 4 == 0, y >= 0, y < pixelsHigh else { return nil }
        return UnsafeRawPointer(layout.base + y * layout.bytesPerRow).assumingMemoryBound(to: UInt32.self)
    }

    /// Whether `x`, `y`'s pixel holds exactly the bytes of `other`'s at the same place, over a run
    /// of `count` pixels.
    fileprivate func bytesMatch<Other>(_ x: Int, _ y: Int, count: Int, in other: PixelMemo<Other>) -> Bool {
        guard let mine = layout, let theirs = other.layout, mine.bytesPerPixel == theirs.bytesPerPixel,
              x >= 0, y >= 0, y < pixelsHigh, y < other.pixelsHigh,
              x + count <= pixelsWide, x + count <= other.pixelsWide else { return false }
        let n = mine.bytesPerPixel
        return memcmp(mine.base + y * mine.bytesPerRow + x * n, theirs.base + y * theirs.bytesPerRow + x * n, count * n) == 0
    }
}

extension PixelMemo where Answer == Bool {
    /// How many pixels of rows `ys` and columns `xs` the question answers true for: the count of
    /// `self(x, y)` over that rectangle, in one loop that asks again only when a pixel's bytes
    /// change. Asking per pixel through `callAsFunction` costs about 0.35 µs a pixel in a Debug
    /// build, which a 2× render's 2.5 million pixels turn into a second of the main actor.
    func count(rows ys: Range<Int>, columns xs: Range<Int>) -> Int {
        let ys = ys.clamped(to: 0..<pixelsHigh), xs = xs.clamped(to: 0..<pixelsWide)
        var n = 0
        var lastWord: UInt32 = 0, lastAnswer = false, primed = false
        // `while` over plain integers, not `for` over a range: unoptimized, a range's iterator
        // looks up generic metadata on every step, which cost more than the pixels.
        var y = ys.lowerBound
        while y < ys.upperBound {
            var x = xs.lowerBound
            if let row = words(y) {
                while x < xs.upperBound {
                    let word = row[x]
                    if !primed || word != lastWord {
                        lastWord = word
                        lastAnswer = self(x, y)
                        primed = true
                    }
                    if lastAnswer { n += 1 }
                    x += 1
                }
            } else {
                while x < xs.upperBound {
                    if self(x, y) { n += 1 }
                    x += 1
                }
            }
            y += 1
        }
        return n
    }
}

/// `a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y)`, asked once per distinct pair of pixel values,
/// for two renders of one size. Exact for the reason `PixelMemo` is: each side's answer depends only
/// on that pixel's bytes and its bitmap's format. So where two bitmaps of one format hold the same
/// bytes, nothing differs, and a scan skips that stretch of a row with one `memcmp`.
final class PixelDifference {
    /// Each side's `colorAt`, read once per distinct pixel value.
    let a: PixelMemo<NSColor?>
    let b: PixelMemo<NSColor?>
    private let sameFormat: Bool
    private var verdicts: [Pair: Bool] = [:]
    private var last: (pair: Pair, differs: Bool)?

    private struct Pair: Hashable { let a: UInt64, b: UInt64 }

    init(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) {
        self.a = PixelMemo(a) { $0 }
        self.b = PixelMemo(b) { $0 }
        sameFormat = self.a.sameFormat(as: self.b)
    }

    func callAsFunction(_ x: Int, _ y: Int) -> Bool {
        guard let ka = a.key(x, y), let kb = b.key(x, y) else {
            return a.rep.colorAt(x: x, y: y) != b.rep.colorAt(x: x, y: y)
        }
        let pair = Pair(a: ka, b: kb)
        if let last, last.pair == pair { return last.differs }
        let differs: Bool
        if let known = verdicts[pair] {
            differs = known
        } else {
            differs = a(x, y) != b(x, y)
            verdicts[pair] = differs
        }
        last = (pair, differs)
        return differs
    }

    /// Calls `body` with each pixel of rows `ys` and columns `xs` that differs, row by row, left to
    /// right: the pixels `self(x, y)` is true for, found in one loop that skips matching rows and
    /// asks again only when a pair of pixels changes.
    func forEachDiffering(rows ys: Range<Int>, columns xs: Range<Int>, _ body: (_ x: Int, _ y: Int) -> Void) {
        let ys = ys.clamped(to: 0..<min(a.pixelsHigh, b.pixelsHigh))
        let xs = xs.clamped(to: 0..<min(a.pixelsWide, b.pixelsWide))
        guard !xs.isEmpty else { return }
        var lastA: UInt32 = 0, lastB: UInt32 = 0, lastDiffers = false, primed = false
        // `while`, not `for` over a range: see `PixelMemo.count(rows:columns:)`.
        var y = ys.lowerBound
        while y < ys.upperBound {
            defer { y += 1 }
            if sameFormat, a.bytesMatch(xs.lowerBound, y, count: xs.count, in: b) { continue }
            var x = xs.lowerBound
            if let rowA = a.words(y), let rowB = b.words(y) {
                while x < xs.upperBound {
                    let wa = rowA[x], wb = rowB[x]
                    if !primed || wa != lastA || wb != lastB {
                        lastA = wa
                        lastB = wb
                        lastDiffers = self(x, y)
                        primed = true
                    }
                    if lastDiffers { body(x, y) }
                    x += 1
                }
            } else {
                while x < xs.upperBound {
                    if self(x, y) { body(x, y) }
                    x += 1
                }
            }
        }
    }

    /// How many pixels of rows `ys` and columns `xs` differ.
    func count(rows ys: Range<Int>, columns xs: Range<Int>) -> Int {
        var n = 0
        forEachDiffering(rows: ys, columns: xs) { _, _ in n += 1 }
        return n
    }
}
