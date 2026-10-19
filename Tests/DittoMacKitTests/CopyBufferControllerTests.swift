import Foundation
import AppKit

/// Exercises the real capture controller with in-memory clipboard/key IO.
/// No NSPasteboard.general, key synthesis, live settings or GUI access.
final class CopyBufferControllerTests: XCTestCase {
    private var store: ClipStore!
    private var defaultsName = ""
    private var originalDefaults: UserDefaults!

    override func setUp() {
        store = ClipStore(path: ":memory:")
        originalDefaults = DittoSettings.defaults
        defaultsName = "dittomac-copy-buffer-tests-\(UUID().uuidString)"
        DittoSettings.defaults = UserDefaults(suiteName: defaultsName)!
        DittoSettings.defaults.set(true, forKey: DittoSettings.orderLatestOnTopKey)
    }

    override func tearDown() {
        store = nil
        DittoSettings.defaults.removePersistentDomain(forName: defaultsName)
        DittoSettings.defaults = originalDefaults
    }

    private final class IO {
        var keys: [PasteBack.ClipboardKeyKind] = []
        var restoredCounts: [Int] = []
        var soundCount = 0
        var trigger: (() -> Bool)?

        var dependencies: CopyBufferController.CaptureIO {
            .init(snapshot: { .init(items: [], changeCountAtSnapshot: 42) },
                  triggerKey: { kind in
                      self.keys.append(kind)
                      return self.trigger?() ?? true
                  },
                  restore: { self.restoredCounts.append($0.changeCountAtSnapshot) },
                  playSound: { self.soundCount += 1 })
        }
    }

    func testCaptureUsesDeliveredIDAfterManualReorder() {
        let old = store.insert(RawClip(text: "old"), maxDataBytes: 1000)!
        for _ in 0..<10 { store.moveClip(old.id, .toTop) }
        let io = IO()
        let controller = CopyBufferController(store: store, captureIO: io.dependencies)
        controller.handleHotkey(bufferIndex: 1, action: .copy)
        let fresh = store.insert(RawClip(text: "copied now"), maxDataBytes: 1000)!
        XCTAssertEqual(store.newestClip()?.id, old.id, "regression precondition: sort timestamp is in the future")
        XCTAssertNil(store.copyBufferClipID(index: 1), "sorting alone must not complete capture")

        controller.didCapture(clipID: fresh.id, changeCount: 43)
        XCTAssertEqual(store.copyBufferClipID(index: 1), fresh.id)
        XCTAssertFalse(controller.isCapturing)
        XCTAssertEqual(io.keys, [.copy])
        XCTAssertEqual(io.restoredCounts, [42])
    }

    func testDuplicateCaptureAndSynchronousDelivery() {
        let existing = store.insert(RawClip(text: "same"), maxDataBytes: 1000)!
        let io = IO()
        DittoSettings.defaults.set(true, forKey: DittoSettings.copyBufferPlaySoundKey(2))
        let controller = CopyBufferController(store: store, captureIO: io.dependencies)
        io.trigger = { [weak controller] in
            let duplicate = self.store.insert(RawClip(text: "same"), maxDataBytes: 1000)!
            controller?.didCapture(clipID: duplicate.id, changeCount: 43)
            return true
        }
        controller.handleHotkey(bufferIndex: 2, action: .cut)
        XCTAssertEqual(store.copyBufferClipID(index: 2), existing.id)
        XCTAssertFalse(controller.isCapturing)
        XCTAssertEqual(io.keys, [.cut])
        XCTAssertEqual(io.restoredCounts, [42])
        XCTAssertEqual(io.soundCount, 1)
        controller.didCapture(clipID: existing.id, changeCount: 43)
        XCTAssertEqual(io.restoredCounts, [42], "late duplicate notification must not restore twice")
    }

    func testCaptureTimeoutPreservesOldBufferAndIgnoresLateDelivery() {
        let previous = store.insert(RawClip(text: "previous buffer"), maxDataBytes: 1000)!
        store.setCopyBuffer(index: 1, clipID: previous.id)
        let io = IO()
        let controller = CopyBufferController(store: store, captureIO: io.dependencies, captureTimeout: 0.02)
        controller.handleHotkey(bufferIndex: 1, action: .copy)
        controller.handleHotkey(bufferIndex: 2, action: .cut)
        XCTAssertEqual(io.keys, [.copy], "overlapping hotkey must not start a second capture")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(controller.isCapturing)
        XCTAssertEqual(store.copyBufferClipID(index: 1), previous.id)
        XCTAssertEqual(io.restoredCounts, [42])
        let late = store.insert(RawClip(text: "late"), maxDataBytes: 1000)!
        controller.didCapture(clipID: late.id, changeCount: 43)
        XCTAssertEqual(store.copyBufferClipID(index: 1), previous.id)
        XCTAssertEqual(io.restoredCounts, [42])
    }

    func testFailedKeyDispatchDoesNotReplaceBuffer() {
        let previous = store.insert(RawClip(text: "keep"), maxDataBytes: 1000)!
        store.setCopyBuffer(index: 1, clipID: previous.id)
        let io = IO()
        io.trigger = { false }
        let controller = CopyBufferController(store: store, captureIO: io.dependencies, captureTimeout: 0.02)
        controller.handleHotkey(bufferIndex: 1, action: .copy)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(controller.isCapturing)
        XCTAssertEqual(store.copyBufferClipID(index: 1), previous.id)
        XCTAssertTrue(io.restoredCounts.isEmpty, "failed dispatch must not write the clipboard")
    }

    func testUnchangedClipboardDoesNotCompleteCapture() {
        let old = store.insert(RawClip(text: "clipboard at startup"), maxDataBytes: 1000)!
        let io = IO()
        let controller = CopyBufferController(store: store, captureIO: io.dependencies)
        controller.handleHotkey(bufferIndex: 1, action: .copy)
        controller.didCapture(clipID: old.id, changeCount: 42)
        XCTAssertTrue(controller.isCapturing, "startup poll/save-current before clipboard changes is not a copy")
        XCTAssertNil(store.copyBufferClipID(index: 1))
        XCTAssertTrue(io.restoredCounts.isEmpty)
        controller.didCapture(clipID: old.id, changeCount: 43)
        XCTAssertEqual(store.copyBufferClipID(index: 1), old.id, "copying identical content still completes after a clipboard change")
        XCTAssertEqual(io.restoredCounts, [42])
    }

    func testMonitorPipelineUsesCapturedIDAndPasteboardVersion() {
        let pb = NSPasteboard(name: .init("dittomac-capture-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("unchanged startup clipboard", forType: .string)
        let baseline = pb.changeCount
        let monitor = ClipboardMonitor(pasteboard: pb)
        monitor.typesWhitelistProvider = { [ClipUTI.text] }
        let future = store.insert(RawClip(text: "old sorted clip"), maxDataBytes: 1000)!
        for _ in 0..<10 { store.moveClip(future.id, .toTop) }
        var restored = 0
        var deliveredID: Int64?
        let controller = CopyBufferController(store: store, captureIO: .init(
            snapshot: { .init(items: [], changeCountAtSnapshot: baseline) },
            triggerKey: { _ in
                XCTAssertTrue(monitor.captureNow())
                XCTAssertNil(self.store.copyBufferClipID(index: 1), "unchanged clipboard must not complete capture")
                pb.clearContents()
                pb.setString("actual new copy", forType: .string)
                return monitor.captureNow()
            },
            restore: { _ in restored += 1 },
            playSound: { XCTFail("sound disabled") }
        ))
        monitor.onClip = { [weak controller] raw in
            guard let inserted = self.store.insert(raw, maxDataBytes: 1000) else { return }
            deliveredID = inserted.id
            controller?.didCapture(clipID: inserted.id, changeCount: monitor.lastCaptureChangeCount)
        }
        defer { monitor.onClip = nil }
        controller.handleHotkey(bufferIndex: 1, action: .copy)
        XCTAssertEqual(store.copyBufferClipID(index: 1), deliveredID)
        XCTAssertNotEqual(deliveredID, future.id)
        XCTAssertEqual(store.payload(id: deliveredID!)?.text, "actual new copy")
        XCTAssertEqual(restored, 1)
        XCTAssertFalse(controller.isCapturing)
    }

    static var registrations: [(String, (CopyBufferControllerTests) -> Void)] {
        [
            ("captureUsesDeliveredIDAfterManualReorder", { $0.testCaptureUsesDeliveredIDAfterManualReorder() }),
            ("duplicateCaptureAndSynchronousDelivery", { $0.testDuplicateCaptureAndSynchronousDelivery() }),
            ("captureTimeoutPreservesOldBufferAndIgnoresLateDelivery", { $0.testCaptureTimeoutPreservesOldBufferAndIgnoresLateDelivery() }),
            ("failedKeyDispatchDoesNotReplaceBuffer", { $0.testFailedKeyDispatchDoesNotReplaceBuffer() }),
            ("unchangedClipboardDoesNotCompleteCapture", { $0.testUnchangedClipboardDoesNotCompleteCapture() }),
            ("monitorPipelineUsesCapturedIDAndPasteboardVersion", { $0.testMonitorPipelineUsesCapturedIDAndPasteboardVersion() }),
        ]
    }
}
