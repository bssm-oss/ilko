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

import SwiftUI
import AppKit
import ServiceManagement

let sharedEngine = WallpaperEngine.shared()

@main
struct LiveWallpaperApp: App {
    
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
            Settings { EmptyView() }
    }
        
}


class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    // ilko 핵심 컨트롤러
    let profileManager = ProfileManager()
    let locationWatcher = LocationWatcher()
    let lockScreen = LockScreenCoordinator()
    private var switchController: SwitchController!
    private var menuBarController: MenuBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {

        NSApp.setActivationPolicy(.accessory)

        guard let engine = sharedEngine else {
            fatalError("[AppDelegate] WallpaperEngine 초기화 실패 — 앱을 시작할 수 없습니다.")
        }

        // 컨트롤러 초기화 (순서 중요: watcher → switch → menubar)
        switchController = SwitchController(
            profileManager: profileManager,
            locationWatcher: locationWatcher,
            engine: engine,
            lockScreen: lockScreen
        )
        menuBarController = MenuBarController(
            profileManager: profileManager,
            switchController: switchController,
            engine: engine,
            showWindow: { [weak self] in self?.showWindow() }
        )

        // SSID 폴링 시작
        locationWatcher.start()

        // ilko 전용 월페이퍼 폴더를 WallpaperEngine에 등록
        // (LiveWallpaper의 기존 WallpaperFolder와 분리)
        let ilkoFolder = ProfileManager.wallpapersDirectory.path
        engine.selectFolder(ilkoFolder)

        // 메인 윈도우 (환경 객체 주입)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.toolbarStyle = .unified
        window.center()
        window.contentView = NSHostingView(
            rootView: ContentView()
                .environmentObject(profileManager)
                .environmentObject(locationWatcher)
                .environmentObject(switchController)
                .environmentObject(lockScreen)
        )
        window.title = "ILKO"
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        if !isLoginItemEnabled() {
            setLoginItem(enabled: true)
        }
    }

    @objc func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func hideWindow() {
        window.orderOut(nil)
    }
}

// MARK: Permission Access

func isLoginItemEnabled() -> Bool {
    return UserDefaults.standard.bool(forKey: UserDefaultsKeys.launchAtLogin)
}


func setLoginItem(enabled: Bool) {
    do {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.launchAtLogin)
    } catch {
        print("❌ Failed to update login items: \(error.localizedDescription)")
    }
}

