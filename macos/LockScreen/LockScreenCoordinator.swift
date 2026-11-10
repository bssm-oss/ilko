import AppKit
import Combine

/// 잠금화면 영상 기능의 앱 측 조정자.
/// 영상 프로필이 적용되면 백그라운드에서 변환 → Aerial 슬롯 적용을 수행한다.
/// 데스크탑 재생(wallpaperdaemon)과는 독립적이며, 실패해도 데스크탑에는 영향이 없다.
@MainActor
final class LockScreenCoordinator: ObservableObject {
    static let changedNotification = "com.live.wallpaper.lockScreenChanged" as CFString

    @Published private(set) var isEncoding = false
    @Published private(set) var isSupported = false
    @Published var notice: String?
    @Published private(set) var isEnabled: Bool
    @Published private(set) var selectedAssetID: String?

    let catalog: AerialCatalog?
    private let slot: LockScreenSlot
    private let encoder: AerialEncoder
    private let defaults = UserDefaults.standard
    private var job: Task<Void, Never>?
    private var lastVideoPath: String?
    private var unlockObserver: NSObjectProtocol?

    init(slot: LockScreenSlot = LockScreenSlot(), encoder: AerialEncoder = AerialEncoder()) {
        self.slot = slot
        self.encoder = encoder
        catalog = try? AerialCatalog()
        isSupported = catalog != nil && (try? slot.validateIndexFormat()) != nil
        isEnabled = defaults.bool(forKey: UserDefaultsKeys.lockScreenEnabled)
        selectedAssetID = defaults.string(forKey: UserDefaultsKeys.lockScreenAssetID)
        if !isSupported && isEnabled { persistEnabled(false) }

        unlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.selfHeal() }
        }
    }

    var selectedAsset: AerialAsset? { selectedAssetID.flatMap { catalog?.asset(id: $0) } }

    // MARK: - SwitchController 에서 호출

    func videoApplied(path: String) {
        lastVideoPath = path
        if isEnabled { schedule(path) }
    }

    func imageApplied() {
        lastVideoPath = nil
        job?.cancel()
    }

    // MARK: - 설정 UI 에서 호출

    func setEnabled(_ on: Bool) {
        guard on != isEnabled, !on || isSupported else { return }
        if on {
            if selectedAsset == nil {
                let current = slot.currentSelectedAssetID()
                selectedAssetID = catalog?.defaultSlot(excluding: current)?.id
                defaults.set(selectedAssetID, forKey: UserDefaultsKeys.lockScreenAssetID)
            }
            persistEnabled(true)
            if let path = lastVideoPath { schedule(path) }
        } else {
            job?.cancel()
            persistEnabled(false)
            let slot = self.slot, id = selectedAssetID, wasVideo = lastVideoPath != nil
            Task.detached {
                if let id { try? slot.removeSlotFile(assetID: id) }
                // 영상 프로필 중이면 원래 배경 선택으로 복원, 이미지 프로필이면 그 이미지를 유지
                if wasVideo { try? slot.restore() } else { slot.discardBackup() }
            }
        }
    }

    func selectSlot(_ assetID: String) {
        guard assetID != selectedAssetID else { return }
        if let old = selectedAssetID { try? slot.removeSlotFile(assetID: old) }
        selectedAssetID = assetID
        defaults.set(assetID, forKey: UserDefaultsKeys.lockScreenAssetID)
        if isEnabled, let path = lastVideoPath { schedule(path) }
    }

    /// 잠금 해제·앱 시작 시: 슬롯이 지워졌거나 원본으로 돌아갔으면 다시 적용,
    /// 사용자가 시스템 설정에서 배경을 바꿨으면 기능을 끈다.
    func selfHeal() {
        guard isEnabled, !isEncoding, let path = lastVideoPath, let asset = selectedAsset else { return }
        let slot = self.slot, encoder = self.encoder
        Task {
            guard let encoded = try? await encoder.encode(source: URL(fileURLWithPath: path)) else { return }
            let status = await Task.detached { slot.status(encoded: encoded, asset: asset) }.value
            switch status {
            case .intact:
                break
            case .fileMissingOrReplaced:
                print("[LockScreen] 슬롯이 사라짐/교체됨 — 재적용")
                schedule(path)
            case .selectionChangedByUser:
                print("[LockScreen] 시스템 배경이 변경됨 — 기능 끔")
                job?.cancel()
                try? slot.removeSlotFile(assetID: asset.id)
                slot.discardBackup()
                persistEnabled(false)
                notice = L.lockScreenDisabledNotice
            }
        }
    }

    // MARK: - 내부

    private func schedule(_ path: String) {
        job?.cancel()
        guard let asset = selectedAsset else {
            print("[LockScreen] ⚠️ 슬롯 미선택")
            return
        }
        let slot = self.slot, encoder = self.encoder
        job = Task {
            isEncoding = true
            defer { isEncoding = false }
            do {
                let encoded = try await encoder.encode(source: URL(fileURLWithPath: path))
                // 변환 중 다른 프로필로 바뀌었거나 기능이 꺼졌으면 적용하지 않는다(최신 요청만)
                guard !Task.isCancelled, isEnabled, lastVideoPath == path else { return }
                try await Task.detached { try slot.apply(encoded: encoded, asset: asset) }.value
                print("[LockScreen] ✅ 잠금화면 영상 적용: \(asset.name)")
            } catch {
                print("[LockScreen] ❌ \(error)")
            }
        }
    }

    private func persistEnabled(_ on: Bool) {
        isEnabled = on
        defaults.set(on, forKey: UserDefaultsKeys.lockScreenEnabled)
        defaults.synchronize()
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(Self.changedNotification), nil, nil, true)
    }
}
