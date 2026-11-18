import AppKit
import Darwin
import Security
import SwiftUI

private struct InstallError: LocalizedError {
    let detail: String
    var errorDescription: String? { detail }

    init(_ detail: String) {
        self.detail = detail
    }
}

private enum AppFiles {
    static let name = "夏威夷果开罐器.app"
    static let identifier = "app.archivehere.local"
    static let targetFolder = URL(fileURLWithPath: "/Applications", isDirectory: true)
    static let destination = targetFolder.appendingPathComponent(name, isDirectory: true)

    static var bundledApp: URL {
        Bundle.main.resourceURL!.appendingPathComponent(name, isDirectory: true)
    }

    static var terminal: URL? {
        if let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            return registered
        }
        let system = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app", isDirectory: true)
        return FileManager.default.fileExists(atPath: system.path) ? system : nil
    }

    static func version(of location: URL) -> Int? {
        let properties = try? location.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard properties?.isDirectory == true, properties?.isSymbolicLink == false,
              let bundle = Bundle(url: location), bundle.bundleIdentifier == identifier,
              let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path),
              let version = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
            return nil
        }
        return Int(version)
    }

    static func canConfigure() -> Bool {
        let bundledVersion = version(of: bundledApp) ?? Int.max
        return (version(of: destination) ?? 0) >= bundledVersion
    }

    private static func validateSignature(of item: URL) throws {
        var code: SecStaticCode?
        let create = SecStaticCodeCreateWithPath(item as CFURL, SecCSFlags(), &code)
        guard create == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            throw InstallError("应用校验失败。请重新下载完整的安装文件。")
        }
    }

    static func install(progress: @escaping (Double) -> Void) throws {
        guard let incoming = version(of: bundledApp) else {
            throw InstallError("安装窗口里缺少完整的「夏威夷果开罐器」应用。请重新下载。")
        }
        if let existing = version(of: destination), existing > incoming {
            progress(1)
            return
        }
        try validateSignature(of: bundledApp)

        let staging = try makeStagingFolder()
        defer { try? FileManager.default.removeItem(at: staging) }
        let copy = staging.appendingPathComponent(name, isDirectory: true)
        let meter = CopyMeter(source: bundledApp, report: progress)
        let error = withExtendedLifetime(meter) {
            archivehere_copy_bundle(bundledApp.path, copy.path,
                Unmanaged.passUnretained(meter).toOpaque(), { pointer, name, bytes in
                    guard let pointer, let name else { return }
                    Unmanaged<CopyMeter>.fromOpaque(pointer).takeUnretainedValue()
                        .update(path: String(cString: name), bytes: bytes)
                })
        }
        if error != 0 {
            throw errorForCopy(error)
        }
        progress(1)
        try validateSignature(of: copy)

        if renamex_np(copy.path, destination.path, UInt32(RENAME_EXCL)) == 0 {
            return
        }
        let moveError = errno
        guard moveError == EEXIST || moveError == ENOTEMPTY else {
            throw errorForCopy(moveError)
        }
        guard let installed = version(of: destination) else {
            throw InstallError("「应用程序」中已有一个同名项目。请先在访达检查该项目，再重试安装。")
        }
        if installed > incoming {
            return
        }
        if renamex_np(copy.path, destination.path, UInt32(RENAME_SWAP)) != 0 {
            throw errorForCopy(errno)
        }
        // A copy installed by macOS Installer can be owned by root.
        if (try? FileManager.default.removeItem(at: copy)) == nil {
            try? FileManager.default.trashItem(at: copy, resultingItemURL: nil)
        }
    }

    private static func makeStagingFolder() throws -> URL {
        var template = Array(targetFolder.appendingPathComponent(".archivehere-copy.XXXXXX").path.utf8CString)
        return try template.withUnsafeMutableBufferPointer { buffer in
            guard let name = mkdtemp(buffer.baseAddress!) else {
                throw errorForCopy(errno)
            }
            return URL(fileURLWithFileSystemRepresentation: name, isDirectory: true, relativeTo: nil)
        }
    }

    private static func errorForCopy(_ code: Int32) -> InstallError {
        switch code {
        case EACCES, EPERM, EROFS:
            return InstallError("无法写入「应用程序」。请使用有安装权限的 Mac 账户重试。")
        case ENOSPC, EDQUOT:
            return InstallError("磁盘空间不足。腾出空间后即可重试。")
        default:
            return InstallError("无法拷贝到「应用程序」。\(String(cString: strerror(code)))")
        }
    }
}

private final class CopyMeter {
    private let total: Int64
    private let report: (Double) -> Void
    private var transferred: [String: Int64] = [:]
    private var copied: Int64 = 0
    private var lastProgress = 0.0

    init(source: URL, report: @escaping (Double) -> Void) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        let files = FileManager.default.enumerator(at: source, includingPropertiesForKeys: Array(keys))
        var size: Int64 = 0
        while let file = files?.nextObject() as? URL {
            if let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true {
                size += Int64(values.fileSize ?? 0)
            }
        }
        self.total = max(1, size)
        self.report = report
    }

    func update(path: String, bytes: Int64) {
        let previous = transferred[path] ?? 0
        guard bytes > previous else { return }
        transferred[path] = bytes
        copied += bytes - previous
        let fraction = min(1, Double(copied) / Double(total))
        if fraction - lastProgress >= 0.01 {
            lastProgress = fraction
            report(fraction)
        }
    }
}

@MainActor
private final class InstallerState: ObservableObject {
    enum Phase {
        case ready, copying, installed, openingTerminal, terminalOpened, error(String)
    }

    @Published private(set) var phase: Phase
    @Published private(set) var fraction = 0.0
    @Published private(set) var isInstalled: Bool

    init() {
        let installed = AppFiles.canConfigure()
        self.isInstalled = installed
        self.phase = installed ? .installed : .ready
    }

    var isBusy: Bool {
        switch phase {
        case .copying, .openingTerminal: return true
        default: return false
        }
    }

    var isCopying: Bool {
        if case .copying = phase { return true }
        return false
    }

    func copyApp() {
        guard !isBusy else { return }
        fraction = 0
        phase = .copying
        let started = DispatchTime.now()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try AppFiles.install { progress in
                    DispatchQueue.main.async {
                        self.fraction = progress
                    }
                }
            }
            // A quick copy should still leave time to see the progress bar.
            DispatchQueue.main.asyncAfter(deadline: max(.now(), started + .milliseconds(500))) {
                self.isInstalled = AppFiles.canConfigure()
                switch result {
                case .success: self.phase = .installed
                case .failure(let error): self.phase = .error(error.localizedDescription)
                }
            }
        }
    }

    func openTerminal() {
        guard isInstalled, !isBusy else { return }
        guard AppFiles.canConfigure() else {
            isInstalled = false
            phase = .error("请先完成第一步，把「夏威夷果开罐器」拷贝到「应用程序」。")
            return
        }
        guard let command = Bundle.main.url(forResource: "设置默认解压程序", withExtension: "command"),
              let terminal = AppFiles.terminal else {
            phase = .error("找不到终端或设置关联的脚本。")
            return
        }
        phase = .openingTerminal
        Task { @MainActor in
            do {
                _ = try await NSWorkspace.shared.open([command], withApplicationAt: terminal,
                    configuration: NSWorkspace.OpenConfiguration())
                phase = .terminalOpened
            } catch {
                phase = .error("无法打开终端。\(error.localizedDescription)")
            }
        }
    }
}

private struct StepTile: View {
    let step: String
    let label: String
    let image: NSImage?
    let systemImage: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                Group {
                    if let image {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else {
                        Image(systemName: systemImage)
                            .resizable().scaledToFit().padding(19)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 104, height: 104)
                .accessibilityHidden(true)
                Text(step)
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.top, 3)
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 194)
        }
        .buttonStyle(StepTileStyle(enabled: enabled))
        .disabled(!enabled)
        .accessibilityLabel(Text("\(step)，\(label)"))
    }
}

private struct StepTileStyle: ButtonStyle {
    let enabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16)
        let pressing = enabled && configuration.isPressed
        configuration.label
            .background(shape.fill(pressing ? Color.accentColor.opacity(0.14)
                                   : Color(nsColor: .controlBackgroundColor).opacity(enabled ? 0.94 : 0.55)))
            .overlay(shape.strokeBorder(
                pressing ? Color.accentColor.opacity(0.72) : Color(nsColor: .separatorColor).opacity(0.68),
                lineWidth: pressing ? 1.5 : 1))
            .contentShape(shape)
            .opacity(enabled ? 1 : 0.78)
    }
}

@MainActor
private struct InstallerView: View {
    @ObservedObject var state: InstallerState
    let archiveIcon: NSImage?
    let terminalIcon: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            Text("安装夏威夷果开罐器")
                .font(.system(size: 25, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 16) {
                StepTile(step: "第一步", label: "拷贝到应用程序", image: archiveIcon,
                         systemImage: "shippingbox", enabled: !state.isBusy, action: state.copyApp)
                StepTile(step: "第二步", label: "在终端设置默认打开方式", image: terminalIcon,
                         systemImage: "terminal", enabled: state.isInstalled && !state.isBusy,
                         action: state.openTerminal)
            }
            status
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .topLeading)
        }
        .padding(28)
        .padding(.top, 18)
        .frame(width: 590, height: 390, alignment: .topLeading)
        .background(
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(colors: [Color.orange.opacity(0.08), .clear, Color.blue.opacity(0.07)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        )
    }

    @ViewBuilder
    private var status: some View {
        switch state.phase {
        case .ready:
            EmptyView()
        case .copying:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("正在拷贝到「应用程序」…")
                    Spacer()
                    Text("\(Int(state.fraction * 100))%").monospacedDigit()
                }
                .font(.system(size: 12))
                ProgressView(value: state.fraction)
                    .accessibilityLabel(Text("拷贝进度"))
            }
        case .installed:
            Label("「夏威夷果开罐器」已安装，可以进行第二步。", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        case .openingTerminal:
            Text("正在打开终端…").font(.system(size: 13)).foregroundStyle(.secondary)
        case .terminalOpened:
            Label("已打开终端，请按提示完成文件关联。", systemImage: "terminal")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        case .error(let detail):
            Label(detail, systemImage: "exclamationmark.circle")
                .font(.system(size: 13))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

@MainActor
private final class InstallerDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var state: InstallerState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = InstallerState()
        self.state = state
        let icon = Bundle.main.url(forResource: "ArchiveHere", withExtension: "icns").flatMap { NSImage(contentsOf: $0) }
        let terminal = AppFiles.terminal.map { NSWorkspace.shared.icon(forFile: $0.path) }
        let view = InstallerView(state: state, archiveIcon: icon, terminalIcon: terminal)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 590, height: 390),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "安装夏威夷果开罐器"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: view)
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        state?.isCopying != true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        state?.isCopying == true ? .terminateCancel : .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        return true
    }
}

@main
private enum InstallerMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = InstallerDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
