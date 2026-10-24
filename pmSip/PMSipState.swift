import Combine
import Foundation

@MainActor
final class PMSipState: ObservableObject {
    enum SleepState: Sendable {
        case enabled
        case disabled
        case unknown
    }

    @Published private(set) var sleepState: SleepState = .unknown
    @Published private(set) var stateSince = Date()
    @Published private(set) var errorMessage: String?

    private nonisolated static let pmsetPath = "/usr/bin/pmset"
    private nonisolated static let sudoPath = "/usr/bin/sudo"
    private var refreshTask: Task<Void, Never>?
    private var isToggling = false

    init() {
        refreshSleepState()
    }

    func refreshSleepState() {
        guard refreshTask == nil, !isToggling else { return }

        refreshTask = Task {
            defer { refreshTask = nil }
            let observed = await Task.detached(priority: .utility) {
                Self.readDisableSleepState()
            }.value
            guard !Task.isCancelled else { return }

            updateSleepState(observed)
            errorMessage = observed == .unknown
                ? "Could not read the pmset sleep state."
                : nil
        }
    }

    func toggleSleepPrevention() {
        guard !isToggling else { return }

        let enabled: Bool
        switch sleepState {
        case .enabled:
            enabled = false
        case .disabled:
            enabled = true
        case .unknown:
            refreshSleepState()
            return
        }

        refreshTask?.cancel()
        isToggling = true
        Task {
            defer { isToggling = false }
            let writeError = await Task.detached(priority: .userInitiated) {
                Self.writeDisableSleepState(enabled)
            }.value

            let requested: SleepState = enabled ? .enabled : .disabled
            if writeError == nil {
                updateSleepState(requested)
                errorMessage = nil
            }

            let observed = await Task.detached(priority: .userInitiated) {
                Self.readDisableSleepState()
            }.value
            updateSleepState(observed)

            if observed == .unknown {
                errorMessage = "Could not read the pmset sleep state after toggling."
            } else if let writeError {
                errorMessage = writeError
            } else if observed != requested {
                errorMessage = "The pmset sleep state does not match the requested setting."
            } else {
                errorMessage = nil
            }
        }
    }

    private func updateSleepState(_ observed: SleepState) {
        guard sleepState != observed else { return }
        sleepState = observed
        stateSince = Date()
    }

    private nonisolated static func writeDisableSleepState(_ enabled: Bool) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.sudoPath)
        // Fail immediately if sudo requires a password.
        process.arguments = ["-n", Self.pmsetPath, "-a", "disablesleep", enabled ? "1" : "0"]

        process.standardError = Pipe()
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            return "Could not start sudo: \(error.localizedDescription)"
        }

        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return "Could not change the sleep state. Check the sudoers setup in INSTALL.md."
        }

        return nil
    }

    private nonisolated static func readDisableSleepState() -> SleepState {
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

    nonisolated static func parseSleepDisabled(from output: String) -> SleepState {
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
