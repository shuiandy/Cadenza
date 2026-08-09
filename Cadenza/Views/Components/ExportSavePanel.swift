import AppKit
import UniformTypeIdentifiers

/// NSSavePanel helpers for single-file local exports.
/// Returns nil when the user cancels; throws on write/copy failure.
@MainActor
enum ExportSavePanel {

    static func saveText(_ content: String, suggestedName: String) throws -> URL? {
        guard let url = present(suggestedName: suggestedName) else { return nil }
        do {
            try Data(content.utf8).write(to: url, options: .atomic)
        } catch {
            NSLog("[ExportSavePanel] text save failed: %@", String(describing: error))
            throw ExportError.unexpected(String(describing: error))
        }
        return url
    }

    static func copyFile(from source: URL, suggestedName: String) throws -> URL? {
        guard let url = present(suggestedName: suggestedName) else { return nil }
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: url.path) {
                // 面板已确认覆盖。不能先删再拷——拷贝失败会连用户原文件一起丢。
                // 先拷到同卷临时目录，再原子替换。
                let tempDir = try fm.url(
                    for: .itemReplacementDirectory, in: .userDomainMask,
                    appropriateFor: url, create: true
                )
                let tempCopy = tempDir.appendingPathComponent(url.lastPathComponent)
                try fm.copyItem(at: source, to: tempCopy)
                _ = try fm.replaceItemAt(url, withItemAt: tempCopy)
            } else {
                try fm.copyItem(at: source, to: url)
            }
        } catch {
            NSLog("[ExportSavePanel] audio copy failed: %@", String(describing: error))
            throw ExportError.unexpected(String(describing: error))
        }
        return url
    }

    private static func present(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        if let ext = suggestedName.split(separator: ".").last.map(String.init),
           let type = UTType(filenameExtension: ext) {
            panel.allowedContentTypes = [type]
        }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
