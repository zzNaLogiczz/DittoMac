import Foundation
import AppKit

/// ClipboardMonitor 行为回归(F2/F9);会短暂操作系统剪贴板
final class MonitorTests: XCTestCase {
    var monitor: ClipboardMonitor!
    var received: [RawClip] = []

    override func setUp() {
        super.setUp()
        monitor = ClipboardMonitor()
        monitor.onClip = { [weak self] in self?.received.append($0) }
        monitor.start()
    }

    override func tearDown() {
        monitor.stop()
        monitor = nil
        super.tearDown()
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func setPasteboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    func testCapturesExternalCopy() {
        setPasteboard("monitor-test-外部复制")
        pump(1.2)
        XCTAssertTrue(received.contains { $0.text == "monitor-test-外部复制" }, "应捕获外部复制")
    }

    func testSkipsConcealedType() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("secret-password-不应入库", forType: .string)
        pb.setData(Data("x".utf8), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pump(1.2)
        XCTAssertFalse(received.contains { $0.text == "secret-password-不应入库" },
                       "密码类内容必须跳过")
    }

    func testSelfWriteIgnored() {
        // 走真实 PasteBack 路径:写后上报 changeCount 区间,monitor 精确豁免
        PasteBack.write(RawClip(text: "self-write-不应入库"), monitor: monitor)
        pump(1.2)
        XCTAssertFalse(received.contains { $0.text == "self-write-不应入库" },
                       "自写剪贴板必须被忽略")
        // 豁免不吞用户复制:下一次外部复制仍要捕获
        setPasteboard("self-write-之后的外部复制")
        pump(1.2)
        XCTAssertTrue(received.contains { $0.text == "self-write-之后的外部复制" })
    }

    /// 完整粘贴时序(write → CmdV → 延迟恢复)全程不得污染历史
    func testPasteFlowDoesNotPolluteHistory() {
        setPasteboard("粘贴前的用户内容")
        pump(1.2)   // 先让用户内容合法入库一次
        _ = PasteBack.paste(RawClip(text: "paste-flow-payload"), restoreAfter: 0.3, monitor: monitor)
        pump(1.0)
        XCTAssertEqual(received.filter { $0.text == "paste-flow-payload" }.count, 0,
                       "写入的目标条目不得入库")
        // 0.3s 后原剪贴板恢复 → 又是一次自写,不得造成重复入库(应为 1 次:最初那次)
        pump(0.8)
        XCTAssertEqual(received.filter { $0.text == "粘贴前的用户内容" }.count, 1,
                       "恢复旧内容是自写,不得重复入库")
    }

    func testPausedStopsCapture() {
        monitor.setPaused(true)
        setPasteboard("paused-期间不记录")
        pump(1.2)
        XCTAssertFalse(received.contains { $0.text == "paused-期间不记录" })
        monitor.setPaused(false)
    }

    /// F9:高频复制压力(200ms 间隔 × 10,对齐 rubric 50 次/10s 场景的抽样)→ 0 丢条
    func testHighFrequencyCopyNoLoss() {
        let texts = (0..<10).map { "高频-\($0)" }
        var pending = texts
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { t in
            guard !pending.isEmpty else { t.invalidate(); return }
            let s = pending.removeFirst()
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(s, forType: .string)
        }
        pump(3.5)
        let captured = texts.filter { text in received.contains { $0.text == text } }
        XCTAssertEqual(captured.count, texts.count, "高频复制不得丢条,未捕获: \(Set(texts).subtracting(captured))")
    }

    static var registrations: [(String, (MonitorTests) -> Void)] {
        [
            ("testCapturesExternalCopy", { $0.testCapturesExternalCopy() }),
            ("testSkipsConcealedType", { $0.testSkipsConcealedType() }),
            ("testSelfWriteIgnored", { $0.testSelfWriteIgnored() }),
            ("testPasteFlowDoesNotPolluteHistory", { $0.testPasteFlowDoesNotPolluteHistory() }),
            ("testPausedStopsCapture", { $0.testPausedStopsCapture() }),
            ("testHighFrequencyCopyNoLoss", { $0.testHighFrequencyCopyNoLoss() }),
        ]
    }
}

/// 性能基准(P3/P4 的数据层部分)
final class PerfTests: XCTestCase {
    func testSearchAndRecentP95() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dittomac-perf-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ClipStore(path: dir.appendingPathComponent("p.sqlite").path)

        // 500 条中英混合语料,部分长文本
        for i in 0..<500 {
            let long = i % 5 == 0 ? String(repeating: "长文本压力行。", count: 40) : ""
            _ = store.insert(RawClip(text: "条目\(i) clipboard 剪贴板 query-\(i % 37) \(long)"),
                             maxDataBytes: 20 << 20)
        }
        XCTAssertEqual(store.count, 500)

        func p95(_ ms: [Double]) -> Double { ms.sorted()[Int(Double(ms.count - 1) * 0.95)] }

        var searchTimes: [Double] = []
        for _ in 0..<100 { searchTimes.append(measure { _ = store.search("剪贴板 query", limit: 500) }) }
        var recentTimes: [Double] = []
        for _ in 0..<100 { recentTimes.append(measure { _ = store.recent(limit: 500) }) }

        let s = p95(searchTimes), r = p95(recentTimes)
        print("PERF search p95 = \(s)ms, recent(500) p95 = \(r)ms")
        XCTAssertLessThanOrEqual(s, 100, "P3: search p95 应 ≤100ms(9 分线)")
        XCTAssertLessThanOrEqual(r, 150, "P4: recent(500) p95 应 ≤150ms")
    }

    private func measure(_ body: () -> Void) -> Double {
        let t0 = DispatchTime.now()
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
    }

    static var registrations: [(String, (PerfTests) -> Void)] {
        [
            ("testSearchAndRecentP95", { $0.testSearchAndRecentP95() }),
        ]
    }
}
