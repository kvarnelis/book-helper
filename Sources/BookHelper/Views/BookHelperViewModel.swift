import Combine
import Foundation
import AppKit

@MainActor
final class BookHelperViewModel: ObservableObject {
    @Published var items: [BookFileItem] = []
    @Published var statusMessage: String?
    @Published var refreshCounter = 0

    private let isbnExtractor = BookISBNExtractor()
    private var itemObservers: [UUID: AnyCancellable] = [:]

    var renameReadyCount: Int {
        items.filter { $0.isSelected && $0.status.canRename }.count
    }

    var zoteroReadyCount: Int {
        items.filter { $0.isSelected && $0.status.canImportToZotero }.count
    }

    var hasItems: Bool {
        !items.isEmpty
    }

    func handleDroppedURLs(_ urls: [URL]) {
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        guard !pdfs.isEmpty else {
            statusMessage = "Drop PDF files."
            return
        }

        statusMessage = nil
        var existingPaths = Set(items.map { $0.currentURL.standardizedFileURL.path })
        for url in pdfs {
            guard !existingPaths.contains(url.standardizedFileURL.path) else { continue }
            existingPaths.insert(url.standardizedFileURL.path)
            let item = BookFileItem(url: url)
            observe(item)
            items.append(item)

            Task {
                await process(item)
            }
        }
    }

    func lookupManualISBN(for item: BookFileItem) {
        let isbn = item.manualISBN.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isbn.isEmpty else { return }

        Task {
            await lookupISBN(isbn, for: item)
        }
    }

    func updateSelectedTitles() {
        let selected = items.filter { $0.isSelected && $0.status.canRename && $0.metadata != nil }
        guard !selected.isEmpty else { return }

        for item in selected {
            updateTitle(for: item)
        }
    }

    func importSelectedToZotero() {
        let selected = items.filter { $0.isSelected && $0.status.canImportToZotero && $0.metadata != nil }
        guard !selected.isEmpty else { return }

        statusMessage = "Importing \(selected.count) book\(selected.count == 1 ? "" : "s") to Zotero…"
        for item in selected {
            item.status = .importingToZotero
        }

        Task {
            await importSelectedBatch(selected)
        }
    }

    private func importSelectedBatch(_ items: [BookFileItem]) async {
        var successCount = 0
        var failureCount = 0

        await withTaskGroup(of: Bool.self) { group in
            for item in items {
                group.addTask {
                    await self.importToZotero(item)
                }
            }

            for await success in group {
                if success {
                    successCount += 1
                } else {
                    failureCount += 1
                }
            }
        }

        // Switch to Zotero only if all imports succeeded
        if failureCount == 0 && successCount > 0 {
            switchToZoteroIfPreferred()
        }
    }

    private func importToZotero(_ item: BookFileItem) async -> Bool {
        guard let metadata = item.metadata else {
            item.status = .error("No metadata")
            return false
        }

        // Rename the PDF first to avoid importing with raw download filename
        let currentURL = item.currentURL
        do {
            let newURL = try await Task.detached(priority: .userInitiated) {
                try BookRenamer.rename(pdfURL: currentURL, metadata: metadata)
            }.value
            item.currentURL = newURL
        } catch {
            item.status = .error(error.localizedDescription)
            statusMessage = error.localizedDescription
            return false
        }

        // Upload to Zotero with the renamed PDF
        do {
            try await ZoteroClient.shared.importBook(metadata: metadata, pdfURL: item.currentURL)
            item.status = .done
            statusMessage = "Imported \(metadata.fullTitle) to Zotero"
            return true
        } catch {
            item.status = .zoteroError(error.localizedDescription)
            statusMessage = error.localizedDescription
            return false
        }
    }

    private func switchToZoteroIfPreferred() {
        guard UserDefaults.standard.object(forKey: "switchToZoteroAfterImporting") as? Bool ?? true else { return }

        let zoteroBundle = "org.zotero.zotero"
        guard let zoteroURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: zoteroBundle) else {
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        Task {
            do {
                try await NSWorkspace.shared.openApplication(at: zoteroURL, configuration: configuration)
            } catch {
                // Silently fail - Zotero is running (import succeeded), but activation failed
            }
        }
    }

    func remove(_ item: BookFileItem) {
        item.stopAccessingFile()
        itemObservers.removeValue(forKey: item.id)
        items.removeAll { $0.id == item.id }
    }

    func clearCompleted() {
        let completed = items.filter { $0.status == .done }
        let completedIDs = Set(completed.map(\.id))
        guard !completedIDs.isEmpty else { return }

        completed.forEach { $0.stopAccessingFile() }
        items.removeAll { completedIDs.contains($0.id) }
        completedIDs.forEach { itemObservers.removeValue(forKey: $0) }
    }

    func reset() {
        items.forEach { $0.stopAccessingFile() }
        items = []
        itemObservers = [:]
        statusMessage = nil
    }

    private func observe(_ item: BookFileItem) {
        itemObservers[item.id] = item.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.refreshCounter += 1
            }
        }
    }

    private func process(_ item: BookFileItem) async {
        item.status = .scanning

        let filenameISBNs = await isbnExtractor.extractISBNs(in: item.currentURL.deletingPathExtension().lastPathComponent)
        let documentISBNs = await isbnExtractor.extractISBNs(from: item.currentURL)
        let lccnCandidates = await isbnExtractor.extractLCCNs(from: item.currentURL)
        let isbnCandidates = orderedUnique(filenameISBNs + documentISBNs)

        if !isbnCandidates.isEmpty, await lookupISBNCandidates(isbnCandidates, for: item) {
            return
        }

        if !lccnCandidates.isEmpty, await lookupLCCNCandidates(lccnCandidates, for: item) {
            return
        }

        await lookupFromFilename(for: item)
    }

    private func lookupFromFilename(for item: BookFileItem) async {
        item.status = .lookingUp
        let guess = filenameGuess(from: item.currentURL)

        if let metadata = await BookMetadataLookupService.shared.searchBestMatch(title: guess.title, author: guess.author) {
            item.metadata = metadata
            item.isbn = metadata.isbn
            item.status = .ready
            statusMessage = "Recovered metadata from filename"
        } else {
            item.status = .noISBNFound
            statusMessage = "No ISBN found. Enter one manually."
        }
    }

    private func lookupISBN(_ isbn: String, for item: BookFileItem) async {
        item.status = .lookingUp
        item.isbn = isbn

        if let metadata = await BookMetadataLookupService.shared.lookupISBN(isbn) {
            item.metadata = metadata
            item.status = .ready
        } else {
            item.status = .error("No title found for ISBN")
        }
    }

    private func lookupISBNCandidates(_ isbns: [String], for item: BookFileItem) async -> Bool {
        item.status = .lookingUp

        for isbn in isbns {
            item.isbn = isbn
            if let metadata = await BookMetadataLookupService.shared.lookupISBN(isbn) {
                item.metadata = metadata
                item.isbn = metadata.isbn ?? isbn
                item.status = .ready
                return true
            }
        }

        return false
    }

    private func lookupLCCNCandidates(_ lccns: [String], for item: BookFileItem) async -> Bool {
        item.status = .lookingUp

        for lccn in lccns {
            if let metadata = await BookMetadataLookupService.shared.lookupLCCN(lccn) {
                item.metadata = metadata
                item.isbn = metadata.isbn
                item.status = .ready
                statusMessage = "Recovered metadata from Library of Congress"
                return true
            }
        }

        return false
    }

    private func updateTitle(for item: BookFileItem) {
        guard let metadata = item.metadata else {
            item.status = .error("No metadata")
            return
        }

        item.status = .updating
        let itemID = item.id
        let currentURL = item.currentURL

        Task.detached(priority: .userInitiated) { [itemID, currentURL, metadata, viewModel = self] in
            do {
                let newURL = try BookRenamer.rename(pdfURL: currentURL, metadata: metadata)
                await viewModel.finishRename(itemID: itemID, newURL: newURL)
            } catch {
                await viewModel.failRename(itemID: itemID, message: error.localizedDescription)
            }
        }
    }

    private func finishRename(itemID: UUID, newURL: URL) {
        guard let item = items.first(where: { $0.id == itemID }) else { return }
        item.currentURL = newURL
        item.status = .renamed
        statusMessage = "Renamed \(newURL.lastPathComponent); ready to import to Zotero"
    }

    private func failRename(itemID: UUID, message: String) {
        guard let item = items.first(where: { $0.id == itemID }) else { return }
        item.status = .error(message)
    }

    private func filenameGuess(from url: URL) -> (title: String, author: String?) {
        let baseName = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let doubleDashParts = baseName.components(separatedBy: " -- ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if doubleDashParts.count >= 2, doubleDashParts[0].count > 8 {
            return (doubleDashParts[0], doubleDashParts[1])
        }

        for separator in [" - ", ". "] {
            guard let range = baseName.range(of: separator) else { continue }
            let author = String(baseName[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let title = String(baseName[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !author.isEmpty, title.count > 8 {
                return (title, author)
            }
        }

        return (baseName, nil)
    }

    private func orderedUnique(_ values: [String]) -> [String] {
        var result: [String] = []
        for value in values where !result.contains(value) {
            result.append(value)
        }
        return result
    }
}
