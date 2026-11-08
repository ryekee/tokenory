import AppKit
import Foundation
import Observation

struct ReleaseVersion: Comparable {
    let components: [Int]

    init(_ value: String) throws {
        let number = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = number.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              parts.allSatisfy({ Int($0) != nil }) else { throw UpdateError.invalidRelease }
        components = parts.map { Int($0)! }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

struct AppRelease {
    let tag: String
    let version: ReleaseVersion
    let url: URL

    static func decode(_ data: Data) throws -> Self {
        struct Payload: Decodable {
            let tag_name: String
            let html_url: URL
            let draft: Bool
            let prerelease: Bool
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard !payload.draft, !payload.prerelease,
              payload.html_url.scheme == "https", payload.html_url.host == "github.com",
              payload.html_url.path.hasPrefix("/ryekee/tokenory/releases/tag/") else {
            throw UpdateError.invalidRelease
        }
        return try Self(tag: payload.tag_name, version: ReleaseVersion(payload.tag_name), url: payload.html_url)
    }
}

enum UpdateError: LocalizedError {
    case noRelease, rateLimited, http(Int), invalidRelease
    var errorDescription: String? {
        switch self {
        case .noRelease: L("update.no_release")
        case .rateLimited: L("update.rate_limited")
        case .http(let status): LF("update.http_error", status)
        case .invalidRelease: L("update.invalid_release")
        }
    }
}

@MainActor @Observable
final class UpdateChecker {
    static let shared = UpdateChecker()
    static let endpoint = URL(string: "https://api.github.com/repos/ryekee/tokenory/releases/latest")!
    var isChecking = false
    let currentVersion: String
    private let fetch: (URLRequest) async throws -> (Data, URLResponse)

    init(currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
         fetch: @escaping (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) {
        self.currentVersion = currentVersion
        self.fetch = fetch
    }

    func latestUpdate() async throws -> AppRelease? {
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Tokenory/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await fetch(request)
        guard let response = response as? HTTPURLResponse else { throw UpdateError.invalidRelease }
        switch response.statusCode {
        case 200: break
        case 404: throw UpdateError.noRelease
        case 403, 429: throw UpdateError.rateLimited
        default: throw UpdateError.http(response.statusCode)
        }
        let release = try AppRelease.decode(data)
        return try release.version > ReleaseVersion(currentVersion) ? release : nil
    }

    func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        let alert = NSAlert()
        do {
            if let release = try await latestUpdate() {
                alert.messageText = LF("update.available", release.tag)
                alert.informativeText = LF("update.download_note", currentVersion)
                alert.addButton(withTitle: L("update.open_release"))
                alert.addButton(withTitle: L("action.cancel"))
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.url) }
                return
            }
            alert.messageText = L("update.up_to_date")
            alert.informativeText = LF("update.current", currentVersion)
        } catch {
            alert.alertStyle = .warning
            alert.messageText = L("update.failed")
            alert.informativeText = error.localizedDescription
        }
        alert.addButton(withTitle: L("update.ok"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
