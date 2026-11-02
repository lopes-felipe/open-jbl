import SwiftUI
import AppKit
import CoreServices

@main
struct OpenJBLApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        if ProcessInfo.processInfo.arguments.contains("--self-test") {
            SelfTest.runAndExit()
        }
    }

    var body: some Scene {
        Window("OpenJBL", id: "main") {
            MainWindow(model: model)
                .frame(minWidth: 780, minHeight: 530)
                .onAppear { delegate.attach(model); NSApp.setActivationPolicy(.regular) }
                .onDisappear { NSApp.setActivationPolicy(.accessory) }
        }
        .defaultSize(width: 900, height: 620)
        .commands {
            CommandMenu("Controls") {
                Button("Release Controls") { Task { await model.releaseControls() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            if ProcessInfo.processInfo.arguments.contains("--developer-tools") {
                CommandMenu("Developer") {
                    Button("Run Captured Telemetry Suite") {
                        Task { await model.runSuite(.telemetry, prerequisitesConfirmed: false) }
                    }
                    .disabled(model.isBusy || model.selected == nil)
                }
            }
        }
        MenuBarExtra {
            MenuPanel(model: model)
        } label: {
            Label {
                if model.preferences.menuBarPercentage,
                   case .level(let percent, _, _) = model.snapshot.batteryAgent,
                   !model.snapshot.batteryAgentStale {
                    Text("\(percent)%")
                } else { Text("OpenJBL") }
            } icon: { Image(systemName: "earbuds") }
                .onAppear { delegate.attach(model) }
        }
        .menuBarExtraStyle(.window)
        Settings {
            SettingsView(model: model).frame(width: 580, height: 440)
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var terminationPending = false
    private var launchFinished = false
    private var loginLaunch = false
    // LSUIElement supplies the initial accessory policy. MainWindow's lifecycle
    // owns later changes; resetting it here can override its earlier onAppear.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func attach(_ model: AppModel) {
        self.model = model
        if launchFinished { model.completeLaunch(atLogin: loginLaunch) }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        loginLaunch = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem))?.booleanValue ?? false
        launchFinished = true
        model?.completeLaunch(atLogin: loginLaunch)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task {
            await model.releaseControls()
            finishTermination(sender)
        }
        Task {
            try? await Task.sleep(for: .seconds(10))
            finishTermination(sender)
        }
        return .terminateLater
    }
    private func finishTermination(_ application: NSApplication) {
        guard terminationPending else { return }
        terminationPending = false
        application.reply(toApplicationShouldTerminate: true)
    }
}
