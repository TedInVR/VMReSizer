import Foundation
import AppKit
import SwiftUI

final class UpdateController: ObservableObject {
    static let shared = UpdateController()
    @Published var checking = false
    @Published var automatic = UserDefaults.standard.object(forKey: "automaticUpdates") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(automatic, forKey: "automaticUpdates")
            do { try configuration().save() } catch { alert(error.localizedDescription) }
        }
    }
    func configuration() -> UpdateConfig {
        UpdateConfig(appPath: Bundle.main.bundleURL.path, automatic: automatic)
    }
    func alert(_ text: String) {
        let panel = NSAlert(); panel.messageText = "VM Re-Sizer Updates"
        panel.informativeText = text; panel.runModal()
    }
    func configure() {
        do {
            try configuration().save()
            let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/VMUpdater")
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("com.tedwhitten.vmresizer.updater.plist")
            let plist: [String: Any] = [
                "Label": "com.tedwhitten.vmresizer.updater",
                "ProgramArguments": [helpers.path, "--background"],
                "StartInterval": 900, "RunAtLoad": true,
                "ProcessType": "Background", "LimitLoadToSessionType": "Aqua",
                "StandardOutPath": UpdatePaths.support.appendingPathComponent("agent.stdout.log").path,
                "StandardErrorPath": UpdatePaths.support.appendingPathComponent("agent.stderr.log").path
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            let domain = "gui/\(getuid())"
            if (try? Data(contentsOf: url)) != data {
                _ = try? runTool("/bin/launchctl", ["bootout", domain + "/com.tedwhitten.vmresizer.updater"])
                try data.write(to: url, options: .atomic)
            }
            if (try? runTool("/bin/launchctl", ["print", domain + "/com.tedwhitten.vmresizer.updater"])) == nil {
                try runTool("/bin/launchctl", ["bootstrap", domain, url.path])
            }
            do { try mirrorDevelopment(from: Bundle.main.bundleURL) }
            catch { writeUpdateLog("Development-source copy unavailable; source remains inside the installed app bundle.") }
        } catch { alert("The background updater could not be registered.\n\n" + error.localizedDescription) }
    }
    func check() {
        guard !checking else { return }
        checking = true
        Task {
            do {
                let client = GitHubClient()
                let release = try await client.latest()
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
                await MainActor.run {
                    self.checking = false
                    if isNewer(release.version, than: version) {
                        do {
                            try Data(release.version.utf8).write(to: UpdatePaths.pending, options: .atomic)
                            self.alert("Version \(release.version) is available and queued. Quit VM Re-Sizer when you are ready. It will download and install after the app closes, and leave the app closed.")
                        } catch { self.alert(error.localizedDescription) }
                    } else { self.alert("You’re up to date — version \(version).") }
                }
            } catch {
                await MainActor.run { self.checking = false; self.alert(error.localizedDescription) }
            }
        }
    }
    func connect() {
        let panel = NSAlert(); panel.messageText = "Connect Private GitHub Updates"
        panel.informativeText = "Existing GitHub CLI and Git Keychain credentials are tried automatically. If access is unavailable, create a fine-grained personal access token for TedInVR/VMReSizer with Contents: Read-only, then paste it below. It is stored in macOS Keychain, never in the app or repository.\n\nTokens may expire; reconnect here if necessary."
        panel.addButton(withTitle: "Save and Check"); panel.addButton(withTitle: "Cancel")
        panel.addButton(withTitle: "Open Token Settings")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = "GitHub fine-grained token"; panel.accessoryView = field
        panel.window.initialFirstResponder = field
        let response = panel.runModal()
        if response == .alertThirdButtonReturn {
            NSWorkspace.shared.open(URL(string: "https://github.com/settings/personal-access-tokens/new")!)
            return
        }
        guard response == .alertFirstButtonReturn else { return }
        let token = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.stringValue = ""
        guard !token.isEmpty else { alert("No token was entered. Existing GitHub credentials will still be tried."); return }
        checking = true
        Task {
            do {
                _ = try await GitHubClient(token: token).latest()
                try GitHubCredentials.save(token)
                await MainActor.run { self.checking = false; self.alert("Private GitHub release access is connected. Background updates will run while the app is closed.") }
            } catch {
                await MainActor.run { self.checking = false; self.alert(error.localizedDescription) }
            }
        }
    }
    func launchAfterQuit() {
        guard automatic || FileManager.default.fileExists(atPath: UpdatePaths.pending.path) else { return }
        let process = Process()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/VMUpdater")
        process.arguments = ["--after-quit"]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var session: ApplicationLock?
    static var isExporting: () -> Bool = { false }
    func applicationWillFinishLaunching(_ notification: Notification) {
        do { session = try ApplicationLock(exclusive: false) }
        catch {
            let alert = NSAlert(); alert.messageText = "VM Re-Sizer"
            alert.informativeText = error.localizedDescription; alert.runModal()
            NSApp.terminate(nil)
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) { UpdateController.shared.configure() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.isExporting() {
            let panel = NSAlert(); panel.messageText = "Export in progress"
            panel.informativeText = "Please let the export finish before closing VM Re-Sizer."
            panel.runModal(); return .terminateCancel
        }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        UpdateController.shared.launchAfterQuit()
        session?.release()
    }
}
