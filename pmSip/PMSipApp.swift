import AppKit
import Combine
import SwiftUI

@main
struct PMSipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // AppKit handles left-click toggles and right-click menus separately.
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = PMSipState()
    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()

    private static let activeColor = NSColor(red: 0.435, green: 0.306, blue: 0.216, alpha: 1)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else { return }

        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        // @Published emits before the property changes; use the emitted value.
        state.$sleepState
            .sink { [weak self] sleepState in
                self?.updateIcon(sleepState: sleepState)
            }
            .store(in: &cancellables)
        state.$errorMessage
            .sink { [weak self] errorMessage in
                self?.updateTooltip(errorMessage: errorMessage)
            }
            .store(in: &cancellables)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard NSApp.currentEvent?.type == .rightMouseUp else {
            state.toggleSleepPrevention()
            return
        }

        showContextMenu(for: sender)
    }

    private func showContextMenu(for button: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        let menu = NSMenu()
        let quitItem = NSMenuItem(title: "Quit pmSip", action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
        // Keep statusItem.menu unset so left-click still toggles sleep.
        NSMenu.popUpContextMenu(menu, with: event, for: button)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func updateIcon(sleepState: PMSipState.SleepState) {
        guard let button = statusItem.button else { return }

        switch sleepState {
        case .enabled:
            let base = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "Sleep prevention enabled")
            let tinted = base.map { Self.tinted($0, color: Self.activeColor) }
            tinted?.isTemplate = false
            button.image = tinted
        case .disabled:
            let image = NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: "Sleep prevention disabled")
            image?.isTemplate = true
            button.image = image
        case .unknown:
            let base = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "Sleep prevention state unknown")
            let tinted = base.map { Self.tinted($0, color: .systemRed) }
            tinted?.isTemplate = false
            button.image = tinted
        }
    }

    private func updateTooltip(errorMessage: String?) {
        statusItem.button?.toolTip = errorMessage
    }

    // Tint the symbol while preserving its alpha.
    private static func tinted(_ image: NSImage, color: NSColor) -> NSImage {
        let result = NSImage(size: image.size)
        result.lockFocus()
        color.set()
        let rect = NSRect(origin: .zero, size: image.size)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        rect.fill(using: .sourceAtop)
        result.unlockFocus()
        return result
    }
}
