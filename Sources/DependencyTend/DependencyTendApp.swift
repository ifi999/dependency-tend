import AppCore
import AppKit
import SwiftUI

@main
struct DependencyTendApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppComposition.makeViewModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            // 뱃지: "⬆12 ⚠1" / "✓"
            Text(model.badgeText)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 메뉴바 전용 앱: Dock 아이콘 숨김 (swift run으로 실행해도 적용)
        NSApp.setActivationPolicy(.accessory)
    }
}
