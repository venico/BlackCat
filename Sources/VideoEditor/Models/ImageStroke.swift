// ImageStroke.swift
// 图片描边的唯一实现。预览和导出都走这里，避免两边各写一套导致观感不一致。
import Foundation
import CoreImage
import SwiftUI
import AppKit

enum ImageStroke {

    /// 沿不透明区域的轮廓生成描边，结果垫在原图下方。
    /// - Parameters:
    ///   - width: 描边宽度，画布像素单位。就是轮廓往外扩几个像素，不再打折
    ///   - softness: 0 = 硬边（默认），1 = 最柔和。描边通常要硬边，所以模糊只在明确要求时才做
    static func apply(to img: CIImage, width: CGFloat, color: Color, softness: Double) -> CIImage {
        guard width > 0.01 else { return img }

        // 膨胀 alpha，把不透明区域往外推 width 个像素
        var halo = img.applyingFilter("CIMorphologyMaximum",
                                      parameters: [kCIInputRadiusKey: width])

        // 染成描边色：各通道取 alpha 的倍数，直接得到 premultiplied 的纯色层
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
        halo = halo.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: c.redComponent),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: c.greenComponent),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: c.blueComponent),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])

        if softness > 0.01 {
            // 高斯模糊会把 extent 撑大一圈，糊完裁回去，免得描边越算越肥
            let extent = halo.extent
            halo = halo
                .applyingFilter("CIGaussianBlur",
                                parameters: [kCIInputRadiusKey: width * softness])
                .cropped(to: extent)
        }

        return img.composited(over: halo)
    }
}
