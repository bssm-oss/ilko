import AppKit
import Combine

/// SSID 변경을 구독하고, 매칭 프로필의 월페이퍼를 적용한다.
@MainActor
class SwitchController: ObservableObject {
    @Published private(set) var activeProfile: Profile?

    private let profileManager: ProfileManager
    private let locationWatcher: LocationWatcher
    private let engine: WallpaperEngine
    private let lockScreen: LockScreenCoordinator
    private var cancellable: AnyCancellable?

    init(profileManager: ProfileManager, locationWatcher: LocationWatcher, engine: WallpaperEngine,
         lockScreen: LockScreenCoordinator) {
        self.profileManager = profileManager
        self.lockScreen = lockScreen
        self.locationWatcher = locationWatcher
        self.engine = engine

        cancellable = locationWatcher.$currentGatewayMAC
            .dropFirst()  // 초기값 nil 무시 — LocationWatcher가 실제 체크한 후에만 반응
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mac in
                Task { @MainActor [weak self] in self?.onNetworkChange(mac) }
            }
    }

    /// 메뉴바 등에서 수동으로 프로필을 전환할 때 사용한다.
    func apply(_ profile: Profile) {
        applyProfile(profile)
    }

    /// 현재 네트워크에 맞는 프로필을 강제로 적용한다 (이미 활성 중이어도 재적용).
    func applyCurrentNetwork() {
        let mac = locationWatcher.currentGatewayMAC
        guard let profile = profileManager.profileFor(gatewayMAC: mac) else {
            print("[SwitchController] ❌ 매칭 프로필 없음 (mac: \(mac ?? "nil"))")
            return
        }
        print("[SwitchController] 🔄 강제 적용: \(profile.name)")
        applyProfile(profile)
    }

    private func onNetworkChange(_ mac: String?) {
        let allProfiles = profileManager.profiles.map { "\($0.name)[\($0.gatewayMAC ?? "기본")]" }.joined(separator: ", ")
        print("[SwitchController] 네트워크 변경 감지: \(mac ?? "nil") | 등록 프로필: \(allProfiles)")
        guard let profile = profileManager.profileFor(gatewayMAC: mac) else {
            print("[SwitchController] ❌ 매칭 프로필 없음")
            return
        }
        print("[SwitchController] ✅ 매칭: \(profile.name) (MAC: \(profile.gatewayMAC ?? "기본"), wallpaper: \(profile.wallpaperPath.isEmpty ? "없음" : profile.wallpaperPath))")
        guard profile.id != activeProfile?.id else {
            print("[SwitchController] 이미 활성 프로필, 건너뜀")
            return
        }
        applyProfile(profile)
    }

    private func applyProfile(_ profile: Profile) {
        print("[SwitchController] 프로필 적용 시작: \(profile.name)")
        activeProfile = profile
        profileManager.activeProfileID = profile.id
        let path = profile.wallpaperPath
        guard !path.isEmpty else {
            print("[SwitchController] ⚠️ 월페이퍼 경로가 비어있음 — 프로필은 전환됐지만 월페이퍼 변경 없음")
            return
        }
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "mp4", "mov":
            applyVideo(path)
        case "jpg", "jpeg", "png":
            applyImage(path)
        default:
            break
        }
    }

    /// mp4/mov: WallpaperEngine으로 모든 디스플레이에 루프 재생
    private func applyVideo(_ path: String) {
        let displayIDs = NSScreen.screens.compactMap {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        }
        engine.startWallpaper(withPath: path, onDisplays: displayIDs)
        lockScreen.videoApplied(path: path)  // 잠금화면(Aerial 슬롯) — 켜져 있을 때만 동작
    }

    /// jpg/png: NSWorkspace로 정적 배경 설정, 기존 라이브 데몬 종료
    private func applyImage(_ path: String) {
        let url = URL(fileURLWithPath: path)
        for screen in NSScreen.screens {
            try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
        }
        engine.killAllDaemons()
        lockScreen.imageApplied()
    }
}
