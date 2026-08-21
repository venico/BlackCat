import AppKit
import CoreImage

/// 画布上的本地图像处理（裁剪、镜像、旋转）+ 产物落盘。
///
/// 抽出来是因为操作栏和卡片上的裁剪框都要用 —— 逻辑写两份迟早走样。
enum CanvasImageOps {

    /// 产物放 Application Support 下，名字带后缀。
    /// 用稳定名字而不是 UUID，用户在 Finder 里也认得出这是哪张图处理出来的
    static func outputURL(basedOn source: URL, suffix: String, ext: String = "png") -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BlackCat/canvas", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = source.deletingPathExtension().lastPathComponent + suffix
        var url = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base)_\(i)").appendingPathExtension(ext)
            i += 1
        }
        return url
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "canvas", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "编码 PNG 失败"])
        }
        try data.write(to: url)
    }

    static func loadCGImage(_ url: URL) -> CGImage? {
        NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// 按相对矩形（0~1，原点左上）裁剪
    static func crop(_ url: URL, to rel: CGRect) throws -> URL {
        guard let img = loadCGImage(url) else {
            throw NSError(domain: "canvas", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "读不出这张图"])
        }
        let w = CGFloat(img.width), h = CGFloat(img.height)
        // CGImage 的坐标原点在左上，跟裁剪框一致，直接换算
        let rect = CGRect(x: (rel.minX * w).rounded(),
                          y: (rel.minY * h).rounded(),
                          width: max(1, (rel.width * w).rounded()),
                          height: max(1, (rel.height * h).rounded()))
        guard let out = img.cropping(to: rect) else {
            throw NSError(domain: "canvas", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "裁剪失败"])
        }
        let dest = outputURL(basedOn: url, suffix: "_裁剪")
        try writePNG(out, to: dest)
        return dest
    }

    static func mirror(_ url: URL, vertical: Bool) throws -> URL {
        guard let img = loadCGImage(url) else {
            throw NSError(domain: "canvas", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "读不出这张图"])
        }
        let ci = CIImage(cgImage: img)
        let t = vertical ? CGAffineTransform(scaleX: 1, y: -1) : CGAffineTransform(scaleX: -1, y: 1)
        let flipped = ci.transformed(by: t)
        guard let out = CIContext().createCGImage(flipped, from: flipped.extent) else {
            throw NSError(domain: "canvas", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "镜像失败"])
        }
        let dest = outputURL(basedOn: url, suffix: vertical ? "_垂直镜像" : "_水平镜像")
        try writePNG(out, to: dest)
        return dest
    }

    static func rotate90(_ url: URL) throws -> URL {
        guard let img = loadCGImage(url) else {
            throw NSError(domain: "canvas", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "读不出这张图"])
        }
        let ci = CIImage(cgImage: img).transformed(by: CGAffineTransform(rotationAngle: -.pi / 2))
        guard let out = CIContext().createCGImage(ci, from: ci.extent) else {
            throw NSError(domain: "canvas", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "旋转失败"])
        }
        let dest = outputURL(basedOn: url, suffix: "_旋转")
        try writePNG(out, to: dest)
        return dest
    }
}
