import Testing
import AppKit
@testable import FileExplorer

/// `RestructureRender.differingPixels`' own answers, since every Restructure render test reads
/// through it: identical renders differ nowhere, and renders that can't be laid over each other
/// are a failure, never "no difference".
@Suite struct RestructureRenderCompareTests {

    private func rep(_ side: Int, white: Bool = true) throws -> NSBitmapImageRep {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        let data = try #require(rep.bitmapData)
        for i in 0..<(rep.bytesPerRow * side) { data[i] = white ? 255 : 0 }
        return rep
    }

    @Test func identicalRendersDifferInNoPixel() throws {
        #expect(RestructureRender.differingPixels(try rep(8), try rep(8)) == 0)
    }

    @Test func everyPixelOfTwoUnlikeRendersIsCounted() throws {
        #expect(RestructureRender.differingPixels(try rep(8), try rep(8, white: false)) == 64)
    }

    /// The case that answered 0: an `== 0` check through it then passed on two renders of
    /// different sizes, which is what a surface that changed its layout produces.
    @Test func rendersOfTwoSizesAreAFailureNotNoDifference() throws {
        let large = try rep(8), small = try rep(4)
        var answer = 0
        // Only the helper's own record can satisfy this: nothing else inside it can fail.
        withKnownIssue("the comparison must record that it could not compare") {
            answer = RestructureRender.differingPixels(large, small)
        }
        #expect(answer != 0, "a mismatch answered 0, which every `== 0` check reads as no difference")
    }
}
