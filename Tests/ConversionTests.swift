import XCTest
import UIKit
import PDFKit
@testable import FileeMobile

final class ConversionTests: XCTestCase {
    private func inTemporaryFolder(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func fixture(_ root: URL, name: String = "source.png", transparent: Bool = false) throws -> URL {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 400), format: format).image { c in
            if !transparent {
                UIColor.red.setFill()
                c.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
            }
        }
        let source = root.appendingPathComponent(name)
        try XCTUnwrap(image.pngData()).write(to: source)
        return source
    }

    func testJPEGResizesAndKeepsAspectRatio() throws {
        try inTemporaryFolder { root in
            let source = try fixture(root)
            let files = try Converter.run(inputs: [source], format: .jpg, quality: 0.8,
                                          maxDimension: 256, output: root.appendingPathComponent("out"))
            let image = try XCTUnwrap(UIImage(contentsOfFile: files[0].path)?.cgImage)
            XCTAssertEqual(image.width, 256)
            XCTAssertEqual(image.height, 128)
            let bytes = try Data(contentsOf: files[0])
            XCTAssertEqual(Array(bytes.prefix(2)), [0xff, 0xd8])
        }
    }

    func testTransparentJPEGIsFlattenedToWhite() throws {
        try inTemporaryFolder { root in
            let source = try fixture(root, transparent: true)
            let files = try Converter.run(inputs: [source], format: .jpg, quality: 1,
                                          maxDimension: 256, output: root.appendingPathComponent("out"))
            let image = try XCTUnwrap(UIImage(contentsOfFile: files[0].path)?.cgImage)
            var pixel = [UInt8](repeating: 0, count: 4)
            try pixel.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                    bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            XCTAssertTrue(pixel.prefix(3).allSatisfy { $0 >= 250 }, "Transparent pixels should become white, not black")
        }
    }

    func testMultipagePDFExportsEveryPage() throws {
        try inTemporaryFolder { root in
            let source = root.appendingPathComponent("two-pages.pdf")
            try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 200)).writePDF(to: source) { c in
                c.beginPage(); UIColor.red.setFill(); c.cgContext.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
                c.beginPage(); UIColor.blue.setFill(); c.cgContext.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
            }
            let files = try Converter.run(inputs: [source], format: .png, quality: 0.8,
                                          maxDimension: 256, output: root.appendingPathComponent("out"))
            XCTAssertEqual(files.count, 2)
            XCTAssertNotEqual(files[0], files[1])
            for file in files { XCTAssertNotNil(UIImage(contentsOfFile: file.path)) }
        }
    }

    func testBatchFailureRemovesEarlierOutputsAndPreservesInputs() throws {
        try inTemporaryFolder { root in
            let valid = try fixture(root)
            let original = try Data(contentsOf: valid)
            let invalid = root.appendingPathComponent("broken.png")
            try Data("bad".utf8).write(to: invalid)
            let output = root.appendingPathComponent("out")
            XCTAssertThrowsError(try Converter.run(inputs: [valid, invalid], format: .png, quality: 0.8,
                                                  maxDimension: 256, output: output))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
            XCTAssertEqual(try Data(contentsOf: valid), original)
            XCTAssertEqual(try Data(contentsOf: invalid), Data("bad".utf8))
        }
    }

    func testInputAndOptionLimitsAreRejected() throws {
        try inTemporaryFolder { root in
            let source = try fixture(root)
            let output = root.appendingPathComponent("out")
            for inputs in [[URL](), Array(repeating: source, count: 21)] {
                XCTAssertThrowsError(try Converter.run(inputs: inputs, format: .png, quality: 0.8,
                                                      maxDimension: 256, output: output))
            }
            for dimension in [0, 4097] {
                XCTAssertThrowsError(try Converter.run(inputs: [source], format: .png, quality: 0.8,
                                                      maxDimension: dimension, output: output))
            }
            XCTAssertThrowsError(try Converter.run(inputs: [source], format: .jpg, quality: .nan,
                                                  maxDimension: 256, output: output))
        }
    }

    func testOversizedFileIsRejected() throws {
        try inTemporaryFolder { root in
            let source = root.appendingPathComponent("large.png")
            XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
            let handle = try FileHandle(forWritingTo: source)
            try handle.truncate(atOffset: UInt64(Converter.maxFileBytes + 1))
            try handle.close()
            XCTAssertThrowsError(try Converter.run(inputs: [source], format: .png, quality: 0.8,
                                                  maxDimension: 256, output: root.appendingPathComponent("out")))
        }
    }

    func testDuplicateInputNamesProduceDistinctOutputs() throws {
        try inTemporaryFolder { root in
            let source = try fixture(root)
            let files = try Converter.run(inputs: [source, source], format: .png, quality: 0.8,
                                          maxDimension: 256, output: root.appendingPathComponent("out"))
            XCTAssertEqual(files.count, 2)
            XCTAssertNotEqual(files[0], files[1])
            XCTAssertTrue(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        }
    }

    func testImagePDFRoundTripAndOriginalPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40)).image { c in
            UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        }
        let source = root.appendingPathComponent("source.png")
        let original = try XCTUnwrap(image.pngData())
        try original.write(to: source)
        let pdfs = try Converter.run(inputs: [source], format: .pdf, quality: 0.8,
                                    maxDimension: 1024, output: root.appendingPathComponent("pdf"))
        XCTAssertEqual(PDFDocument(url: pdfs[0])?.pageCount, 1)
        let images = try Converter.run(inputs: pdfs, format: .png, quality: 0.8,
                                      maxDimension: 1024, output: root.appendingPathComponent("pages"))
        XCTAssertEqual(images.count, 1)
        XCTAssertNotNil(UIImage(contentsOfFile: images[0].path))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testInvalidImageProducesNoPartialResults() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("invalid.png")
        try Data("not an image".utf8).write(to: source)
        let output = root.appendingPathComponent("out")
        XCTAssertThrowsError(try Converter.run(inputs: [source], format: .jpg, quality: 0.8,
                                             maxDimension: 1024, output: output))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    }
}

