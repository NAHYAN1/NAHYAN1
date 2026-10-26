import XCTest
import UIKit
import PDFKit
@testable import FileeMobile

final class ConversionTests: XCTestCase {
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
