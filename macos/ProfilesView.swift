import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Profiles View
struct ProfilesView: View {
    @EnvironmentObject var profileManager: ProfileManager
    @EnvironmentObject var locationWatcher: LocationWatcher
    @EnvironmentObject var switchController: SwitchController
    @Binding var editingProfile: Profile?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("프로필 관리")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button {
                    editingProfile = Profile(id: UUID(), name: "", gatewayMAC: locationWatcher.currentGatewayMAC, wallpaperPath: "")
                } label: {
                    Label("추가", systemImage: "plus")
                }
            }
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(profileManager.profiles) { profile in
                        ProfileRowView(
                            profile: profile,
                            currentNetworkID: locationWatcher.currentGatewayMAC,
                            onEdit: { editingProfile = profile },
                            onDelete: {
                                let isActive = switchController.activeProfile?.id == profile.id
                                profileManager.delete(id: profile.id)
                                if isActive, let fallback = profileManager.profiles.first(where: { $0.gatewayMAC == nil }) {
                                    switchController.apply(fallback)
                                }
                            }
                        )
                    }
                }
                .padding()
            }
        }
        .padding()
        .frame(width: 500, height: 400)
        .contentShape(Rectangle())
        .background(.ultraThinMaterial)
        .compatibleGlass(cornerRadius: 1)
    }
}

// MARK: - Profile Row
struct ProfileRowView: View {
    let profile: Profile
    let currentNetworkID: String?
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).fontWeight(.medium)
                Text(profile.gatewayMAC.map { "MAC: \($0)" } ?? "기본 프로필")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("편집", action: onEdit)
            if profile.gatewayMAC != nil {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Profile Editor Sheet
struct ProfileEditorView: View {
    @EnvironmentObject var lockScreen: LockScreenCoordinator
    @State var profile: Profile
    let isDefaultProfile: Bool
    let existingProfiles: [Profile]
    let currentNetworkID: String?
    let onSave: (Profile) -> Void
    let onCancel: () -> Void

    @State private var thumbnailImage: NSImage?
    /// 저장 시 잠금화면용 변환 작업 (진행 중이면 변환 창 표시)
    @State private var conversion: Task<Void, Never>?

    private var isDuplicateName: Bool {
        existingProfiles.contains { $0.id != profile.id && $0.name == profile.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(profile.wallpaperPath.isEmpty ? "프로필 추가" : "프로필 편집")
                .font(.title2).fontWeight(.bold)

            // 이름
            HStack(alignment: .top, spacing: 12) {
                Text("이름")
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .trailing)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("홈, 카페, 회사…", text: $profile.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .disabled(isDefaultProfile)
                    if isDuplicateName {
                        Text("이미 같은 이름의 프로필이 있어요.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            // 네트워크
            HStack(spacing: 12) {
                Text("네트워크")
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .trailing)
                Text(profile.gatewayMAC ?? "없음 = 기본 프로필")
                    .foregroundStyle(profile.gatewayMAC == nil ? .secondary : .primary)
                    .frame(width: 160, alignment: .leading)
                    .font(.system(.body, design: .monospaced))
                if !isDefaultProfile {
                    if let mac = currentNetworkID {
                        if profile.gatewayMAC == mac {
                            Label("현재 네트워크", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Button("현재 네트워크로") {
                                profile.gatewayMAC = mac
                            }
                            .font(.caption)
                        }
                    }
                }
            }

            // 월페이퍼 파일
            HStack(spacing: 12) {
                Text("월페이퍼")
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .trailing)
                Text(profile.wallpaperPath.isEmpty
                     ? "파일 없음"
                     : URL(fileURLWithPath: profile.wallpaperPath).lastPathComponent)
                    .foregroundStyle(profile.wallpaperPath.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 160, alignment: .leading)
                Button("선택") { openFilePicker() }
            }

            // 미리보기 (hit-testing 비활성화: 썸네일이 위 버튼 영역을 덮지 않도록)
            if let img = thumbnailImage {
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 160)
                    .overlay(
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFill()
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                    .allowsHitTesting(false)
            }

            Divider()

            HStack {
                Spacer()
                Button("취소", action: onCancel)
                Button("저장") { save() }
                .buttonStyle(.borderedProminent)
                .disabled(profile.name.isEmpty || profile.wallpaperPath.isEmpty || isDuplicateName || conversion != nil)
            }
        }
        .padding(24)
        .frame(width: 460)
        .overlay {
            // 리눅스 버전처럼: 저장 시 변환이 끝날 때까지 기다리게 하는 변환 창
            if conversion != nil {
                ZStack {
                    Color.black.opacity(0.35)
                    VStack(spacing: 12) {
                        Text(L.lockScreenEncoding).font(.headline)
                        Text(URL(fileURLWithPath: profile.wallpaperPath).lastPathComponent)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        let p = lockScreen.progress[profile.wallpaperPath] ?? 0
                        ProgressView(value: p).frame(width: 240)
                        Text("\(Int(p * 100))%").font(.caption).monospacedDigit()
                        Button("취소") { conversion?.cancel() }
                    }
                    .padding(24)
                    .frame(width: 320)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .task(id: profile.wallpaperPath) {
            thumbnailImage = await loadThumbnail(path: profile.wallpaperPath)
        }
    }

    /// 잠금화면 기능이 켜져 있고 영상이면 변환이 끝난 뒤 저장한다. 취소하면 편집 창에 남는다.
    private func save() {
        let path = profile.wallpaperPath
        guard lockScreen.isEnabled, !CloudFile.needsMaterialization(URL(fileURLWithPath: path)) else {
            onSave(profile)
            return
        }
        conversion = Task { @MainActor in
            let ok = await lockScreen.convertForProfile(path: path)
            conversion = nil
            if ok { onSave(profile) }
        }
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .jpeg, .png]

        guard let window = NSApp.keyWindow else {
            if panel.runModal() == .OK, let url = panel.url {
                applySelectedURL(url)
            }
            return
        }

        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async { applySelectedURL(url) }
        }
    }

    private func applySelectedURL(_ url: URL) {
        // 클라우드/온라인 전용 소스는 로컬로 복사하지 않는다(용량). 원본을 그대로 참조하고
        // 썸네일만 레이지 생성한다. 로컬 소스만 ilko 디렉터리로 복사한다.
        if CloudFile.needsMaterialization(url) {
            profile.wallpaperPath = url.path
            return
        }
        do {
            let dest = try ProfileManager.importWallpaper(from: url)
            profile.wallpaperPath = dest.path
        } catch {
            NSLog("applySelectedURL: importWallpaper failed for \(url.path): \(error)")
            profile.wallpaperPath = url.path
        }
    }

    private func loadThumbnail(path: String) async -> NSImage? {
        guard !path.isEmpty else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png":
            return NSImage(contentsOfFile: path)
        case "mp4", "mov":
            return await Task.detached(priority: .utility) {
                let asset = AVAsset(url: URL(fileURLWithPath: path))
                let gen = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 800, height: 500)
                guard let cgImage = try? gen.copyCGImage(at: .zero, actualTime: nil) else { return nil }
                return NSImage(cgImage: cgImage, size: .zero)
            }.value
        default:
            return nil
        }
    }


}
