//
//  Downloads+UI.swift
//  Asspp
//
//  Created by 秋星桥 on 2024/7/13.
//

import ApplePackage
import Foundation
import SwiftUI

enum DownloadAction: Hashable {
    case suspend
    case resume
    case restart
    case delete
}

@MainActor
extension Downloads {
    func performDownloadAction(for request: PackageManifest, action: DownloadAction) {
        switch action {
        case .suspend:
            suspend(request: request)
        case .resume:
            resume(request: request)
        case .restart:
            restart(request: request)
        case .delete:
            delete(request: request)
        }
    }

    func getAvailableActions(for request: PackageManifest) -> [DownloadAction] {
        switch request.state.status {
        case .pending, .downloading:
            [.suspend, .delete]
        case .paused:
            [.resume, .delete]
        case .failed:
            [.restart, .delete]
        case .completed:
            [.delete]
        }
    }

    func getActionLabel(for action: DownloadAction) -> (title: String, systemImage: String, isDestructive: Bool) {
        switch action {
        case .suspend:
            (String(localized: "Pause"), "stop.fill", false)
        case .resume:
            (String(localized: "Resume"), "play.fill", false)
        case .restart:
            (String(localized: "Restart Download"), "arrow.clockwise", false)
        case .delete:
            (String(localized: "Delete"), "trash", true)
        }
    }
}

extension Downloads {
    func startDownload(for package: AppStore.AppPackage, accountID: String) async throws {
        #if os(macOS)
        do {
            try await startLegacyDownload(for: package, accountID: accountID)
        } catch {
            guard MacIPAToolFallback.shouldRetry(error) else { throw error }
            guard let account = AppStore.this.accounts.first(where: { $0.id == accountID }) else {
                throw AuthenticationError.accountNotFound
            }
            logger.info("Legacy download HTTP 403/empty; using bundled ipatool 2.7")
            let ipa = try await MacIPAToolFallback.download(
                appID: package.software.id,
                version: package.externalVersionID,
                expectedEmail: account.account.email
            )
            defer { try? FileManager.default.removeItem(at: ipa.deletingLastPathComponent()) }
            try StorePackageValidator.validate(at: ipa, package: package)
            let request = try PackageManifest(account: account, package: package, localIPA: ipa)
            _ = add(request: request)
            saveManifests()
            logger.info("ipatool produced a verified IPA; added to Downloads")
        }
        #else
        try await startLegacyDownload(for: package, accountID: accountID)
        #endif
    }

    private func startLegacyDownload(for package: AppStore.AppPackage, accountID: String) async throws {
        try await AppStore.this.withAccount(id: accountID) { account in
            let downloadOutput = try await StoreDownloadService.download(account: &account.account, package: package)
            let request = try Downloads.this.add(request: .init(
                account: account,
                package: package,
                downloadOutput: downloadOutput,
            ))
            Downloads.this.resume(request: request)
        }
    }
}
