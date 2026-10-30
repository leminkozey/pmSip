import CoreGraphics
import Foundation
import IOKit
import ObjectiveC

final class LidDimmer: @unchecked Sendable {
    private struct Levels: Codable {
        var display: Float?
        var keyboard: Float?
        var keyboardAuto: Bool?
    }

    private typealias GetDisplayBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetDisplayBrightness = @convention(c) (UInt32, Float) -> Int32

    private static let defaultsKey = "LidDimmer.saved"
    private static let fadeDuration = 0.4

    private let queue = DispatchQueue(label: "com.leminkozey.pmsip.lid", qos: .utility)
    private var lastOpen = Levels()
    private var dimmed: Levels?
    private var displayID: UInt32?

    private let getDisplayBrightness: GetDisplayBrightness?
    private let setDisplayBrightness: SetDisplayBrightness?
    private let keyboardClient: NSObject?
    private let keyboardID: UInt64?

    init() {
        let displayServicesPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        if let handle = dlopen(displayServicesPath, RTLD_NOW),
           let get = dlsym(handle, "DisplayServicesGetBrightness"),
           let set = dlsym(handle, "DisplayServicesSetBrightness") {
            getDisplayBrightness = unsafeBitCast(get, to: GetDisplayBrightness.self)
            setDisplayBrightness = unsafeBitCast(set, to: SetDisplayBrightness.self)
        } else {
            getDisplayBrightness = nil
            setDisplayBrightness = nil
        }

        let coreBrightnessPath = "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
        if dlopen(coreBrightnessPath, RTLD_NOW) != nil,
           let clientClass = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type {
            let client = clientClass.init()
            let ids = client.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeUnretainedValue()
            keyboardClient = client
            keyboardID = (ids as? [NSNumber])?.first?.uint64Value
        } else {
            keyboardClient = nil
            keyboardID = nil
        }

        queue.async { [self] in
            guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey) else { return }
            dimmed = try? JSONDecoder().decode(Levels.self, from: data)
            restore()
        }
    }

    func poll() {
        queue.async { [self] in
            if Self.isLidClosed() {
                if dimmed == nil { dim() }
            } else {
                if dimmed != nil { restore() }
                sample()
            }
        }
    }

    func restoreIfDimmed() {
        queue.async { [self] in restore() }
    }

    func restoreIfDimmedSync() {
        queue.sync { restore(fade: false) }
    }

    private static func isLidClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }

        let state = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (state?.takeRetainedValue() as? Bool) ?? false
    }

    private static func builtinDisplayID() -> UInt32? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    private func sample() {
        if let id = Self.builtinDisplayID(), let get = getDisplayBrightness {
            var level: Float = 0
            if get(id, &level) == 0 {
                displayID = id
                lastOpen.display = level
            }
        }
        lastOpen.keyboard = readKeyboardLevel()
        lastOpen.keyboardAuto = readKeyboardAuto()
    }

    private func dim() {
        if lastOpen.display == nil || lastOpen.keyboard == nil { sample() }
        if (lastOpen.display ?? 0) < 0.05 { lastOpen.display = 0.5 }

        dimmed = lastOpen
        UserDefaults.standard.set(try? JSONEncoder().encode(lastOpen), forKey: Self.defaultsKey)

        writeKeyboardAuto(false)
        apply(0, to: lastOpen)
    }

    private func restore(fade: Bool = true) {
        guard let saved = dimmed else { return }

        if fade {
            let start = DispatchTime.now().uptimeNanoseconds
            while true {
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
                let progress = Float(elapsed / Self.fadeDuration)
                if progress >= 1 { break }
                apply(progress * progress, to: saved)
                Thread.sleep(forTimeInterval: 0.004)
            }
        }
        apply(1, to: saved)
        if let auto = saved.keyboardAuto { writeKeyboardAuto(auto) }

        dimmed = nil
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }

    private func apply(_ factor: Float, to levels: Levels) {
        if let set = setDisplayBrightness, let id = displayID ?? Self.builtinDisplayID(), let level = levels.display {
            _ = set(id, level * factor)
        }
        if let level = levels.keyboard {
            writeKeyboardLevel(level * factor)
        }
    }

    private func readKeyboardLevel() -> Float? {
        guard let client = keyboardClient, let id = keyboardID else { return nil }
        typealias Call = @convention(c) (AnyObject, Selector, UInt64) -> Float
        let selector = NSSelectorFromString("brightnessForKeyboard:")
        let imp = class_getMethodImplementation(type(of: client), selector)
        return unsafeBitCast(imp, to: Call.self)(client, selector, id)
    }

    private func readKeyboardAuto() -> Bool? {
        guard let client = keyboardClient, let id = keyboardID else { return nil }
        typealias Call = @convention(c) (AnyObject, Selector, UInt64) -> Bool
        let selector = NSSelectorFromString("isAutoBrightnessEnabledForKeyboard:")
        let imp = class_getMethodImplementation(type(of: client), selector)
        return unsafeBitCast(imp, to: Call.self)(client, selector, id)
    }

    private func writeKeyboardLevel(_ level: Float) {
        guard let client = keyboardClient, let id = keyboardID else { return }
        typealias Call = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
        let selector = NSSelectorFromString("setBrightness:forKeyboard:")
        let imp = class_getMethodImplementation(type(of: client), selector)
        _ = unsafeBitCast(imp, to: Call.self)(client, selector, level, id)
    }

    private func writeKeyboardAuto(_ enabled: Bool) {
        guard let client = keyboardClient, let id = keyboardID else { return }
        typealias Call = @convention(c) (AnyObject, Selector, Bool, UInt64) -> Void
        let selector = NSSelectorFromString("enableAutoBrightness:forKeyboard:")
        let imp = class_getMethodImplementation(type(of: client), selector)
        unsafeBitCast(imp, to: Call.self)(client, selector, enabled, id)
    }
}
