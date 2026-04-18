import Foundation
import AppKit
import SwiftUI

/// Polls the upstream repo (macOS26/Agent) for new commits on `main`, syncs
/// the user's fork (Guiraud/Agent), rebuilds + signs + notarises a DMG, then
/// lets the user relaunch the freshly built app. Triggered at launch and
/// every 24 h while the app is running.
@MainActor
@Observable
final class AutoUpdateService {
    static let shared = AutoUpdateService()

    enum Phase: Equatable {
        case idle
        case checking
        case syncing
        case building
        case notarizing
        case ready(appPath: URL, dmgPath: URL?)
        case failed(message: String)

        var isBusy: Bool {
            switch self {
            case .checking, .syncing, .building, .notarizing: return true
            default: return false
            }
        }
    }

    // MARK: - Public observable state

    var phase: Phase = .idle
    var lastCheck: Date?
    var lastLogLines: [String] = []   // ring buffer, last ~20 lines

    // MARK: - Config (UserDefaults-backed)

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let lastSeenSHA = "upstreamLastSeenSHA"
        static let lastCheckDate = "upstreamLastCheckDate"
        static let autoUpdateEnabled = "autoUpdateEnabled"
        static let autoPushToFork = "autoPushToFork"
        static let developerIDName = "updateDeveloperIDName"
        static let appleTeamID = "updateAppleTeamID"
        static let notaryProfile = "updateNotaryProfile"
    }

    var autoUpdateEnabled: Bool {
        get { defaults.object(forKey: Keys.autoUpdateEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.autoUpdateEnabled) }
    }

    var autoPushToFork: Bool {
        get { defaults.object(forKey: Keys.autoPushToFork) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.autoPushToFork) }
    }

    var developerIDName: String {
        get { defaults.string(forKey: Keys.developerIDName) ?? "" }
        set { defaults.set(newValue, forKey: Keys.developerIDName) }
    }

    var appleTeamID: String {
        get { defaults.string(forKey: Keys.appleTeamID) ?? "" }
        set { defaults.set(newValue, forKey: Keys.appleTeamID) }
    }

    var notaryProfile: String {
        get { defaults.string(forKey: Keys.notaryProfile) ?? "AgentNotaryProfile" }
        set { defaults.set(newValue, forKey: Keys.notaryProfile) }
    }

    var lastSeenSHA: String {
        get { defaults.string(forKey: Keys.lastSeenSHA) ?? "" }
        set { defaults.set(newValue, forKey: Keys.lastSeenSHA) }
    }

    // MARK: - Repo constants

    private let upstreamOwner = "macOS26"
    private let upstreamRepo = "Agent"
    private let upstreamBranch = "main"

    /// Absolute path to the git working tree — the bundle is built from source
    /// so we look for the project root relative to the running executable.
    /// Override with UserDefaults key `updateRepoPath` for dev.
    var repoPath: URL {
        if let override = defaults.string(forKey: "updateRepoPath"),
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        // Try to locate the repo by walking up from the running binary.
        let bundlePath = Bundle.main.bundleURL.deletingLastPathComponent()
        var url = bundlePath
        for _ in 0..<8 {
            let pbx = url.appendingPathComponent("Agent.xcodeproj/project.pbxproj")
            if FileManager.default.fileExists(atPath: pbx.path) {
                return url
            }
            url = url.deletingLastPathComponent()
        }
        // Fallback: user's home default path
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/Gitlab/Tries/Agent")
    }

    // MARK: - Scheduling

    private var timer: Timer?

    func startPeriodicChecks() {
        timer?.invalidate()
        // 24h
        let t = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkForUpdates() }
        }
        t.tolerance = 600
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Main entry point

    func checkForUpdates(force: Bool = false) async {
        guard autoUpdateEnabled || force else { return }
        guard !phase.isBusy else { return }

        // Debounce: skip if checked <1h ago (unless forced).
        if !force,
           let last = defaults.object(forKey: Keys.lastCheckDate) as? Date,
           Date().timeIntervalSince(last) < 3_600 {
            return
        }

        phase = .checking
        defer { lastCheck = Date() }
        defaults.set(Date(), forKey: Keys.lastCheckDate)

        do {
            let latest = try await fetchLatestUpstreamSHA()
            log("[CHECK] upstream \(upstreamBranch) @ \(latest.prefix(7))")

            if latest == lastSeenSHA {
                log("[CHECK] already up to date")
                phase = .idle
                return
            }

            try await runPipeline(targetSHA: latest)
        } catch {
            phase = .failed(message: error.localizedDescription)
            log("[ERROR] \(error.localizedDescription)")
        }
    }

    // MARK: - GitHub API

    private func fetchLatestUpstreamSHA() async throws -> String {
        let urlStr = "https://api.github.com/repos/\(upstreamOwner)/\(upstreamRepo)/commits/\(upstreamBranch)"
        guard let url = URL(string: urlStr) else {
            throw UpdateError.badURL
        }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("Agent-AutoUpdate", forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw UpdateError.httpError(code)
        }
        struct CommitResponse: Decodable { let sha: String }
        return try JSONDecoder().decode(CommitResponse.self, from: data).sha
    }

    // MARK: - Pipeline

    private func runPipeline(targetSHA: String) async throws {
        phase = .syncing
        let script = repoPath.appendingPathComponent("scripts/update-and-build.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw UpdateError.missingScript(script.path)
        }

        var env = ProcessInfo.processInfo.environment
        env["DEVELOPER_ID_NAME"] = developerIDName
        env["APPLE_TEAM_ID"] = appleTeamID
        env["NOTARY_PROFILE"] = notaryProfile
        env["AUTO_PUSH_FORK"] = autoPushToFork ? "1" : "0"
        env["UPSTREAM_SHA"] = targetSHA

        let exit = try await runShellStreaming(
            executable: "/bin/bash",
            args: [script.path],
            cwd: repoPath,
            env: env,
            onLine: { [weak self] line in
                Task { @MainActor in self?.handlePipelineLine(line) }
            }
        )

        guard exit == 0 else {
            phase = .failed(message: "Build script exited with code \(exit). Voir le journal.")
            return
        }

        let builtApp = repoPath.appendingPathComponent("build/latest/Agent!.app")
        let builtDMG = repoPath.appendingPathComponent("build/latest/Agent.dmg")
        let dmg = FileManager.default.fileExists(atPath: builtDMG.path) ? builtDMG : nil

        guard FileManager.default.fileExists(atPath: builtApp.path) else {
            phase = .failed(message: "Compilation terminée mais Agent!.app introuvable.")
            return
        }

        // Persist success
        lastSeenSHA = targetSHA
        phase = .ready(appPath: builtApp, dmgPath: dmg)
        log("[DONE] \(builtApp.path)")
    }

    private func handlePipelineLine(_ line: String) {
        log(line)
        if line.contains("[STEP] xcodebuild") || line.contains("[STEP] build") {
            phase = .building
        } else if line.contains("[STEP] notarize") || line.contains("[STEP] staple") {
            phase = .notarizing
        } else if line.contains("[STEP] git") {
            phase = .syncing
        }
    }

    // MARK: - Relaunch

    func relaunch(to appURL: URL) {
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "sleep 1 && /usr/bin/open -n '\(appURL.path.replacingOccurrences(of: "'", with: "'\\''"))'"]
        do {
            try task.run()
        } catch {
            log("[ERROR] relaunch failed: \(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: - Logging

    private func log(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }
        lastLogLines.append(trimmed)
        if lastLogLines.count > 40 {
            lastLogLines.removeFirst(lastLogLines.count - 40)
        }
        // Also append to ~/Library/Logs/Agent/update.log
        Self.appendToDiskLog(trimmed)
    }

    static func logFileURL() -> URL {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/Agent", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("update.log")
    }

    private static func appendToDiskLog(_ line: String) {
        let url = logFileURL()
        let stamped = "[\(ISO8601DateFormatter().string(from: Date()))] \(line)\n"
        if let data = stamped.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    // MARK: - Process streaming

    private func runShellStreaming(
        executable: String,
        args: [String],
        cwd: URL,
        env: [String: String],
        onLine: @escaping (String) -> Void
    ) async throws -> Int32 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            let task = Process()
            task.launchPath = executable
            task.arguments = args
            task.currentDirectoryURL = cwd
            task.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            task.standardOutput = outPipe
            task.standardError = errPipe

            let bufferLock = NSLock()
            var pendingOut = Data()
            var pendingErr = Data()

            func flush(_ buffer: inout Data) {
                while let nlIdx = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer[buffer.startIndex..<nlIdx]
                    if let s = String(data: lineData, encoding: .utf8) {
                        onLine(s)
                    }
                    buffer.removeSubrange(buffer.startIndex...nlIdx)
                }
            }

            outPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { return }
                bufferLock.lock()
                pendingOut.append(d)
                flush(&pendingOut)
                bufferLock.unlock()
            }
            errPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { return }
                bufferLock.lock()
                pendingErr.append(d)
                flush(&pendingErr)
                bufferLock.unlock()
            }

            task.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                // Flush any trailing data
                bufferLock.lock()
                if !pendingOut.isEmpty, let s = String(data: pendingOut, encoding: .utf8) { onLine(s) }
                if !pendingErr.isEmpty, let s = String(data: pendingErr, encoding: .utf8) { onLine(s) }
                bufferLock.unlock()
                cont.resume(returning: proc.terminationStatus)
            }

            do {
                try task.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}

enum UpdateError: LocalizedError {
    case badURL
    case httpError(Int)
    case missingScript(String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "URL GitHub invalide."
        case .httpError(let code):
            return "Erreur HTTP GitHub (\(code))."
        case .missingScript(let path):
            return "Script introuvable : \(path). Exécutez `chmod +x` dans scripts/."
        }
    }
}
