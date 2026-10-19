import Foundation

// 轻量 XCTest 替身:CLT 无 XCTest.framework,用同名断言 API + 显式注册的 runner
open class XCTestCase {
    public required init() {}
    open func setUp() {}
    open func tearDown() {}
    var _failures = 0
    var _ran = 0
}

enum MiniTest {
    static var current: XCTestCase?
    static var currentName = ""
    static var totalFailures = 0
    static var totalCases = 0
}

private func record(_ cond: Bool, _ msg: String, file: StaticString, line: UInt) {
    if cond { return }
    MiniTest.totalFailures += 1
    MiniTest.current?._failures += 1
    print("  ❌ [\(MiniTest.currentName)] \(file):\(line) \(msg)")
}

public func XCTAssertEqual<T: Equatable>(_ a: T?, _ b: T?, _ message: String = "",
                                         file: StaticString = #fileID, line: UInt = #line) {
    record(a == b, "assertEqual: \(String(describing: a)) != \(String(describing: b)) \(message)",
           file: file, line: line)
}

public func XCTAssertTrue(_ cond: Bool, _ message: String = "",
                          file: StaticString = #fileID, line: UInt = #line) {
    record(cond, "assertTrue: \(message)", file: file, line: line)
}

public func XCTAssertFalse(_ cond: Bool, _ message: String = "",
                           file: StaticString = #fileID, line: UInt = #line) {
    record(!cond, "assertFalse: \(message)", file: file, line: line)
}

public func XCTAssertNotNil(_ v: Any?, _ message: String = "",
                            file: StaticString = #fileID, line: UInt = #line) {
    record(v != nil, "assertNotNil: \(message)", file: file, line: line)
}

public func XCTAssertNil(_ v: Any?, _ message: String = "",
                         file: StaticString = #fileID, line: UInt = #line) {
    record(v == nil, "assertNil: \(message)", file: file, line: line)
}

public func XCTAssertLessThanOrEqual<T: Comparable>(_ a: T, _ b: T, _ message: String = "",
                                                    file: StaticString = #fileID, line: UInt = #line) {
    record(a <= b, "assertLessThanOrEqual: \(a) > \(b) \(message)", file: file, line: line)
}

/// 浮点近似断言(Wave4:透明度 alpha / 行高等浮点纯函数)
public func XCTAssertEqual<T: FloatingPoint>(_ a: T, _ b: T, accuracy: T, _ message: String = "",
                                             file: StaticString = #fileID, line: UInt = #line) {
    record(abs(a - b) <= abs(accuracy),
           "assertEqual(accuracy): \(a) != \(b) ± \(accuracy) \(message)",
           file: file, line: line)
}

public func XCTAssertGreaterThan<T: Comparable>(_ a: T, _ b: T, _ message: String = "",
                                                file: StaticString = #fileID, line: UInt = #line) {
    record(a > b, "assertGreaterThan: \(a) <= \(b) \(message)", file: file, line: line)
}

public func XCTAssertNotEqual<T: Equatable>(_ a: T?, _ b: T?, _ message: String = "",
                                            file: StaticString = #fileID, line: UInt = #line) {
    record(a != b, "assertNotEqual: \(String(describing: a)) == \(String(describing: b)) \(message)",
           file: file, line: line)
}

public func XCTFail(_ message: String = "", file: StaticString = #fileID, line: UInt = #line) {
    record(false, "fail: \(message)", file: file, line: line)
}
