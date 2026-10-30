import AppKit
import CoreGraphics
import Foundation
import IOKit
import IOKit.hid

// Reads the lid angle. Uses the HID angle sensor of recent MacBooks and falls
// back to the clamshell flag of IOPMrootDomain (open/closed only).
final class LidSensor {
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?

    init() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: 0x05AC,
            kIOHIDProductIDKey: 0x8104,
            kIOHIDPrimaryUsagePageKey: 0x20,
            kIOHIDPrimaryUsageKey: 0x8A,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let device = devices.first,
              IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return
        }
        self.manager = manager
        self.device = device
    }

    deinit {
        if let device { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        if let manager { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
    }

    var hasAngleSensor: Bool { device != nil }

    /// Lid angle in degrees, or nil if the Mac has no angle sensor.
    func angle() -> Double? {
        guard let device else { return nil }
        var report = [UInt8](repeating: 0, count: 8)
        var length = report.count
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &length)
        guard result == kIOReturnSuccess, length >= 3 else { return nil }
        let raw = (UInt16(report[2]) << 8) | UInt16(report[1])
        return Double(raw)
    }

    /// True if the clamshell is closed, nil if it cannot be read.
    func clamshellClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let property = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return property?.takeRetainedValue() as? Bool
    }
}

// Display and keyboard backlight through private frameworks. Every lookup is
// optional, so a missing symbol after a macOS update disables the feature
// instead of crashing.
final class BacklightControl {
    private typealias GetDisplayBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetDisplayBrightness = @convention(c) (UInt32, Float) -> Int32
    private typealias SetKeyboardBrightness = @convention(c) (AnyObject, Selector, Float, UInt64) -> Int8
    private typealias GetKeyboardBrightness = @convention(c) (AnyObject, Selector, UInt64) -> Float

    private let getDisplay: GetDisplayBrightness?
    private let setDisplay: SetDisplayBrightness?
    private let keyboardClient: AnyObject?
    private let keyboardID: UInt64

    init() {
        let displayHandle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        getDisplay = displayHandle
            .flatMap { dlsym($0, "DisplayServicesGetBrightness") }
            .map { unsafeBitCast($0, to: GetDisplayBrightness.self) }
        setDisplay = displayHandle
            .flatMap { dlsym($0, "DisplayServicesSetBrightness") }
            .map { unsafeBitCast($0, to: SetDisplayBrightness.self) }

        _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        let client = (NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type)?.init()
        keyboardClient = client
        let ids = client?.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeRetainedValue() as? [NSNumber]
        keyboardID = ids?.first?.uint64Value ?? 1
    }

    private static func builtInDisplay() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    func displayBrightness() -> Float? {
        guard let getDisplay, let id = Self.builtInDisplay() else { return nil }
        var value: Float = 0
        return getDisplay(id, &value) == 0 ? value : nil
    }

    func setDisplayBrightness(_ value: Float) {
        guard let setDisplay, let id = Self.builtInDisplay() else { return }
        _ = setDisplay(id, value)
    }

    func keyboardBrightness() -> Float? {
        guard let keyboardClient else { return nil }
        let selector = NSSelectorFromString("brightnessForKeyboard:")
        guard keyboardClient.responds(to: selector),
              let imp = keyboardClient.method(for: selector) else { return nil }
        return unsafeBitCast(imp, to: GetKeyboardBrightness.self)(keyboardClient, selector, keyboardID)
    }

    func setKeyboardBrightness(_ value: Float) {
        guard let keyboardClient else { return }
        let selector = NSSelectorFromString("setBrightness:forKeyboard:")
        guard keyboardClient.responds(to: selector),
              let imp = keyboardClient.method(for: selector) else { return }
        _ = unsafeBitCast(imp, to: SetKeyboardBrightness.self)(keyboardClient, selector, value, keyboardID)
    }
}

/// Turns display and keyboard backlight off while the lid is closed and
/// pmSip keeps the Mac awake, and restores the previous values on opening.
@MainActor
final class LidDimmer {
    static let enabledKey = "dimWhenLidClosed"
    static let thresholdKey = "lidClosedThresholdDegrees"
    private static let savedDisplayKey = "lidDimmerSavedDisplay"
    private static let savedKeyboardKey = "lidDimmerSavedKeyboard"

    private static let pollInterval: TimeInterval = 1
    // Avoids flapping around the threshold.
    private static let hysteresis = 5.0

    private let defaults = UserDefaults.standard
    private let sensor = LidSensor()
    private let backlight = BacklightControl()
    private var timer: Timer?
    private var dimmed = false

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set {
            defaults.set(newValue, forKey: Self.enabledKey)
            reconfigure()
        }
    }

    private var threshold: Double {
        let value = defaults.double(forKey: Self.thresholdKey)
        return value > 0 ? value : 10
    }

    private var keepingAwake = false

    init() {
        // A crash or kill while dimmed would leave the screen black.
        restoreSavedValues()
    }

    func setKeepingAwake(_ keepingAwake: Bool) {
        self.keepingAwake = keepingAwake
        reconfigure()
    }

    func restoreForQuit() {
        timer?.invalidate()
        timer = nil
        restore()
    }

    private func reconfigure() {
        if isEnabled && keepingAwake {
            guard timer == nil else { return }
            timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            poll()
        } else {
            timer?.invalidate()
            timer = nil
            restore()
        }
    }

    private func poll() {
        guard let closed = lidClosed() else { return }
        if closed && !dimmed {
            dim()
        } else if !closed && dimmed {
            restore()
        }
    }

    private func lidClosed() -> Bool? {
        if let angle = sensor.angle() {
            // Once dimmed, require a bit more opening before restoring.
            return angle < (dimmed ? threshold + Self.hysteresis : threshold)
        }
        return sensor.clamshellClosed()
    }

    private func dim() {
        let display = backlight.displayBrightness()
        let keyboard = backlight.keyboardBrightness()
        // Persist first, so a crash after this point can still be undone.
        if let display { defaults.set(display, forKey: Self.savedDisplayKey) }
        if let keyboard { defaults.set(keyboard, forKey: Self.savedKeyboardKey) }
        dimmed = true

        backlight.setDisplayBrightness(0)
        backlight.setKeyboardBrightness(0)
    }

    private func restore() {
        guard dimmed else { return }
        restoreSavedValues()
        dimmed = false
    }

    private func restoreSavedValues() {
        if let display = defaults.object(forKey: Self.savedDisplayKey) as? Float {
            backlight.setDisplayBrightness(display)
        }
        if let keyboard = defaults.object(forKey: Self.savedKeyboardKey) as? Float {
            backlight.setKeyboardBrightness(keyboard)
        }
        defaults.removeObject(forKey: Self.savedDisplayKey)
        defaults.removeObject(forKey: Self.savedKeyboardKey)
    }
}
