import Testing
import CoreGraphics
import Foundation
@testable import FileExplorer

/// **`PictureText.bitmap` for a PDF the app didn't make** (Ask Claude's scan reading, TE264): the
/// crop box, clipped, and a size cap. Pure CoreGraphics, so any Mac.
@Suite struct PictureTextBitmapTests {

    /// One page of `size` points, black in its bottom half, cropped to its top half when `crop`.
    private static func page(_ size: CGSize, cropTop crop: Bool = false) throws -> CGPDFPage {
        let data = NSMutableData()
        var media = CGRect(origin: .zero, size: size)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
        var top = CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        let info = crop ? [kCGPDFContextCropBox as String: Data(bytes: &top, count: MemoryLayout<CGRect>.size)] : nil
        context.beginPDFPage(info as CFDictionary?)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height / 2))
        context.endPDFPage()
        context.closePDF()
        let provider = try #require(CGDataProvider(data: data as CFData))
        let document = try #require(CGPDFDocument(provider))
        return try #require(document.page(at: 1))
    }

    /// The darkest pixel's gray level, 0 black to 255 white.
    private static func darkest(_ image: CGImage) throws -> UInt8 {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 255, count: width * height)
        let context = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                             bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels.min() ?? 255
    }

    /// **The crop box is what is drawn.** The black half lies outside the crop: drawn by the media
    /// box it fills half the bitmap; drawn by the crop box none of it shows.
    @Test func theCropBoxHidesWhatTheCropHides() throws {
        let page = try Self.page(CGSize(width: 612, height: 792), cropTop: true)
        let media = try #require(PictureText.bitmap(of: page))
        #expect(try Self.darkest(media) < 50)
        let cropped = try #require(PictureText.bitmap(of: page, box: .cropBox, longestSide: PictureText.readSize))
        #expect(cropped.width == 1920 && cropped.height == 1242)
        #expect(try Self.darkest(cropped) > 200)
    }

    /// **A page one picture pixel to a point is drawn at `longestSide`, not at its own size.** The
    /// media box's floor keeps 14,400 points as 14,400 pixels, a bitmap of about 600 MB.
    @Test func aHugePageIsCappedAtItsLongestSide() throws {
        let page = try Self.page(CGSize(width: 14_400, height: 10_800))
        let capped = try #require(PictureText.bitmap(of: page, box: .cropBox, longestSide: PictureText.readSize))
        #expect(capped.width == 1920 && capped.height == 1440)
        // A small page still grows to the size Vision reads, as Save as PDF's does.
        let letter = try Self.page(CGSize(width: 612, height: 792))
        let small = try #require(PictureText.bitmap(of: letter, box: .cropBox, longestSide: PictureText.readSize))
        #expect(small.height == 1920)
    }
}
