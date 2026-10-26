import Foundation
import UIKit
import PDFKit
import ImageIO

enum OutputFormat: String, CaseIterable, Identifiable {
    case jpg = "JPG", png = "PNG", pdf = "PDF"
    var id: String { rawValue }
    var fileExtension: String { rawValue.lowercased() }
}

enum ConversionError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let reason): return reason }
    }
}

/// Uses only bundled Apple frameworks; no shell, downloaded engines, or network calls.
enum Converter {
    static let maxFileBytes = 40 * 1024 * 1024
    static let maxPages = 100

    static func run(inputs: [URL], format: OutputFormat, quality: Double,
                    maxDimension: Int, output: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        guard !inputs.isEmpty, inputs.count <= 20 else {
            throw ConversionError.invalid("Choose between 1 and 20 files.")
        }
        guard (256...4096).contains(maxDimension), quality.isFinite else {
            throw ConversionError.invalid("Invalid image size or quality.")
        }
        var results: [URL] = []
        // One job owns this unique directory. Remove partial outputs if any step fails.
        do {
            for (index, input) in inputs.enumerated() {
                let size = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= maxFileBytes else {
                    throw ConversionError.invalid("Each input must be 40 MB or smaller.")
                }
                let stem = "\(index + 1)-" + input.deletingPathExtension().lastPathComponent
                if input.pathExtension.lowercased() == "pdf" {
                    guard format != .pdf else {
                        throw ConversionError.invalid("Choose JPG or PNG to export PDF pages.")
                    }
                    guard let document = PDFDocument(url: input), !document.isLocked,
                          document.pageCount > 0, document.pageCount <= maxPages else {
                        throw ConversionError.invalid("Use an unlocked PDF with 1–100 pages.")
                    }
                    for pageIndex in 0..<document.pageCount {
                        try autoreleasepool {
                            guard let page = document.page(at: pageIndex) else {
                                throw ConversionError.invalid("Could not read a PDF page.")
                            }
                            let bounds = page.bounds(for: .mediaBox)
                            guard bounds.width > 0, bounds.height > 0 else {
                                throw ConversionError.invalid("Invalid PDF page dimensions.")
                            }
                            let scale = CGFloat(maxDimension) / max(bounds.width, bounds.height)
                            let image = page.thumbnail(of: CGSize(width: bounds.width * scale,
                                                                 height: bounds.height * scale), for: .mediaBox)
                            let target = output.appendingPathComponent("\(stem)-page-\(pageIndex + 1).\(format.fileExtension)")
                            try save(image, format: format, quality: quality, target: target)
                            results.append(target)
                        }
                    }
                } else {
                    try autoreleasepool {
                        let image = try loadImage(input, maxDimension: maxDimension)
                        let target = output.appendingPathComponent("\(stem).\(format.fileExtension)")
                        if format == .pdf {
                            let bounds = CGRect(origin: .zero, size: image.size)
                            try UIGraphicsPDFRenderer(bounds: bounds).writePDF(to: target) { context in
                                context.beginPage()
                                image.draw(in: bounds)
                            }
                        } else {
                            try save(image, format: format, quality: quality, target: target)
                        }
                        results.append(target)
                    }
                }
            }
            return results
        } catch {
            for file in try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil) {
                try? FileManager.default.removeItem(at: file)
            }
            throw error
        }
    }

    private static func loadImage(_ url: URL, maxDimension: Int) throws -> UIImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) == 1 else {
            throw ConversionError.invalid("Use a still image. Animated or multi-frame images are not supported yet.")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ConversionError.invalid("This image could not be decoded.")
        }
        return UIImage(cgImage: cgImage)
    }

    private static func save(_ image: UIImage, format: OutputFormat,
                             quality: Double, target: URL) throws {
        var rendered = image
        if format == .jpg {
            // JPEG has no alpha channel. Explicitly flatten transparent pixels onto white.
            let rendererFormat = UIGraphicsImageRendererFormat()
            rendererFormat.scale = 1
            rendererFormat.opaque = true
            rendered = UIGraphicsImageRenderer(size: image.size, format: rendererFormat).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: image.size))
                image.draw(at: .zero)
            }
        }
        let bytes = format == .jpg
            ? rendered.jpegData(compressionQuality: CGFloat(min(1, max(0.1, quality))))
            : rendered.pngData()
        guard let bytes else { throw ConversionError.invalid("Could not encode the image.") }
        try bytes.write(to: target, options: [.atomic, .completeFileProtection])
    }
}
