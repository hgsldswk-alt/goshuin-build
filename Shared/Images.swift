import CoreImage.CIFilterBuiltins
import ImageIO
import UIKit

enum StampImages {
    static let maxBytes = 40_000_000

    static func validate(_ data: Data) throws -> CGImageSource {
        guard data.count <= maxBytes else { throw ArchiveError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let size = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = size[kCGImagePropertyPixelWidth] as? Int,
              let height = size[kCGImagePropertyPixelHeight] as? Int,
              (1...20_000).contains(width), (1...20_000).contains(height), width * height <= 110_000_000 else {
            throw ArchiveError.badPhoto
        }
        return source
    }

    static func image(_ data: Data, maxPixel: Int, crop: Crop? = nil) throws -> UIImage {
        let source = try validate(data)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let pixels = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw ArchiveError.badPhoto }
        guard let crop else { return UIImage(cgImage: pixels) }
        let width = Double(pixels.width)
        let height = Double(pixels.height)
        let rect = CGRect(x: crop.x * width, y: crop.y * height,
                          width: crop.width * width, height: crop.height * height).integral
        guard crop.isValid, let clipped = pixels.cropping(to: rect) else { throw ArchiveError.badPhoto }
        return UIImage(cgImage: clipped)
    }

    static func captureDate(_ data: Data) -> (Date?, String?) {
        guard let source = try? validate(data),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [String: Any],
              let value = exif["DateTimeOriginal"] as? String, value.count == 19 else { return (nil, nil) }
        let day = value.prefix(10).replacingOccurrences(of: ":", with: "-")
        guard VisitDay.date(day) != nil else { return (nil, nil) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = .current
        if let zone = exif["OffsetTimeOriginal"] as? String {
            formatter.dateFormat += "XXXXX"
            if let date = formatter.date(from: value + zone) { return (date, day) }
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        }
        return (formatter.date(from: value), day)
    }
}

enum ShareArtwork {
    static let size = CGSize(width: 1080, height: 1350)
    static let paper = UIColor(red: 246/255, green: 242/255, blue: 233/255, alpha: 1)
    static let ink = UIColor(red: 39/255, green: 37/255, blue: 31/255, alpha: 1)
    static let red = UIColor(red: 163/255, green: 54/255, blue: 45/255, alpha: 1)

    static func qr(_ url: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let pixels = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: pixels)
    }

    static func render(title: String, caption: String, images: [UIImage], storeID: String?) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let storeURL = storeID.flatMap { id in
            id.isEmpty || !id.utf8.allSatisfy { (48...57).contains($0) } ? nil : "https://apps.apple.com/app/id" + id
        }
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.pngData { context in
            let cg = context.cgContext
            func fill(_ color: UIColor, _ rect: CGRect) {
                cg.setFillColor(color.cgColor)
                cg.fill(rect)
            }
            func text(_ value: String, _ font: UIFont, _ color: UIColor, _ rect: CGRect) {
                (value as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                         attributes: [.font: font, .foregroundColor: color], context: nil)
            }
            fill(paper, CGRect(origin: .zero, size: size))
            fill(red, CGRect(x: 72, y: 72, width: 62, height: 8))
            text(title, .boldSystemFont(ofSize: 58), ink, CGRect(x: 72, y: 112, width: 936, height: 180))
            text(caption, .systemFont(ofSize: 30), ink, CGRect(x: 72, y: 296, width: 936, height: 120))
            let images = Array(images.prefix(6))
            let columns = images.count > 1 ? 2 : 1
            let rows = max(1, (images.count + columns - 1) / columns)
            let cellWidth = (936 - CGFloat(columns - 1) * 18) / CGFloat(columns)
            let cellHeight = (660 - CGFloat(rows - 1) * 18) / CGFloat(rows)
            for (index, image) in images.enumerated() {
                let rect = CGRect(x: 72 + CGFloat(index % columns) * (cellWidth + 18),
                                  y: 424 + CGFloat(index / columns) * (cellHeight + 18),
                                  width: cellWidth, height: cellHeight)
                fill(.white, rect)
                let scale = min(rect.width / image.size.width, rect.height / image.size.height)
                let scaled = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: CGRect(x: rect.midX - scaled.width / 2, y: rect.midY - scaled.height / 2,
                                      width: scaled.width, height: scaled.height))
            }
            if images.isEmpty {
                for offset in [0, 36, 72] {
                    let rectangle = CGRect(x: 254 + offset, y: 490 + offset, width: 500, height: 410)
                    fill(.white, rectangle)
                    cg.setStrokeColor(red.withAlphaComponent(0.26).cgColor)
                    cg.stroke(rectangle, width: 2)
                }
                fill(red, CGRect(x: 648, y: 835, width: 95, height: 95))
            }
            fill(red.withAlphaComponent(0.25), CGRect(x: 72, y: 1110, width: 936, height: 2))
            text(L.t("share.hashtags"), .boldSystemFont(ofSize: 33), red,
                 CGRect(x: 72, y: 1150, width: 708, height: 75))
            text(L.t("share.download"), .systemFont(ofSize: 27), ink,
                 CGRect(x: 72, y: 1230, width: 708, height: 75))
            let codeBox = CGRect(x: 842, y: 1140, width: 166, height: 166)
            fill(.white, codeBox)
            if let storeURL, let image = qr(storeURL) {
                cg.interpolationQuality = .none
                image.draw(in: codeBox.insetBy(dx: 17, dy: 17))
            } else {
                text(L.t("share.qrPlaceholder"), .systemFont(ofSize: 23), ink,
                     codeBox.insetBy(dx: 14, dy: 25))
            }
        }
    }
}
