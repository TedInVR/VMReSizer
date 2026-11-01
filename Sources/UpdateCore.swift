import Foundation
import AppKit
import CryptoKit
import Darwin

let repository = "TedInVR/VMReSizer"
let appIdentifier = "com.tedwhitten.vmresizer"
let releaseArchive = "VM-Re-Sizer-macOS.zip"

enum UpdateError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(s) = self { return s }; return nil }
}

struct UpdatePaths {
    static var support: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/VM Re-Sizer", isDirectory: true)
    }
    static func prepare() throws {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
    }
    static var config: URL { support.appendingPathComponent("updater.json") }
    static var pending: URL { support.appendingPathComponent("manual-update-request") }
    static var lock: URL { support.appendingPathComponent("application.lock") }
    static var log: URL { support.appendingPathComponent("updater.log") }
}

struct UpdateConfig: Codable {
    var appPath: String
    var automatic: Bool
    func save() throws {
        try UpdatePaths.prepare()
        try JSONEncoder().encode(self).write(to: UpdatePaths.config, options: .atomic)
    }
    static func load() throws -> UpdateConfig {
        try JSONDecoder().decode(UpdateConfig.self, from: Data(contentsOf: UpdatePaths.config))
    }
}

final class ApplicationLock {
    private var descriptor: Int32 = -1
    init(exclusive: Bool) throws {
        try UpdatePaths.prepare()
        descriptor = Darwin.open(UpdatePaths.lock.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw UpdateError.message("Unable to create the application update lock.") }
        if flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) != 0 {
            Darwin.close(descriptor); descriptor = -1
            throw UpdateError.message("VM Re-Sizer is busy. An update check or installation may be finishing; please open it again in a moment.")
        }
    }
    func release() {
        if descriptor >= 0 { flock(descriptor, LOCK_UN); Darwin.close(descriptor); descriptor = -1 }
    }
    deinit { release() }
}

@discardableResult
func runTool(_ path: String, _ arguments: [String], input: String? = nil, environment: [String: String]? = nil) throws -> String {
    let task = Process(), out = Pipe(), err = Pipe()
    task.executableURL = URL(fileURLWithPath: path); task.arguments = arguments
    task.standardOutput = out; task.standardError = err
    if let environment = environment { task.environment = environment }
    if let input = input {
        let pipe = Pipe(); task.standardInput = pipe
        try task.run()
        pipe.fileHandleForWriting.write(Data(input.utf8)); try? pipe.fileHandleForWriting.close()
    } else {
        task.standardInput = FileHandle.nullDevice
        try task.run()
    }
    // Commands used here emit only small output; no credentials are ever sent to logs.
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let errorData = err.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else {
        // Do not propagate stderr: credential helpers can include private data.
        _ = errorData
        throw UpdateError.message("A required system command failed (\(URL(fileURLWithPath: path).lastPathComponent), exit \(task.terminationStatus)).")
    }
    return String(data: data, encoding: .utf8) ?? ""
}

// Apple's stable, signed git credential helper stores the token in macOS Keychain.
// No token is embedded in the app, written into a settings file, or passed on a command line.
struct GitHubCredentials {
    static func helper(_ action: String, value: String) -> String? {
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"; env["GCM_INTERACTIVE"] = "never"
        return try? runTool("/usr/bin/git", ["credential-osxkeychain", action], input: value, environment: env)
    }
    static func token() -> String? {
        let request = "protocol=https\nhost=github.com\npath=TedInVR/VMReSizer\nusername=VMReSizer\n\n"
        if let response = helper("get", value: request), let token = password(response) { return token }
        // Reuse an existing GitHub CLI login without displaying or logging its token.
        for path in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"] where FileManager.default.isExecutableFile(atPath: path) {
            if let value = try? runTool(path, ["auth", "token", "--hostname", "github.com"]), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Finally try the standard host credential already used by git on this Mac.
        if let response = helper("get", value: "protocol=https\nhost=github.com\n\n") { return password(response) }
        return nil
    }
    static func password(_ response: String) -> String? {
        for line in response.split(separator: "\n") where line.hasPrefix("password=") {
            let value = String(line.dropFirst(9)); if !value.isEmpty { return value }
        }
        return nil
    }
    static func save(_ token: String) throws {
        guard !token.isEmpty, !token.contains("\n"), !token.contains("\r"),
              helper("store", value: "protocol=https\nhost=github.com\npath=TedInVR/VMReSizer\nusername=VMReSizer\npassword=\(token)\n\n") != nil else {
            throw UpdateError.message("The GitHub credential could not be saved in macOS Keychain. Apple's Command Line Tools must be installed for Keychain access through Git.")
        }
    }
}

struct ReleaseAsset: Decodable { let id: Int; let name: String; let size: Int }
struct AppRelease: Decodable {
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let assets: [ReleaseAsset]
    var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
    func asset(_ name: String) throws -> ReleaseAsset {
        guard let asset = assets.first(where: { $0.name == name }), asset.id > 0, asset.size < 120_000_000 else {
            throw UpdateError.message("The release is missing a valid \(name) file.")
        }
        return asset
    }
}

func versionParts(_ value: String) -> [Int]? {
    let components = value.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 3 else { return nil }
    let parts = components.compactMap { Int($0) }
    return parts.count == 3 && parts.allSatisfy({ $0 >= 0 }) ? parts : nil
}
func isNewer(_ next: String, than current: String) -> Bool {
    guard let n = versionParts(next), let c = versionParts(current) else { return false }
    return c.lexicographicallyPrecedes(n)
}
func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func expectedChecksum(_ text: String) throws -> String {
    for line in text.split(separator: "\n") {
        let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if words.count == 2, (words[1] == Substring(releaseArchive) || words[1] == Substring("*" + releaseArchive)) {
            let hash = String(words[0]).lowercased()
            if hash.count == 64 && hash.allSatisfy({ $0.isHexDigit }) { return hash }
        }
    }
    throw UpdateError.message("The release checksum file is invalid.")
}

final class GitHubClient: NSObject, URLSessionTaskDelegate {
    let token: String?
    init(token: String? = nil) { self.token = token ?? GitHubCredentials.token(); super.init() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https", let host = request.url?.host,
              host == "api.github.com" || host == "github.com" || host.hasSuffix(".githubusercontent.com") else {
            completionHandler(nil); return
        }
        var safe = request
        if host != "api.github.com" { safe.setValue(nil, forHTTPHeaderField: "Authorization") }
        completionHandler(safe)
    }
    func fetch(_ path: String, binary: Bool = false) async throws -> Data {
        let url = URL(string: "https://api.github.com/repos/\(repository)/\(path)")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
        request.setValue(binary ? "application/octet-stream" : "application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("VM-Re-Sizer", forHTTPHeaderField: "User-Agent")
        if let token = token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 90
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.message("No response from GitHub.") }
        if http.statusCode == 401 || http.statusCode == 404 {
            throw UpdateError.message("GitHub could not provide this private release. Use Help > Connect GitHub to provide a token with read-only Contents access to TedInVR/VMReSizer, or confirm that a release has been published.")
        }
        guard http.statusCode == 200 else { throw UpdateError.message("GitHub returned HTTP \(http.statusCode). Try again later.") }
        guard data.count <= 120_000_000 else { throw UpdateError.message("The release download is too large.") }
        return data
    }
    func latest() async throws -> AppRelease {
        let release = try JSONDecoder().decode(AppRelease.self, from: await fetch("releases/latest"))
        guard !release.draft, !release.prerelease, versionParts(release.version) != nil else {
            throw UpdateError.message("GitHub has no valid stable release.")
        }
        _ = try release.asset(releaseArchive); _ = try release.asset("SHA256SUMS")
        return release
    }
}

func writeUpdateLog(_ text: String) {
    try? UpdatePaths.prepare()
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(text)\n"
    if let data = line.data(using: .utf8) {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: UpdatePaths.log.path),
           let size = attrs[.size] as? NSNumber, size.intValue > 200_000 { try? FileManager.default.removeItem(at: UpdatePaths.log) }
        if !FileManager.default.fileExists(atPath: UpdatePaths.log.path) { try? data.write(to: UpdatePaths.log) }
        else if let handle = try? FileHandle(forWritingTo: UpdatePaths.log) {
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data); try? handle.close()
        }
    }
}

func mirrorDevelopment(from app: URL) throws {
    let source = app.appendingPathComponent("Contents/Resources/Development")
    guard FileManager.default.fileExists(atPath: source.path) else { return }
    let version = Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    let parent = app.deletingLastPathComponent().appendingPathComponent("VM Re-Sizer Development", isDirectory: true)
    let destination = parent.appendingPathComponent(version, isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.copyItem(at: source, to: destination) }
}
