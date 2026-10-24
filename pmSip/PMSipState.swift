import Combine
import Darwin
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

    private enum CommandFailure: Error {
        case timedOut
        case failed(String)

        var message: String {
            switch self {
            case .timedOut: return "The pmset command timed out after 3 seconds."
            case .failed(let message): return message
            }
        }
    }

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

            updateSleepState(observed.state)
            errorMessage = observed.errorMessage
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

            if case .timedOut? = writeError {
                updateSleepState(.unknown)
                errorMessage = writeError?.message
                return
            }

            let requested: SleepState = enabled ? .enabled : .disabled
            if writeError == nil {
                updateSleepState(requested)
                errorMessage = nil
            }

            let observed = await Task.detached(priority: .userInitiated) {
                Self.readDisableSleepState()
            }.value
            updateSleepState(observed.state)

            if let readError = observed.errorMessage {
                errorMessage = readError
            } else if let writeError {
                errorMessage = writeError.message
            } else if observed.state != requested {
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

    private nonisolated static func writeDisableSleepState(_ enabled: Bool) -> CommandFailure? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.sudoPath)
        // Fail immediately if sudo requires a password.
        process.arguments = ["-n", Self.pmsetPath, "-a", "disablesleep", enabled ? "1" : "0"]

        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice

        do {
            try runWithTimeout(process)
        } catch CommandFailure.timedOut {
            return .timedOut
        } catch {
            return .failed("Could not start sudo: \(error.localizedDescription)")
        }

        guard process.terminationStatus == 0 else {
            return .failed("Could not change the sleep state. Check the sudoers setup in INSTALL.md.")
        }

        return nil
    }

    private nonisolated static func readDisableSleepState() -> (state: SleepState, errorMessage: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pmsetPath)
        process.arguments = ["-g"]

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        defer { try? stdoutPipe.fileHandleForReading.close() }

        do {
            try runWithTimeout(process)
        } catch CommandFailure.timedOut {
            return (.unknown, CommandFailure.timedOut.message)
        } catch {
            return (.unknown, "Could not read the pmset sleep state.")
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else {
            return (.unknown, "Could not read the pmset sleep state.")
        }

        let state = parseSleepDisabled(from: output)
        return (state, state == .unknown ? "Could not read the pmset sleep state." : nil)
    }

    private nonisolated static func runWithTimeout(_ process: Process) throws {
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        guard exited.wait(timeout: .now() + 3) == .timedOut else { return }

        if process.isRunning {
            process.terminate()
            if exited.wait(timeout: .now() + .milliseconds(200)) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        throw CommandFailure.timedOut
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
