// Fitting a picture to a screen.
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum FitPlan: Equatable, Sendable {
    /// Scale to fill the screen and crop the overflow.
    case crop
    /// Show the whole picture at this size over a blurred, darkened copy of itself.
    case fit(width: Int, height: Int)
}

public enum Renderer {
    /// Crop to fill when the aspect ratios are within threshold of each other, otherwise fit
    /// the whole picture over a blurred copy. A picture is never enlarged more than maxUpscale,
    /// so a small one is shown whole at that size instead of blown up and blurry.
    public static func plan(imageWidth iw: Int, imageHeight ih: Int, screenWidth w: Int, screenHeight h: Int,
                            threshold: Double = 1.2, maxUpscale: Double = 2) -> FitPlan {
        let (iw, ih, w, h) = (Double(iw), Double(ih), Double(w), Double(h))
        var r = (iw / ih) / (w / h)
        if r < 1 { r = 1 / r }
        let fill = max(w / iw, h / ih)
        let fit = min(w / iw, h / ih)
        if r <= threshold && fill <= maxUpscale { return .crop }
        let s = min(fit, maxUpscale)
        return .fit(width: Int(iw * s + 0.5), height: Int(ih * s + 0.5))
    }

    /// Width and height as displayed, after the EXIF orientation; nil if it isn't a picture.
    public static func size(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return size(of: source)
    }

    static func size(of source: CGImageSource) -> (width: Int, height: Int)? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? (h, w) : (w, h)
    }

    /// The longer side in pixels of the picture whose first bytes are data, or nil when
    /// they don't tell.
    public static func longerSide(ofStart data: Data) -> Int? {
        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, data as CFData, false)
        return size(of: source).map { max($0.width, $0.height) }
    }

    /// Whether ImageIO can decode the file: a Wi-Fi login page or an error page can come back
    /// as a successful download.
    public static func isPicture(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: false] as CFDictionary) != nil
            && size(of: source) != nil
    }

    static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    /// Render src for a w x h screen into out (a JPEG), through a .part file so a failure
    /// never leaves half a picture behind.
    public static func render(_ src: URL, width w: Int, height h: Int, to out: URL,
                              threshold: Double = 1.2, maxUpscale: Double = 2) throws {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil), let (iw, ih) = size(of: source) else {
            throw APODError.message("can't read \(src.lastPathComponent) as an image")
        }
        let plan = plan(imageWidth: iw, imageHeight: ih, screenWidth: w, screenHeight: h,
                        threshold: threshold, maxUpscale: maxUpscale)
        let screen = CGRect(x: 0, y: 0, width: w, height: h)

        // Decode no larger than needed: APOD originals can be tens of thousands of pixels wide.
        let fillScale = max(Double(w) / Double(iw), Double(h) / Double(ih))
        let longest = Double(max(iw, ih))
        let need = Int(ceil(longest * min(fillScale, 1)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(need, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw APODError.message("can't read \(src.lastPathComponent) as an image")
        }
        let base = CIImage(cgImage: decoded)

        func scaled(_ image: CIImage, toWidth tw: Double, height th: Double) -> CIImage {
            let sx = tw / image.extent.width, sy = th / image.extent.height
            let f = CIFilter(name: "CILanczosScaleTransform")!
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(sy, forKey: kCIInputScaleKey)
            f.setValue(sx / sy, forKey: kCIInputAspectRatioKey)
            let out = f.outputImage!
            return out.transformed(by: CGAffineTransform(translationX: -out.extent.minX, y: -out.extent.minY))
        }

        // The picture scaled to fill the screen, centred and cropped.
        func filled(_ image: CIImage) -> CIImage {
            let s = max(Double(w) / image.extent.width, Double(h) / image.extent.height)
            let big = scaled(image, toWidth: (image.extent.width * s).rounded(.up), height: (image.extent.height * s).rounded(.up))
            let dx = ((big.extent.width - Double(w)) / 2).rounded(.down)
            let dy = ((big.extent.height - Double(h)) / 2).rounded(.down)
            return big.transformed(by: CGAffineTransform(translationX: -dx, y: -dy)).cropped(to: screen)
        }

        var result: CIImage
        switch plan {
        case .crop:
            result = filled(base)
        case .fit(let fw, let fh):
            // Blurred and darkened to 60%, so the picture in front stands out.
            let blurred = filled(base).clampedToExtent()
                .applyingGaussianBlur(sigma: 60)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0.6, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0.6, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0.6, w: 0),
                ])
                .cropped(to: screen)
            let front = scaled(base, toWidth: Double(fw), height: Double(fh))
                .transformed(by: CGAffineTransform(translationX: Double((w - fw) / 2), y: Double((h - fh) / 2)))
            result = front.composited(over: blurred).cropped(to: screen)
        }

        guard let cg = context.createCGImage(result, from: screen, format: .RGBA8,
                                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw APODError.message("rendering failed")
        }
        try writeJPEG(cg, to: out)
    }

    static func writeJPEG(_ image: CGImage, to out: URL, quality: Double = 0.92) throws {
        let part = out.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: part)
        guard let dest = CGImageDestinationCreateWithURL(part as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw APODError.message("rendering failed")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: part)
            throw APODError.message("rendering failed")
        }
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: part, to: out)
    }
}
