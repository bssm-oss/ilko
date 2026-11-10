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

    /// - Parameter screenSaver: true 면 화면 보호기(Idle)도 이 Aerial, false 면 화면 보호기는 원래 설정 유지
    func apply(encoded: URL, asset: AerialAsset, screenSaver: Bool = false) throws {
        var index = try readIndex()
        try validate(index)

        try writeSlotFile(from: encoded, to: slotURL(asset.id), sourceURL: asset.sourceURL)

        let paths = Self.wallpaperEntryPaths(index)
        if !FileManager.default.fileExists(atPath: backupURL.path) {
            // 데스크탑/화면 보호기 자리가 있는 칸을 통째로 백업 → 끌 때 그대로 되돌린다
            let entries: [[String: Any]] = paths.compactMap { path in
                Self.value(index, path).map { ["path": path, "entry": $0] }
            }
            try FileManager.default.createDirectory(at: backupURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["entries": entries], format: .binary, options: 0)
                .write(to: backupURL, options: .atomic)
        }

        // 잠금화면은 데스크탑 선택으로 그려진다(검증됨). 모든 데스크탑 자리를 이 Aerial 로 바꾼다.
        // 화면 보호기(Idle)는 screenSaver 일 때만 바꾸고, 아니면 백업해 둔 원래 설정을 유지한다.
        let config = try PropertyListSerialization.data(
            fromPropertyList: ["assetID": asset.id], format: .binary, options: 0)
        let choice: [String: Any] = ["Provider": Self.aerialsProvider, "Configuration": config, "Files": [Any]()]
        let original = backupEntries()
        for path in paths {
            guard var entry = Self.value(index, path) as? [String: Any] else { continue }
            if let linked = entry["Linked"] as? [String: Any] {
                if screenSaver {
                    entry["Linked"] = Self.withChoice(linked, choice)
                } else {
                    // 묶음 모양은 데스크탑과 화면 보호기를 함께 바꾸므로, 둘로 나눠 화면 보호기에는 원래 설정을 남긴다
                    entry["Linked"] = nil
                    entry["Type"] = "individual"
                    entry["Desktop"] = Self.withChoice(linked, choice)
                    entry["Idle"] = linked
                }
            } else {
                if let desktop = entry["Desktop"] as? [String: Any] { entry["Desktop"] = Self.withChoice(desktop, choice) }
                if let idle = entry["Idle"] as? [String: Any] {
                    if screenSaver {
                        entry["Idle"] = Self.withChoice(idle, choice)
                    } else if let orig = original[path], let origIdle = (orig["Idle"] ?? orig["Linked"]) as? [String: Any] {
                        entry["Idle"] = origIdle
                    }
                }
            }
            Self.setValue(&index, path, entry)
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
            let entries = backup["entries"] as? [[String: Any]]
        else { return nil }
        let first = entries.lazy.compactMap { ($0["entry"] as? [String: Any]).flatMap(Self.desktopChoices)?.first }.first
        return assetID(ofChoice: first)
    }

    /// 슬롯 해제(placeholder) + 백업해 둔 원래 Choices 복원.
    func restore() throws {
        var index = try readIndex()
        if let id = currentAssetID(index) { try releaseSlotFile(assetID: id) }
        if let data = try? Data(contentsOf: backupURL),
            let backup = try PropertyListSerialization.propertyList(from: data, options: .init(), format: nil) as? [String: Any],
            let entries = backup["entries"] as? [[String: Any]] {
            for item in entries {
                guard let path = item["path"] as? [String], let entry = item["entry"] else { continue }
                Self.setValue(&index, path, entry)
            }
            try writeIndex(index)
        }
        discardBackup()
        processes.restartWallpaperProcesses()
    }

    func discardBackup() { try? FileManager.default.removeItem(at: backupURL) }

    /// 백업된 칸: 경로 → 원래 칸 내용
    private func backupEntries() -> [[String]: [String: Any]] {
        guard let data = try? Data(contentsOf: backupURL),
            let backup = try? PropertyListSerialization.propertyList(from: data, options: .init(), format: nil) as? [String: Any],
            let entries = backup["entries"] as? [[String: Any]]
        else { return [:] }
        var map: [[String]: [String: Any]] = [:]
        for item in entries {
            if let path = item["path"] as? [String], let entry = item["entry"] as? [String: Any] { map[path] = entry }
        }
        return map
    }

    // MARK: - status

    func status(encoded: URL, asset: AerialAsset) -> SlotStatus {
        // 데스크탑 자리 중 하나라도 이 Aerial 이 아니면 사용자가 바꾼 것
        guard let index = try? readIndex() else { return .selectionChangedByUser }
        let ids = Self.desktopEntryPaths(index).map { path in
            (Self.value(index, path) as? [String: Any]).flatMap(Self.desktopChoices).flatMap { assetID(ofChoice: $0.first) }
        }
        guard !ids.isEmpty, ids.allSatisfy({ $0 == asset.id }) else { return .selectionChangedByUser }
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

    /// 가장 구체적인(디스플레이별) 데스크탑 자리의 assetID (Aerial 이 아니면 nil)
    private func currentAssetID(_ index: [String: Any]) -> String? {
        guard let path = Self.desktopEntryPaths(index).first,
            let entry = Self.value(index, path) as? [String: Any] else { return nil }
        return assetID(ofChoice: Self.desktopChoices(entry)?.first)
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
        guard !Self.desktopEntryPaths(index).isEmpty else {
            throw LockScreenError.unsupportedFormat("Index.plist has no desktop wallpaper entry")
        }
    }

    // MARK: Index.plist 구조
    // 각 칸(AllSpacesAndDisplays, SystemDefault, Displays/<id>, Spaces/<id>/Default, Spaces/<id>/Displays/<id>)은
    // 묶음(`Linked`) 또는 분리(`Desktop` + `Idle`) 모양이다. 데스크탑 자리 = `Linked` 또는 `Desktop`.

    /// 데스크탑 자리가 있는 칸의 경로. 구체적인 것(디스플레이별)부터.
    static func desktopEntryPaths(_ index: [String: Any]) -> [[String]] {
        candidatePaths(index).filter { path in
            guard let entry = value(index, path) as? [String: Any], let list = desktopChoices(entry) else { return false }
            return !list.isEmpty
        }
    }

    /// 데스크탑 또는 화면 보호기 자리가 있는 칸의 경로 (백업·적용 대상)
    static func wallpaperEntryPaths(_ index: [String: Any]) -> [[String]] {
        candidatePaths(index).filter { path in
            guard let entry = value(index, path) as? [String: Any] else { return false }
            return entry["Linked"] is [String: Any] || entry["Desktop"] is [String: Any] || entry["Idle"] is [String: Any]
        }
    }

    private static func withChoice(_ slot: [String: Any], _ choice: [String: Any]) -> [String: Any] {
        var slot = slot
        var content = slot["Content"] as? [String: Any] ?? [:]
        var list = content["Choices"] as? [Any] ?? []
        if list.isEmpty { list = [choice] } else { list[0] = choice }
        content["Choices"] = list
        slot["Content"] = content
        return slot
    }

    private static func candidatePaths(_ index: [String: Any]) -> [[String]] {
        var paths: [[String]] = []
        if let displays = index["Displays"] as? [String: Any] {
            paths += displays.keys.sorted().map { ["Displays", $0] }
        }
        if let spaces = index["Spaces"] as? [String: Any] {
            for sid in spaces.keys.sorted() {
                guard let space = spaces[sid] as? [String: Any] else { continue }
                if let displays = space["Displays"] as? [String: Any] {
                    paths += displays.keys.sorted().map { ["Spaces", sid, "Displays", $0] }
                }
                paths.append(["Spaces", sid, "Default"])
            }
        }
        paths += indexKeys.map { [$0] }
        return paths
    }

    private static func desktopKey(_ entry: [String: Any]) -> String? {
        entry["Linked"] is [String: Any] ? "Linked" : entry["Desktop"] is [String: Any] ? "Desktop" : nil
    }

    static func desktopChoices(_ entry: [String: Any]) -> [Any]? {
        guard let key = desktopKey(entry), let slot = entry[key] as? [String: Any],
            let content = slot["Content"] as? [String: Any] else { return nil }
        return content["Choices"] as? [Any]
    }

    private static func value(_ dict: [String: Any], _ path: [String]) -> Any? {
        guard let head = path.first else { return dict }
        guard let next = dict[head] else { return nil }
        if path.count == 1 { return next }
        guard let sub = next as? [String: Any] else { return nil }
        return value(sub, Array(path.dropFirst()))
    }

    /// 경로의 중간 칸이 없으면 아무것도 하지 않는다(그 사이 디스플레이가 사라진 경우 등)
    private static func setValue(_ dict: inout [String: Any], _ path: [String], _ newValue: Any) {
        guard let head = path.first else { return }
        if path.count == 1 { dict[head] = newValue; return }
        guard var sub = dict[head] as? [String: Any] else { return }
        setValue(&sub, Array(path.dropFirst()), newValue)
        dict[head] = sub
    }

    private static func digestPrefix(_ url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        var h = SHA256()
        while let chunk = try? fh.read(upToCount: 1 << 20), !chunk.isEmpty { h.update(data: chunk) }
        return h.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
