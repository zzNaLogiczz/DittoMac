import Foundation

/// 命令行动词(上游 Command Line Options wiki;CP_Main.cpp:26-125
/// DittoCommandLineInfo::ParseParam 的已验证语义):
/// /Open /Close /Connect /Disconnect /PlainTextPaste /Paste:(id) /Edit:(id) /Exit,
/// 大小写不敏感;Paste/Edit 必须带 `:id` 后缀才生效(上游 ReverseFind(':') 分支)
public enum DittoVerb: Equatable, Sendable {
    case open
    case close
    case connect
    case disconnect
    case plainTextPaste
    case exitApp
    case paste(clipID: Int64)
    case edit(clipID: Int64)

    /// 转发用原始名(DistributedNotification 的 userInfo 只收 property list 类型,
    /// 传字符串 + id 两个标量)
    public var rawName: String {
        switch self {
        case .open: return "open"
        case .close: return "close"
        case .connect: return "connect"
        case .disconnect: return "disconnect"
        case .plainTextPaste: return "plaintextpaste"
        case .exitApp: return "exit"
        case .paste: return "paste"
        case .edit: return "edit"
        }
    }

    public var clipID: Int64? {
        switch self {
        case .paste(let id), .edit(let id): return id
        default: return nil
        }
    }

    /// 从转发回来的原始名 + id 还原动词
    public static func from(rawName: String, clipID: Int64?) -> DittoVerb? {
        switch rawName {
        case "open": return .open
        case "close": return .close
        case "connect": return .connect
        case "disconnect": return .disconnect
        case "plaintextpaste": return .plainTextPaste
        case "exit": return .exitApp
        case "paste": return clipID.map { .paste(clipID: $0) }
        case "edit": return clipID.map { .edit(clipID: $0) }
        default: return nil
        }
    }
}

/// 纯 argv 解析器(无副作用,可单测)。
/// 兼容上游 `/Verb` 与 `-Verb`、`--verb` 前缀;`Paste:123` 冒号语法(大小写不敏感)
public enum CommandLineParser {

    /// 从 argv 提取第一个动词;无动词返回 nil。
    /// 跳过 argv[0](可执行文件路径,上游 ParseCommandLine 同样不解析程序名)
    public static func parse(_ arguments: [String]) -> DittoVerb? {
        for arg in arguments.dropFirst() {
            var body = arg
            while let first = body.first, first == "/" || first == "-" {
                body.removeFirst()
            }
            guard !body.isEmpty else { continue }

            var name = body
            var id: Int64?
            if let colon = body.firstIndex(of: ":") {
                name = String(body[..<colon])
                id = Int64(body[body.index(after: colon)...])
            }
            switch name.lowercased() {
            case "open": return .open
            case "close": return .close
            case "connect": return .connect
            case "disconnect": return .disconnect
            case "plaintextpaste": return .plainTextPaste
            case "exit": return .exitApp
            case "paste":
                if let id { return .paste(clipID: id) }   // 无 :id 后缀不生效(上游同)
            case "edit":
                if let id { return .edit(clipID: id) }
            default:
                continue
            }
        }
        return nil
    }
}
