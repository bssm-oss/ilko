import AppKit
import SwiftUI

// MARK: - Settings View
struct SettingsView: View {
    @ObservedObject var viewModel: WallpaperViewModel
    @EnvironmentObject var lockScreen: LockScreenCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var showFolderPicker = false
    @AppStorage(UserDefaultsKeys.scaleMode) var scaleMode: Int = 0
    @State private var isShowingView = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Header
            HStack {
                Text(L.settings)
                    .font(.title2)
                    .fontWeight(.bold)
            }
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Folder Selection
                    SettingRow(title: L.wallpaperFolder) {
                        HStack {
                            TextField(L.selectFolderOrType, text: $viewModel.folderPath)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                            Button(action: selectFolder) {
                                Image(systemName: "folder.fill")
                            }
                            Button(action: openInFinder) {
                                Image(systemName: "finder")
                            }
                        }
                    }

                    Divider()

                    // Scale Mode
                    SettingRow(title: L.videoScalingMode) {
                        Picker("", selection: $scaleMode) {
                            Text(L.scaleFill).tag(0)
                            Text(L.scaleFit).tag(1)
                            Text(L.scaleStretch).tag(2)
                            Text(L.scaleCenter).tag(3)
                            Text(L.scaleHeightFill).tag(4)
                        }
                        .onChange(of: scaleMode) {
                            viewModel.engine.updateScaleMode(scaleMode)
                        }
                    }

                    Divider()

                    // Auto-Pause When App is Active
                    SettingRow(title: L.pauseWhenActive) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: {
                                    UserDefaults.standard.bool(
                                        forKey: UserDefaultsKeys.pauseOnAppFocus)
                                },
                                set: {
                                    UserDefaults.standard.set(
                                        $0, forKey: UserDefaultsKeys.pauseOnAppFocus)
                                }
                            )
                        )
                        .toggleStyle(.switch)
                    }

                    // Vignette Bar
                    SettingRow(title: L.vinttageBar) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: {
                                    UserDefaults.standard.bool(forKey: UserDefaultsKeys.vignetteBar)
                                },
                                set: {
                                    UserDefaults.standard.set(
                                        $0, forKey: UserDefaultsKeys.vignetteBar)
                                }
                            )
                        )
                        .toggleStyle(.switch)
                    }

                    Divider()

                    // Video Volume
                    SettingRow(title: L.videoVolume) {
                        HStack {
                            Slider(value: $viewModel.volume, in: 0...100, step: 1)
                                .frame(width: 200)
                                .onChange(of: viewModel.volume) { newValue in
                                    viewModel.engine.updateVolume(newValue)
                                }
                            Text("\(Int(viewModel.volume))%")
                                .frame(width: 60, alignment: .leading)
                                .monospacedDigit()
                        }
                    }

                    Divider()

                    // Lock Screen (Aerial slot)
                    LockScreenSettingsSection()

                    Divider()

                    // Optimize Videos
                    SettingRow(title: L.optimizeCodecs) {
                        Button(L.optimize) {
                            viewModel.optimizeVideos()
                        }
                        .disabled(true)
                    }

                    // Clear Cache
                    SettingRow(title: L.clearCache) {
                        Button(L.clearCacheButton) {
                            viewModel.clearCache()
                        }
                    }

                    // Reset User Data
                    SettingRow(title: L.resetUserData) {
                        Button(L.reset) {
                            // 설정이 지워지기 전에 잠금화면 기능을 꺼서 시스템 배경을 원래대로 되돌린다
                            lockScreen.setEnabled(false)
                            viewModel.resetUserData()
                        }
                    }
                }
                .padding()
            }
        }
        .padding()
        .frame(width: 600, height: 500)
        .background(.ultraThinMaterial)
        .compatibleGlass(cornerRadius: 1)
    }

    func formatTime(_ totalMinutes: Int) -> String {
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        if h > 0 {
            return "\(h)h \(m)m"
        }
        return "\(m) min"
    }

    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = L.selectFolderTitle
        panel.prompt = L.choose

        if panel.runModal() == .OK, let url = panel.url {
            viewModel.folderPath = url.path
            viewModel.engine.selectFolder(url.path())
            viewModel.reloadContent()
        }
    }

    private func openInFinder() {
        if let url = URL(string: "file://\(viewModel.folderPath)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Lock Screen Section
/// 잠금화면 영상: 토글 + 덮어쓸 Aerial 슬롯 선택
struct LockScreenSettingsSection: View {
    @EnvironmentObject var lockScreen: LockScreenCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingRow(title: L.lockScreenVideo) {
                Toggle("", isOn: Binding(get: { lockScreen.isEnabled }, set: { lockScreen.setEnabled($0) }))
                    .toggleStyle(.switch)
                    .disabled(!lockScreen.isSupported)
                if lockScreen.isEncoding {
                    ProgressView().controlSize(.small)
                    Text(L.lockScreenEncoding).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !lockScreen.isSupported {
                Text(L.lockScreenUnsupported).font(.caption).foregroundStyle(.secondary)
            }
            if lockScreen.notice == .systemWallpaperChanged {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text(L.lockScreenDisabledNotice).font(.caption)
                    Spacer()
                    Button { lockScreen.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                }
                .padding(8)
                .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            if lockScreen.isEnabled {
                SettingRow(title: L.lockScreenSaver) {
                    Toggle("", isOn: Binding(get: { lockScreen.screenSaverEnabled },
                                             set: { lockScreen.setScreenSaverEnabled($0) }))
                        .toggleStyle(.switch)
                }
            }
            if lockScreen.isEnabled, let catalog = lockScreen.catalog {
                Text(L.lockScreenSlot).font(.subheadline).fontWeight(.semibold)
                Text(L.lockScreenSlotHint).font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
                        let excluded = lockScreen.excludedAssetID
                        ForEach(catalog.assets) { asset in
                            AerialSlotCell(asset: asset, selected: asset.id == lockScreen.selectedAssetID)
                                // 사용자의 원래 Aerial 은 덮어쓸 수 없다
                                .opacity(asset.id == excluded ? 0.35 : 1)
                                .onTapGesture { lockScreen.selectSlot(asset.id) }
                        }
                    }
                }
                .frame(height: 220)
            }
        }
    }
}

private struct AerialSlotCell: View {
    let asset: AerialAsset
    let selected: Bool

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let url = asset.thumbnailURL, let img = NSImage(contentsOf: url) {
                    Image(nsImage: img).resizable().aspectRatio(16 / 9, contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 120, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(selected ? Color.accentColor : .clear, lineWidth: 3)
            )
            Text(asset.name).font(.caption2).lineLimit(1).frame(width: 120)
        }
    }
}

// MARK: - Setting Row
struct SettingRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack {
            Text(title)
                .frame(width: 200, alignment: .leading)
            content
            Spacer()
        }
    }
}
