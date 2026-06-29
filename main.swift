import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - System sleep control

enum SleepControl {
    /// Reads the current state via `pmset -g` (no admin rights needed).
    /// When sleep is disabled, `pmset -g` prints a `SleepDisabled  1` line.
    static func isDisabled() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        for line in output.split(separator: "\n") where line.contains("SleepDisabled") {
            return line.contains("1")
        }
        return false
    }

    /// Sets `pmset -a disablesleep`. After a one-time setup (which asks for the
    /// password once), this runs silently with no further prompts.
    @discardableResult
    static func setDisabled(_ on: Bool) -> Bool {
        let value = on ? "1" : "0"
        // Fast path: passwordless sudo via our /etc/sudoers.d rule.
        if runSudoNoPrompt(value) { return true }
        // First run (or rule missing): install the rule + apply, one auth prompt.
        return installRuleAndApply(value)
    }

    /// Silent setter for automation: only the passwordless path, never prompts.
    /// Returns false if the sudoers rule isn't set up yet.
    @discardableResult
    static func setDisabledSilent(_ on: Bool) -> Bool {
        runSudoNoPrompt(on ? "1" : "0")
    }

    /// `sudo -n pmset …` — succeeds only if the NOPASSWD sudoers rule exists.
    private static func runSudoNoPrompt(_ value: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", value]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// One admin prompt: writes a NOPASSWD sudoers drop-in limited to exactly
    /// `pmset -a disablesleep 0|1`, validates it, then applies the change.
    private static func installRuleAndApply(_ value: String) -> Bool {
        let user = NSUserName()
        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
        let shell = "/bin/echo '\(rule)' > /etc/sudoers.d/dontsleep"
            + " && /bin/chmod 440 /etc/sudoers.d/dontsleep"
            + " && /usr/sbin/visudo -cf /etc/sudoers.d/dontsleep"
            + " && /usr/bin/pmset -a disablesleep \(value)"
        let source = "do shell script \"\(shell)\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        return error == nil
    }
}

// MARK: - Watched app

struct WatchedApp: Codable, Identifiable, Equatable {
    let id: String   // bundle identifier
    let name: String
}

// MARK: - Shared state (drives both the window and the menu-bar item)

@MainActor
final class AppModel: ObservableObject {
    @Published var isAwake = false { didSet { updateDockIcon() } }
    @Published var working = false
    @Published var errorText: String?

    // Auto-mode: keep awake while any watched app runs; sleep when all are closed.
    @Published var autoMode = false
    @Published var watchedApps: [WatchedApp] = []
    @Published var runningWatched: Set<String> = []

    private var monitorTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard

    init() {
        autoMode = defaults.bool(forKey: "autoMode")
        if let data = defaults.data(forKey: "watchedApps"),
           let list = try? JSONDecoder().decode([WatchedApp].self, from: data) {
            watchedApps = list
        }
    }

    /// Called from the window's onAppear: read state and start the monitor.
    func start() {
        refresh()
        refreshRunning()
        if autoMode { evaluate(prompt: false) }
        if monitorTask == nil { startMonitoring() }
    }

    func refresh() {
        isAwake = SleepControl.isDisabled()
    }

    /// Swaps the Dock / app-switcher icon to match the current state.
    private func updateDockIcon() {
        if let image = NSImage(named: isAwake ? "AppIconOn" : "AppIconOff") {
            NSApp.applicationIconImage = image
        }
    }

    // MARK: Manual toggle

    func toggle() {
        setState(!isAwake, prompt: true)
    }

    private func setState(_ desired: Bool, prompt: Bool) {
        guard !working else { return }
        working = true
        errorText = nil
        Task { @MainActor in
            let ok = prompt ? SleepControl.setDisabled(desired)
                            : SleepControl.setDisabledSilent(desired)
            let actual = SleepControl.isDisabled()
            self.working = false
            self.isAwake = actual
            if !ok && actual != desired {
                self.errorText = prompt
                    ? String(localized: "Couldn't change it — password cancelled?")
                    : String(localized: "Press the button once manually to set up auto mode.")
            }
        }
    }

    // MARK: Watch list

    func setAutoMode(_ on: Bool) {
        autoMode = on
        defaults.set(on, forKey: "autoMode")
        if on {
            refreshRunning()
            evaluate(prompt: true)
        }
    }

    func addApp(_ url: URL) {
        guard let id = Bundle(url: url)?.bundleIdentifier else {
            errorText = String(localized: "Couldn't read the app.")
            return
        }
        let name = url.deletingPathExtension().lastPathComponent
        guard !watchedApps.contains(where: { $0.id == id }) else { return }
        watchedApps.append(WatchedApp(id: id, name: name))
        saveWatched()
        refreshRunning()
        evaluate(prompt: true)
    }

    func removeApp(_ id: String) {
        watchedApps.removeAll { $0.id == id }
        saveWatched()
        refreshRunning()
        evaluate(prompt: false)
    }

    func icon(for app: WatchedApp) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.id) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func saveWatched() {
        if let data = try? JSONEncoder().encode(watchedApps) {
            defaults.set(data, forKey: "watchedApps")
        }
    }

    // MARK: Monitoring

    private func startMonitoring() {
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                self.refreshRunning()
                if self.autoMode { self.evaluate(prompt: false) }
            }
        }
    }

    private func refreshRunning() {
        let ids = Set(watchedApps.map { $0.id })
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
            .intersection(ids)
        if running != runningWatched { runningWatched = running }
    }

    /// Applies the auto-rule: any watched app running → awake; none → sleep.
    private func evaluate(prompt: Bool) {
        guard autoMode, !watchedApps.isEmpty, !working else { return }
        let desired = !runningWatched.isEmpty
        guard desired != isAwake else { return }
        setState(desired, prompt: prompt)
    }
}

// MARK: - Main window

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("showInMenuBar") private var showInMenuBar = true

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 18) {
                statusBlock
                toggleButton
                autoSection
                menuBarRow
                caption
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 30)
            .focusEffectDisabled() // no focus rings on the controls
        }
        .frame(width: 384)
        .onAppear {
            model.start()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // Deep, saturated backdrop with vivid blobs so the Liquid Glass button
    // refracts real colour.
    private var backdrop: some View {
        ZStack {
            LinearGradient(
                colors: model.isAwake
                    ? [Color(red: 0.02, green: 0.30, blue: 0.26),
                       Color(red: 0.03, green: 0.46, blue: 0.40),
                       Color(red: 0.01, green: 0.16, blue: 0.32)]
                    : [Color(red: 0.11, green: 0.06, blue: 0.32),
                       Color(red: 0.20, green: 0.09, blue: 0.46),
                       Color(red: 0.03, green: 0.03, blue: 0.16)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            blob(model.isAwake ? Color(red: 0.20, green: 1.0, blue: 0.60)
                               : Color(red: 0.62, green: 0.25, blue: 1.0),
                 size: 300, blur: 80, opacity: 0.55, x: -110, y: -170)
            blob(model.isAwake ? Color(red: 0.10, green: 0.85, blue: 0.95)
                               : Color(red: 0.96, green: 0.28, blue: 0.74),
                 size: 320, blur: 92, opacity: 0.50, x: 120, y: 40)
            blob(model.isAwake ? Color(red: 0.32, green: 0.95, blue: 0.70)
                               : Color(red: 0.28, green: 0.45, blue: 1.0),
                 size: 260, blur: 80, opacity: 0.45, x: 30, y: 210)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: model.isAwake)
    }

    private func blob(_ color: Color, size: CGFloat, blur: CGFloat,
                      opacity: Double, x: CGFloat, y: CGFloat) -> some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .blur(radius: blur)
            .opacity(opacity)
            .offset(x: x, y: y)
    }

    private var statusBlock: some View {
        VStack(spacing: 12) {
            Image(systemName: model.isAwake ? "eye.fill" : "moon.zzz.fill")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(.white)
            Text(model.isAwake ? "Mac won't sleep" : "Sleep is on")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
            Text(model.isAwake
                 ? "Lid can stay closed — everything keeps running"
                 : "Close the lid and the Mac sleeps")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var toggleButton: some View {
        GlassEffectContainer {
            Button(action: model.toggle) {
                HStack(spacing: 10) {
                    if model.working {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: model.isAwake ? "pause.fill" : "bolt.fill")
                            .font(.headline)
                    }
                    Text(model.working ? "One sec…" : (model.isAwake ? "Turn off" : "Keep awake"))
                        .font(.headline)
                }
                .foregroundStyle(.white)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(
                .regular
                    .tint(model.isAwake ? Color.green.opacity(0.45) : Color.blue.opacity(0.40))
                    .interactive(),
                in: .capsule
            )
            .disabled(model.working)
            .focusable(false)
            .focusEffectDisabled()
        }
    }

    // Auto-mode: pick apps; awake while any runs, sleep when all are closed.
    private var autoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(get: { model.autoMode }, set: { model.setAutoMode($0) })) {
                Label("Auto by apps", systemImage: "wand.and.stars")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
            }
            .toggleStyle(.switch)
            .tint(.green)
            .focusable(false)
            .focusEffectDisabled()

            Text("Any app from the list running → eye. All closed → sleep.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)

            if model.watchedApps.isEmpty {
                Text("List is empty — add apps below.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 6) {
                    ForEach(model.watchedApps) { app in
                        appRow(app)
                    }
                }
            }

            Button(action: pickApp) {
                Label("Add app", systemImage: "plus")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
            }
            .buttonStyle(.plain)
            .background(.white.opacity(0.14), in: .rect(cornerRadius: 11))
        }
        .padding(14)
        .background(.white.opacity(0.10), in: .rect(cornerRadius: 16))
    }

    private func appRow(_ app: WatchedApp) -> some View {
        HStack(spacing: 10) {
            if let icon = model.icon(for: app) {
                Image(nsImage: icon).resizable().frame(width: 22, height: 22)
            } else {
                Image(systemName: "app.dashed")
                    .frame(width: 22, height: 22)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Text(app.name)
                .font(.subheadline)
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 6)
            Circle()
                .fill(model.runningWatched.contains(app.id) ? Color.green : Color.white.opacity(0.25))
                .frame(width: 8, height: 8)
            Button {
                model.removeApp(app.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.white.opacity(0.08), in: .rect(cornerRadius: 10))
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Add")
        panel.message = String(localized: "Pick an app for auto mode")
        if panel.runModal() == .OK, let url = panel.url {
            model.addApp(url)
        }
    }

    // The requested switch: show / hide the menu-bar item.
    private var menuBarRow: some View {
        Toggle(isOn: $showInMenuBar) {
            Label("Show in menu bar", systemImage: "menubar.rectangle")
                .font(.subheadline)
                .foregroundStyle(.white)
        }
        .toggleStyle(.switch)
        .tint(.green)
        .focusable(false)
        .focusEffectDisabled()
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.white.opacity(0.10), in: .rect(cornerRadius: 14))
    }

    private var caption: some View {
        VStack(spacing: 8) {
            if let errorText = model.errorText {
                Text(errorText)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.yellow)
                    .multilineTextAlignment(.center)
            }
            Text("pmset -a disablesleep \(model.isAwake ? "1" : "0")")
                .font(.caption.monospaced())
                .foregroundStyle(.white.opacity(0.55))
            Text("Keep the Mac plugged in. The setting resets after reboot.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Menu-bar popover content

struct MenuContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: model.isAwake ? "eye.fill" : "moon.zzz.fill")
                    .font(.title3)
                    .foregroundStyle(model.isAwake ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.isAwake ? "Mac won't sleep" : "Sleep is on")
                        .font(.headline)
                    Text(model.isAwake ? "Lid can stay closed" : "Closing the lid will sleep")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button(action: model.toggle) {
                Text(model.working ? "One sec…" : (model.isAwake ? "Turn off" : "Keep awake"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isAwake ? .green : .blue)
            .disabled(model.working)

            Divider()

            HStack {
                Button("Open window") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .font(.callout)
        }
        .padding(16)
        .frame(width: 268)
    }
}

// MARK: - App entry

// Keeps the app alive when the window's red close button is clicked — it stays
// in the menu bar / Dock instead of quitting. Reopen via the menu bar or Dock.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true // let SwiftUI restore the main window on Dock click
    }
}

struct DontSleepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @AppStorage("showInMenuBar") private var showInMenuBar = true

    var body: some Scene {
        Window("DontSleep", id: "main") {
            ContentView().environmentObject(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        MenuBarExtra(isInserted: $showInMenuBar) {
            MenuContent().environmentObject(model)
        } label: {
            Image(systemName: model.isAwake ? "eye.fill" : "moon.zzz.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

DontSleepApp.main()
