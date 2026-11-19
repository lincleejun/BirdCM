import XCTest
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
@testable import BirdCM

/// The image viewer's logic: decode size, EXIF-upright original, the initial zoom onto the bird.
final class ImageViewerTests: XCTestCase {
    func testDecodeEdgeIsCapped() {
        XCTAssertEqual(ImageViewer.edge(CGSize(width: 8064, height: 6048)), 4096)   // 48 MP: never a full decode
        XCTAssertEqual(ImageViewer.edge(CGSize(width: 3000, height: 4000)), 4000)
        XCTAssertEqual(ImageViewer.edge(CGSize(width: 80, height: 60)), 80)          // never enlarged
    }
    func testFocusAndZoomRect() {
        let size = CGSize(width: 4000, height: 3000), box = [0.4, 0.4, 0.5, 0.5]
        XCTAssertEqual(ImageViewer.focus(size: size, boxes: [box], crops: [[0.1, 0.2, 0.3, 0.4]], index: 0), [0.1, 0.2, 0.3, 0.4], "the stored display crop wins")
        XCTAssertEqual(ImageViewer.focus(size: size, boxes: [box], crops: nil, index: 0), DisplayCrop.make(size: size, box: box).normalized(in: size))
        XCTAssertNil(ImageViewer.focus(size: size, boxes: [box], crops: nil, index: nil), "原图: the whole photo")
        XCTAssertNil(ImageViewer.focus(size: size, boxes: [box], crops: nil, index: 3))
        XCTAssertEqual(ImageViewer.zoomRect([0.25, 0.5, 0.75, 1], in: CGSize(width: 400, height: 300)), CGRect(x: 100, y: 150, width: 200, height: 150))
        // Aspect-fit canvas: a landscape photo in a portrait screen fills the width.
        XCTAssertEqual(ImageViewer.fit(CGSize(width: 4000, height: 3000), in: CGSize(width: 400, height: 800)), CGSize(width: 400, height: 300))
    }
    func testOriginalIsUpright() throws {
        // 80×60 stored, EXIF 6 (rotate 90° CW): upright 60×80, the left-to-right red ramp becomes top-to-bottom.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: url) }
        var px = [UInt8]()
        for _ in 0..<60 { for x in 0..<80 { px += [UInt8(x * 3), 0, 90] } }
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, RGB(w: 80, h: 60, px: px).cgImage(), [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let (image, focus) = try XCTUnwrap(ImageViewer.original(url, boxes: [[0.2, 0.2, 0.4, 0.4]], crops: nil, index: 0))
        XCTAssertEqual(image.width, 60); XCTAssertEqual(image.height, 80)
        XCTAssertEqual(focus, DisplayCrop.make(size: CGSize(width: 60, height: 80), box: [0.2, 0.2, 0.4, 0.4]).normalized(in: CGSize(width: 60, height: 80)))
        var rgba = [UInt8](repeating: 0, count: 60 * 80 * 4)
        let ctx = try XCTUnwrap(CGContext(data: &rgba, width: 60, height: 80, bitsPerComponent: 8, bytesPerRow: 240, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 60, height: 80))   // buffer row 0 = the image's top row
        XCTAssertLessThan(rgba[0], 20); XCTAssertGreaterThan(rgba[79 * 240], 200, "red grows downwards once upright")
    }
}

/// The viewer on a personal photo (zoomed onto the bird, 查看原图记录), light and dark.
final class ImageViewerSnapshots: SnapshotCase {
    @MainActor func testImageViewer() async throws {
        for mode in [SnapshotCase.light, SnapshotCase.dark] {
            let m = model("normal"), r = try XCTUnwrap(m.current)
            await until { !m.items.isEmpty }
            XCTAssertNotNil(m.url(r.id), "the fixture's original is in the library")
            try await shot("image-viewer", mode, test: "testImageViewer",
                           ImageViewer(source: .photo(id: r.id, boxes: r.boxes, crops: r.displayCrops, index: 0)).environment(m).tint(Palette.accent))
        }
    }

    func testReferenceSource() {
        var c=Reference.Card(state:"ok");c.licence="CC BY-SA 4.0";c.author="A";c.file="Bald Eagle (1).jpg";c.sourceURL="https://commons.wikimedia.org/wiki/File:Bald_Eagle"
        guard case let .web(url,author,_,_,nc,_)? = ImageViewerSource.reference(c) else {return XCTFail()}
        XCTAssertEqual(url.absoluteString,"https://commons.wikimedia.org/wiki/Special:FilePath/Bald%20Eagle%20(1).jpg?width=1280");XCTAssertEqual(author,"A");XCTAssertFalse(nc)
        c.file="https://inaturalist-open-data.s3.amazonaws.com/photos/123/square.jpg";c.nc=true
        guard case let .web(u2,_,_,_,nc2,_)? = ImageViewerSource.reference(c) else {return XCTFail()}
        XCTAssertEqual(u2.absoluteString,"https://inaturalist-open-data.s3.amazonaws.com/photos/123/large.jpg");XCTAssertTrue(nc2)
        c.licence=nil;XCTAssertNil(ImageViewerSource.reference(c))
        c.licence="CC0";c.state="none";XCTAssertNil(ImageViewerSource.reference(c))
    }
}
