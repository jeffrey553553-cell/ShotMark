import Foundation

enum AppMetadata {
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
    }
}

struct AppVersion: Comparable, Equatable, CustomStringConvertible {
    let components: [Int]

    init?(_ value: String) {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .drop(while: { $0 == "v" || $0 == "V" })
            .split(separator: "-", maxSplits: 1)
            .first
            .map(String.init) ?? ""
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else { return nil }
        components = parts.compactMap { Int($0) }
    }

    var description: String {
        components.map(String.init).joined(separator: ".")
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

struct ShotMarkUpdateRelease: Equatable {
    let version: AppVersion
    let displayVersion: String
    let releasePageURL: URL
    let downloadURL: URL
    let sha256Digest: String
    let publishedAt: Date?
}

enum UpdateCheckResult: Equatable {
    case upToDate(currentVersion: String)
    case updateAvailable(ShotMarkUpdateRelease)
}

enum UpdateCheckError: LocalizedError, Equatable {
    case invalidCurrentVersion
    case invalidServerResponse
    case releaseUnavailable
    case responseTooLarge
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidCurrentVersion:
            "当前应用版本格式无法识别。"
        case .invalidServerResponse:
            "更新服务器返回了无效响应。"
        case .releaseUnavailable:
            "暂时没有可用的正式安装包。"
        case .responseTooLarge:
            "更新信息异常，已停止读取。"
        case .network(let message):
            "无法连接更新服务器：\(message)"
        }
    }
}

struct UpdateCheckPolicy {
    static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    static func shouldAutomaticallyCheck(
        enabled: Bool,
        lastCheckedAt: Date?,
        now: Date = Date()
    ) -> Bool {
        guard enabled else { return false }
        guard let lastCheckedAt else { return true }
        return now.timeIntervalSince(lastCheckedAt) >= automaticCheckInterval
    }
}

final class UpdateCheckService {
    typealias Loader = (URLRequest, @escaping (Result<(Data, HTTPURLResponse), Error>) -> Void) -> Void

    static let releaseEndpoint = URL(
        string: "https://api.github.com/repos/jeffrey553553-cell/ShotMark/releases/latest"
    )!
    static let maximumResponseBytes = 2 * 1_024 * 1_024

    private let loader: Loader
    private let authorizationToken: String?

    init(
        loader: @escaping Loader = UpdateCheckService.defaultLoader,
        authorizationToken: String? = nil
    ) {
        self.loader = loader
        self.authorizationToken = authorizationToken
    }

    func check(
        currentVersion: String,
        completion: @escaping (Result<UpdateCheckResult, UpdateCheckError>) -> Void
    ) {
        guard let installedVersion = AppVersion(currentVersion) else {
            completion(.failure(.invalidCurrentVersion))
            return
        }

        var request = URLRequest(url: Self.releaseEndpoint)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadRevalidatingCacheData
        request.setValue("ShotMark/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let authorizationToken, !authorizationToken.isEmpty {
            request.setValue("Bearer \(authorizationToken)", forHTTPHeaderField: "Authorization")
        }

        loader(request) { result in
            let checked: Result<UpdateCheckResult, UpdateCheckError>
            switch result {
            case .failure(let error):
                checked = .failure(.network(error.localizedDescription))
            case .success(let (data, response)):
                checked = Self.parse(
                    data: data,
                    response: response,
                    installedVersion: installedVersion,
                    currentVersion: currentVersion
                )
            }
            DispatchQueue.main.async {
                completion(checked)
            }
        }
    }

    static func parse(
        data: Data,
        response: HTTPURLResponse,
        installedVersion: AppVersion,
        currentVersion: String
    ) -> Result<UpdateCheckResult, UpdateCheckError> {
        guard (200..<300).contains(response.statusCode) else {
            return .failure(.invalidServerResponse)
        }
        guard data.count <= maximumResponseBytes else {
            return .failure(.responseTooLarge)
        }
        guard let payload = try? JSONDecoder.github.decode(GitHubReleasePayload.self, from: data),
              !payload.draft,
              !payload.prerelease,
              let releaseVersion = AppVersion(payload.tagName),
              let releasePageURL = URL(string: payload.htmlURL),
              isOfficialReleaseURL(releasePageURL),
              let asset = payload.assets.first(where: { $0.name.caseInsensitiveCompare("ShotMark.dmg") == .orderedSame }),
              let downloadURL = URL(string: asset.downloadURL),
              isOfficialReleaseURL(downloadURL),
              let digest = normalizedDigest(asset.digest)
        else {
            return .failure(.releaseUnavailable)
        }

        guard releaseVersion > installedVersion else {
            return .success(.upToDate(currentVersion: currentVersion))
        }
        return .success(.updateAvailable(ShotMarkUpdateRelease(
            version: releaseVersion,
            displayVersion: payload.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
            releasePageURL: releasePageURL,
            downloadURL: downloadURL,
            sha256Digest: digest,
            publishedAt: payload.publishedAt
        )))
    }

    private static func normalizedDigest(_ digest: String?) -> String? {
        guard let digest else { return nil }
        let value = digest.lowercased()
        guard value.hasPrefix("sha256:") else { return nil }
        let hash = String(value.dropFirst("sha256:".count))
        guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hash
    }

    private static func isOfficialReleaseURL(_ url: URL) -> Bool {
        url.scheme == "https"
            && url.host?.lowercased() == "github.com"
            && url.path.hasPrefix("/jeffrey553553-cell/ShotMark/releases/")
    }

    private static func defaultLoader(
        request: URLRequest,
        completion: @escaping (Result<(Data, HTTPURLResponse), Error>) -> Void
    ) {
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data, let response = response as? HTTPURLResponse else {
                completion(.failure(URLError(.badServerResponse)))
                return
            }
            completion(.success((data, response)))
        }.resume()
    }
}

private struct GitHubReleasePayload: Decodable {
    struct Asset: Decodable {
        let name: String
        let downloadURL: String
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case name
            case downloadURL = "browser_download_url"
            case digest
        }
    }

    let tagName: String
    let htmlURL: String
    let draft: Bool
    let prerelease: Bool
    let publishedAt: Date?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case draft
        case prerelease
        case publishedAt = "published_at"
        case assets
    }
}

private extension JSONDecoder {
    static let github: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
