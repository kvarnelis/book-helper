import AppKit
import Combine
import Foundation

struct ZoteroImportNotice: Equatable {
    let bookTitle: String
}

@MainActor
final class BookHelperViewModel: ObservableObject {
    @Published var items: [BookFileItem] = []
    @Published var statusMessage: String?
    @Published var zoteroImportNotice: ZoteroImportNotice?
    @Published var refreshCounter = 0

    private let isbnExtractor = BookISBNExtractor()
    private let epubExtractor = EPUBExtractor()
    private let lookupService: any BookMetadataLookingUp

    private let zoteroClient: ZoteroClient
    private let preferences: UserDefaults
    private let activateZotero: (() -> Void)?

    init(lookupService: any BookMetadataLookingUp = BookMetadataLookupService.shared,
         zoteroClient: ZoteroClient = .shared,
         preferences: UserDefaults = .standard,
         activateZotero: (() -> Void)? = nil) {
        self.lookupService = lookupService
        self.zoteroClient = zoteroClient
        self.preferences = preferences
        self.activateZotero = activateZotero
    }

    var defaultStatusMessage: String {
        if items.isEmpty { return "Add PDFs or DRM-free EPUBs." }
        if items.contains(where: { $0.format == .epub }) {
            return "EPUBs: rename only · \(zoteroReadyCount) PDF\(zoteroReadyCount == 1 ? "" : "s") ready for Zotero"
        }
        return "\(zoteroReadyCount) ready for Zotero"
    }
    private var itemObservers: [UUID: AnyCancellable] = [:]

    var renameReadyCount: Int {
        items.filter { $0.isSelected && $0.status.canRename }.count
    }

    var zoteroReadyCount: Int {
        items.filter { $0.isSelected && $0.canImportToZotero }.count
    }

    var hasItems: Bool {
        !items.isEmpty
    }

    func handleDroppedURLs(_ urls: [URL]) {
        let books = urls.filter { BookFileFormat(url: $0) != nil }
        guard !books.isEmpty else {
            statusMessage = "Add PDF or EPUB files."
            return
        }

        statusMessage = nil
        var existingPaths = Set(items.map { $0.currentURL.standardizedFileURL.path })
        for url in books {
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
        if case .unreadable = item.status { return }
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
        let selected = items.filter { $0.isSelected && $0.canImportToZotero && $0.metadata != nil }
        guard !selected.isEmpty else { return }

        zoteroImportNotice = nil
        statusMessage = "Importing \(selected.count) book\(selected.count == 1 ? "" : "s") to Zotero…"
        selected.forEach { $0.status = .importingToZotero }
        Task {
            var allSucceeded = true
            for item in selected {
                guard items.contains(where: { $0.id == item.id }) else {
                    allSucceeded = false
                    continue
                }
                if !(await importToZotero(item)) { allSucceeded = false }
            }
            if allSucceeded && (preferences.object(forKey: BookHelperPreferenceKey.switchToZotero) as? Bool ?? true) {
                if let activateZotero { activateZotero() }
                else { showLastImportedBookInZotero() }
            }
        }
    }

    func showLastImportedBookInZotero() {
        guard let zoteroURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.zotero.zotero") else {
            zoteroImportNotice = nil
            statusMessage = "Zotero is not installed."
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: zoteroURL, configuration: configuration) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in
                self?.zoteroImportNotice = nil
                self?.statusMessage = "Could not open Zotero: \(error.localizedDescription)"
            }
        }
    }

    func remove(_ item: BookFileItem) {
        item.stopAccessingFile()
        itemObservers.removeValue(forKey: item.id)
        items.removeAll { $0.id == item.id }
    }

    func clearCompleted() {
        let completed = items.filter { $0.isComplete }
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
        zoteroImportNotice = nil
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

        if item.format == .epub {
            await processEPUB(item)
            return
        }

        let filenameISBNs = isbnExtractor.extractISBNs(in: item.currentURL.deletingPathExtension().lastPathComponent)
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

    private func processEPUB(_ item: BookFileItem) async {
        do {
            let extracted = try await epubExtractor.extract(from: item.currentURL)
            if let metadata = extracted.metadata {
                item.metadata = metadata
                item.isbn = metadata.isbn
                item.status = .ready
                return
            }
            let filenameISBNs = isbnExtractor.extractISBNs(in: item.currentURL.deletingPathExtension().lastPathComponent)
            let candidates = Array(orderedUnique(extracted.isbnCandidates + filenameISBNs).prefix(5))
            if await lookupISBNCandidates(candidates, for: item) { return }
            if await lookupLCCNCandidates(Array(extracted.lccnCandidates.prefix(5)), for: item) { return }
            await lookupFromFilename(for: item)
        } catch {
            item.status = .unreadable(error.localizedDescription)
        }
    }

    private func lookupFromFilename(for item: BookFileItem) async {
        item.status = .lookingUp
        let guess = filenameGuess(from: item.currentURL)

        if let metadata = await lookupService.searchBestMatch(title: guess.title, author: guess.author) {
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

        if let metadata = await lookupService.lookupISBN(isbn) {
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
            if let metadata = await lookupService.lookupISBN(isbn) {
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
            if let metadata = await lookupService.lookupLCCN(lccn) {
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
                let newURL = try BookRenamer.rename(fileURL: currentURL, metadata: metadata)
                await viewModel.finishRename(itemID: itemID, newURL: newURL)
            } catch {
                await viewModel.failRename(itemID: itemID, message: error.localizedDescription)
            }
        }
    }

    private func importToZotero(_ item: BookFileItem) async -> Bool {
        zoteroImportNotice = nil

        guard let metadata = item.metadata else {
            item.status = .error("No metadata")
            statusMessage = "No metadata"
            return false
        }

        let currentURL = item.currentURL
        do {
            item.currentURL = try await Task.detached(priority: .userInitiated) {
                try BookRenamer.rename(fileURL: currentURL, metadata: metadata)
            }.value
        } catch {
            item.status = .error(error.localizedDescription)
            statusMessage = error.localizedDescription
            return false
        }

        do {
            try await zoteroClient.importBook(metadata: metadata, pdfURL: item.currentURL)
            item.status = .done
            zoteroImportNotice = ZoteroImportNotice(bookTitle: metadata.fullTitle)
            statusMessage = nil

            if preferences.bool(forKey: BookHelperPreferenceKey.removeImportedBooks) {
                remove(item)
            }
            return true
        } catch {
            item.status = .zoteroError(error.localizedDescription)
            zoteroImportNotice = nil
            statusMessage = error.localizedDescription
            return false
        }
    }

    private func finishRename(itemID: UUID, newURL: URL) {
        guard let item = items.first(where: { $0.id == itemID }) else { return }
        item.currentURL = newURL
        item.status = .renamed
        statusMessage = item.format == .epub
            ? "Renamed \(newURL.lastPathComponent)"
            : "Renamed \(newURL.lastPathComponent); ready to import to Zotero"
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
