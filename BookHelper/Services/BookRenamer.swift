import Foundation

enum BookRenamer {
    enum RenameError: LocalizedError {
        case emptyTitle
        case renameFailed(String)

        var errorDescription: String? {
            switch self {
            case .emptyTitle: return "No title to write"
            case .renameFailed(let message): return "Could not rename book: \(message)"
            }
        }
    }

    static func rename(fileURL: URL, metadata: BookMetadata) throws -> URL {
        guard BookFileFormat(url: fileURL) != nil else {
            throw RenameError.renameFailed("Only PDF and EPUB files are supported")
        }
        let title = metadata.fullTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw RenameError.emptyTitle
        }

        let targetURL = uniqueTargetURL(for: fileURL, title: title)
        guard targetURL != fileURL else {
            return fileURL
        }

        do {
            try FileManager.default.moveItem(at: fileURL, to: targetURL)
            return targetURL
        } catch {
            throw RenameError.renameFailed(error.localizedDescription)
        }
    }

    private static func uniqueTargetURL(for sourceURL: URL, title: String) -> URL {
        let directory = sourceURL.deletingLastPathComponent()
        let baseName = sanitizedFileBaseName(from: title)
        var target = directory.appendingPathComponent(baseName).appendingPathExtension(sourceURL.pathExtension)

        if target.standardizedFileURL == sourceURL.standardizedFileURL {
            return sourceURL
        }

        var counter = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = directory.appendingPathComponent("\(baseName) (\(counter))").appendingPathExtension(sourceURL.pathExtension)
            counter += 1
        }

        return target
    }

    private static func sanitizedFileBaseName(from title: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\0\"?*|<>")
        let cleaned = title.unicodeScalars
            .filter { !illegal.contains($0) }
            .map(String.init)
            .joined()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.isEmpty {
            return "Untitled"
        }

        if cleaned.count > 180 {
            return String(cleaned.prefix(180)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return cleaned
    }
}
