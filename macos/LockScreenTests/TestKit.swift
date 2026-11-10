import Foundation

// 최소 테스트 러너 (Xcode/XCTest 없이 swiftc 로 빌드)
nonisolated(unsafe) var testFailures = 0
nonisolated(unsafe) var testCount = 0
nonisolated(unsafe) var currentTestFailed = false

func expect(_ cond: Bool, _ msg: String, file: String = #fileID, line: Int = #line) {
    if !cond {
        currentTestFailed = true
        print("    ✗ \(file):\(line) \(msg)")
    }
}

func test(_ name: String, _ body: () async throws -> Void) async {
    testCount += 1
    currentTestFailed = false
    do { try await body() } catch {
        currentTestFailed = true
        print("    ✗ threw \(error)")
    }
    if currentTestFailed { testFailures += 1 }
    print("\(currentTestFailed ? "FAIL" : "ok  ") \(name)")
}

func finishTests() -> Never {
    print(testFailures == 0 ? "PASS \(testCount)/\(testCount)" : "FAILED \(testFailures)/\(testCount)")
    exit(testFailures > 0 ? 1 : 0)
}

let fixturesDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

func makeTempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("lockscreen-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}
