import Foundation

struct PreparedTransferFile: Sendable {
    let url: URL
    let name: String
    let size: Int64
    let temporaryDirectory: URL?

    func cleanup() {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }
}

enum FileTransfer {
    static func prepareUpload(urls: [URL], maximumBytes: Int64) async throws -> PreparedTransferFile {
        try await Task.detached {
            let urls = urls.map(\.standardizedFileURL)
            guard !urls.isEmpty else {
                throw SyncClipboardError.unsupportedFileSelection
            }

            _ = try totalSize(of: urls, maximumBytes: maximumBytes)
            let fileManager = FileManager.default
            let temporaryDirectory = fileManager.temporaryDirectory
                .appendingPathComponent("SyncClipboard-\(UUID().uuidString)", isDirectory: true)
            let stagingDirectory = temporaryDirectory.appendingPathComponent("contents", isDirectory: true)

            do {
                try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
                if urls.count == 1,
                   try urls[0].resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    let name = urls[0].lastPathComponent
                    let copyURL = temporaryDirectory.appendingPathComponent(name)
                    try copyExcludingSymbolicLinks(from: urls[0], to: copyURL)
                    let copiedSize = try totalSize(of: [copyURL], maximumBytes: maximumBytes)
                    return PreparedTransferFile(
                        url: copyURL,
                        name: name,
                        size: copiedSize,
                        temporaryDirectory: temporaryDirectory
                    )
                }

                try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
                for source in urls {
                    let destination = uniqueURL(
                        named: source.lastPathComponent,
                        in: stagingDirectory,
                        fileManager: fileManager
                    )
                    try copyExcludingSymbolicLinks(from: source, to: destination)
                }
                _ = try totalSize(of: [stagingDirectory], maximumBytes: maximumBytes)

                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd-HHmmss"
                let name = "SyncClipboard-\(formatter.string(from: Date())).zip"
                let archiveURL = temporaryDirectory.appendingPathComponent(name)
                try createZIP(from: stagingDirectory, at: archiveURL)
                let archiveSize = try archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? 0
                guard archiveSize <= maximumBytes else {
                    throw SyncClipboardError.transferTooLarge(maximumBytes)
                }

                return PreparedTransferFile(
                    url: archiveURL,
                    name: name,
                    size: archiveSize,
                    temporaryDirectory: temporaryDirectory
                )
            } catch {
                try? fileManager.removeItem(at: temporaryDirectory)
                throw error
            }
        }.value
    }

    static func saveDownloadedFile(
        _ temporaryURL: URL,
        suggestedName: String,
        downloadsDirectory: URL = defaultDownloadsDirectory
    ) async throws -> URL {
        try await Task.detached {
            let fileManager = FileManager.default
            let name = try safeFileName(suggestedName)
            try fileManager.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
            let destination = uniqueURL(named: name, in: downloadsDirectory, fileManager: fileManager)
            try fileManager.moveItem(at: temporaryURL, to: destination)
            return destination
        }.value
    }

    static var defaultDownloadsDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SyncClipboard", isDirectory: true)
    }

    static func safeFileName(_ proposedName: String) throws -> String {
        let name = URL(fileURLWithPath: proposedName).lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else {
            throw SyncClipboardError.invalidRemoteFileName
        }
        return name
    }

    private static func totalSize(of urls: [URL], maximumBytes: Int64) throws -> Int64 {
        var total: Int64 = 0
        var pending = urls
        var foundSupportedItem = false

        while let url = pending.popLast() {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])

            if values.isSymbolicLink == true {
                continue
            }
            if values.isRegularFile == true {
                foundSupportedItem = true
                total += Int64(values.fileSize ?? 0)
                guard total <= maximumBytes else {
                    throw SyncClipboardError.transferTooLarge(maximumBytes)
                }
            } else if values.isDirectory == true {
                foundSupportedItem = true
                pending.append(contentsOf: try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil
                ))
            } else {
                throw SyncClipboardError.unsupportedFileSelection
            }
        }

        guard foundSupportedItem else {
            throw SyncClipboardError.unsupportedFileSelection
        }
        return total
    }

    private static func copyExcludingSymbolicLinks(from source: URL, to destination: URL) throws {
        let values = try source.resourceValues(forKeys: [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        if values.isSymbolicLink == true {
            return
        }
        if values.isRegularFile == true {
            try FileManager.default.copyItem(at: source, to: destination)
            return
        }
        guard values.isDirectory == true else {
            throw SyncClipboardError.unsupportedFileSelection
        }

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for child in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            try copyExcludingSymbolicLinks(
                from: child,
                to: destination.appendingPathComponent(child.lastPathComponent)
            )
        }
    }

    private static func createZIP(from source: URL, at destination: URL) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", source.path, destination.path]
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SyncClipboardError.archiveFailed(message.isEmpty ? "ditto exited with status \(process.terminationStatus)" : message)
        }
    }

    private static func uniqueURL(named name: String, in directory: URL, fileManager: FileManager) -> URL {
        let original = directory.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: original.path) else { return original }

        let extensionName = original.pathExtension
        let stem = original.deletingPathExtension().lastPathComponent
        var index = 1
        while true {
            let candidateName = extensionName.isEmpty
                ? "\(stem) (\(index))"
                : "\(stem) (\(index)).\(extensionName)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }
}
