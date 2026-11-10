import Foundation

private let cA = "AAAA0000-0000-0000-0000-000000000001"
private let cB = "BBBB0000-0000-0000-0000-000000000002"
private let cC = "CCCC0000-0000-0000-0000-000000000003"

@MainActor
private final class CoordEnv {
    let dir = makeTempDir()
    let proc = CountingProcesses()
    var providerAtNotify: [String?] = []
    var slot: LockScreenSlot!
    var coord: LockScreenCoordinator!
    var videos: URL { dir.appendingPathComponent("videos") }
    var index: URL { dir.appendingPathComponent("Index.plist") }
    var cache: URL { dir.appendingPathComponent("cache") }

    init(originalAerial: String? = nil, videosIsFile: Bool = false) throws {
        let fm = FileManager.default
        if videosIsFile { try Data([1]).write(to: videos) } else { try fm.createDirectory(at: videos, withIntermediateDirectories: true) }
        try fm.copyItem(at: fixturesDir.appendingPathComponent("Index.plist"), to: index)
        if let id = originalAerial { try setIndexAerial(id) }
        slot = LockScreenSlot(videosDir: videos, indexURL: index,
                              backupURL: dir.appendingPathComponent("backup.plist"), processes: proc)
        let catalog = try AerialCatalog(manifestURL: fixturesDir.appendingPathComponent("entries.json"), thumbnailsDir: dir)
        let defaults = UserDefaults(suiteName: "lockscreen-test-\(UUID().uuidString)")!
        coord = LockScreenCoordinator(slot: slot, encoder: AerialEncoder(cacheDir: cache), catalog: catalog,
                                      defaults: defaults, disableSettleDelay: 0) { [weak self] in
            guard let self else { return }
            self.providerAtNotify.append(self.currentProvider())
        }
    }

    func setIndexAerial(_ id: String) throws {
        var p = try PropertyListSerialization.propertyList(from: Data(contentsOf: index), options: .init(), format: nil) as! [String: Any]
        let cfg = try PropertyListSerialization.data(fromPropertyList: ["assetID": id], format: .binary, options: 0)
        for key in ["AllSpacesAndDisplays", "SystemDefault"] {
            var top = p[key] as! [String: Any]; var linked = top["Linked"] as! [String: Any]
            var content = linked["Content"] as! [String: Any]
            content["Choices"] = [["Provider": "com.apple.wallpaper.choice.aerials", "Configuration": cfg, "Files": [Any]()]]
            linked["Content"] = content; top["Linked"] = linked; p[key] = top
        }
        try PropertyListSerialization.data(fromPropertyList: p, format: .binary, options: 0).write(to: index)
    }

    func currentProvider() -> String? {
        guard let p = try? PropertyListSerialization.propertyList(from: Data(contentsOf: index), options: .init(), format: nil) as? [String: Any],
            let top = p["AllSpacesAndDisplays"] as? [String: Any], let linked = top["Linked"] as? [String: Any],
            let content = linked["Content"] as? [String: Any], let c = (content["Choices"] as? [[String: Any]])?.first
        else { return nil }
        return c["Provider"] as? String
    }

    func video(_ name: String, seconds: Double, size: CGSize = CGSize(width: 320, height: 180)) async throws -> String {
        let url = dir.appendingPathComponent(name)
        try await makeTestVideo(url: url, size: size, fps: 30, seconds: seconds, barHeight: 0, withAudio: false)
        return url.path
    }
}

@MainActor
func coordinatorTests() async {
    // I2: 연속 전환 시 마지막 영상만 슬롯에 남고, 변환 중 표시가 끝까지 유지되며, 취소된 변환은 캐시를 남기지 않는다
    await test("testRapidSwitchLastWinsAndEncodingFlag") {
        let e = try CoordEnv()
        let a = try await e.video("a.mov", seconds: 6, size: CGSize(width: 1280, height: 720))
        let b = try await e.video("b.mov", seconds: 0.5)
        e.coord.setEnabled(true)
        e.coord.videoApplied(path: a)
        expect(e.coord.isEncoding, "encoding flag set synchronously")
        try await Task.sleep(nanoseconds: 200_000_000)
        e.coord.videoApplied(path: b)
        expect(e.coord.isEncoding, "still encoding after switch")
        await e.coord.settle()
        expect(!e.coord.isEncoding, "flag cleared at the end")
        let bEnc = try await AerialEncoder(cacheDir: e.cache).encode(source: URL(fileURLWithPath: b))
        let slotFile = e.videos.appendingPathComponent("\(cC).mov")
        expect((try? Data(contentsOf: slotFile)) == (try? Data(contentsOf: bEnc)), "slot holds B")
        let aKey = try AerialEncoder.cacheKey(for: URL(fileURLWithPath: a))
        expect(!FileManager.default.fileExists(atPath: e.cache.appendingPathComponent("\(aKey).mov").path), "A encode cancelled")
    }

    // I3: 첫 적용(변환) 중 잠금 해제 self-heal 이 기능을 끄면 안 된다
    await test("testSelfHealDuringFirstApplyKeepsEnabled") {
        let e = try CoordEnv()
        let a = try await e.video("a.mov", seconds: 3, size: CGSize(width: 1280, height: 720))
        e.coord.setEnabled(true)
        e.coord.videoApplied(path: a)
        try await Task.sleep(nanoseconds: 100_000_000)
        e.coord.selfHeal()
        await e.coord.settle()
        expect(e.coord.isEnabled, "still enabled")
        expect(e.slot.currentSelectedAssetID() == cC, "slot applied")
        expect(e.coord.notice == nil, "no notice")
    }

    // I4: 적용이 실패했던 상태에서 잠금 해제 → 끄지 말고 재시도
    await test("testApplyFailureRetriesOnSelfHeal") {
        let e = try CoordEnv(videosIsFile: true)
        let a = try await e.video("a.mov", seconds: 0.5)
        e.coord.setEnabled(true)
        e.coord.videoApplied(path: a)
        await e.coord.settle()
        expect(e.slot.currentSelectedAssetID() == nil, "apply failed (videos dir is a file)")
        try FileManager.default.removeItem(at: e.videos)
        try FileManager.default.createDirectory(at: e.videos, withIntermediateDirectories: true)
        e.coord.selfHeal()
        await e.coord.settle()
        expect(e.coord.isEnabled, "still enabled")
        expect(e.coord.notice == nil, "no misleading notice")
        expect(e.slot.currentSelectedAssetID() == cC, "retried and applied")
    }

    // I5: 영상 모드에서 끌 때 원래 선택 복원을 끝낸 뒤에 daemon 알림을 보낸다
    await test("testDisableRestoresBeforeNotify") {
        let e = try CoordEnv()
        let a = try await e.video("a.mov", seconds: 0.5)
        e.coord.setEnabled(true)
        e.coord.videoApplied(path: a)
        await e.coord.settle()
        expect(e.slot.currentSelectedAssetID() == cC, "applied")
        e.providerAtNotify.removeAll()
        e.coord.setEnabled(false)
        await e.coord.settle()
        expect(e.providerAtNotify == ["com.apple.wallpaper.choice.image"], "notify after restore, got \(e.providerAtNotify)")
        expectPlaceholder(e.videos.appendingPathComponent("\(cC).mov"))
    }

    // I6: 사용자의 원래 Aerial 은 슬롯으로 고를 수 없다
    await test("testSelectSlotRejectsUsersOriginalAerial") {
        let e = try CoordEnv(originalAerial: cB)
        e.coord.setEnabled(true)
        expect(e.coord.selectedAssetID == cC, "default excludes current B")
        expect(e.coord.excludedAssetID == cB, "excluded is B")
        e.coord.selectSlot(cB)
        expect(e.coord.selectedAssetID == cC, "B rejected")
        e.coord.selectSlot(cA)
        expect(e.coord.selectedAssetID == cA, "A accepted")
    }
}
