/*
 * This file is part of LiveWallpaper – LiveWallpaper App for macOS.
 * Copyright (C) 2025 Bios thusvill
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import AppKit
import SwiftUI

// MARK: - Main Content View
struct ContentView: View {
    @StateObject private var viewModel = WallpaperViewModel()
    @State private var showSettings = false
    @State private var showProfiles = false
    @State private var editingProfile: Profile?
    @EnvironmentObject var locationWatcher: LocationWatcher
    @EnvironmentObject var switchController: SwitchController
    @EnvironmentObject var profileManager: ProfileManager

    @Environment(\.dismiss) private var dismiss
    static var didCloseOnLaunch = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Spacer(minLength: 20)
                ToolbarView(
                    showSettings: $showSettings,
                    showProfiles: $showProfiles,
                    onReload: {
                        viewModel.reloadContent()
                        switchController.applyCurrentNetwork()
                    }
                )
                .padding(.horizontal).padding(.top, 24).padding(.bottom, 12)

                ZStack(alignment: .bottom) {
                    VideoGridView(
                        videos: viewModel.videos, viewModel: viewModel,
                        onVideoSelect: { video in
                            viewModel.startWallpaper(video: video)
                        }
                    )
                    .padding(.horizontal, 24).padding(.bottom, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .ignoresSafeArea(.all)
            .compatibleGlass(cornerRadius: 16)
            .frame(minWidth: 600, minHeight: 250)
            .onAppear {
                viewModel.reloadContent()
                if !Self.didCloseOnLaunch, !viewModel.engine.isFirstLaunch() {
                    Self.didCloseOnLaunch = true
                    dismiss()
                }
            }

            if showSettings {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { showSettings = false }

                SettingsView(viewModel: viewModel)
                    .shadow(radius: 3)
                    .cornerRadius(15)
                    .animation(.easeInOut, value: showSettings)
            }

            if showProfiles {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { showProfiles = false }

                ProfilesView(editingProfile: $editingProfile)
                    .shadow(radius: 3)
                    .cornerRadius(15)
                    .animation(.easeInOut, value: showProfiles)
            }
        }
        .animation(.easeInOut, value: showSettings)
        .animation(.easeInOut, value: showProfiles)
        .sheet(item: $editingProfile) { profile in
            ProfileEditorView(
                profile: profile,
                isDefaultProfile: profile.gatewayMAC == nil,
                existingProfiles: profileManager.profiles,
                currentNetworkID: locationWatcher.currentGatewayMAC,
                onSave: { updated in
                    let isNew = !profileManager.profiles.contains(where: { $0.id == updated.id })
                    if isNew {
                        profileManager.add(updated)
                        switchController.apply(updated)
                    } else {
                        profileManager.update(updated)
                        if switchController.activeProfile?.id == updated.id {
                            switchController.apply(updated)
                        }
                    }
                    editingProfile = nil
                },
                onCancel: { editingProfile = nil }
            )
        }
    }
}

// MARK: - Toolbar View
struct ToolbarView: View {
    @Binding var showSettings: Bool
    @Binding var showProfiles: Bool
    let onReload: () -> Void

    var body: some View {
        HStack {
            Spacer()

            if #available(macOS 26.0, *) {
                Button(action: onReload) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16))
                }
                .buttonStyle(.glass)
            } else {
                Button(action: onReload) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16))
                }
            }

            if #available(macOS 26.0, *) {
                Button(action: { showProfiles = true }) {
                    Image(systemName: "person.2")
                        .font(.system(size: 16))
                }
                .buttonStyle(.glass)
            } else {
                Button(action: { showProfiles = true }) {
                    Image(systemName: "person.2")
                        .font(.system(size: 16))
                }
            }

            if #available(macOS 26.0, *) {
                Button(action: { showSettings = true }) {
                    Image(systemName: "gear")
                        .font(.system(size: 16))
                }
                .buttonStyle(.glass)
            } else {
                Button(action: { showSettings = true }) {
                    Image(systemName: "gear")
                        .font(.system(size: 16))
                }
            }
        }
    }
}

#Preview {
    ContentView()
}

#Preview {
    SettingsView(viewModel: WallpaperViewModel())
        .environmentObject(LockScreenCoordinator())
        .environmentObject(ProfileManager())
        .environmentObject(LocationWatcher())
}
