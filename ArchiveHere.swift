import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers

private struct ExtractionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    init(_ message: String) {
        self.message = message
    }
}

private enum Extractor {
    private static let tarSuffixes = [
        ".tar.gz", ".tar.gzip", ".tar.bz2", ".tar.bz", ".tar.xz", ".tar.z",
        ".tar.lz", ".tar.lzip", ".tar.lzma", ".tar.br", ".tar.lz4", ".tar.lzfse", ".cpio.gz",
    ]
    private static let streamExtensions: Set<String> = ["gz", "gzip", "bz", "bz2", "xz", "z", "lz", "lzip", "lzma"]
    private static let nativeStreams: Set<String> = ["br", "lz4", "lzfse"]

    static func extract(_ input: URL) throws -> URL {
        let source = input.standardizedFileURL
        let parent = source.deletingLastPathComponent().resolvingSymlinksInPath()
        let originalName = source.lastPathComponent
        let lowerName = originalName.lowercased()
        let ext = source.pathExtension.lowercased()
        let fileManager = FileManager.default

        if lowerName.range(of: #"\.part[0-9]+\.rar$|\.7z\.[0-9]+$"#, options: .regularExpression) != nil
            || (ext == "rar" && fileManager.fileExists(atPath: source.deletingPathExtension().appendingPathExtension("r00").path)) {
            throw ExtractionError("此版本无法解压分卷压缩包。")
        }

        let tarSuffix = tarSuffixes.first(where: { lowerName.hasSuffix($0) })
        let basename: String
        if let suffix = tarSuffix {
            basename = String(originalName.dropLast(suffix.count))
        } else {
            basename = source.deletingPathExtension().lastPathComponent
        }
        let folderName = validName(basename) ? basename : "解压文件"
        let streamName = streamExtensions.contains(ext) && tarSuffix == nil ? folderName : nil

        let quarantine = try quarantineData(at: source)
        let staging = try createStaging(in: parent)
        defer { try? fileManager.removeItem(at: staging) }

        let payload = staging.appendingPathComponent("contents", isDirectory: true)
        try fileManager.createDirectory(at: payload, withIntermediateDirectories: false)
        if nativeStreams.contains(ext) {
            let decoded = tarSuffix == nil ? payload.appendingPathComponent(folderName)
                : staging.appendingPathComponent("decoded-archive")
            guard decode_stream(source.path, decoded.path, ext) == 0 else {
                throw ExtractionError("无法解码 \(ext.uppercased()) 数据。请检查文件和可用空间。")
            }
            if tarSuffix != nil {
                try unpack(source: decoded, payload: payload, streamName: nil)
            }
        } else {
            try unpack(source: source, payload: payload, streamName: streamName)
        }

        // Downloaded files retain the source archive's Gatekeeper quarantine.
        if let quarantine {
            try applyQuarantine(quarantine, to: payload)
        }

        let items = try fileManager.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
        guard !items.isEmpty else {
            throw ExtractionError("没有可解压的内容。压缩包可能为空或已损坏。")
        }
        if items.count == 1, let item = items.first {
            let isDirectory = try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            return try publish(item, name: item.lastPathComponent, isDirectory: isDirectory, in: parent)
        }
        return try publish(payload, name: folderName, isDirectory: true, in: parent)
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    private static func createStaging(in parent: URL) throws -> URL {
        var template = Array(parent.appendingPathComponent(".archivehere.XXXXXX").path.utf8CString)
        return try template.withUnsafeMutableBufferPointer { buffer in
            guard let path = mkdtemp(buffer.baseAddress!) else {
                throw posixError(errno, path: parent.path)
            }
            return URL(fileURLWithFileSystemRepresentation: path, isDirectory: true, relativeTo: nil)
        }
    }

    private static func unpack(source: URL, payload: URL, streamName: String?) throws {
        var error = [CChar](repeating: 0, count: 2048)
        let outcome = streamName?.withCString {
            extract_archive(source.path, payload.path, $0, &error, error.count)
        } ?? extract_archive(source.path, payload.path, nil, &error, error.count)
        if outcome != 0 {
            let message = String(decoding: error.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            throw ExtractionError(message)
        }
    }

    private static func publish(_ item: URL, name: String, isDirectory: Bool, in parent: URL) throws -> URL {
        let ext = isDirectory ? "" : (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension

        for index in 1...10_000 {
            let candidateName = index == 1 ? name : "\(stem) \(index)\(ext.isEmpty ? "" : ".\(ext)")"
            let candidate = parent.appendingPathComponent(candidateName, isDirectory: isDirectory)
            if renamex_np(item.path, candidate.path, UInt32(RENAME_EXCL)) == 0 {
                return candidate
            }
            let code = errno
            if code != EEXIST && code != ENOTEMPTY {
                throw posixError(code, path: candidate.path)
            }
        }

        throw ExtractionError("目标目录中有太多同名项目，无法生成解压后的名称。")
    }

    private static func quarantineData(at source: URL) throws -> Data? {
        let key = "com.apple.quarantine"
        let length = getxattr(source.path, key, nil, 0, 0, 0)
        if length < 0 {
            let code = errno
            if code == ENOATTR || code == ENOTSUP {
                return nil
            }
            throw posixError(code, path: source.path)
        }
        if length == 0 { return nil }
        var bytes = Data(count: length)
        let count = bytes.withUnsafeMutableBytes {
            getxattr(source.path, key, $0.baseAddress, $0.count, 0, 0)
        }
        if count < 0 {
            throw posixError(errno, path: source.path)
        }
        bytes.count = count
        return bytes
    }

    private static func applyQuarantine(_ data: Data, to folder: URL) throws {
        var enumerationError: Error?
        guard let entries = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
            errorHandler: { _, error in enumerationError = error; return false }) else {
            throw ExtractionError("无法读取解压后的文件。")
        }
        try setQuarantine(data, at: folder)
        for case let item as URL in entries {
            try setQuarantine(data, at: item)
        }
        if let enumerationError { throw enumerationError }
    }

    private static func setQuarantine(_ data: Data, at item: URL) throws {
        let result = data.withUnsafeBytes {
            setxattr(item.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
        }
        if result != 0 {
            throw posixError(errno, path: item.path)
        }
    }

    private static func posixError(_ code: Int32, path: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
            NSLocalizedDescriptionKey: "\((path as NSString).lastPathComponent)：\(String(cString: strerror(code)))",
        ])
    }
}

@MainActor
private final class ArchiveApp: NSObject, NSApplicationDelegate {
    private let worker = DispatchQueue(label: "archivehere.extraction", qos: .userInitiated)
    private var idle: Timer?
    private var pending = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        scheduleIdle()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        idle?.invalidate()
        pending += 1

        worker.async {
            var errors: [String] = []
            for file in files {
                do {
                    _ = try Extractor.extract(file)
                } catch {
                    errors.append("\(file.lastPathComponent)\n\(error.localizedDescription)")
                }
            }

            let details = errors.joined(separator: "\n\n")
            DispatchQueue.main.async {
                if !details.isEmpty {
                    Self.alert("解压失败", details: details)
                }
                self.pending -= 1
                self.scheduleIdle()
            }
        }
    }

    private func scheduleIdle() {
        idle?.invalidate()
        guard pending == 0 else { return }
        idle = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in
            DispatchQueue.main.async {
                if self.pending == 0 {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private static func alert(_ title: String, details: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = details
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

@MainActor
private enum ArchiveAssociations {
    static func installDefaults() async -> Int32 {
        let bundle = Bundle.main
        guard let groups = bundle.object(forInfoDictionaryKey: "ArchiveHereAssociationGroups")
                as? [[String: [String]]] else {
            print("读取应用支持的格式失败。")
            return 1
        }

        let workspace = NSWorkspace.shared
        let appURL = bundle.bundleURL
        let installedPath = appURL.standardizedFileURL.resolvingSymlinksInPath()
        let generalTypes: Set<UTType> = [.item, .content, .data, .archive]
        var outcomes: [UTType: Bool] = [:]
        var failures: [String] = []

        print("正在设置当前账户的默认解压程序。macOS 弹出确认时，请按提示操作。")
        for group in groups {
            guard let extensions = group["Extensions"], let identifier = group["Identifiers"]?.first else {
                continue
            }
            let canonicalType = UTType(identifier) ?? UTType(importedAs: identifier, conformingTo: .archive)
            for suffix in extensions {
                let resolvedType = UTType(filenameExtension: suffix)
                let type = resolvedType.flatMap { $0.isDynamic || generalTypes.contains($0) ? nil : $0 }
                    ?? canonicalType
                let success: Bool
                if let previous = outcomes[type] {
                    success = previous
                } else {
                    func selectedApp() -> URL? {
                        workspace.urlForApplication(toOpen: type)?.standardizedFileURL.resolvingSymlinksInPath()
                    }
                    if selectedApp() == installedPath {
                        success = true
                    } else {
                        do {
                            try await workspace.setDefaultApplication(at: appURL, toOpen: type)
                            success = selectedApp() == installedPath
                        } catch {
                            success = false
                        }
                    }
                    outcomes[type] = success
                }
                print("\(success ? "已设为夏威夷果开罐器" : "未能更改")  .\(suffix)")
                if !success { failures.append(".\(suffix)") }
            }
        }
        if failures.isEmpty {
            print("文件关联已设置。现在可以在访达双击压缩包。")
            return 0
        }
        print("请在访达里对以下格式使用「显示简介 → 打开方式 → 夏威夷果开罐器 → 全部更改」")
        print(failures.joined(separator: "、"))
        return 1
    }
}

@main
private enum Main {
    @MainActor
    static func main() {
        if CommandLine.arguments.dropFirst().first == "--set-defaults" {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            Task { @MainActor in
                exit(await ArchiveAssociations.installDefaults())
            }
            app.run()
            exit(1)
        }

        // Exercise the same extractor from the command line during development.
        if CommandLine.arguments.dropFirst().first == "--extract" {
            var failed = false
            for path in CommandLine.arguments.dropFirst(2) {
                do {
                    print(try Extractor.extract(URL(fileURLWithPath: path)).path)
                } catch {
                    FileHandle.standardError.write(Data("\(path)：\(error.localizedDescription)\n".utf8))
                    failed = true
                }
            }
            exit(failed || CommandLine.arguments.count < 3 ? 1 : 0)
        }

        let app = NSApplication.shared
        let delegate = ArchiveApp()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
