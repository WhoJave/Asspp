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

    static func shouldRetry(_ error: Error) -> Bool {
        guard let issue = error as? StoreDownloadError else { return false }
        switch issue {
        case .response(403), .emptyResponse(403), .empty: true
        default: false
        }
    }

    static func download(appID: Int64, version: String?, expectedEmail: String) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try blockingDownload(appID: appID, version: version, expectedEmail: expectedEmail)
        }.value
    }

    private static func blockingDownload(appID: Int64, version: String?, expectedEmail: String) throws -> URL {
        guard let executable = Bundle.main.resourceURL?.appendingPathComponent("ipatool"),
              FileManager.default.isExecutableFile(atPath: executable.path)
        else { throw Failure.helperMissing }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AssppIPATool-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: directory) } }

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
        let response = try launch(executable, arguments: arguments, directory: directory)
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

    private static func launch(_ executable: URL, arguments: [String], directory: URL) throws -> (status: Int32, output: String) {
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
        do {
            try process.run()
            process.waitUntilExit()
        } catch { throw Failure.requestFailed }
        // Raw CLI output may reveal account details. Never forward it to Asspp logs.
        return (process.terminationStatus, (try? String(contentsOf: log, encoding: .utf8)) ?? "")
    }
}
#endif
