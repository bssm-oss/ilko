import Foundation

func catalogTests() async {
    let manifest = fixturesDir.appendingPathComponent("entries.json")
    let A = "AAAA0000-0000-0000-0000-000000000001"
    let B = "BBBB0000-0000-0000-0000-000000000002"
    let C = "CCCC0000-0000-0000-0000-000000000003"

    await test("testParsesAssets") {
        let cat = try AerialCatalog(manifestURL: manifest, thumbnailsDir: makeTempDir())
        expect(cat.assets.count == 3, "asset without URL skipped, got \(cat.assets.count)")
        let a = cat.asset(id: A)
        expect(a?.name == "Asset A", "name")
        expect(a?.sourceURL.absoluteString == "https://example.invalid/a.mov", "sourceURL")
    }

    await test("testThumbnailOnlyWhenFileExists") {
        let thumbs = makeTempDir()
        FileManager.default.createFile(atPath: thumbs.appendingPathComponent("\(A).png").path, contents: Data([1]))
        let cat = try AerialCatalog(manifestURL: manifest, thumbnailsDir: thumbs)
        expect(cat.asset(id: A)?.thumbnailURL != nil, "A has thumbnail")
        expect(cat.asset(id: B)?.thumbnailURL == nil, "B has none")
    }

    await test("testDefaultSlotPrefersHiddenNonShuffle") {
        let cat = try AerialCatalog(manifestURL: manifest, thumbnailsDir: makeTempDir())
        expect(cat.defaultSlot(excluding: nil)?.id == C, "prefers C")
        expect(cat.defaultSlot(excluding: C)?.id == B, "then B")
        // B,C 둘 다 못 쓰는 카탈로그 → 마지막 항목
        let only = try AerialCatalog(manifestURL: manifest, thumbnailsDir: makeTempDir())
        let filtered = only.assets.filter { $0.showInTopLevel }
        expect(AerialCatalog.pickDefault(from: filtered, excluding: nil)?.id == filtered.last?.id, "fallback last")
    }

    await test("testMalformedThrows") {
        let bad = makeTempDir().appendingPathComponent("bad.json")
        try Data(#"{"foo":1}"#.utf8).write(to: bad)
        do {
            _ = try AerialCatalog(manifestURL: bad, thumbnailsDir: makeTempDir())
            expect(false, "should throw")
        } catch let e as LockScreenError {
            if case .unsupportedFormat = e {} else { expect(false, "wrong error \(e)") }
        }
    }
}
