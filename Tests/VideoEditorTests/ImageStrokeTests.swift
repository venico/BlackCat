import XCTest
import Foundation
import AppKit
import CoreImage
@testable import VideoEditorLib

// MARK: - 图片描边

final class ImageStrokeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // 素材库是全局单例，不清一遍的话上个用例导入的素材会串到下个用例
        MediaLibrary.shared.resetForTesting()
    }

    /// 描边字段是后加的，旧 .bcj 里没有这两个 key。
    /// ImageClip 用自动合成的 Codable，非可选新字段会让旧文件直接解码失败，
    /// 所以这条断言是在守「老项目还能不能打开」
    func testOldProjectFileStillDecodes() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "assetID": "\(UUID().uuidString)",
          "name": "old",
          "startTime": 0,
          "endTime": 5,
          "imageWidth": 100,
          "imageHeight": 100,
          "scaleX": 1, "scaleY": 1, "lockAspect": true,
          "offsetX": 0, "offsetY": 0,
          "cropTop": 0, "cropBottom": 0, "cropLeft": 0, "cropRight": 0,
          "mirrorH": false, "mirrorV": false, "rotation": 0,
          "colorAdjust": {"brightness":0,"contrast":0,"saturation":0,"hue":0}
        }
        """.data(using: .utf8)!

        let clip = try JSONDecoder().decode(ImageClip.self, from: json)
        XCTAssertEqual(clip.strokeW, 0, "旧文件没有描边字段，应回落到 0")
        XCTAssertNil(clip.strokeWidth)
    }

    /// 新写入的描边能存下来再读回来
    func testStrokeRoundTrip() throws {
        var clip = ImageClip(assetID: UUID(), name: "n", startTime: 0, endTime: 5)
        clip.strokeColorHex = "#FF0000"
        clip.strokeWidth = 8

        let data = try JSONEncoder().encode(clip)
        let back = try JSONDecoder().decode(ImageClip.self, from: data)
        XCTAssertEqual(back.strokeW, 8)
        XCTAssertEqual(back.strokeColorHex, "#FF0000")
    }

    /// 中心不透明方块 + 四周透明，用来量描边
    private func makeDotImage(size: Int = 80, box: Int = 20) throws -> CIImage {
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw XCTSkip("无法创建上下文")
        }
        ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        let o = (size - box) / 2
        ctx.fill(CGRect(x: o, y: o, width: box, height: box))
        guard let cg = ctx.makeImage() else { throw XCTSkip("无法生成测试图") }
        return CIImage(cgImage: cg)
    }

    private func sample(_ img: CIImage, size: Int) throws -> NSBitmapImageRep {
        guard let out = CIContext().createCGImage(img, from: CGRect(x: 0, y: 0, width: size, height: size)) else {
            throw XCTSkip("渲染失败")
        }
        return NSBitmapImageRep(cgImage: out)
    }

    /// 描边宽度必须是实打实的像素数。
    /// 之前导出侧把半径打了对折（width * 0.5），5px 只外扩 2.5px，在 1080p 上几乎看不见，
    /// 表现就是「导出没有描边」。这条断言把宽度钉死
    func testStrokeWidthIsHonoredInPixels() throws {
        let size = 80, box = 20
        let img = try makeDotImage(size: size, box: box)
        let width: CGFloat = 8
        let out = ImageStroke.apply(to: img, width: width, color: .blue, softness: 0)
        let rep = try sample(out, size: size)

        // 方块上边缘在 y = (80-20)/2 = 30，往外 8px 内都该有描边
        let edge = (size - box) / 2
        for d in 1...Int(width) - 1 {
            let a = rep.colorAt(x: size / 2, y: edge - d)?.alphaComponent ?? 0
            XCTAssertGreaterThan(a, 0.5, "距轮廓 \(d)px 处应有描边，说明宽度没被打折")
        }
        // 超出宽度就该没有了
        let beyond = rep.colorAt(x: size / 2, y: edge - Int(width) - 4)?.alphaComponent ?? 1
        XCTAssertLessThan(beyond, 0.1, "超出描边宽度的地方不该有颜色")
    }

    /// 硬边不该糊出去；柔和度拉满才允许渐变
    func testSoftnessControlsEdgeHardness() throws {
        let size = 80
        let img = try makeDotImage(size: size)
        let width: CGFloat = 8
        let edge = (size - 20) / 2

        let hard = try sample(ImageStroke.apply(to: img, width: width, color: .blue, softness: 0), size: size)
        let soft = try sample(ImageStroke.apply(to: img, width: width, color: .blue, softness: 1), size: size)

        // 硬边：描边最外沿仍然接近完全不透明
        let hardOuter = hard.colorAt(x: size / 2, y: edge - Int(width) + 1)?.alphaComponent ?? 0
        XCTAssertGreaterThan(hardOuter, 0.8, "softness=0 应是硬边")

        // 柔和：同一位置明显更淡
        let softOuter = soft.colorAt(x: size / 2, y: edge - Int(width) + 1)?.alphaComponent ?? 0
        XCTAssertLessThan(softOuter, hardOuter - 0.15, "softness=1 应比硬边明显更淡")
    }

    /// width=0 时必须原样返回，不能凭空加东西
    func testZeroWidthIsNoOp() throws {
        let img = try makeDotImage()
        let out = ImageStroke.apply(to: img, width: 0, color: .blue, softness: 0)
        XCTAssertEqual(out.extent, img.extent, "宽度为 0 时不应改变图像")
    }

    /// 导出用的滤镜链：膨胀 alpha → 染成纯色。
    /// 滤镜名写错时 CoreImage 不会抛错、只会静默还回原图，所以要拿像素验收
    func testExportStrokeFilterChainProducesColoredHalo() throws {
        // 中间一个不透明红点，四周透明
        let size = 40
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let _ = Optional(ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))) else {
            throw XCTSkip("无法创建上下文")
        }
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 16, y: 16, width: 8, height: 8))
        guard let cg = ctx.makeImage() else { throw XCTSkip("无法生成测试图") }

        let src = CIImage(cgImage: cg)
        let dilated = src.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 4.0])
        let colored = dilated.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1),   // 蓝色描边
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
        let composed = src.composited(over: colored)

        let cictx = CIContext()
        guard let out = cictx.createCGImage(composed, from: CGRect(x: 0, y: 0, width: size, height: size)) else {
            throw XCTSkip("渲染失败")
        }
        let rep = NSBitmapImageRep(cgImage: out)

        // 红点中心仍是红的（原图盖在描边上）
        let center = rep.colorAt(x: 20, y: 20)
        XCTAssertGreaterThan(center?.redComponent ?? 0, 0.5, "主体本色应保留")

        // 红点外扩一圈应出现蓝色描边，且不透明
        let ring = rep.colorAt(x: 20, y: 13)
        XCTAssertGreaterThan(ring?.alphaComponent ?? 0, 0.5, "膨胀区域应不透明 —— 否则滤镜链没生效")
        XCTAssertGreaterThan(ring?.blueComponent ?? 0, 0.5, "膨胀区域应被染成描边色")

        // 更远处仍是透明的，说明描边有边界不是糊满全图
        let far = rep.colorAt(x: 2, y: 2)
        XCTAssertLessThan(far?.alphaComponent ?? 1, 0.1, "描边不应扩散到整张图")
    }
}
