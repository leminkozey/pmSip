import Combine
import Foundation

@MainActor
final class PMSipState: ObservableObject {
    enum SleepState {
        case enabled
        case disabled
        case unknown
    }

    @Published private(set) var sleepState: SleepState
    @Published private(set) var stateSince: Date
    @Published private(set) var errorMessage: String?

    private static let pmsetPath = "/usr/bin/pmset"
    private static let sudoPath = "/usr/bin/sudo"

    init() {
        let sleepState = Self.readDisableSleepState()
        self.sleepState = sleepState
        self.stateSince = Date()
        self.errorMessage = sleepState == .unknown
            ? "Could not read the pmset sleep state."
            : nil
    }

    func toggleSleepPrevention() {
        let enabled: Bool
        switch sleepState {
        case .enabled:
            enabled = false
        case .disabled:
            enabled = true
        case .unknown:
            sleepState = Self.readDisableSleepState()
            errorMessage = sleepState == .unknown
                ? "Could not read the pmset sleep state."
                : nil
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.sudoPath)
        // Fail immediately if sudo requires a password.
        process.arguments = ["-n", Self.pmsetPath, "-a", "disablesleep", enabled ? "1" : "0"]

        process.standardError = Pipe()
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            errorMessage = "Could not start sudo: \(error.localizedDescription)"
            return
        }

        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            errorMessage = "Could not change the sleep state. Check the sudoers setup in INSTALL.md."
            return
        }

        sleepState = enabled ? .enabled : .disabled
        stateSince = Date()
        errorMessage = nil
    }

    private static func readDisableSleepState() -> SleepState {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pmsetPath)
        process.arguments = ["-g"]

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return .unknown
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else {
            return .unknown
        }

        return parseSleepDisabled(from: output)
    }

    static func parseSleepDisabled(from output: String) -> SleepState {
        for line in output.split(separator: "\n") {
            let components = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let key = components.first, key == "SleepDisabled" else { continue }
            guard components.count == 2 else { return .unknown }
            switch components[1] {
            case "1": return .enabled
            case "0": return .disabled
            default: return .unknown
            }
        }

        return .unknown
    }
}
