#if os(macOS)
import Foundation

/// A macOS-only bridge to a bundled, SHA-256-verified ipatool 2.7 binary.
/// Never passes Asspp Apple ID credentials to a subprocess.
enum MacIPAToolFallback {
    enum Failure: LocalizedError {
        case helperMissing, loginNeeded, wrongAccount, requestFailed, outputMissing
        var errorDescription: String? {
            switch self {
            case .helperMissing: "The bundled ipatool 2.7.0 executable is missing. Reinstall this Asspp build."
            case .loginNeeded: "ipatool has no readable saved login. In macOS Terminal run 'ipatool auth login' with the same Apple ID, approve Keychain access, then retry Asspp."
            case .wrongAccount: "ipatool is signed into a different Apple ID. In Terminal run 'ipatool auth revoke' followed by 'ipatool auth login' with the account selected in Asspp."
            case .requestFailed: "ipatool 2.7 also could not download this IPA. Verify this Apple ID with ipatool in Terminal."
            case .outputMissing: "ipatool did not produce an IPA file."
            }
        }
    }

    enum Stage: Sendable, Equatable {
        case checkingAccount, connecting, transferring, processing, verifying, importing
        var title: String {
            switch self {
            case .checkingAccount: "Checking ipatool Keychain account"
            case .connecting: "Requesting download from Apple"
            case .transferring: "Downloading IPA"
            case .processing: "Finalizing IPA and signatures"
            case .verifying: "Verifying app identity and platform"
            case .importing: "Adding IPA to Downloads"
            }
        }
    }

    struct ProgressUpdate: Sendable, Equatable {
        let appName: String
        var stage: Stage
        var bytesReceived: Int64 = 0
        var bytesPerSecond: Int64 = 0
        let expectedBytes: Int64?

        /// App Store fileSizeBytes is only an estimate of wire size.
        /// Never present estimated progress as a precise percentage.
        var estimatedFraction: Double? {
            guard stage == .transferring, bytesReceived > 0,
                  let expectedBytes, expectedBytes > 0 else { return nil }
            return min(0.98, Double(bytesReceived) / Double(expectedBytes))
        }
    }

    static func shouldRetry(_ error: Error) -> Bool {
        guard let issue = error as? StoreDownloadError else { return false }
        switch issue {
        case .response(403), .emptyResponse(403), .empty: return true
        default: return false
        }
    }

    static func download(
        appID: Int64,
        version: String?,
        expectedEmail: String,
        appName: String,
        expectedBytes: Int64?,
        onProgress: @escaping @Sendable (ProgressUpdate) -> Void
    ) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try blockingDownload(appID: appID, version: version, expectedEmail: expectedEmail,
                                 appName: appName, expectedBytes: expectedBytes, onProgress: onProgress)
        }.value
    }

    private static func blockingDownload(
        appID: Int64, version: String?, expectedEmail: String,
        appName: String, expectedBytes: Int64?,
        onProgress: @escaping @Sendable (ProgressUpdate) -> Void
    ) throws -> URL {
        guard let executable = Bundle.main.resourceURL?.appendingPathComponent("ipatool"),
              FileManager.default.isExecutableFile(atPath: executable.path)
        else { throw Failure.helperMissing }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AssppIPATool-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: directory) } }

        onProgress(.init(appName: appName, stage: .checkingAccount, expectedBytes: expectedBytes))

        // The CLI maintains its own Keychain session, independent of Asspp.
        // Explicitly check its Apple ID to prevent downloading under a different account.
        let auth = try launch(executable, arguments: ["--format", "json", "--non-interactive", "auth", "info"], directory: directory)
        guard auth.status == 0, let email = extractEmail(auth.output) else { throw Failure.loginNeeded }
        guard email.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(expectedEmail.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        else { throw Failure.wrongAccount }

        let ipa = directory.appendingPathComponent("package.ipa")
        var arguments = ["--format", "json", "--non-interactive", "download",
                         "--app-id", String(appID), "--platform", "iphone",
                         "--output", ipa.path]
        if let version, !version.isEmpty { arguments += ["--external-version-id", version] }
        onProgress(.init(appName: appName, stage: .connecting, expectedBytes: expectedBytes))
        let response = try launch(executable, arguments: arguments, directory: directory,
                                  monitorIPA: ipa, appName: appName, expectedBytes: expectedBytes,
                                  onProgress: onProgress)
        guard response.status == 0 else { throw Failure.requestFailed }
        let attributes = try? FileManager.default.attributesOfItem(atPath: ipa.path)
        guard let size = attributes?[.size] as? NSNumber, size.int64Value > 0 else {
            throw Failure.outputMissing
        }
        success = true
        return ipa
    }

    private static func extractEmail(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let email = json["email"] as? String else { continue }
            return email
        }
        return nil
    }

    private static func launch(
        _ executable: URL, arguments: [String], directory: URL,
        monitorIPA: URL? = nil, appName: String = "", expectedBytes: Int64? = nil,
        onProgress: (@Sendable (ProgressUpdate) -> Void)? = nil
    ) throws -> (status: Int32, output: String) {
        let log = directory.appendingPathComponent("ipatool-" + UUID().uuidString + ".log")
        guard FileManager.default.createFile(atPath: log.path, contents: nil) else { throw Failure.requestFailed }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: log) }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        process.currentDirectoryURL = directory
        do { try process.run() } catch { throw Failure.requestFailed }

        if let monitorIPA, let onProgress {
            // ipatool writes to <output>.tmp before re-packaging its final IPA.
            // Monitor file growth without parsing or exposing sensitive CLI logs.
            let temporary = URL(fileURLWithPath: monitorIPA.path + ".tmp")
            var lastBytes: Int64 = 0
            var lastTime = Date()
            while process.isRunning {
                let partialBytes = fileSize(temporary)
                let finalBytes = fileSize(monitorIPA)
                let received = max(lastBytes, partialBytes, finalBytes)
                let now = Date()
                let seconds = max(now.timeIntervalSince(lastTime), 0.001)
                let speed = Int64(Double(max(0, received - lastBytes)) / seconds)
                let stage: Stage = finalBytes > 0 || (lastBytes > 0 && partialBytes == 0)
                    ? .processing : (received > 0 ? .transferring : .connecting)
                onProgress(.init(appName: appName, stage: stage,
                                 bytesReceived: received, bytesPerSecond: speed,
                                 expectedBytes: expectedBytes))
                lastBytes = received
                lastTime = now
                Thread.sleep(forTimeInterval: 0.5)
            }
            onProgress(.init(appName: appName, stage: .processing,
                             bytesReceived: lastBytes, expectedBytes: expectedBytes))
        }
        process.waitUntilExit()
        // Raw CLI output may reveal account details. Never forward it to Asspp logs.
        return (process.terminationStatus, (try? String(contentsOf: log, encoding: .utf8)) ?? "")
    }

    private static func fileSize(_ url: URL) -> Int64 {
        guard let attr = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attr[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }
}
#endif
