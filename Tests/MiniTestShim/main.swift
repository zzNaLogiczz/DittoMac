import Foundation

// 测试入口:各套件显式注册

func runSuite<T: XCTestCase>(_ name: String, _ cls: T.Type,
                             _ regs: [(String, (T) -> Void)]) -> (pass: Int, fail: Int) {
    var pass = 0, fail = 0
    for (testName, method) in regs {
        MiniTest.totalCases += 1
        let instance = cls.init()
        instance.setUp()
        MiniTest.current = instance
        MiniTest.currentName = "\(name)/\(testName)"
        let before = MiniTest.totalFailures
        method(instance)
        instance.tearDown()
        if MiniTest.totalFailures > before {
            fail += 1
            print("📕 \(name)/\(testName)")
        } else {
            pass += 1
            print("✅ \(name)/\(testName)")
        }
    }
    MiniTest.current = nil
    return (pass, fail)
}

var totalPass = 0, totalFail = 0
let suites: [(String, () -> (pass: Int, fail: Int))] = [
    ("ClipStoreTests", { runSuite("ClipStoreTests", ClipStoreTests.self, ClipStoreTests.registrations) }),
    ("GroupTests", { runSuite("GroupTests", GroupTests.self, GroupTests.registrations) }),
    ("Wave2FeatureTests", { runSuite("Wave2FeatureTests", Wave2FeatureTests.self, Wave2FeatureTests.registrations) }),
    ("TextDiffTests", { runSuite("TextDiffTests", TextDiffTests.self, TextDiffTests.registrations) }),
    ("CaptureFilterTests", { runSuite("CaptureFilterTests", CaptureFilterTests.self, CaptureFilterTests.registrations) }),
    ("CopyBufferControllerTests", { runSuite("CopyBufferControllerTests", CopyBufferControllerTests.self, CopyBufferControllerTests.registrations) }),
    ("MonitorTests", { runSuite("MonitorTests", MonitorTests.self, MonitorTests.registrations) }),
    ("PerfTests", { runSuite("PerfTests", PerfTests.self, PerfTests.registrations) }),
    ("SpecialPasteTests", { runSuite("SpecialPasteTests", SpecialPasteTests.self, SpecialPasteTests.registrations) }),
    ("ClipDescriptionTests", { runSuite("ClipDescriptionTests", ClipDescriptionTests.self, ClipDescriptionTests.registrations) }),
    ("L10nTests", { runSuite("L10nTests", L10nTests.self, L10nTests.registrations) }),
    ("Wave3FeatureTests", { runSuite("Wave3FeatureTests", Wave3FeatureTests.self, Wave3FeatureTests.registrations) }),
    ("Wave4FeatureTests", { runSuite("Wave4FeatureTests", Wave4FeatureTests.self, Wave4FeatureTests.registrations) }),
    ("Wave5FeatureTests", { runSuite("Wave5FeatureTests", Wave5FeatureTests.self, Wave5FeatureTests.registrations) }),
    ("NetSyncTests", { runSuite("NetSyncTests", NetSyncTests.self, NetSyncTests.registrations) }),
]
for (name, runner) in suites {
    let (p, f) = runner()
    totalPass += p; totalFail += f
    print("▪ \(name): \(p) 通过 / \(f) 失败")
}

print("")
print("Executed \(MiniTest.totalCases) tests: \(totalPass) passed, \(totalFail) failed, \(MiniTest.totalFailures) assertion failures")
exit(totalFail == 0 ? 0 : 1)
