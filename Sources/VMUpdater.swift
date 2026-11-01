import Foundation
import AppKit
import Darwin

#if !TESTING
@main
#endif
struct VMUpdater {
    static func main() async {
        do {
            if CommandLine.arguments.contains("--after-quit") {
                for _ in 0..<40 {
                    if !appRunning() { break }
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            guard !appRunning() else { return }
            let config = try UpdateConfig.load()
            guard config.automatic || FileManager.default.fileExists(atPath: UpdatePaths.pending.path) else { return }
            let lock: ApplicationLock
            do { lock = try ApplicationLock(exclusive: true) } catch { return }
            defer { lock.release() }
            guard !appRunning() else { return }
            let target = URL(fileURLWithPath: config.appPath)
            guard target.pathExtension == "app", let bundle = Bundle(url: target),
                  bundle.bundleIdentifier == appIdentifier,
                  let installed = bundle.infoDictionary?["CFBundleShortVersionString"] as? String else {
                throw UpdateError.message("The installed app could not be found. Open VM Re-Sizer to reconnect its location.")
            }
            let client = GitHubClient()
            let release = try await client.latest()
            guard isNewer(release.version, than: installed) else {
                try? FileManager.default.removeItem(at: UpdatePaths.pending)
                writeUpdateLog("Already up to date (\(installed)).")
                return
            }
            let archiveAsset = try release.asset(releaseArchive)
            let sumAsset = try release.asset("SHA256SUMS")
            let sumData = try await client.fetch("releases/assets/\(sumAsset.id)", binary: true)
            let expected = try expectedChecksum(String(data: sumData, encoding: .utf8) ?? "")
            let archive = try await client.fetch("releases/assets/\(archiveAsset.id)", binary: true)
            guard archive.count == archiveAsset.size, sha256(archive) == expected else {
                throw UpdateError.message("The downloaded update failed its size or SHA-256 verification. No changes were made.")
            }
            let workspace = UpdatePaths.support.appendingPathComponent("staging-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: workspace) }
            let zip = workspace.appendingPathComponent("release.zip")
            try archive.write(to: zip)
            let listing = try runTool("/usr/bin/unzip", ["-Z1", zip.path])
            guard !listing.isEmpty, listing.split(separator: "\n").allSatisfy({ name in
                !name.hasPrefix("/") && !name.split(separator: "/").contains("..") &&
                    (name.hasPrefix("VM Re-Sizer.app/") || name == "VM Re-Sizer.app")
            }) else { throw UpdateError.message("The update archive has unexpected paths.") }
            let unpacked = workspace.appendingPathComponent("unpacked")
            try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: false)
            try runTool("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
            let next = unpacked.appendingPathComponent("VM Re-Sizer.app")
            guard let nextBundle = Bundle(url: next), nextBundle.bundleIdentifier == appIdentifier,
                  nextBundle.infoDictionary?["CFBundleShortVersionString"] as? String == release.version,
                  FileManager.default.isExecutableFile(atPath: next.appendingPathComponent("Contents/MacOS/VMReSizer").path),
                  FileManager.default.isExecutableFile(atPath: next.appendingPathComponent("Contents/Helpers/VMUpdater").path) else {
                throw UpdateError.message("The update's app identity, version or executables did not match.")
            }
            try runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", next.path])
            guard !appRunning() else { return }
            try install(next, to: target)
            try? FileManager.default.removeItem(at: UpdatePaths.pending)
            do { try mirrorDevelopment(from: target) }
            catch { writeUpdateLog("App updated; development-source copy could not be refreshed. Open the app to retry.") }
            writeUpdateLog("Installed \(release.version). App left closed.")
        } catch {
            // Error descriptions are generated locally, never HTTP bodies or credential output.
            writeUpdateLog(error.localizedDescription)
        }
    }
    static func appRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == appIdentifier && !$0.isTerminated }
    }
    static func install(_ source: URL, to target: URL) throws {
        let fm = FileManager.default
        let parent = target.deletingLastPathComponent()
        let fresh = parent.appendingPathComponent(".VMReSizer-new-" + UUID().uuidString + ".app")
        let backup = parent.appendingPathComponent(".VMReSizer-backup-" + UUID().uuidString + ".app")
        try fm.copyItem(at: source, to: fresh)
        defer { try? fm.removeItem(at: fresh) }
        try fm.moveItem(at: target, to: backup)
        do { try fm.moveItem(at: fresh, to: target) }
        catch {
            do { try fm.moveItem(at: backup, to: target) }
            catch { throw UpdateError.message("The update could not finish restoring the old app. Its backup remains at \(backup.path).") }
            throw UpdateError.message("The update could not be installed. The previous version was restored.")
        }
        try? fm.removeItem(at: backup)
    }
}
