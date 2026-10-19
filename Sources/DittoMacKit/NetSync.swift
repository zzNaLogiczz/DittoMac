import Foundation
import Network
import Security
import CommonCrypto

// MARK: - 局域网剪贴板同步(原版 LAN CLIP SYNC / Friends)
//
// 上游行为规格(只读参考):
//   - TCP 服务器监听可配置端口,默认 23443:Server.cpp:51(htons(m_lPort) 绑定),
//     默认值见 Options.cpp:1475(GetProfileLong("SendRecvPort", 23443))。
//   - 每连接一个 ClientThread 逐帧收(Server.cpp:78-93),accept 后转发进插入管线。
//   - 好友("send clients")列表 + 每条目右键 "Send To" 发送:QPasteWnd.cpp:1802,
//     自定义好友菜单 CustomFriendsHelper.h(CustomFriendStartId 起)。
//   - 传输加密:EncryptDecrypt 插件(Encryption.cpp:64-80,SHA-256 派生主密钥的
//     Rijndael 流),密码在 Friends 设置页(OptionFriends.cpp)。
//   - 接收开关:上游 DisableRecieve(Options.cpp:1478-1492)—— 关掉后不再收。
//
// ⚠️ 线级协议偏差(有意):上游帧头是 360 字节的 CSendInfo C 结构体
// (ServerDefines.h:12-37:int m_nSize + eSendType + 版本 + IP/机器名/描述定长字符数组
// + md5 + manualSend + respondPort …)+ 私有 Rijndael 加密流。此处为 macOS 原生协议:
// 魔数 + 长度前缀 + JSON 头,CommonCrypto AES-256-CBC 加密。Windows 互操作未实现
// —— 是否追求线级兼容待人工讨论。头字段名与语义一一对应 CSendInfo
// (type↔m_Type,computerName↔m_cComputerName,ip↔m_cIP,desc↔m_cDesc,
// manualSend↔m_manualSend,respondPort↔m_respondPort,version↔m_nVersion=1)。

// MARK: - 帧头(上游 CSendInfo 的 JSON 等价物)

public struct NetSyncHeader: Codable, Equatable, Sendable {
    public static let typeClip = "clip"
    public static let typeExit = "exit"
    public static let typeAck = "ack"

    /// 帧类型:"clip"(带剪贴内容)/ "exit"(发送完毕,关闭连接)
    public var type: String
    /// 发送方机器名(上游 m_cComputerName)
    public var computerName: String
    /// 发送方 IP(上游 m_cIP)
    public var ip: String
    /// 描述(上游 m_cDesc;携带发送侧条目描述)
    public var desc: String
    /// 是否手动发送(上游 m_manualSend;右键 "发送到" = true)
    public var manualSend: Bool
    /// 响应端口(上游 m_respondPort;接收方回执用,当前未用,保留字段)
    public var respondPort: Int
    /// 协议版本(上游 m_nVersion = 1,ServerDefines.h:19)
    public var version: Int
    /// 明文标志:仅明文帧有意义(密文帧里该字段随头一起加密,由模式字节判别)
    public var encrypted: Bool

    public init(type: String, computerName: String, ip: String, desc: String,
                manualSend: Bool, respondPort: Int = 0, version: Int = 1,
                encrypted: Bool = false) {
        self.type = type
        self.computerName = computerName
        self.ip = ip
        self.desc = desc
        self.manualSend = manualSend
        self.respondPort = respondPort
        self.version = version
        self.encrypted = encrypted
    }
}

// MARK: - 剪贴内容载荷

/// 单个格式:type = UTI(如 public.rtf),data = zlib 压缩后的字节(RFC1950 容器,
/// 复用 ZlibCodec —— 与上游 Data.ooData 列同一压缩格式,Clip_ImportExport.cpp:44-46),
/// size = 压缩前长度(对应上游 Data.lOriginalSize,解压目标长度)
public struct NetSyncFormat: Codable, Equatable, Sendable {
    public var type: String
    public var data: Data
    public var size: Int

    public init(type: String, data: Data, size: Int) {
        self.type = type
        self.data = data
        self.size = size
    }
}

/// "clip" 帧的载荷 JSON:{desc, appName, sentAt, formats, text, filePaths}
public struct NetSyncClipPayload: Codable, Equatable, Sendable {
    public var desc: String
    public var appName: String
    public var sentAt: Date
    public var formats: [NetSyncFormat]
    /// 纯文本便捷字段(与 formats 并存:接收端直接落 text 列)
    public var text: String?
    public var filePaths: [String]?

    public init(desc: String, appName: String, sentAt: Date,
                formats: [NetSyncFormat], text: String? = nil,
                filePaths: [String]? = nil) {
        self.desc = desc
        self.appName = appName
        self.sentAt = sentAt
        self.formats = formats
        self.text = text
        self.filePaths = filePaths
    }

    // MARK: RawClip ↔ 载荷

    /// 发送侧打包:已知字段按代表性 UTI 压缩进 formats;text/filePaths 单独成字段。
    /// 空条目(没有任何内容)返回 nil,调用方跳过
    public static func from(raw: RawClip) -> NetSyncClipPayload? {
        guard !raw.isEmpty else { return nil }
        var formats: [NetSyncFormat] = []
        func append(_ type: String, _ data: Data?) {
            guard let data, !data.isEmpty, let zipped = ZlibCodec.compress(data) else { return }
            formats.append(NetSyncFormat(type: type, data: zipped, size: data.count))
        }
        append(ClipUTI.rtf, raw.rtfData)
        append(ClipUTI.html, raw.htmlData)
        if let image = raw.imageData {
            // PNG 按原 UTI;其余位图(TIFF 等)统一标 tiff(接收端 imageData 落同一列)
            append(ClipPackage.isPNGData(image) ? ClipUTI.png : ClipUTI.tiff, image)
        }
        for extra in raw.extraFormats where !extra.data.isEmpty {
            append(extra.type, extra.data)
        }
        // desc:首行截 500(展示口径;完整内容在 text/formats 里)
        let desc = raw.text.map { String($0.prefix(500)) } ?? ""
        return NetSyncClipPayload(desc: desc, appName: raw.appName ?? "",
                                  sentAt: Date(), formats: formats,
                                  text: raw.text, filePaths: raw.filePaths)
    }

    /// 接收侧还原:zlib 按原始长度解压,已知 UTI 映射回 RawClip 各列,未知名进
    /// extraFormats。任何一个格式解压失败 → 整帧 nil(宁可丢弃也不落半截内容)
    public func toRawClip() -> RawClip? {
        guard !formats.isEmpty || text?.isEmpty == false || filePaths?.isEmpty == false else {
            return nil
        }
        var raw = RawClip()
        var extras: [ClipFormat] = []
        var remainingBytes = NetSyncFrame.maxPayloadBytes
        for format in formats {
            guard format.size > 0, format.size <= remainingBytes,
                  let unzipped = ZlibCodec.decompress(format.data, originalSize: format.size) else {
                return nil
            }
            remainingBytes -= format.size
            switch format.type {
            case ClipUTI.rtf: raw.rtfData = unzipped
            case ClipUTI.html: raw.htmlData = unzipped
            case ClipUTI.png, ClipUTI.tiff: if raw.imageData == nil { raw.imageData = unzipped }
            default: extras.append(ClipFormat(type: format.type, data: unzipped))
            }
        }
        raw.text = text
        raw.filePaths = filePaths
        raw.extraFormats = extras
        raw.appName = appName
        return raw
    }
}

// MARK: - 帧编解码
//
// 帧布局(小端):
//   [magic "DITTO" 5 字节][模式 1 字节:'P' 明文 / 'E' 加密]
//   [头长度 u32][头 JSON][载荷长度 u64][载荷]
// 加密模式('E')下,头 JSON 与载荷各自是 AES-256-CBC 密文(IV 前置,见 NetSyncCrypto);
// 长度字段是密文长度。模式字节必须放在加密区外:接收方要先知道用哪种方式解头
// (任务口径"明文模式带 header 标志"——该标志 encrypted:false 只在明文帧可见,
// 密文帧的判别即模式字节,两者不矛盾:明文帧头里 encrypted=false 恒成立)。

public enum NetSyncFrame {

    public static let magic = Data("DITTO".utf8)
    static let modePlain: UInt8 = UInt8(ascii: "P")
    static let modeEncrypted: UInt8 = UInt8(ascii: "E")
    /// 头(密文)长度上限:头是短 JSON + 描述,1MB 足够宽裕
    public static let maxHeaderBytes = 1 << 20
    /// 载荷(密文)长度上限:单条体积上限 20MB 之上留余量
    public static let maxPayloadBytes = 128 << 20

    public enum Result {
        /// (头, 载荷, 消费字节数)
        case frame(NetSyncHeader, Data, Int)
        /// 缓冲不完整,继续收
        case needMoreData
        /// 魔数/模式/长度/JSON/解密失败 —— 丢弃整帧(调用方应断开连接)
        case malformed
    }

    /// 编码一帧。password 非 nil → 加密模式;nil → 明文模式
    public static func encode(header: NetSyncHeader, payload: Data,
                              password: String?) -> Data? {
        guard payload.count <= maxPayloadBytes,
              let headerJSON = try? JSONEncoder().encode(header),
              headerJSON.count <= maxHeaderBytes else { return nil }
        var out = Data()
        out.append(magic)
        if let password, !password.isEmpty {
            // 加密:头与载荷各自 IV‖密文(解密侧按长度切分)
            guard let key = NetSyncCrypto.key(from: password),
                  let encHeader = NetSyncCrypto.encrypt(headerJSON, key: key),
                  let encPayload = NetSyncCrypto.encrypt(payload, key: key),
                  encHeader.count <= maxHeaderBytes,
                  encPayload.count <= maxPayloadBytes else { return nil }
            out.append(modeEncrypted)
            appendLE32(UInt32(encHeader.count), to: &out)
            out.append(encHeader)
            appendLE64(UInt64(encPayload.count), to: &out)
            out.append(encPayload)
        } else {
            var plainHeader = header
            plainHeader.encrypted = false   // 明文帧的标志位(密文帧该字段无意义)
            guard let plainJSON = try? JSONEncoder().encode(plainHeader) else { return nil }
            out.append(modePlain)
            appendLE32(UInt32(plainJSON.count), to: &out)
            out.append(plainJSON)
            appendLE64(UInt64(payload.count), to: &out)
            out.append(payload)
        }
        return out
    }

    /// 从缓冲解析一帧(不消费缓冲;调用方按 consumed 前移)
    public static func parse(from buffer: Data, password: String?) -> Result {
        let prefixLength = magic.count + 1 + 4
        guard buffer.count >= prefixLength else { return .needMoreData }
        guard buffer.prefix(magic.count) == magic else { return .malformed }
        let mode = buffer[buffer.startIndex + magic.count]
        // 长度先按原始宽度校验再转 Int:损坏字段(u64 全 1)直接转 Int 会溢出陷阱
        let headerLengthRaw = readLE32(buffer, offset: magic.count + 1)
        guard headerLengthRaw > 0, headerLengthRaw <= UInt32(maxHeaderBytes) else { return .malformed }
        let headerLength = Int(headerLengthRaw)

        let payloadLengthOffset = prefixLength + headerLength
        guard buffer.count >= payloadLengthOffset + 8 else { return .needMoreData }
        let payloadLengthRaw = readLE64(buffer, offset: payloadLengthOffset)
        guard payloadLengthRaw <= UInt64(maxPayloadBytes) else { return .malformed }
        let payloadLength = Int(payloadLengthRaw)
        let totalLength = payloadLengthOffset + 8 + payloadLength
        guard buffer.count >= totalLength else { return .needMoreData }

        let headerBlob = buffer.subdata(
            in: (buffer.startIndex + prefixLength)..<(buffer.startIndex + payloadLengthOffset))
        let payloadBlob = buffer.subdata(
            in: (buffer.startIndex + payloadLengthOffset + 8)..<(buffer.startIndex + totalLength))

        let headerJSON: Data
        let payload: Data
        switch mode {
        case modePlain:
            // 接收侧设了密码却收到明文帧 → 拒收(防降级窃听;上游有密码同样加密)
            guard password == nil || password?.isEmpty == true else { return .malformed }
            headerJSON = headerBlob
            payload = payloadBlob
        case modeEncrypted:
            guard let password, !password.isEmpty,
                  let key = NetSyncCrypto.key(from: password),
                  let decryptedHeader = NetSyncCrypto.decrypt(headerBlob, key: key) else {
                return .malformed   // 无密码/密码错(解密或填充校验失败)
            }
            headerJSON = decryptedHeader
            guard let decryptedPayload = NetSyncCrypto.decrypt(payloadBlob, key: key) else {
                return .malformed
            }
            payload = decryptedPayload
        default:
            return .malformed
        }

        guard let header = try? JSONDecoder().decode(NetSyncHeader.self, from: headerJSON),
              header.version >= 1 else { return .malformed }
        return .frame(header, payload, totalLength)
    }

    // MARK: 小端读写

    static func appendLE32(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    static func appendLE64(_ value: UInt64, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    static func readLE32(_ data: Data, offset: Int) -> UInt32 {
        let i = data.index(data.startIndex, offsetBy: offset)
        return UInt32(data[i]) | UInt32(data[data.index(after: i)]) << 8
            | UInt32(data[data.index(i, offsetBy: 2)]) << 16
            | UInt32(data[data.index(i, offsetBy: 3)]) << 24
    }

    static func readLE64(_ data: Data, offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 56, by: 8) {
            let byte = data[data.index(data.startIndex, offsetBy: offset + shift / 8)]
            value |= UInt64(byte) << UInt64(shift)
        }
        return value
    }
}

// MARK: - 传输加密(上游 EncryptDecrypt 插件的 CommonCrypto 等价)
//
// 方案(文档化):
//   key      = SHA256(共享密码)(上游 Encryption.cpp:64-80 同样以 SHA-256 派生主密钥)
//   cipher   = AES-256-CBC + PKCS7(CommonCrypto CCCrypt)
//   密文布局 = IV(16 字节,SecRandomCopyBytes 随机)‖ 密文
//   每帧头/载荷独立加密(各自的 IV),同明文两次加密因随机 IV 而不同。
// 密码错误:CBC 填充校验大概率直接失败返回 nil;极小概率解出乱码 → 随后的
// JSON 解码失败,同样干净拒绝(两种路径都不会把错数据当帧收下)。

public enum NetSyncCrypto {

    /// SHA-256(密码) → 32 字节 AES-256 密钥;空密码 → nil(不进入加密模式)
    public static func key(from password: String) -> Data? {
        guard !password.isEmpty else { return nil }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        Data(password.utf8).withUnsafeBytes { raw in
            _ = CC_SHA256(raw.baseAddress, CC_LONG(raw.count), &digest)
        }
        return Data(digest)
    }

    /// AES-256-CBC 加密:IV ‖ 密文;失败 nil
    public static func encrypt(_ plaintext: Data, key: Data) -> Data? {
        guard key.count == kCCKeySizeAES256 else { return nil }
        var iv = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        guard SecRandomCopyBytes(kSecRandomDefault, iv.count, &iv) == errSecSuccess else {
            return nil
        }
        guard let ciphertext = crypt(operation: CCOperation(kCCEncrypt),
                                     data: plaintext, key: key, iv: Data(iv)) else { return nil }
        return Data(iv) + ciphertext
    }

    /// AES-256-CBC 解密;填充校验失败(密码错/数据损坏)→ nil
    public static func decrypt(_ blob: Data, key: Data) -> Data? {
        guard key.count == kCCKeySizeAES256, blob.count > kCCBlockSizeAES128 else { return nil }
        let iv = blob.prefix(kCCBlockSizeAES128)
        let ciphertext = blob.dropFirst(kCCBlockSizeAES128)
        return crypt(operation: CCOperation(kCCDecrypt), data: ciphertext,
                     key: key, iv: Data(iv))
    }

    private static func crypt(operation: CCOperation, data: Data, key: Data, iv: Data) -> Data? {
        let capacity = data.count + kCCBlockSizeAES128
        var out = Data(count: capacity)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outPtr -> CCCryptorStatus in
            data.withUnsafeBytes { inPtr -> CCCryptorStatus in
                key.withUnsafeBytes { keyPtr -> CCCryptorStatus in
                    iv.withUnsafeBytes { ivPtr -> CCCryptorStatus in
                        CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, key.count,
                                ivPtr.baseAddress,
                                inPtr.baseAddress, data.count,
                                outPtr.baseAddress, capacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess, moved > 0 else { return nil }
        return out.prefix(moved)
    }
}

// MARK: - 共享密码存取(Keychain;绝不进 UserDefaults)

public enum NetSyncKeychain {
    static let service = "local.dittomac.netsync"
    static let account = "shared-password"

    private static func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// 保存(不存在则新增,存在则更新)。成功 true
    @discardableResult
    public static func savePassword(_ password: String) -> Bool {
        guard !password.isEmpty else { return false }
        let data = Data(password.utf8)
        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = data
        var status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: data]
            status = SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary)
        }
        return status == errSecSuccess
    }

    /// 读取;未设置/出错 → nil
    public static func loadPassword() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 删除;不存在也算成功(幂等)
    @discardableResult
    public static func deletePassword() -> Bool {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

// MARK: - 好友(上游 "send clients" 列表,OptionFriends.cpp 的 Friends 页)

public struct NetSyncFriend: Codable, Equatable, Sendable {
    public var name: String
    public var host: String
    public var port: Int

    public init(name: String, host: String, port: Int) {
        self.name = name
        self.host = host
        self.port = port
    }

    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !host.trimmingCharacters(in: .whitespaces).isEmpty
            && (1...65535).contains(port)
    }
}

// MARK: - 接收服务器(上游 Server.cpp:MTServerThread 的 NWListener 等价)

public final class NetSyncServer {

    /// 收到一条剪贴内容(在 serverQueue 上回调;插入存储由调用方负责 ——
    /// ClipStore 自带串行队列,线程安全)。必须同步完成持久化后返回 true;
    /// false 或未设置回调都表示拒绝,不会向发送方确认成功。
    public var onClip: ((NetSyncHeader, NetSyncClipPayload) -> Bool)?

    private var listener: NWListener?
    private let serverQueue = DispatchQueue(label: "DittoMacKit.NetSyncServer")
    /// 活动的接入连接(强持有防释放:收帧状态机对象无人引用会立刻 dealloc,
    /// 收包回调全部静默丢失);连接结束自摘
    private var liveConnections: [ObjectIdentifier: NetSyncConnection] = [:]
    /// 解密密码(启动时快照;密码变更由上层重启监听器生效)
    private var password: String?
    /// 实际绑定的端口(测试用 0 = 系统分配临时端口;ready 后可读)
    public private(set) var boundPort: UInt16?

    private let queueKey = DispatchSpecificKey<Bool>()

    public init() { serverQueue.setSpecific(key: queueKey, value: true) }

    /// 开始监听。port = 0 → 临时端口;loopbackOnly 将监听限定到 127.0.0.1。
    /// 生产默认监听局域网;成功返回 true,boundPort 更新。
    @discardableResult
    public func start(port: UInt16, password: String?, loopbackOnly: Bool = false) -> Bool {
        stop()
        self.password = (password?.isEmpty == false) ? password : nil
        let nwPort: NWEndpoint.Port = port == 0 ? .any : (NWEndpoint.Port(rawValue: port) ?? .any)
        let parameters = NWParameters.tcp
        if loopbackOnly {
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
        }
        guard let listener = try? NWListener(using: parameters, on: nwPort) else { return false }
        self.listener = listener
        let ready = DispatchSemaphore(value: 0)
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            guard let self, let listener, self.listener === listener else {
                connection.cancel()
                return
            }
            let conn = NetSyncConnection(connection: connection, password: self.password) { [weak self] header, payload in
                self?.onClip?(header, payload) ?? false
            }
            self.liveConnections[ObjectIdentifier(conn)] = conn
            conn.onFinished = { [weak self, weak conn] in
                guard let self, let conn else { return }
                self.liveConnections.removeValue(forKey: ObjectIdentifier(conn))
            }
            conn.start(on: self.serverQueue)
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.start(queue: serverQueue)
        // ready 或失败都放行;失败时 boundPort 保持 nil → 返回 false
        _ = ready.wait(timeout: .now() + 5)
        if case .ready = listener.state, let p = listener.port?.rawValue {
            boundPort = p
            return true
        }
        stop()
        return false
    }

    /// 停止监听并关闭所有接入连接(上游关闭接收 = 关 socket)。
    /// liveConnections 的整理在 serverQueue 上同步做(与连接回调同队列,免竞态)
    public func stop() {
        let closeConnections = {
            self.listener?.cancel()
            self.listener = nil
            self.boundPort = nil
            let connections = Array(self.liveConnections.values)
            self.liveConnections.removeAll()
            connections.forEach { $0.teardown() }
        }
        if DispatchQueue.getSpecific(key: queueKey) == true {
            closeConnections()
        } else {
            serverQueue.sync(execute: closeConnections)
        }
    }

    deinit {
        listener?.cancel()
    }
}

/// 单个接入连接的收帧状态机(上游 ClientThread / RecieveSocket 的等价物):
/// 累积字节 → 逐帧解析 → "clip" 回调 / "exit" 关闭 / malformed 断开。
/// 由 NetSyncServer.liveConnections 强持有,结束时回调 onFinished 自摘
private final class NetSyncConnection {

    private let connection: NWConnection
    private let password: String?
    private let onClip: (NetSyncHeader, NetSyncClipPayload) -> Bool
    /// 连接终结(收到 exit / 对端关闭 / 出错 / 服务器 stop)后回调,供服务器摘除引用
    var onFinished: (() -> Void)?
    private var buffer = Data()
    private var finished = false
    private var responding = false
    private var received = 0
    private var accepted = 0
    private var timeoutWork: DispatchWorkItem?

    init(connection: NWConnection, password: String?,
         onClip: @escaping (NetSyncHeader, NetSyncClipPayload) -> Bool) {
        self.connection = connection
        self.password = password
        self.onClip = onClip
    }

    func start(on queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.receiveNext() }
            if case .failed = state { self?.finish() }
        }
        connection.start(queue: queue)
        let timeout = DispatchWorkItem { [weak self] in self?.finish() }
        timeoutWork = timeout
        queue.asyncAfter(deadline: .now() + 30, execute: timeout)
    }

    deinit { connection.cancel() }

    /// 服务器 stop 时从外部拆除
    func teardown() {
        finish()
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.processBuffer()
            }
            // exit 的 ACK 必须写完后才关闭,即使同一次 receive 也收到 EOF。
            if self.responding { return }
            if self.finished || error != nil || isComplete {
                // 对端关闭 / 出错 / 收到 exit:结束本连接
                if let error, !self.finished {
                    DiagLog.error("netsync: 连接错误 \(error)")
                }
                self.finish()
                return
            }
            self.receiveNext()
        }
    }

    private func processBuffer() {
        while !finished && !responding {
            switch NetSyncFrame.parse(from: buffer, password: password) {
            case .frame(let header, let payload, let consumed):
                buffer = buffer.count == consumed
                    ? Data()
                    : buffer.subdata(in: (buffer.startIndex + consumed)..<buffer.endIndex)
                if header.type == NetSyncHeader.typeExit {
                    guard let request = try? JSONDecoder().decode(NetSyncRequest.self, from: payload),
                          request.count > 0, request.count == received, buffer.isEmpty else { finish(); return }
                    let receipt = NetSyncReceipt(requestID: request.requestID,
                                                 received: received, accepted: accepted)
                    guard let body = try? JSONEncoder().encode(receipt),
                          let ack = NetSyncFrame.encode(
                            header: NetSyncHeader(type: NetSyncHeader.typeAck,
                                                  computerName: "", ip: "", desc: "",
                                                  manualSend: false),
                            payload: body, password: password) else { finish(); return }
                    responding = true
                    connection.send(content: ack, completion: .contentProcessed { [weak self] _ in
                        self?.finish()
                    })
                    return
                }
                guard header.type == NetSyncHeader.typeClip else { finish(); return }
                received += 1
                guard let decoded = try? JSONDecoder().decode(NetSyncClipPayload.self, from: payload),
                      decoded.toRawClip() != nil else {
                    DiagLog.error("netsync: 剪贴内容校验失败")
                    continue
                }
                if onClip(header, decoded) { accepted += 1 }
            case .needMoreData:
                return
            case .malformed:
                // 破损/解密失败:整条连接的数据已不可信,断开(上游 RecieveSocket 失败即断)
                DiagLog.error("netsync: 畸形帧,断开连接")
                finish()
                return
            }
        }
    }

    /// 幂等收尾:关 socket + 自摘(在 serverQueue 上调用,无并发问题)
    private func finish() {
        guard !finished else { return }
        finished = true
        timeoutWork?.cancel()
        timeoutWork = nil
        connection.cancel()
        onFinished?()
    }
}

/// exit 请求与 ACK 使用同一密码封帧。随机请求 ID 将回执绑定到本次发送。
private struct NetSyncRequest: Codable {
    let requestID: UUID
    let count: Int
}

private struct NetSyncReceipt: Codable {
    let requestID: UUID
    let received: Int
    let accepted: Int
}

// MARK: - 发送客户端(上游 Client.cpp / SendSocket 的 NWConnection 等价)

public enum NetSyncClient {

    /// 把若干条剪贴内容发到目标好友:单条连接上依次发 N 个 "clip" 帧 + 一个 "exit" 帧,
    /// 接收方校验且持久化全部条目后返回 ACK 才成功;EOF、复位或部分成功都算失败。
    /// completion 在 completionQueue 上回调(发送本身在调用线程执行,勿在主线程调)
    public static func send(clips: [NetSyncClipPayload], to host: String, port: UInt16,
                            password: String?, computerName: String,
                            completionQueue: DispatchQueue,
                            timeout: TimeInterval = 10,
                            completion: @escaping (_ ok: Bool, _ message: String) -> Void) {
        guard !clips.isEmpty else {
            completionQueue.async { completion(false, "empty selection") }
            return
        }
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            completionQueue.async { completion(false, "bad port \(port)") }
            return
        }
        // 预先编码全部帧(编码失败无需碰网络)。
        // ip 字段留空:发送方本机地址信息量低,接收端需要时可从接入 socket 取对端地址
        var frames = Data()
        for clip in clips {
            guard let payload = try? JSONEncoder().encode(clip),
                  let frame = NetSyncFrame.encode(
                      header: NetSyncHeader(type: NetSyncHeader.typeClip,
                                            computerName: computerName,
                                            ip: "", desc: clip.desc,
                                            manualSend: true),
                      payload: payload, password: password) else {
                completionQueue.async { completion(false, "encode failed") }
                return
            }
            frames.append(frame)
        }
        let request = NetSyncRequest(requestID: UUID(), count: clips.count)
        guard let requestData = try? JSONEncoder().encode(request),
              let exitFrame = NetSyncFrame.encode(
            header: NetSyncHeader(type: NetSyncHeader.typeExit,
                                  computerName: computerName, ip: "",
                                  desc: "", manualSend: true),
            payload: requestData, password: password) else {
            completionQueue.async { completion(false, "encode exit failed") }
            return
        }
        frames.append(exitFrame)

        let connection = NWConnection(host: NWEndpoint.Host(host),
                                       port: endpointPort, using: .tcp)
        let queue = DispatchQueue(label: "DittoMacKit.NetSyncClient")
        let guardOnce = NetSyncOnce()
        var timeoutWork: DispatchWorkItem?
        func finish(_ ok: Bool, _ message: String) {
            guard guardOnce.claim() else { return }
            timeoutWork?.cancel()
            timeoutWork = nil
            connection.stateUpdateHandler = nil
            connection.cancel()
            completionQueue.async { completion(ok, message) }
        }
        // 超时守卫(连接挂死/对端不回包时保证回调必达)
        let deadline = DispatchWorkItem { finish(false, "timeout after \(timeout)s") }
        timeoutWork = deadline
        queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
        var acknowledgement = Data()
        func receiveAck() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, complete, error in
                if let data { acknowledgement.append(data) }
                // ACK 仅有计数与 UUID;限定整个回执,不能按攻击者声明的长度无限累积。
                guard acknowledgement.count <= 16_384 else {
                    finish(false, "oversized acknowledgement"); return
                }
                switch NetSyncFrame.parse(from: acknowledgement, password: password) {
                case .frame(let header, let payload, let consumed):
                    guard header.type == NetSyncHeader.typeAck,
                          consumed == acknowledgement.count,
                          let receipt = try? JSONDecoder().decode(NetSyncReceipt.self, from: payload),
                          receipt.requestID == request.requestID,
                          receipt.received >= 0, receipt.accepted >= 0,
                          receipt.accepted <= receipt.received else {
                        finish(false, "invalid acknowledgement"); return
                    }
                    guard receipt.received == clips.count, receipt.accepted == clips.count else {
                        finish(false, "receiver stored \(receipt.accepted)/\(clips.count) clips"); return
                    }
                    finish(true, "delivered \(receipt.accepted) clips")
                case .malformed:
                    finish(false, "invalid acknowledgement")
                case .needMoreData:
                    guard error == nil, !complete else {
                        finish(false, "connection closed without acknowledgement"); return
                    }
                    receiveAck()
                }
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                sendAll(connection, frames: frames, on: queue) { error in
                    if let error {
                        finish(false, "send error \(error)")
                        return
                    }
                    receiveAck()
                }
            case .failed(let error):
                finish(false, "connect failed \(error)")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private static func sendAll(_ connection: NWConnection, frames: Data,
                                on queue: DispatchQueue,
                                completion: @escaping (Error?) -> Void) {
        connection.send(content: frames, completion: .contentProcessed { error in
            completion(error)
        })
    }
}

/// 一次性原子标志(发送完成/超时/失败只回调一次)
final class NetSyncOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

// MARK: - 设置键与好友持久化(UserDefaults;密码除外 —— 密码只进 Keychain)

public extension DittoSettings {
    /// 监听端口(上游 SendRecvPort,默认 23443,Options.cpp:1475)
    static let netPortKey = "ditto.net.port"
    /// 接收开关(上游 DisableRecieve 的反向;默认关 —— 隐私优先)
    static let netReceiveEnabledKey = "ditto.net.receiveEnabled"
    /// 好友列表(JSON 数组 {name, host, port};上游 Friends 页的 send clients)
    static let netFriendsKey = "ditto.net.friends"
    /// 收到的条目落入的组 id(可选"接收组";-1 = 顶层)
    static let netReceiveGroupIDKey = "ditto.net.receiveGroupID"

    static let defaultNetPort = 23443

    static func netPort() -> Int {
        let value = defaults.integer(forKey: netPortKey)
        return (1...65535).contains(value) ? value : defaultNetPort
    }

    static func setNetPort(_ value: Int) {
        defaults.set(min(max(value, 1), 65535), forKey: netPortKey)
    }

    /// 接收开关(默认关:object 判默认,与 includeGroupClips 同款)
    static func netReceiveEnabled() -> Bool {
        defaults.object(forKey: netReceiveEnabledKey) == nil
            ? false
            : defaults.bool(forKey: netReceiveEnabledKey)
    }

    static func setNetReceiveEnabled(_ on: Bool) {
        defaults.set(on, forKey: netReceiveEnabledKey)
    }

    /// 接收组(默认顶层 -1;组被删后由调用方回落顶层 —— store.insert 对不存在的
    /// parentID 会照写,读取时组内条目不显示在顶层,故设置端删组时须清此键)
    static func netReceiveGroupID() -> Int64 {
        let value = defaults.integer(forKey: netReceiveGroupIDKey)
        return value > 0 ? Int64(value) : -1
    }

    static func setNetReceiveGroupID(_ id: Int64) {
        defaults.set(id > 0 ? Int(id) : -1, forKey: netReceiveGroupIDKey)
    }

    /// 好友列表读取(JSON 解析失败安全退化为空表,不崩)
    static func loadNetFriends() -> [NetSyncFriend] {
        guard let data = defaults.data(forKey: netFriendsKey) else { return [] }
        return (try? JSONDecoder().decode([NetSyncFriend].self, from: data)) ?? []
    }

    static func saveNetFriends(_ friends: [NetSyncFriend]) {
        guard let data = try? JSONEncoder().encode(friends) else { return }
        defaults.set(data, forKey: netFriendsKey)
    }
}
