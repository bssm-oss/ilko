import Foundation

final class CountingProcesses: WallpaperProcessControlling, @unchecked Sendable {
    var restarts = 0
    func restartWallpaperProcesses() { restarts += 1 }
}

private func readIndex(_ url: URL) throws -> [String: Any] {
    try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: .init(), format: nil) as! [String: Any]
}

private func choice0(_ index: [String: Any], _ key: String) -> [String: Any] {
    let linked = (index[key] as! [String: Any])["Linked"] as! [String: Any]
    return ((linked["Content"] as! [String: Any])["Choices"] as! [[String: Any]])[0]
}

private func assetID(of choice: [String: Any]) -> String? {
    guard let data = choice["Configuration"] as? Data,
        let cfg = try? PropertyListSerialization.propertyList(from: data, options: .init(), format: nil) as? [String: Any]
    else { return nil }
    return cfg["assetID"] as? String
}

private func xattrString(_ url: URL, _ name: String) -> String? {
    let len = getxattr(url.path, name, nil, 0, 0, 0)
    guard len > 0 else { return nil }
    var buf = [UInt8](repeating: 0, count: len)
    getxattr(url.path, name, &buf, len, 0, 0)
    return String(decoding: buf, as: UTF8.self)
}

func slotTests() async {
    func env() throws -> (slot: LockScreenSlot, proc: CountingProcesses, dir: URL, index: URL, encoded: URL) {
        let dir = makeTempDir()
        let videos = dir.appendingPathComponent("videos")
        try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
        let index = dir.appendingPathComponent("Index.plist")
        try FileManager.default.copyItem(at: fixturesDir.appendingPathComponent("Index.plist"), to: index)
        let encoded = dir.appendingPathComponent("enc.mov")
        try Data((0..<4096).map { UInt8($0 % 251) }).write(to: encoded)
        let proc = CountingProcesses()
        let slot = LockScreenSlot(videosDir: videos, indexURL: index,
                                  backupURL: dir.appendingPathComponent("backup.plist"), processes: proc)
        return (slot, proc, dir, index, encoded)
    }
    let A = AerialAsset(id: "AAAA", name: "A", sourceURL: URL(string: "https://example.invalid/a.mov")!,
                        thumbnailURL: nil, showInTopLevel: true, includeInShuffle: true)
    let B = AerialAsset(id: "BBBB", name: "B", sourceURL: URL(string: "https://example.invalid/b.mov")!,
                        thumbnailURL: nil, showInTopLevel: true, includeInShuffle: true)

    await test("testApplyWritesSlotXattrAndIndex") {
        let e = try env()
        try e.slot.apply(encoded: e.encoded, asset: A)
        let slotFile = e.dir.appendingPathComponent("videos/AAAA.mov")
        expect(try Data(contentsOf: slotFile) == Data(contentsOf: e.encoded), "slot bytes == encoded")
        expect(xattrString(slotFile, "SourceURL") == A.sourceURL.absoluteString, "SourceURL xattr")
        let idx = try readIndex(e.index)
        for key in ["AllSpacesAndDisplays", "SystemDefault"] {
            let c = choice0(idx, key)
            expect(c["Provider"] as? String == "com.apple.wallpaper.choice.aerials", "\(key) provider")
            expect(assetID(of: c) == "AAAA", "\(key) assetID")
        }
        expect(FileManager.default.fileExists(atPath: e.dir.appendingPathComponent("backup.plist").path), "backup")
        expect(e.proc.restarts == 1, "restart once, got \(e.proc.restarts)")
    }

    await test("testRestoreRevertsChoicesAndDeletesSlot") {
        let e = try env()
        let original = try readIndex(e.index)
        try e.slot.apply(encoded: e.encoded, asset: A)
        try e.slot.restore()
        let idx = try readIndex(e.index)
        for key in ["AllSpacesAndDisplays", "SystemDefault"] {
            expect(NSDictionary(dictionary: choice0(idx, key)).isEqual(to: choice0(original, key)), "\(key) restored")
        }
        expect(!FileManager.default.fileExists(atPath: e.dir.appendingPathComponent("videos/AAAA.mov").path), "slot deleted")
        expect(!FileManager.default.fileExists(atPath: e.dir.appendingPathComponent("backup.plist").path), "backup removed")
        expect(e.proc.restarts == 2, "restarts 2, got \(e.proc.restarts)")
    }

    await test("testSecondApplyKeepsOriginalBackup") {
        let e = try env()
        let original = try readIndex(e.index)
        try e.slot.apply(encoded: e.encoded, asset: A)
        try e.slot.removeSlotFile(assetID: "AAAA")
        try e.slot.apply(encoded: e.encoded, asset: B)
        try e.slot.restore()
        let idx = try readIndex(e.index)
        expect(choice0(idx, "AllSpacesAndDisplays")["Provider"] as? String
               == choice0(original, "AllSpacesAndDisplays")["Provider"] as? String, "back to original provider")
        expect(!FileManager.default.fileExists(atPath: e.dir.appendingPathComponent("videos/BBBB.mov").path), "B slot deleted")
    }

    await test("testStatus") {
        let e = try env()
        try e.slot.apply(encoded: e.encoded, asset: A)
        expect(e.slot.status(encoded: e.encoded, asset: A) == .intact, "intact")
        try FileManager.default.removeItem(at: e.dir.appendingPathComponent("videos/AAAA.mov"))
        expect(e.slot.status(encoded: e.encoded, asset: A) == .fileMissingOrReplaced, "missing")
        try e.slot.apply(encoded: e.encoded, asset: A)
        try Data([9, 9, 9]).write(to: e.dir.appendingPathComponent("videos/AAAA.mov"))
        expect(e.slot.status(encoded: e.encoded, asset: A) == .fileMissingOrReplaced, "replaced")
        expect(e.slot.status(encoded: e.encoded, asset: B) == .selectionChangedByUser, "other asset selected")
    }

    await test("testApplyRejectsUnknownIndexFormat") {
        let e = try env()
        try PropertyListSerialization.data(fromPropertyList: ["Something": 1], format: .binary, options: 0).write(to: e.index)
        do {
            try e.slot.apply(encoded: e.encoded, asset: A)
            expect(false, "should throw")
        } catch let err as LockScreenError {
            if case .unsupportedFormat = err {} else { expect(false, "wrong error \(err)") }
        }
        expect(!FileManager.default.fileExists(atPath: e.dir.appendingPathComponent("videos/AAAA.mov").path), "no slot written")
        expect(e.proc.restarts == 0, "no restart")
    }
}
