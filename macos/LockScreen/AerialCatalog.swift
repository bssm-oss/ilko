import Foundation

/// 잠금화면 기능 공통 오류
nonisolated enum LockScreenError: Error, Equatable {
    case unsupportedFormat(String)
    case encodeFailed(String)
    case io(String)
}

/// macOS Aerial 배경화면 하나
nonisolated struct AerialAsset: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let sourceURL: URL
    let thumbnailURL: URL?
    let showInTopLevel: Bool
    let includeInShuffle: Bool
}

/// WallpaperAerialsExtension 에 내장된 Aerial 카탈로그(entries.json) 리더.
/// 잠금화면 영상을 덮어쓸 "슬롯" 후보 목록을 제공한다.
nonisolated struct AerialCatalog: Sendable {
    static let systemManifestURL = URL(
        fileURLWithPath:
            "/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex/Contents/Resources/entries.json"
    )
    static let systemThumbnailsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials/thumbnails")

    let assets: [AerialAsset]

    init(manifestURL: URL = systemManifestURL, thumbnailsDir: URL = systemThumbnailsDir) throws {
        let data: Data
        do { data = try Data(contentsOf: manifestURL) } catch {
            throw LockScreenError.io("manifest unreadable: \(manifestURL.path)")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let raw = root["assets"] as? [[String: Any]]
        else { throw LockScreenError.unsupportedFormat("entries.json has no assets array") }

        let fm = FileManager.default
        assets = raw.compactMap { item in
            guard let id = item["id"] as? String,
                let urlString = item["url-4K-SDR-240FPS"] as? String,
                let url = URL(string: urlString)
            else { return nil }
            let thumb = thumbnailsDir.appendingPathComponent("\(id).png")
            return AerialAsset(
                id: id,
                name: item["accessibilityLabel"] as? String ?? id,
                sourceURL: url,
                thumbnailURL: fm.fileExists(atPath: thumb.path) ? thumb : nil,
                showInTopLevel: item["showInTopLevel"] as? Bool ?? true,
                includeInShuffle: item["includeInShuffle"] as? Bool ?? true
            )
        }
        if assets.isEmpty { throw LockScreenError.unsupportedFormat("no usable aerial assets") }
    }

    func asset(id: String) -> AerialAsset? { assets.first { $0.id == id } }

    /// 사용자가 잘 쓰지 않을 슬롯을 기본값으로 고른다.
    func defaultSlot(excluding: String?) -> AerialAsset? {
        Self.pickDefault(from: assets, excluding: excluding)
    }

    static func pickDefault(from assets: [AerialAsset], excluding: String?) -> AerialAsset? {
        let candidates = assets.filter { $0.id != excluding }
        return candidates.first { !$0.showInTopLevel && !$0.includeInShuffle }
            ?? candidates.first { !$0.showInTopLevel }
            ?? candidates.last
    }
}
