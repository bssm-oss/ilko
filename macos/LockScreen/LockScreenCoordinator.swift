import AppKit
import Combine

nonisolated enum LockScreenNotice: Equatable, Sendable {
    /// 사용자가 시스템 설정에서 배경을 바꿔 기능을 껐음
    case systemWallpaperChanged
}

/// 슬롯 쓰기를 직렬화한다. 오래된 작업의 apply 가 최신 apply 와 겹치지 않게 한다.
private actor SlotWriter {
    let slot: LockScreenSlot
    init(_ slot: LockScreenSlot) { self.slot = slot }

    func apply(_ encoded: URL, _ asset: AerialAsset) throws { try slot.apply(encoded: encoded, asset: asset) }
    func release(_ id: String) { try? slot.releaseSlotFile(assetID: id) }
    func status(_ encoded: URL, _ asset: AerialAsset) -> SlotStatus { slot.status(encoded: encoded, asset: asset) }

    /// 기능 끄기: 영상 모드면 원래 선택 복원, 아니면 슬롯만 놓고 백업 폐기
    func disable(slotID: String?, restoreChoices: Bool) {
        if let slotID { try? slot.releaseSlotFile(assetID: slotID) }
        if restoreChoices {
            do { try slot.restore() } catch {
                print("[LockScreen] restore 실패: \(error)")
                slot.discardBackup()
            }
        } else {
            slot.discardBackup()
        }
    }
}

/// 잠금화면 영상 기능의 앱 측 조정자.
/// 영상 프로필이 적용되면 백그라운드에서 변환 → Aerial 슬롯 적용을 수행한다.
/// 데스크탑 재생(wallpaperdaemon)과는 독립적이며, 실패해도 데스크탑에는 영향이 없다.
///
/// 모든 작업(적용·자가복구·끄기)은 하나의 `job` 으로 직렬화되며, 세대(generation)가 바뀌면
/// 이전 작업은 취소되고 그 결과는 버려진다.
@MainActor
final class LockScreenCoordinator: ObservableObject {
    nonisolated static let changedNotification = "com.live.wallpaper.lockScreenChanged"
    static let enabledKey = "lockscreen_enabled"
    static let assetKey = "lockscreen_asset_id"

    @Published private(set) var isEncoding = false
    /// 변환 중인 영상 경로 → 진행률(0~1)
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var isSupported = false
    @Published var notice: LockScreenNotice?
    @Published private(set) var isEnabled: Bool
    @Published private(set) var selectedAssetID: String?

    let catalog: AerialCatalog?
    private let slot: LockScreenSlot
    private let writer: SlotWriter
    private let encoder: AerialEncoder
    private let store: UserDefaults
    private let notifyChange: () -> Void
    private let disableSettleDelay: Double

    private(set) var job: Task<Void, Never>?
    private var generation = 0
    private var busy = false
    private var lastVideoPath: String?
    /// 이 실행에서 실제로 적용에 성공한 슬롯 (실패/미적용이면 nil)
    private var appliedAssetID: String?
    private var unlockObserver: NSObjectProtocol?

    init(slot: LockScreenSlot = LockScreenSlot(), encoder: AerialEncoder = AerialEncoder(),
         catalog: AerialCatalog? = try? AerialCatalog(), defaults: UserDefaults = .standard,
         disableSettleDelay: Double = 1.0,
         notifyChange: @escaping () -> Void = LockScreenCoordinator.postDarwinChange) {
        self.slot = slot
        self.writer = SlotWriter(slot)
        self.encoder = encoder
        self.catalog = catalog
        self.store = defaults
        self.notifyChange = notifyChange
        self.disableSettleDelay = disableSettleDelay
        isSupported = catalog != nil && (try? slot.validateIndexFormat()) != nil
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        selectedAssetID = defaults.string(forKey: Self.assetKey)
        if !isSupported && isEnabled { persistEnabled(false) }

        Task { [weak self] in
            await encoder.setProgressHandler { url, p in
                Task { @MainActor in self?.updateProgress(url.path, p) }
            }
        }

        unlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.selfHeal() }
        }
    }

    var selectedAsset: AerialAsset? { selectedAssetID.flatMap { catalog?.asset(id: $0) } }

    /// 슬롯으로 고르면 안 되는 Aerial: 사용자의 원래 Aerial (백업 기준, 없으면 현재 시스템 선택)
    var excludedAssetID: String? {
        slot.originalAssetID() ?? (appliedAssetID == nil ? slot.currentSelectedAssetID() : nil)
    }

    // MARK: - SwitchController 에서 호출

    func videoApplied(path: String) {
        lastVideoPath = path
        if isEnabled { schedule(path) }
    }

    func imageApplied() {
        lastVideoPath = nil
        appliedAssetID = nil  // 시스템 배경이 이미지로 바뀜 → 다음 영상 때 다시 적용
        startJob { _ in }     // 진행 중 변환 취소
    }

    /// 프로필 저장 시 호출: 잠금화면용 변환을 끝까지 기다린다(적용은 하지 않음).
    /// 기능이 꺼져 있거나 영상이 아니면 바로 true. 호출 Task 가 취소되면 변환을 멈추고 false.
    func convertForProfile(path: String) async -> Bool {
        guard isEnabled, ["mp4", "mov"].contains((path as NSString).pathExtension.lowercased()) else { return true }
        progress[path] = progress[path] ?? 0
        defer { progress[path] = nil }
        do {
            _ = try await encoder.encode(source: URL(fileURLWithPath: path))
            return !Task.isCancelled
        } catch {
            print("[LockScreen] 프로필 변환 실패/취소: \(error)")
            return false
        }
    }

    // MARK: - 설정 UI 에서 호출

    func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        if on {
            guard isSupported else { return }
            let excluded = excludedAssetID
            if selectedAsset == nil || selectedAssetID == excluded {
                guard let pick = catalog?.defaultSlot(excluding: excluded) else { return }
                setSelected(pick.id)
            }
            persistEnabled(true)
            notifyChange()
            if let path = lastVideoPath { schedule(path) }
        } else {
            let id = selectedAssetID, wasVideo = lastVideoPath != nil
            let writer = self.writer, delay = disableSettleDelay
            persistEnabled(false)
            appliedAssetID = nil
            startJob { [weak self] _ in
                await writer.disable(slotID: id, restoreChoices: wasVideo)
                // WallpaperAgent 재기동을 기다린 뒤 daemon 에 알려 png 정적 배경이 마지막에 적용되게 한다
                if wasVideo && delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
                self?.notifyChange()
            }
        }
    }

    func selectSlot(_ assetID: String) {
        guard assetID != selectedAssetID, assetID != excludedAssetID else { return }
        let old = selectedAssetID
        setSelected(assetID)
        appliedAssetID = nil
        let writer = self.writer
        if let old { Task { await writer.release(old) } }
        if isEnabled, let path = lastVideoPath { schedule(path) }
    }

    /// 잠금 해제·앱 시작 시: 슬롯이 지워졌거나 원본으로 돌아갔으면 다시 적용,
    /// 사용자가 시스템 설정에서 배경을 바꿨으면 기능을 끈다.
    func selfHeal() {
        guard isEnabled, !busy, let path = lastVideoPath, let asset = selectedAsset else { return }
        // 이번 실행에서 적용에 성공한 적이 없으면(실패 등) 사용자 변경으로 오판하지 말고 재시도
        guard appliedAssetID == asset.id else {
            schedule(path)
            return
        }
        let encoder = self.encoder, writer = self.writer
        startJob { [weak self] gen in
            guard let encoded = try? await encoder.encode(source: URL(fileURLWithPath: path)) else { return }
            let status = await writer.status(encoded, asset)
            guard let self, self.isCurrent(gen), self.isEnabled, self.lastVideoPath == path else { return }
            switch status {
            case .intact:
                break
            case .fileMissingOrReplaced:
                print("[LockScreen] 슬롯이 사라짐/교체됨 — 재적용")
                self.schedule(path)
            case .selectionChangedByUser:
                print("[LockScreen] 시스템 배경이 변경됨 — 기능 끔")
                self.persistEnabled(false)
                self.appliedAssetID = nil
                self.notice = .systemWallpaperChanged
                await writer.disable(slotID: asset.id, restoreChoices: false)
                self.notifyChange()
            }
        }
    }

    /// 진행 중인 작업이 모두 끝날 때까지 기다린다
    func settle() async {
        while let j = job {
            await j.value
            if job == j { return }
        }
    }

    nonisolated static func postDarwinChange() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(changedNotification as CFString),
            nil, nil, true)
    }

    // MARK: - 내부

    private func schedule(_ path: String) {
        guard let asset = selectedAsset else {
            print("[LockScreen] ⚠️ 슬롯 미선택")
            return
        }
        let encoder = self.encoder, writer = self.writer
        startJob { [weak self] gen in
            do {
                let encoded = try await encoder.encode(source: URL(fileURLWithPath: path))
                // 변환 중 다른 요청이 들어왔거나 기능이 꺼졌으면 적용하지 않는다(최신 요청만)
                guard let self, self.isCurrent(gen), self.isEnabled, self.lastVideoPath == path else { return }
                try await writer.apply(encoded, asset)
                if self.isCurrent(gen) { self.appliedAssetID = asset.id }
                print("[LockScreen] ✅ 잠금화면 영상 적용: \(asset.name)")
            } catch {
                print("[LockScreen] ❌ \(error)")
            }
        }
        isEncoding = true  // startJob 이 끝날 때 최신 세대 작업만 내린다
    }

    /// 이전 작업을 취소하고 새 세대의 작업을 시작한다. 최신 세대 작업이 끝날 때만 상태를 내린다.
    private func startJob(_ body: @escaping @MainActor (Int) async -> Void) {
        generation += 1
        let gen = generation
        job?.cancel()
        busy = true
        isEncoding = false
        job = Task { [weak self] in
            await body(gen)
            guard let self, self.generation == gen else { return }
            self.busy = false
            self.isEncoding = false
        }
    }

    private func updateProgress(_ path: String, _ p: Double) {
        guard let old = progress[path] else { return }  // 이미 끝났거나 추적하지 않는 경로
        if p > old { progress[path] = p }
    }

    private func isCurrent(_ gen: Int) -> Bool { gen == generation && !Task.isCancelled }

    private func setSelected(_ id: String) {
        selectedAssetID = id
        store.set(id, forKey: Self.assetKey)
    }

    private func persistEnabled(_ on: Bool) {
        isEnabled = on
        store.set(on, forKey: Self.enabledKey)
        store.synchronize()
    }
}
