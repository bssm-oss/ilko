import CryptoKit
import Foundation

/// WallpaperAgent / WallpaperAerialsExtension 재시작 (launchd 가 즉시 재기동한다)
nonisolated protocol WallpaperProcessControlling: Sendable {
    func restartWallpaperProcesses()
}

nonisolated struct SystemWallpaperProcesses: WallpaperProcessControlling {
    func restartWallpaperProcesses() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        // -9: 종료 시 메모리상의 선택을 Index.plist 에 다시 써서 우리 변경을 덮는 것을 막는다
        p.arguments = ["-9", "WallpaperAgent", "WallpaperAerialsExtension"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}

nonisolated enum SlotStatus: Equatable, Sendable {
    case intact
    case fileMissingOrReplaced
    case selectionChangedByUser
}

/// 선택한 Aerial 슬롯(`aerials/videos/<id>.mov`)에 변환된 영상을 넣고,
/// 시스템 배경 선택(Store/Index.plist)을 그 Aerial 로 바꾸거나 되돌린다.
nonisolated struct LockScreenSlot: Sendable {
    static let aerialsProvider = "com.apple.wallpaper.choice.aerials"
    static let indexKeys = ["AllSpacesAndDisplays", "SystemDefault"]

    private static let wallpaperDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper")
    static let systemVideosDir = wallpaperDir.appendingPathComponent("aerials/videos")
    static let systemIndexURL = wallpaperDir.appendingPathComponent("Store/Index.plist")
    static let defaultBackupURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ilko/lockscreen-index-backup.plist")

    let videosDir: URL
    let indexURL: URL
    let backupURL: URL
    let processes: WallpaperProcessControlling

    init(videosDir: URL = LockScreenSlot.systemVideosDir,
         indexURL: URL = LockScreenSlot.systemIndexURL,
         backupURL: URL = LockScreenSlot.defaultBackupURL,
         processes: WallpaperProcessControlling = SystemWallpaperProcesses()) {
        self.videosDir = videosDir
        self.indexURL = indexURL
        self.backupURL = backupURL
        self.processes = processes
    }

    func slotURL(_ assetID: String) -> URL { videosDir.appendingPathComponent("\(assetID).mov") }

    // MARK: - apply / restore

    func apply(encoded: URL, asset: AerialAsset) throws {
        var index = try readIndex()
        try validate(index)

        try writeSlotFile(from: encoded, to: slotURL(asset.id), sourceURL: asset.sourceURL)

        if !FileManager.default.fileExists(atPath: backupURL.path) {
            var backup: [String: Any] = [:]
            for key in Self.indexKeys { backup[key] = try choices(index, key) }
            try FileManager.default.createDirectory(at: backupURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: backup, format: .binary, options: 0)
                .write(to: backupURL, options: .atomic)
        }

        let config = try PropertyListSerialization.data(
            fromPropertyList: ["assetID": asset.id], format: .binary, options: 0)
        for key in Self.indexKeys {
            var list = try choices(index, key)
            list[0] = ["Provider": Self.aerialsProvider, "Configuration": config, "Files": [Any]()]
            try setChoices(&index, key, list)
        }
        try writeIndex(index)
        processes.restartWallpaperProcesses()
    }

    /// 슬롯을 놓는다. 파일을 지우면 macOS 가 그 Aerial 을 다시 받지 않으므로(검증됨),
    /// SourceURL 없는 1바이트 placeholder 로 바꿔 다음 사용 시 원본 재다운로드를 유도한다.
    func releaseSlotFile(assetID: String) throws {
        let url = slotURL(assetID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
        try Data([0]).write(to: url)
    }

    /// 기능을 켜기 전 사용자의 원래 Aerial (백업 기준, Aerial 이 아니었으면 nil)
    func originalAssetID() -> String? {
        guard let data = try? Data(contentsOf: backupURL),
            let backup = try? PropertyListSerialization.propertyList(from: data, options: .init(), format: nil) as? [String: Any],
            let list = backup["AllSpacesAndDisplays"] as? [Any]
        else { return nil }
        return assetID(ofChoice: list.first)
    }

    /// 슬롯 해제(placeholder) + 백업해 둔 원래 Choices 복원.
    func restore() throws {
        var index = try readIndex()
        if let id = currentAssetID(index) { try releaseSlotFile(assetID: id) }
        if let data = try? Data(contentsOf: backupURL),
            let backup = try PropertyListSerialization.propertyList(from: data, options: .init(), format: nil) as? [String: Any] {
            for key in Self.indexKeys {
                if let list = backup[key] as? [Any] { try setChoices(&index, key, list) }
            }
            try writeIndex(index)
        }
        discardBackup()
        processes.restartWallpaperProcesses()
    }

    func discardBackup() { try? FileManager.default.removeItem(at: backupURL) }

    // MARK: - status

    func status(encoded: URL, asset: AerialAsset) -> SlotStatus {
        guard let index = try? readIndex(), currentAssetID(index) == asset.id else { return .selectionChangedByUser }
        let slot = slotURL(asset.id)
        let fm = FileManager.default
        guard let a = try? fm.attributesOfItem(atPath: slot.path)[.size] as? Int,
            let b = try? fm.attributesOfItem(atPath: encoded.path)[.size] as? Int, a == b,
            let ha = Self.digestPrefix(slot), ha == Self.digestPrefix(encoded)
        else { return .fileMissingOrReplaced }
        return .intact
    }

    /// 현재 시스템 선택의 assetID (Aerial 이 아니면 nil)
    func currentSelectedAssetID() -> String? { (try? readIndex()).flatMap(currentAssetID) }

    func validateIndexFormat() throws { try validate(try readIndex()) }

    // MARK: - 내부

    private func currentAssetID(_ index: [String: Any]) -> String? {
        assetID(ofChoice: (try? choices(index, "AllSpacesAndDisplays"))?.first)
    }

    private func assetID(ofChoice choice: Any?) -> String? {
        guard let c = choice as? [String: Any],
            c["Provider"] as? String == Self.aerialsProvider,
            let data = c["Configuration"] as? Data,
            let cfg = try? PropertyListSerialization.propertyList(from: data, options: .init(), format: nil) as? [String: Any]
        else { return nil }
        return cfg["assetID"] as? String
    }

    private func writeSlotFile(from encoded: URL, to slot: URL, sourceURL: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: videosDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: slot.path) { try fm.removeItem(at: slot) }
        // APFS clone: 즉시·추가 공간 없음. 다른 볼륨이면 복사
        if clonefile(encoded.path, slot.path, 0) != 0 {
            do { try fm.copyItem(at: encoded, to: slot) } catch {
                throw LockScreenError.io("copy slot: \(error.localizedDescription)")
            }
        }
        // 확장은 SourceURL 이 매니페스트 URL 과 다르면 원본을 다시 받아 덮어쓴다
        let value = Array(sourceURL.absoluteString.utf8)
        if setxattr(slot.path, "SourceURL", value, value.count, 0, 0) != 0 {
            throw LockScreenError.io("setxattr SourceURL failed: \(errno)")
        }
    }

    private func readIndex() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: indexURL) else {
            throw LockScreenError.unsupportedFormat("Index.plist unreadable")
        }
        guard let index = try? PropertyListSerialization.propertyList(from: data, options: .init(), format: nil) as? [String: Any]
        else { throw LockScreenError.unsupportedFormat("Index.plist is not a dictionary") }
        return index
    }

    private func writeIndex(_ index: [String: Any]) throws {
        try PropertyListSerialization.data(fromPropertyList: index, format: .binary, options: 0)
            .write(to: indexURL, options: .atomic)
    }

    private func validate(_ index: [String: Any]) throws {
        for key in Self.indexKeys {
            guard let list = try? choices(index, key), !list.isEmpty else {
                throw LockScreenError.unsupportedFormat("Index.plist missing \(key).Linked.Content.Choices")
            }
        }
    }

    private func choices(_ index: [String: Any], _ key: String) throws -> [Any] {
        guard let top = index[key] as? [String: Any], let linked = top["Linked"] as? [String: Any],
            let content = linked["Content"] as? [String: Any], let list = content["Choices"] as? [Any]
        else { throw LockScreenError.unsupportedFormat("no \(key) choices") }
        return list
    }

    private func setChoices(_ index: inout [String: Any], _ key: String, _ list: [Any]) throws {
        guard var top = index[key] as? [String: Any], var linked = top["Linked"] as? [String: Any],
            var content = linked["Content"] as? [String: Any]
        else { throw LockScreenError.unsupportedFormat("no \(key) content") }
        content["Choices"] = list
        linked["Content"] = content
        top["Linked"] = linked
        index[key] = top
    }

    private static func digestPrefix(_ url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        var h = SHA256()
        while let chunk = try? fh.read(upToCount: 1 << 20), !chunk.isEmpty { h.update(data: chunk) }
        return h.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
