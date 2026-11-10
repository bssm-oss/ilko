import Foundation

final class CountingProcesses: WallpaperProcessControlling, @unchecked Sendable {
    var restarts = 0
    func restartWallpaperProcesses() { restarts += 1 }
}

func readIndex(_ url: URL) throws -> [String: Any] {
    try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: .init(), format: nil) as! [String: Any]
}

private func choice0(_ index: [String: Any], _ key: String) -> [String: Any] {
    let linked = (index[key] as! [String: Any])["Linked"] as! [String: Any]
    return ((linked["Content"] as! [String: Any])["Choices"] as! [[String: Any]])[0]
}

func assetID(of choice: [String: Any]) -> String? {
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

/// I6: 슬롯을 놓을 때 파일을 지우면 macOS 가 원본을 다시 받지 않는다.
/// SourceURL 없는 1바이트 placeholder 를 남겨야 다음 사용 시 원본을 재다운로드한다.
func expectPlaceholder(_ url: URL, file: String = #fileID, line: Int = #line) {
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
    expect(size == 1, "placeholder size 1, got \(size)", file: file, line: line)
    expect(xattrString(url, "SourceURL") == nil, "placeholder has no SourceURL", file: file, line: line)
}


/// macOS 가 데스크탑/Idle 을 분리해 저장한 Index.plist (setDesktopImageURL 이후 실제 관찰된 모양)
func writeSplitIndex(_ url: URL, idleAsset: String = "IDLE") throws {
    func content(_ choice: [String: Any]) -> [String: Any] {
        ["Content": ["Choices": [choice], "Shuffle": "$null", "EncodedOptionValues": Data([1, 2])],
         "LastSet": Date(timeIntervalSince1970: 1), "LastUse": Date(timeIntervalSince1970: 2)]
    }
    let image: [String: Any] = ["Provider": "com.apple.wallpaper.choice.image", "Files": [Any](),
                                "Configuration": Data("img".utf8)]
    let idle: [String: Any] = ["Provider": "com.apple.wallpaper.choice.aerials", "Files": [Any](),
                               "Configuration": try PropertyListSerialization.data(
                                   fromPropertyList: ["assetID": idleAsset], format: .binary, options: 0)]
    let individual: [String: Any] = ["Type": "individual", "Desktop": content(image), "Idle": content(idle)]
    let index: [String: Any] = [
        "AllSpacesAndDisplays": ["Type": "idle", "Idle": content(idle)],
        "SystemDefault": individual,
        "Spaces": ["": ["Default": individual, "Displays": ["D1": individual]]],
        "Displays": ["D1": individual],
    ]
    try PropertyListSerialization.data(fromPropertyList: index, format: .binary, options: 0).write(to: url)
}

/// Index 안의 모든 데스크탑 선택(Linked 또는 Desktop)의 Provider/assetID
func desktopChoices(_ url: URL) throws -> [(provider: String?, asset: String?)] {
    let idx = try readIndex(url)
    var entries: [[String: Any]] = []
    for k in ["AllSpacesAndDisplays", "SystemDefault"] { if let e = idx[k] as? [String: Any] { entries.append(e) } }
    if let d = idx["Displays"] as? [String: Any] { entries += d.values.compactMap { $0 as? [String: Any] } }
    if let sp = idx["Spaces"] as? [String: Any] {
        for case let space as [String: Any] in sp.values {
            if let e = space["Default"] as? [String: Any] { entries.append(e) }
            if let d = space["Displays"] as? [String: Any] { entries += d.values.compactMap { $0 as? [String: Any] } }
        }
    }
    return entries.compactMap { e in
        guard let slot = (e["Linked"] ?? e["Desktop"]) as? [String: Any],
            let c = ((slot["Content"] as? [String: Any])?["Choices"] as? [[String: Any]])?.first else { return nil }
        return (c["Provider"] as? String, assetID(of: c))
    }
}

/// Index 안의 모든 화면 보호기 선택(Linked 또는 Idle)의 assetID (Aerial 아니면 provider 이름)
func idleChoiceIDs(_ url: URL) throws -> [String] {
    let idx = try readIndex(url)
    var entries: [[String: Any]] = []
    for k in ["AllSpacesAndDisplays", "SystemDefault"] { if let e = idx[k] as? [String: Any] { entries.append(e) } }
    if let d = idx["Displays"] as? [String: Any] { entries += d.values.compactMap { $0 as? [String: Any] } }
    if let sp = idx["Spaces"] as? [String: Any] {
        for case let space as [String: Any] in sp.values {
            if let e = space["Default"] as? [String: Any] { entries.append(e) }
            if let d = space["Displays"] as? [String: Any] { entries += d.values.compactMap { $0 as? [String: Any] } }
        }
    }
    return entries.compactMap { e in
        guard let slot = (e["Linked"] ?? e["Idle"]) as? [String: Any],
            let c = ((slot["Content"] as? [String: Any])?["Choices"] as? [[String: Any]])?.first else { return nil }
        return assetID(of: c) ?? (c["Provider"] as? String ?? "?")
    }
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
        try e.slot.apply(encoded: e.encoded, asset: A, screenSaver: true)
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
        try e.slot.apply(encoded: e.encoded, asset: A, screenSaver: true)
        try e.slot.restore()
        let idx = try readIndex(e.index)
        for key in ["AllSpacesAndDisplays", "SystemDefault"] {
            expect(NSDictionary(dictionary: choice0(idx, key)).isEqual(to: choice0(original, key)), "\(key) restored")
        }
        expectPlaceholder(e.dir.appendingPathComponent("videos/AAAA.mov"))
        expect(!FileManager.default.fileExists(atPath: e.dir.appendingPathComponent("backup.plist").path), "backup removed")
        expect(e.proc.restarts == 2, "restarts 2, got \(e.proc.restarts)")
    }

    await test("testSecondApplyKeepsOriginalBackup") {
        let e = try env()
        let original = try readIndex(e.index)
        try e.slot.apply(encoded: e.encoded, asset: A, screenSaver: true)
        try e.slot.releaseSlotFile(assetID: "AAAA")
        try e.slot.apply(encoded: e.encoded, asset: B, screenSaver: true)
        try e.slot.restore()
        let idx = try readIndex(e.index)
        expect(choice0(idx, "AllSpacesAndDisplays")["Provider"] as? String
               == choice0(original, "AllSpacesAndDisplays")["Provider"] as? String, "back to original provider")
        expectPlaceholder(e.dir.appendingPathComponent("videos/BBBB.mov"))
    }

    await test("testStatus") {
        let e = try env()
        try e.slot.apply(encoded: e.encoded, asset: A, screenSaver: true)
        expect(e.slot.status(encoded: e.encoded, asset: A) == .intact, "intact")
        try FileManager.default.removeItem(at: e.dir.appendingPathComponent("videos/AAAA.mov"))
        expect(e.slot.status(encoded: e.encoded, asset: A) == .fileMissingOrReplaced, "missing")
        try e.slot.apply(encoded: e.encoded, asset: A, screenSaver: true)
        try Data([9, 9, 9]).write(to: e.dir.appendingPathComponent("videos/AAAA.mov"))
        expect(e.slot.status(encoded: e.encoded, asset: A) == .fileMissingOrReplaced, "replaced")
        expect(e.slot.status(encoded: e.encoded, asset: B) == .selectionChangedByUser, "other asset selected")
    }

    await test("testApplyRejectsUnknownIndexFormat") {
        let e = try env()
        try PropertyListSerialization.data(fromPropertyList: ["Something": 1], format: .binary, options: 0).write(to: e.index)
        do {
            try e.slot.apply(encoded: e.encoded, asset: A, screenSaver: true)
            expect(false, "should throw")
        } catch let err as LockScreenError {
            if case .unsupportedFormat = err {} else { expect(false, "wrong error \(err)") }
        }
        expect(!FileManager.default.fileExists(atPath: e.dir.appendingPathComponent("videos/AAAA.mov").path), "no slot written")
        expect(e.proc.restarts == 0, "no restart")
    }

    await test("testReleaseSlotFileLeavesPlaceholder") {
        let e = try env()
        try e.slot.apply(encoded: e.encoded, asset: A, screenSaver: true)
        try e.slot.releaseSlotFile(assetID: "AAAA")
        expectPlaceholder(e.dir.appendingPathComponent("videos/AAAA.mov"))
        try e.slot.releaseSlotFile(assetID: "ZZZZ")  // 없는 슬롯은 만들지 않음
        expect(!FileManager.default.fileExists(atPath: e.dir.appendingPathComponent("videos/ZZZZ.mov").path), "no file created")
    }

    // 데스크탑/Idle 분리 모양: 모든 데스크탑 자리를 Aerial 로, Idle(화면 보호기)은 그대로
    await test("testApplySplitFormatSetsEveryDesktop") {
        let e = try env()
        try writeSplitIndex(e.index)
        let before = try readIndex(e.index)
        try e.slot.validateIndexFormat()
        try e.slot.apply(encoded: e.encoded, asset: A)
        let desks = try desktopChoices(e.index)
        expect(desks.count == 4, "4 desktop entries, got \(desks.count)")
        expect(desks.allSatisfy { $0.provider == "com.apple.wallpaper.choice.aerials" && $0.asset == "AAAA" }, "all desktops → A: \(desks)")
        let after = try readIndex(e.index)
        let idleBefore = (before["SystemDefault"] as! [String: Any])["Idle"] as! [String: Any]
        let idleAfter = (after["SystemDefault"] as! [String: Any])["Idle"] as! [String: Any]
        expect(NSDictionary(dictionary: idleBefore).isEqual(to: idleAfter), "Idle untouched")
        expect(NSDictionary(dictionary: before["AllSpacesAndDisplays"] as! [String: Any])
               .isEqual(to: after["AllSpacesAndDisplays"] as! [String: Any]), "idle-only entry untouched")
        expect(e.slot.currentSelectedAssetID() == "AAAA", "current A")
        expect(e.slot.status(encoded: e.encoded, asset: A) == .intact, "intact")
    }

    await test("testRestoreSplitFormatRestoresExactly") {
        let e = try env()
        try writeSplitIndex(e.index)
        let before = try readIndex(e.index)
        try e.slot.apply(encoded: e.encoded, asset: A)
        try e.slot.restore()
        expect(NSDictionary(dictionary: try readIndex(e.index)).isEqual(to: before), "index restored exactly")
        expectPlaceholder(e.dir.appendingPathComponent("videos/AAAA.mov"))
    }

    // 사용자가 한 디스플레이라도 다른 배경으로 바꾸면 사용자 변경으로 본다
    await test("testStatusSplitDetectsUserChangeOnOneDisplay") {
        let e = try env()
        try writeSplitIndex(e.index)
        try e.slot.apply(encoded: e.encoded, asset: A)
        var idx = try readIndex(e.index)
        var displays = idx["Displays"] as! [String: Any]
        var d1 = displays["D1"] as! [String: Any]
        var desk = d1["Desktop"] as! [String: Any]
        var content = desk["Content"] as! [String: Any]
        content["Choices"] = [["Provider": "com.apple.wallpaper.choice.image", "Files": [Any](), "Configuration": Data("x".utf8)]]
        desk["Content"] = content; d1["Desktop"] = desk; displays["D1"] = d1; idx["Displays"] = displays
        try PropertyListSerialization.data(fromPropertyList: idx, format: .binary, options: 0).write(to: e.index)
        expect(e.slot.status(encoded: e.encoded, asset: A) == .selectionChangedByUser, "user change detected")
    }

    // 화면 보호기 토글 켜짐: 분리 모양의 모든 Idle 칸도 같은 Aerial
    await test("testApplySplitWithScreenSaverSetsEveryIdle") {
        let e = try env()
        try writeSplitIndex(e.index)
        try e.slot.apply(encoded: e.encoded, asset: A, screenSaver: true)
        let idles = try idleChoiceIDs(e.index)
        expect(idles.count == 5 && idles.allSatisfy { $0 == "AAAA" }, "all idle → A: \(idles)")
        expect(try desktopChoices(e.index).allSatisfy { $0.asset == "AAAA" }, "desktops → A")
    }

    // 화면 보호기 토글을 다시 끄면 Idle 은 원래대로
    await test("testApplySplitScreenSaverOffRestoresOriginalIdle") {
        let e = try env()
        try writeSplitIndex(e.index)
        try e.slot.apply(encoded: e.encoded, asset: A, screenSaver: true)
        try e.slot.apply(encoded: e.encoded, asset: A, screenSaver: false)
        let idles = try idleChoiceIDs(e.index)
        expect(idles.count == 5 && idles.allSatisfy { $0 == "IDLE" }, "idle back to original: \(idles)")
        expect(try desktopChoices(e.index).allSatisfy { $0.asset == "AAAA" }, "desktops still A")
    }

    // 묶음 모양 + 화면 보호기 꺼짐: 잠금화면만 바꾸도록 칸을 나누고, 끄면 원래 묶음으로 복원
    await test("testApplyLinkedScreenSaverOffSplitsAndRestores") {
        let e = try env()
        let before = try readIndex(e.index)
        let originalProvider = choice0(before, "SystemDefault")["Provider"] as? String
        try e.slot.apply(encoded: e.encoded, asset: A, screenSaver: false)
        let after = try readIndex(e.index)
        for key in ["AllSpacesAndDisplays", "SystemDefault"] {
            let entry = after[key] as! [String: Any]
            expect(entry["Linked"] == nil && entry["Type"] as? String == "individual", "\(key) split")
        }
        expect(try desktopChoices(e.index).allSatisfy { $0.asset == "AAAA" }, "desktops → A")
        expect(try idleChoiceIDs(e.index).allSatisfy { $0 == originalProvider }, "idle keeps original \(originalProvider ?? "")")
        expect(e.slot.status(encoded: e.encoded, asset: A) == .intact, "intact")
        try e.slot.restore()
        expect(NSDictionary(dictionary: try readIndex(e.index)).isEqual(to: before), "restored exactly")
    }

    await test("testApplyLinkedScreenSaverOnKeepsLinked") {
        let e = try env()
        try e.slot.apply(encoded: e.encoded, asset: A, screenSaver: true)
        let after = try readIndex(e.index)
        expect((after["SystemDefault"] as! [String: Any])["Linked"] != nil, "stays linked")
        expect(try idleChoiceIDs(e.index).allSatisfy { $0 == "AAAA" }, "idle (linked) → A")
    }

    await test("testOriginalAssetIDFromBackup") {
        let e = try env()
        expect(e.slot.originalAssetID() == nil, "no backup → nil")
        // 원래 선택이 Aerial B 였던 상태에서 A 를 적용
        try e.slot.apply(encoded: e.encoded, asset: B)
        e.slot.discardBackup()
        try e.slot.apply(encoded: e.encoded, asset: A)
        expect(e.slot.originalAssetID() == "BBBB", "original from backup, got \(e.slot.originalAssetID() ?? "nil")")
    }
}
