import Combine
import Foundation

@MainActor
final class PMSipState: ObservableObject {
    @Published private(set) var isSleepPrevented: Bool
    @Published private(set) var stateSince: Date
    @Published private(set) var errorMessage: String?

    private static let pmsetPath = "/usr/bin/pmset"
    private static let sudoPath = "/usr/bin/sudo"

    init() {
        let isSleepPrevented = Self.readDisableSleepState()
        self.isSleepPrevented = isSleepPrevented ?? false
        self.stateSince = Date()
        self.errorMessage = isSleepPrevented == nil
            ? "Could not read the pmset sleep state."
            : nil
    }

    func setSleepPrevented(_ enabled: Bool) {
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

        isSleepPrevented = enabled
        stateSince = Date()
        errorMessage = nil
    }

    private static func readDisableSleepState() -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pmsetPath)
        process.arguments = ["-g"]

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else {
            return nil
        }

        return parseSleepDisabled(from: output)
    }

    static func parseSleepDisabled(from output: String) -> Bool? {
        for line in output.split(separator: "\n") {
            let components = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let key = components.first, key == "SleepDisabled" else { continue }
            guard let value = components.dropFirst().first else { continue }
            return value == "1"
        }

        return nil
    }
}
