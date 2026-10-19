import AppKit
import Foundation
import Network

/// 网络同步(原版 LAN CLIP SYNC:Server.cpp TCP + Friends 发送)——
/// 帧编解码 / AES 加密 / zlib 载荷 / 环回集成(仅 localhost,临时端口防 CI 冲突)/
/// 好友持久化 / Keychain 密码
final class NetSyncTests: XCTestCase {

    private func makeHeader(type: String = NetSyncHeader.typeClip) -> NetSyncHeader {
        NetSyncHeader(type: type, computerName: "MacBook-Pro", ip: "192.168.1.8",
                      desc: "测试描述 desc", manualSend: true, respondPort: 23443,
                      version: 1)
    }

    private func makePayload() -> NetSyncClipPayload {
        let rtf = Data("{\\rtf1}".utf8)
        return NetSyncClipPayload(desc: "clip 一", appName: "Safari",
                           sentAt: Date(timeIntervalSince1970: 1_700_000_000),
                           formats: [NetSyncFormat(type: ClipUTI.rtf,
                                                   data: ZlibCodec.compress(rtf)!,
                                                   size: rtf.count)],
                           text: "hello 局域网", filePaths: nil)
    }

    // MARK: - 帧编解码(明文)

    func testFrameCodecRoundtrip() {
        let header = makeHeader()
        let payload = Data("payload-字节-0123".utf8)
        guard let frame = NetSyncFrame.encode(header: header, payload: payload, password: nil) else {
            XCTFail("明文帧编码失败"); return
        }
        // 布局:魔数 5 + 模式字节 'P' + 头长度 u32 LE + 头 JSON + 载荷长度 u64 LE + 载荷
        XCTAssertEqual(String(data: frame.prefix(5), encoding: .utf8), "DITTO", "魔数")
        XCTAssertEqual(frame[frame.startIndex + 5], UInt8(ascii: "P"), "明文模式字节")
        let fixedBytes: Int = 5 + 1 + 4 + 8
        XCTAssertGreaterThan(frame.count, fixedBytes + payload.count, "头 JSON 占中间段")

        guard case .frame(let parsed, let body, let consumed) =
                NetSyncFrame.parse(from: frame, password: nil) else {
            XCTFail("明文帧应可解析"); return
        }
        XCTAssertEqual(parsed, header, "头字段逐项还原(CSendInfo 等价物)")
        XCTAssertEqual(body, payload, "载荷字节一致")
        XCTAssertEqual(consumed, frame.count, "整帧恰好消费")
        XCTAssertEqual(parsed.version, 1, "版本 = 1(上游 m_nVersion)")
        XCTAssertEqual(parsed.encrypted, false, "明文帧头带 encrypted=false 标志")
    }

    /// 多帧连发(一次连接多条剪贴内容):逐帧解析 consumed 推进,顺序保持
    func testMultiFrameParsing() {
        var stream = Data()
        for i in 0..<3 {
            var h = makeHeader()
            h.desc = "clip-\(i)"
            let p = Data("body-\(i)".utf8)
            stream.append(NetSyncFrame.encode(header: h, payload: p, password: nil)!)
        }
        var buffer = stream
        var parsedDescs: [String] = []
        var consumedTotal = 0
        while buffer.count > 0 {
            guard case .frame(let h, _, let consumed) = NetSyncFrame.parse(from: buffer, password: nil) else {
                XCTFail("第 \(parsedDescs.count) 帧解析失败"); return
            }
            parsedDescs.append(h.desc)
            consumedTotal += consumed
            buffer = buffer.count == consumed
                ? Data()
                : buffer.subdata(in: (buffer.startIndex + consumed)..<buffer.endIndex)
        }
        XCTAssertEqual(parsedDescs, ["clip-0", "clip-1", "clip-2"], "帧序保持")
        XCTAssertEqual(consumedTotal, stream.count, "无残留字节")
    }

    /// 畸形输入:坏魔数 / 未知模式字节 / 头长度 0 / 头长度超限 / 垃圾 JSON
    func testMalformedRejected() {
        let header = makeHeader()
        let frame = NetSyncFrame.encode(header: header, payload: Data("x".utf8), password: nil)!

        var badMagic = frame
        badMagic[badMagic.startIndex] = UInt8(ascii: "X")
        guard case .malformed = NetSyncFrame.parse(from: badMagic, password: nil) else {
            XCTFail("坏魔数应拒"); return
        }

        var badMode = frame
        badMode[badMode.startIndex + 5] = UInt8(ascii: "Z")
        guard case .malformed = NetSyncFrame.parse(from: badMode, password: nil) else {
            XCTFail("未知模式字节应拒"); return
        }

        // 头长度 = 0:重写长度字段
        var zeroHeader = frame
        zeroHeader.replaceSubrange(6..<10, with: [0, 0, 0, 0])
        guard case .malformed = NetSyncFrame.parse(from: zeroHeader, password: nil) else {
            XCTFail("头长度 0 应拒"); return
        }

        // 头长度超上限(防长度字段损坏后无界缓冲)
        var huge = Data("DITTO".utf8)
        huge.append(UInt8(ascii: "P"))
        let len: UInt32 = UInt32(NetSyncFrame.maxHeaderBytes + 1)
        withUnsafeBytes(of: len.littleEndian) { huge.append(contentsOf: $0) }
        guard case .malformed = NetSyncFrame.parse(from: huge, password: nil) else {
            XCTFail("超限头长度应拒"); return
        }

        // 长度合法但头是垃圾字节(JSON 解不出)
        var junk = Data("DITTO".utf8)
        junk.append(UInt8(ascii: "P"))
        withUnsafeBytes(of: UInt32(8).littleEndian) { junk.append(contentsOf: $0) }
        junk.append(Data("not json".utf8))
        withUnsafeBytes(of: UInt64(2).littleEndian) { junk.append(contentsOf: $0) }
        junk.append(Data("ab".utf8))
        guard case .malformed = NetSyncFrame.parse(from: junk, password: nil) else {
            XCTFail("垃圾 JSON 头应拒"); return
        }
    }

    /// 截断:完整帧的任意真前缀 → needMoreData(不误报帧,也不当畸形)
    func testTruncatedRejected() {
        let frame = NetSyncFrame.encode(header: makeHeader(),
                                        payload: Data(repeating: 7, count: 64),
                                        password: nil)!
        for cut in [1, 5, 6, 9, frame.count / 2, frame.count - 1] {
            guard case .needMoreData = NetSyncFrame.parse(from: frame.prefix(cut), password: nil) else {
                XCTFail("截断到 \(cut) 字节应等待更多数据"); return
            }
        }
        // 载荷长度声明超上限 → malformed(长度字段损坏的守卫)
        var oversize = frame
        oversize.replaceSubrange((oversize.count - 64 - 8)..<(oversize.count - 64),
                                 with: Data(repeating: 0xFF, count: 8))
        guard case .malformed = NetSyncFrame.parse(from: oversize, password: nil) else {
            XCTFail("载荷长度超限应拒"); return
        }
    }

    // MARK: - 传输加密(AES-256-CBC,SHA-256 派生密钥)

    func testCryptoRoundtrip() {
        let key = NetSyncCrypto.key(from: "共享密码 pw")
        XCTAssertNotNil(key)
        XCTAssertEqual(key!.count, 32, "SHA-256 → 32 字节 AES-256 密钥")
        // 确定性派生:同密码同密钥
        XCTAssertEqual(key, NetSyncCrypto.key(from: "共享密码 pw"))
        XCTAssertNil(NetSyncCrypto.key(from: ""), "空密码不进入加密模式")

        let plain = Data("剪贴板秘密内容 0123456789".utf8)
        guard let blob = NetSyncCrypto.encrypt(plain, key: key!) else {
            XCTFail("加密失败"); return
        }
        XCTAssertGreaterThan(blob.count, 16, "IV + 至少一个密文块")
        XCTAssertEqual(NetSyncCrypto.decrypt(blob, key: key!), plain, "正确密码往返")

        // 随机 IV:同明文两次加密密文不同
        let blob2 = NetSyncCrypto.encrypt(plain, key: key!)!
        XCTAssertNotEqual(blob, blob2, "随机 IV 应产生不同密文")

        // 错误密码:CBC 填充校验大概率直接失败;极小概率解出乱码 —— 两种都算"干净失败"
        let wrong = NetSyncCrypto.key(from: "错误密码")!
        if let garbage = NetSyncCrypto.decrypt(blob, key: wrong) {
            XCTAssertNotEqual(garbage, plain, "错误密码绝不能还原明文")
        }
        // 长度不足(< IV+1 块)→ nil
        XCTAssertNil(NetSyncCrypto.decrypt(Data(repeating: 1, count: 15), key: key!))
        // 空密钥拒用
        XCTAssertNil(NetSyncCrypto.encrypt(plain, key: Data(repeating: 0, count: 16)))
    }

    /// 加密帧:对密码可解;错密码/无密码 → malformed;接收端有密码却收明文帧 → 拒收
    func testEncryptedFrameRoundtrip() {
        let frame = NetSyncFrame.encode(header: makeHeader(),
                                        payload: Data("secret".utf8),
                                        password: "pw-甲")!
        XCTAssertEqual(frame[frame.startIndex + 5], UInt8(ascii: "E"), "加密模式字节")
        XCTAssertTrue(String(data: frame.suffix(frame.count - 6), encoding: .utf8)?.contains("computerName") != true,
                      "加密后头字段不应以明文出现")

        guard case .frame(let h, let p, _) = NetSyncFrame.parse(from: frame, password: "pw-甲") else {
            XCTFail("正确密码应解出帧"); return
        }
        XCTAssertEqual(h.computerName, "MacBook-Pro")
        XCTAssertEqual(p, Data("secret".utf8))

        guard case .malformed = NetSyncFrame.parse(from: frame, password: "pw-乙") else {
            XCTFail("错误密码应干净拒绝"); return
        }
        guard case .malformed = NetSyncFrame.parse(from: frame, password: nil) else {
            XCTFail("无密码收到密文帧应拒绝"); return
        }
        // 降级防护:接收端设了密码却来明文帧 → 拒收
        let plain = NetSyncFrame.encode(header: makeHeader(),
                                        payload: Data(), password: nil)!
        guard case .malformed = NetSyncFrame.parse(from: plain, password: "pw-甲") else {
            XCTFail("设密码的接收端应拒明文帧"); return
        }
    }

    // MARK: - 载荷(RawClip ↔ zlib formats JSON)

    func testPayloadRoundtrip() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4, 5, 6, 7, 8, 9])
        let rtf = Data("{\\rtf1\\ansi 富文本}".utf8)
        let pdf = Data("%PDF-1.4 附加格式".utf8)
        let raw = RawClip(text: "文本 内容", rtfData: rtf, htmlData: nil,
                          imageData: png, filePaths: ["/Users/a/文件 1.png", "/tmp/b.txt"],
                          extraFormats: [ClipFormat(type: "com.microsoft.pdf", data: pdf)],
                          appName: "来源应用")
        guard let payload = NetSyncClipPayload.from(raw: raw) else {
            XCTFail("非空条目应可打包"); return
        }
        // formats 是 zlib 压缩(短串可能反而略长,以"可解回 + 带原始长度"为准)
        let rtfEntry = payload.formats.first { $0.type == ClipUTI.rtf }
        XCTAssertNotNil(rtfEntry)
        XCTAssertEqual(rtfEntry?.size, rtf.count, "size = 压缩前长度(上游 lOriginalSize)")
        XCTAssertEqual(ZlibCodec.decompress(rtfEntry!.data, originalSize: rtf.count), rtf)
        XCTAssertEqual(payload.text, "文本 内容", "text 字段直通")
        XCTAssertEqual(payload.filePaths, raw.filePaths, "filePaths 字段直通")

        guard let restored = payload.toRawClip() else {
            XCTFail("载荷应可还原"); return
        }
        XCTAssertEqual(restored.text, raw.text)
        XCTAssertEqual(restored.rtfData, rtf, "RTF 经 zlib 往返无损")
        XCTAssertEqual(restored.imageData, png, "PNG(按 png UTI)往返无损")
        XCTAssertEqual(restored.filePaths, raw.filePaths)
        XCTAssertEqual(restored.extraFormats, [ClipFormat(type: "com.microsoft.pdf", data: pdf)],
                       "未知名按 UTI 原样保留")

        // 空条目 → 不可发送;纯文本条目 formats 为空但 text 有值 → 仍可还原
        XCTAssertNil(NetSyncClipPayload.from(raw: RawClip()))
        let textOnly = NetSyncClipPayload.from(raw: RawClip(text: "仅文本"))!
        XCTAssertEqual(textOnly.toRawClip()?.text, "仅文本")

        // 坏 zlib 数据 → 整帧拒绝(不落半截内容)
        var corrupt = textOnly
        corrupt.formats = [NetSyncFormat(type: ClipUTI.rtf, data: Data(repeating: 9, count: 16), size: 4096)]
        XCTAssertNil(corrupt.toRawClip(), "解压失败应整体拒绝")
    }

    // MARK: - 环回集成(localhost + 临时端口)

    /// 线程安全的接收记录盒
    private final class ReceivedBox: @unchecked Sendable {
        let lock = NSLock()
        private var items: [(NetSyncHeader, NetSyncClipPayload)] = []
        private let signal = DispatchSemaphore(value: 0)
        func append(_ h: NetSyncHeader, _ p: NetSyncClipPayload) {
            lock.lock(); items.append((h, p)); lock.unlock()
            signal.signal()
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
        var first: (NetSyncHeader, NetSyncClipPayload)? {
            lock.lock(); defer { lock.unlock() }; return items.first
        }
        /// 等到收满 n 条(超时 false)
        func waitfor(_ n: Int, timeout: TimeInterval) -> Bool {
            for _ in 0..<n where signal.wait(timeout: .now() + timeout) == .timedOut { return false }
            return count >= n
        }
    }

    /// 同步发送助手(后台队列跑 + 信号量等完成,全部带超时守卫)
    private func sendSync(_ clips: [NetSyncClipPayload], host: String, port: UInt16,
                          password: String?, timeout: TimeInterval = 3) -> (Bool, String) {
        let done = DispatchSemaphore(value: 0)
        var result: (Bool, String) = (false, "not-run")
        DispatchQueue.global().async {
            NetSyncClient.send(clips: clips, to: host, port: port, password: password,
                               computerName: "test-host", completionQueue: .global(), timeout: timeout) { ok, msg in
                result = (ok, msg)
                done.signal()
            }
        }
        XCTAssertTrue(done.wait(timeout: .now() + 15) != .timedOut, "发送必须在超时内完成")
        return result
    }

    /// 明文环回:临时端口起服务 → 客户端连发 2 条 → 服务端按帧收到且内容一致
    func testServerLoopbackPlaintext() {
        let server = NetSyncServer()
        let box = ReceivedBox()
        server.onClip = { box.append($0, $1); return true }
        XCTAssertTrue(server.start(port: 0, password: nil, loopbackOnly: true), "临时端口监听应成功")
        let port = server.boundPort
        XCTAssertNotNil(port)
        XCTAssertNotEqual(port, 23443, "临时端口避开默认口,防 CI 冲突")

        let clip1 = makePayload()
        var clip2 = makePayload()
        clip2.text = "第二条 clip"
        let (ok, message) = sendSync([clip1, clip2], host: "127.0.0.1", port: port!, password: nil)
        XCTAssertTrue(ok, "发送应成功: \(message)")

        XCTAssertTrue(box.waitfor(2, timeout: 5), "应收满 2 条(实际 \(box.count))")
        XCTAssertEqual(box.count, 2)
        XCTAssertEqual(box.first?.0.computerName, "test-host", "头带发送方机器名")
        XCTAssertEqual(box.first?.1.text, "hello 局域网")
        XCTAssertEqual(box.first?.1.formats.first?.type, ClipUTI.rtf)

        // 收到的载荷应能还原为可入库的 RawClip(接收管线口径)
        let raw = box.first?.1.toRawClip()
        XCTAssertNotNil(raw)
        XCTAssertEqual(raw?.text, "hello 局域网")
        server.stop()
    }

    /// 加密环回:双方同密码 → 正常收;服务端错密码 → 一条都不收
    func testServerLoopbackEncrypted() {
        let server = NetSyncServer()
        let box = ReceivedBox()
        server.onClip = { box.append($0, $1); return true }
        XCTAssertTrue(server.start(port: 0, password: "loop-secret", loopbackOnly: true))
        let port = server.boundPort!

        let (ok, message) = sendSync([makePayload()], host: "127.0.0.1", port: port,
                                     password: "loop-secret")
        XCTAssertTrue(ok, "同密码发送应成功: \(message)")
        XCTAssertTrue(box.waitfor(1, timeout: 5))
        XCTAssertEqual(box.count, 1, "同密码应收到 1 条")
        server.stop()

        // 错密码:服务端无法验证帧,没有 ACK → 发送必须失败
        let server2 = NetSyncServer()
        let box2 = ReceivedBox()
        server2.onClip = { box2.append($0, $1); return true }
        XCTAssertTrue(server2.start(port: 0, password: "right-pw", loopbackOnly: true))
        let port2 = server2.boundPort!
        let (ok2, _) = sendSync([makePayload()], host: "127.0.0.1", port: port2,
                                password: "wrong-pw")
        XCTAssertFalse(ok2, "错密码没有持久化 ACK,不能显示发送成功")
        XCTAssertEqual(box2.waitfor(1, timeout: 0.8), false, "错密码不应有任何交付")
        XCTAssertEqual(box2.count, 0)
        server2.stop()
    }

    /// 接收关闭(默认 OFF):stop 后端口不再监听,发送失败(连接被拒)
    func testReceiveToggleStopsListener() {
        XCTAssertFalse(NetSyncTests.receiveEnabledDefaultProbe(), "接收默认关(隐私优先)")
        let server = NetSyncServer()
        XCTAssertTrue(server.start(port: 0, password: nil, loopbackOnly: true))
        let port = server.boundPort!
        server.stop()   // 上游关闭接收 = 关 socket
        let (ok, _) = sendSync([makePayload()], host: "127.0.0.1", port: port, password: nil)
        XCTAssertFalse(ok, "停止后连接应被拒绝")
    }

    /// ACK 必须晚于真实落库;失败条目不得被计为送达。
    func testAcknowledgementRequiresPersistence() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("netsync-store-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipStore(path: directory.appendingPathComponent("clips.sqlite").path)
        let server = NetSyncServer()
        defer { server.stop() }
        server.onClip = { _, payload in
            guard let raw = payload.toRawClip() else { return false }
            return store.insert(raw, maxDataBytes: 100) != nil
        }
        XCTAssertTrue(server.start(port: 0, password: "persist", loopbackOnly: true))
        guard let port = server.boundPort else { XCTFail("listener failed"); return }
        let first = NetSyncClipPayload.from(raw: RawClip(text: "first"))!
        let second = NetSyncClipPayload.from(raw: RawClip(text: "second"))!
        let (ok, _) = sendSync([first, second], host: "127.0.0.1", port: port, password: "persist")
        XCTAssertTrue(ok)
        XCTAssertEqual(store.count, 2, "成功回调时两条已落库")
        let oversized = NetSyncClipPayload.from(raw: RawClip(text: String(repeating: "x", count: 200)))!
        let third = NetSyncClipPayload.from(raw: RawClip(text: "third"))!
        let (partial, message) = sendSync([third, oversized], host: "127.0.0.1", port: port, password: "persist")
        XCTAssertFalse(partial, "部分成功不能显示全部成功")
        XCTAssertTrue(message.contains("1/2"), message)
        XCTAssertEqual(store.count, 3, "仅允许成功的一条入库")
        let (rejected, rejectedMessage) = sendSync([oversized], host: "127.0.0.1", port: port, password: "persist")
        XCTAssertFalse(rejected)
        XCTAssertTrue(rejectedMessage.contains("0/1"), rejectedMessage)
    }

    func testInvalidPayloadAndMissingPersistenceAreRejected() {
        let server = NetSyncServer()
        let box = ReceivedBox()
        defer { server.stop() }
        server.onClip = { box.append($0, $1); return true }
        XCTAssertTrue(server.start(port: 0, password: nil, loopbackOnly: true))
        guard let port = server.boundPort else { XCTFail("listener failed"); return }
        var invalid = makePayload()
        invalid.formats[0].data = Data(repeating: 9, count: 20)
        let (ok, message) = sendSync([invalid], host: "127.0.0.1", port: port, password: nil)
        XCTAssertFalse(ok)
        XCTAssertTrue(message.contains("0/1"), message)
        XCTAssertEqual(box.count, 0, "解压失败必须在持久化回调前拒绝")
        server.stop()
        server.onClip = nil
        XCTAssertTrue(server.start(port: 0, password: nil, loopbackOnly: true))
        guard let restartedPort = server.boundPort else { XCTFail("listener failed"); return }
        XCTAssertFalse(sendSync([makePayload()], host: "127.0.0.1", port: restartedPort, password: nil).0)
    }

    /// 可控假服务只绑定 127.0.0.1,用于模拟 EOF/无回执/恶意 ACK。
    private func withPeer(_ reply: @escaping (NWConnection, Data) -> Void,
                          client: (UInt16) -> Void) {
        let queue = DispatchQueue(label: "NetSyncTests.peer")
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: parameters) else { XCTFail("listener failed"); return }
        let ready = DispatchSemaphore(value: 0)
        var peers: [NWConnection] = []
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { connection in
            peers.append(connection)
            var buffer = Data()
            func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, done, error in
                    if let data { buffer.append(data) }
                    // 全部帧可能分包;解析到 exit 后才构造回执。
                    while true {
                        guard case .frame(let header, let body, let consumed) =
                                NetSyncFrame.parse(from: buffer, password: "peer-secret") else { break }
                        buffer = Data(buffer.dropFirst(consumed))
                        if header.type == NetSyncHeader.typeExit { reply(connection, body); return }
                    }
                    if !done && error == nil { receive() }
                }
            }
            connection.stateUpdateHandler = { state in
                if case .ready = state { receive() }
            }
            connection.start(queue: queue)
        }
        listener.start(queue: queue)
        XCTAssertTrue(ready.wait(timeout: .now() + 3) == .success)
        guard let port = listener.port?.rawValue else { listener.cancel(); XCTFail("listener failed"); return }
        client(port)
        listener.cancel()
        queue.sync { peers.forEach { $0.cancel() }; peers.removeAll() }
    }

    func testNoAcknowledgementFails() {
        for close in [true, false] {
            withPeer({ connection, _ in
                if close {
                    connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                    completion: .contentProcessed { _ in })
                }
            }, client: { port in
                let (ok, _) = sendSync([makePayload()], host: "127.0.0.1", port: port,
                                       password: "peer-secret", timeout: 0.5)
                XCTAssertFalse(ok, close ? "EOF 不能代替 ACK" : "无 ACK 必须超时失败")
            })
        }
    }

    func testAcknowledgementValidation() {
        // 同一请求 ID 也不能接受明文降级、错密码、假 ID、错误类型、过长或截断回执。
        for mode in ["plain", "wrong-password", "wrong-id", "wrong-type", "wrong-count", "oversize", "truncated"] {
            withPeer({ connection, requestData in
                var receipt = (try? JSONSerialization.jsonObject(with: requestData)) as? [String: Any] ?? [:]
                receipt["received"] = 1
                receipt["accepted"] = 1
                if mode == "wrong-id" { receipt["requestID"] = UUID().uuidString }
                if mode == "wrong-count" { receipt["accepted"] = 0 }
                let payload = try! JSONSerialization.data(withJSONObject: receipt)
                var header = self.makeHeader(type: mode == "wrong-type" ? NetSyncHeader.typeClip : NetSyncHeader.typeAck)
                if mode == "oversize" { header.desc = String(repeating: "x", count: 20_000) }
                var frame = NetSyncFrame.encode(header: header, payload: payload,
                    password: mode == "plain" ? nil : (mode == "wrong-password" ? "other" : "peer-secret"))!
                if mode == "truncated" { frame = Data(frame.dropLast()) }
                connection.send(content: frame, contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { _ in })
            }, client: { port in
                XCTAssertFalse(sendSync([makePayload()], host: "127.0.0.1", port: port,
                                         password: "peer-secret").0, mode)
            })
        }
    }

    func testFragmentedAcknowledgementSucceeds() {
        withPeer({ connection, requestData in
            var receipt = (try? JSONSerialization.jsonObject(with: requestData)) as? [String: Any] ?? [:]
            receipt["received"] = 1
            receipt["accepted"] = 1
            let payload = try! JSONSerialization.data(withJSONObject: receipt)
            let frame = NetSyncFrame.encode(header: self.makeHeader(type: NetSyncHeader.typeAck),
                                             payload: payload, password: "peer-secret")!
            connection.send(content: Data(frame.prefix(11)), completion: .contentProcessed { _ in
                connection.send(content: Data(frame.dropFirst(11)), contentContext: .finalMessage,
                                isComplete: true, completion: .contentProcessed { _ in })
            })
        }, client: { port in
            XCTAssertTrue(sendSync([makePayload()], host: "127.0.0.1", port: port,
                                    password: "peer-secret").0)
        })
    }

    func testStopDuringPersistenceDoesNotAcknowledge() {
        let server = NetSyncServer()
        defer { server.stop() }
        server.onClip = { [weak server] _, _ in
            server?.stop()  // 接收队列内停止不能发生 sync 自锁。
            return true
        }
        XCTAssertTrue(server.start(port: 0, password: nil, loopbackOnly: true))
        guard let port = server.boundPort else { XCTFail("listener failed"); return }
        XCTAssertFalse(sendSync([makePayload()], host: "127.0.0.1", port: port, password: nil).0)
        XCTAssertNil(server.boundPort)
    }

    // MARK: - 好友与设置持久化

    func testFriendsPersistence() {
        let suiteName = "netsync-friends-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let original = DittoSettings.defaults
        DittoSettings.defaults = defaults
        defer { DittoSettings.defaults = original }

        // 默认值:端口 23443(上游 Options.cpp:1475)、接收关、无好友、顶层接收组
        XCTAssertEqual(DittoSettings.netPort(), 23443)
        XCTAssertFalse(DittoSettings.netReceiveEnabled())
        XCTAssertEqual(DittoSettings.loadNetFriends(), [])
        XCTAssertEqual(DittoSettings.netReceiveGroupID(), -1)

        // 好友表读写往返
        let friends = [NetSyncFriend(name: "台式机", host: "192.168.1.20", port: 23443),
                       NetSyncFriend(name: "NAS", host: "nas.local", port: 25000)]
        DittoSettings.saveNetFriends(friends)
        XCTAssertEqual(DittoSettings.loadNetFriends(), friends)
        XCTAssertTrue(friends[0].isValid)
        XCTAssertFalse(NetSyncFriend(name: "", host: "h", port: 1).isValid, "空名非法")
        XCTAssertFalse(NetSyncFriend(name: "n", host: "h", port: 0).isValid, "端口越界非法")
        XCTAssertFalse(NetSyncFriend(name: "n", host: " ", port: 80).isValid, "空主机非法")

        // 端口夹取与开关
        DittoSettings.setNetPort(70000)
        XCTAssertEqual(DittoSettings.netPort(), 65535, "端口上限夹取")
        DittoSettings.setNetPort(0)
        XCTAssertEqual(DittoSettings.netPort(), 1, "端口下限夹取")
        DittoSettings.setNetReceiveEnabled(true)
        XCTAssertTrue(DittoSettings.netReceiveEnabled())

        // 损坏数据安全退化:好友 JSON 坏 → 空表不崩
        defaults.set(Data("not-json".utf8), forKey: DittoSettings.netFriendsKey)
        XCTAssertEqual(DittoSettings.loadNetFriends(), [])
    }

    /// Keychain 密码:能写则验证 增/查/改/删 往返;受限环境(无钥匙串权限)
    /// 降级为"读不到密码 = 明文模式",同样是可断言的行为
    func testKeychainPasswordRoundtrip() {
        let saved = NetSyncKeychain.savePassword("k1-密码")
        if saved {
            XCTAssertEqual(NetSyncKeychain.loadPassword(), "k1-密码", "写入后可读回")
            XCTAssertTrue(NetSyncKeychain.savePassword("k2-更新"), "重复保存走更新")
            XCTAssertEqual(NetSyncKeychain.loadPassword(), "k2-更新")
            XCTAssertTrue(NetSyncKeychain.deletePassword(), "删除成功")
            XCTAssertNil(NetSyncKeychain.loadPassword(), "删除后读不到")
            XCTAssertTrue(NetSyncKeychain.deletePassword(), "再删不存在的也幂等成功")
        } else {
            XCTAssertNil(NetSyncKeychain.loadPassword(),
                         "受限环境:写不进钥匙串时读必须为空(降级明文模式)")
        }
    }

    static var registrations: [(String, (NetSyncTests) -> Void)] {
        [
            ("frameCodecRoundtrip", { $0.testFrameCodecRoundtrip() }),
            ("multiFrameParsing", { $0.testMultiFrameParsing() }),
            ("malformedRejected", { $0.testMalformedRejected() }),
            ("truncatedRejected", { $0.testTruncatedRejected() }),
            ("cryptoRoundtrip", { $0.testCryptoRoundtrip() }),
            ("encryptedFrameRoundtrip", { $0.testEncryptedFrameRoundtrip() }),
            ("payloadRoundtrip", { $0.testPayloadRoundtrip() }),
            ("serverLoopbackPlaintext", { $0.testServerLoopbackPlaintext() }),
            ("serverLoopbackEncrypted", { $0.testServerLoopbackEncrypted() }),
            ("receiveToggleStopsListener", { $0.testReceiveToggleStopsListener() }),
            ("acknowledgementRequiresPersistence", { $0.testAcknowledgementRequiresPersistence() }),
            ("invalidPayloadAndMissingPersistenceAreRejected", { $0.testInvalidPayloadAndMissingPersistenceAreRejected() }),
            ("noAcknowledgementFails", { $0.testNoAcknowledgementFails() }),
            ("acknowledgementValidation", { $0.testAcknowledgementValidation() }),
            ("fragmentedAcknowledgementSucceeds", { $0.testFragmentedAcknowledgementSucceeds() }),
            ("stopDuringPersistenceDoesNotAcknowledge", { $0.testStopDuringPersistenceDoesNotAcknowledge() }),
            ("friendsPersistence", { $0.testFriendsPersistence() }),
            ("keychainPasswordRoundtrip", { $0.testKeychainPasswordRoundtrip() }),
        ]
    }
}

/// 接收默认关的探针(隔离 UserDefaults,不动全局)
private extension NetSyncTests {
    static func receiveEnabledDefaultProbe() -> Bool {
        let suiteName = "netsync-probe-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let original = DittoSettings.defaults
        DittoSettings.defaults = defaults
        defer { DittoSettings.defaults = original }
        return DittoSettings.netReceiveEnabled()
    }
}
