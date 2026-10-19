import Foundation
import CoreImage
import AppKit

// MARK: - 二维码导出(原版 "View as QRCode",QPasteWnd.cpp:4488-4549;
// 上游先试在线二维码服务 URL,离线则本地 qrencode 生成 BMP——CreateQRCodeImage.cpp:29-95,
// 纠错级别 H、每模块 8 像素)
//
// macOS 等价:CoreImage CIQRCodeGenerator 本地生成(纠错 M),按
// ≥10px/module 放大成 NSImage(1bit 码图直接显示会糊)。

/// 二维码生成器:纯输入→输出,便于单测
public enum QRCodeExport {

    /// 纠错级别(任务口径 M;上游 qrencode 用 H——见文件头注释)
    public static let correctionLevel = "H"   // 上游 CreateQRCodeImage.cpp 用 H

    /// 每模块至少像素数(≥10px/module,保证 Retina 下可扫)
    public static let pixelsPerModule: CGFloat = 10

    /// 内容上限:超过则不生成,由 UI 弹"文本过长"提示(原版无此限制,
    /// 但 qrencode 版本上限 ~2900 字节;任务口径 2000 字符)
    public static let maxTextLength = 2000

    /// 生成二维码图片。文本为空/超长/编码失败 → nil
    public static func makeImage(for text: String) -> NSImage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxTextLength else { return nil }

        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data(trimmed.utf8), forKey: "inputMessage")
        filter.setValue(correctionLevel, forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        // 放大:CIQRCodeGenerator 输出每模块 1px,直接转 NSImage 在屏幕上模糊。
        // scale 保证输出 ≥ pixelsPerModule px/module(nearest 保持模块边缘锐利)
        let modules = output.extent.width
        guard modules > 0 else { return nil }
        let scale = max(pixelsPerModule, (pixelsPerModule / modules).rounded(.up))
        let transformed = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let rep = NSCIImageRep(ciImage: transformed)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    /// 生成 PNG 数据(「复制图片」/保存用;失败 → nil)
    public static func makePNG(for text: String) -> Data? {
        guard let image = makeImage(for: text) else { return nil }
        // 重画进位图再编码:NSCIImageRep 不直接支持 PNG 表示
        let size = image.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width),
                                          pixelsHigh: Int(size.height), bitsPerSample: 8,
                                          samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            return nil
        }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .none   // 模块边缘保持锐利
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// 窗口内展示的截断文本(下方说明行;上限 300 字符 + 省略号)
    public static func displayTruncation(of text: String, limit: Int = 300) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}
