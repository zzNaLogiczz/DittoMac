import AppKit
import Foundation

/// 特殊粘贴变换(对齐原版 IDR_QUICK_PASTE 的 Special Paste 子菜单,CP_Main.rc:483-512)
public enum SpecialPaste {

    public enum Transform: CaseIterable, Sendable {
        /// 只保留纯文本表示
        case plainTextOnly
        case upperCase
        case lowerCase
        case capitalizeCase
        case sentenceCase
        case invertCase
        case trimWhitespace
        /// Posixify/Paths:路径转 POSIX 风格(反斜杠→斜杠、去盘符冒号、空格转义)
        case posixifyPaths
        /// CamelCase
        case camelCase
        /// Ascii Text Only:剔除非 ASCII 字符
        case asciiTextOnly
        case removeLineFeeds
        case appendOneLineFeed
        case appendTwoLineFeeds
        case appendCurrentTime
        /// Typoglycemia:每个词(≥4 字母)首尾字母不变,中间字母乱序
        case typoglycemia
        /// Slugify:小写、非字母数字转连字符、去首尾连字符
        case slugify
        /// Paste new Guid:忽略源文本,生成新的 UUID 粘贴
        case newGuid
        /// Paste as Image:只保留图片表示
        case pasteAsImage
        // Multiple Images Horizontally/Vertically 走 composeImages(多选合成);
        // "粘贴不改剪贴顺序"不是变换,由粘贴方跳过 markPasted 实现
    }

    /// 对 payload 施加变换,返回变换后的新 payload(RawClip 是值类型,入参不会被改动)。
    public static func apply(_ transform: Transform, to payload: RawClip) -> RawClip {
        // pasteAsImage 只关心图片,放行;其余变换在无文本时原样返回(图片等无文本条目保持原样)
        if transform == .pasteAsImage {
            var imgOnly = RawClip()
            imgOnly.imageData = payload.imageData
            imgOnly.appName = payload.appName
            return imgOnly.imageData != nil ? imgOnly : payload
        }
        guard let text = payload.text, !text.isEmpty else { return payload }
        var out = payload
        switch transform {
        case .plainTextOnly:
            // 只保留 text;appName 等元数据不动
            out.rtfData = nil
            out.htmlData = nil
            out.imageData = nil
        case .upperCase:
            out.text = text.uppercased()
        case .lowerCase:
            out.text = text.lowercased()
        case .capitalizeCase:
            out.text = text.capitalized
        case .sentenceCase:
            out.text = sentenceCase(text)
        case .invertCase:
            out.text = invertCase(text)
        case .trimWhitespace:
            out.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .removeLineFeeds:
            // 注意:Swift 里 "\r\n" 是单个 Character(CRLF 字素簇),必须用 isNewline 判断
            out.text = text.filter { !$0.isNewline }
        case .appendOneLineFeed:
            out.text = text + "\n"
        case .appendTwoLineFeeds:
            out.text = text + "\n\n"
        case .appendCurrentTime:
            out.text = text + " " + timestampFormatter.string(from: Date())
        case .posixifyPaths:
            out.text = posixify(text)
        case .camelCase:
            out.text = camelCase(text)
        case .asciiTextOnly:
            out.text = String(text.unicodeScalars.filter { $0.isASCII })
        case .typoglycemia:
            out.text = typoglycemia(text)
        case .slugify:
            out.text = slugify(text)
        case .newGuid:
            out.text = UUID().uuidString
        case .pasteAsImage:
            break   // 前置 guard 已单独处理
        }
        return out
    }

    // MARK: - 私有实现

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    /// Sentence case:字符串开头及 `. ! ?` 之后的第一个字母大写,句中其余字母小写。
    /// 只认 ASCII 句末标点 . ! ?(原版定义);中文标点不算句界(中文无大小写,不受影响)。
    private static func sentenceCase(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var atSentenceStart = true
        for ch in s {
            if atSentenceStart && ch.isLetter {
                // 无大小写的字母(中文等)不消耗句首状态,让后面的西文词首字母大写
                if ch.isLowercase {
                    out += ch.uppercased()
                    atSentenceStart = false
                } else if ch.isUppercase {
                    out.append(ch)
                    atSentenceStart = false
                } else {
                    out.append(ch)
                }
            } else {
                out += ch.lowercased()
                if ch == "." || ch == "!" || ch == "?" {
                    atSentenceStart = true
                }
            }
        }
        return out
    }

    /// 逐字符反转大小写。无大小写的字符(中文、数字、符号)原样保留;
    /// "ß"→"SS" 这类多字符映射直接追加字符串,避免构造单字符 Character 失败。
    private static func invertCase(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            if ch.isUppercase {
                out += ch.lowercased()
            } else if ch.isLowercase {
                out += ch.uppercased()
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// Posixify/Paths:C:\a b\c → /c/a\ b/c
    private static func posixify(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "\\", with: "/")
        if t.count >= 2, t[t.index(t.startIndex, offsetBy: 1)] == ":" {
            t = "/" + String(t.removeFirst()).lowercased() + t.dropFirst()
            t = t.replacingOccurrences(of: ":", with: "")
        }
        return t.replacingOccurrences(of: " ", with: "\\ ")
    }

    private static func camelCase(_ text: String) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
        guard let first = words.first else { return text }
        let rest = words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
        return first.lowercased() + rest.joined()
    }

    /// Slugify:小写、空白/下划线等非字母数字序列压缩为单个连字符、去首尾
    private static func slugify(_ text: String) -> String {
        var out = ""
        var lastWasDash = true   // 抑制首部连字符
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    /// Typoglycemia:单词中间字母随机乱序(首尾保留),非字母与短词(≤3)原样
    private static func typoglycemia(_ text: String) -> String {
        func scramble(_ word: Substring) -> String {
            let letters = Array(word)
            guard letters.count > 3 else { return String(word) }
            let middle = letters[1..<letters.count - 1].shuffled()
            return String(letters[0]) + String(middle) + String(letters[letters.count - 1])
        }
        var out = ""
        var word = ""
        for ch in text {
            if ch.isLetter {
                word.append(ch)
            } else {
                if !word.isEmpty { out += scramble(Substring(word)); word = "" }
                out.append(ch)
            }
        }
        if !word.isEmpty { out += scramble(Substring(word)) }
        return out
    }

    /// 多选图片合成(原版 Multiple Images Horizontally/Vertically):全部为图片条目时合成单张 PNG
    public static func composeImages(_ payloads: [RawClip], horizontal: Bool) -> RawClip? {
        let images = payloads.compactMap { p -> NSImage? in
            guard let data = p.imageData else { return nil }
            return NSImage(data: data)
        }
        guard images.count >= 2, images.count == payloads.count else { return nil }
        let gap: CGFloat = 4
        var totalW: CGFloat = 0, totalH: CGFloat = 0
        for img in images {
            let sz = img.size
            if horizontal { totalW += sz.width + gap; totalH = max(totalH, sz.height) }
            else { totalH += sz.height + gap; totalW = max(totalW, sz.width) }
        }
        // 只从累计方向去掉多余的尾间隙(横向合成的高度取 max,不减间隙)
        if horizontal { totalW -= gap } else { totalH -= gap }
        guard totalW > 0, totalH > 0, totalW < 8000, totalH < 8000 else { return nil }
        let canvas = NSImage(size: NSSize(width: totalW, height: totalH))
        canvas.lockFocus()
        var offset: CGFloat = 0
        for img in images {
            let sz = img.size
            let pt: NSPoint
            if horizontal { pt = NSPoint(x: offset, y: 0); offset += sz.width + gap }
            else { pt = NSPoint(x: 0, y: offset); offset += sz.height + gap }
            img.draw(at: pt, from: .zero, operation: .sourceOver, fraction: 1)
        }
        canvas.unlockFocus()
        guard let tiff = canvas.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        var out = RawClip()
        out.imageData = png
        return out
    }
}
