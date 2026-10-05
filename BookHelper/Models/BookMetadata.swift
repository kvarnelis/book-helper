import Foundation
import UniformTypeIdentifiers

enum BookFileFormat: String {
    case pdf, epub

    init?(url: URL) { self.init(rawValue: url.pathExtension.lowercased()) }
    static let contentTypes: [UTType] = [.pdf, .epub]
}

struct BookMetadata: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var subtitle: String?
    var authors: [String]
    var year: String?
    var publisher: String?
    var isbn: String?
    var source: String?

    var fullTitle: String {
        if let subtitle, !subtitle.isEmpty {
            return "\(title): \(subtitle)"
        }
        return title
    }

    init(
        id: UUID = UUID(),
        title: String,
        subtitle: String? = nil,
        authors: [String] = [],
        year: String? = nil,
        publisher: String? = nil,
        isbn: String? = nil,
        source: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.authors = authors
        self.year = year
        self.publisher = publisher
        self.isbn = isbn
        self.source = source
    }
}

enum BookFileStatus: Equatable, Sendable {
    case scanning
    case noISBNFound
    case lookingUp
    case ready
    case updating
    case renamed
    case importingToZotero
    case done
    case zoteroError(String)
    case error(String)
    case unreadable(String)

    var label: String {
        switch self {
        case .scanning: return "Scanning"
        case .noISBNFound: return "No ISBN"
        case .lookingUp: return "Looking up"
        case .ready: return "Ready"
        case .updating: return "Updating"
        case .renamed: return "Renamed"
        case .importingToZotero: return "Importing to Zotero"
        case .done: return "Done"
        case .zoteroError(let message): return "Zotero: \(message)"
        case .error(let message), .unreadable(let message): return "Error: \(message)"
        }
    }

    var systemImage: String {
        switch self {
        case .scanning: return "doc.text.magnifyingglass"
        case .noISBNFound: return "questionmark.circle"
        case .lookingUp: return "magnifyingglass"
        case .ready: return "checkmark.circle"
        case .updating: return "square.and.arrow.down"
        case .renamed: return "pencil.circle.fill"
        case .importingToZotero: return "books.vertical.fill"
        case .done: return "checkmark.circle.fill"
        case .zoteroError: return "exclamationmark.triangle"
        case .error, .unreadable: return "exclamationmark.triangle"
        }
    }

    var isBusy: Bool {
        switch self {
        case .scanning, .lookingUp, .updating, .importingToZotero: return true
        default: return false
        }
    }

    var canRename: Bool {
        switch self {
        case .ready, .renamed, .zoteroError: return true
        default: return false
        }
    }

    var canImportToZotero: Bool {
        switch self {
        case .ready, .renamed, .zoteroError: return true
        default: return false
        }
    }
}

@MainActor
final class BookFileItem: ObservableObject, Identifiable {
    let id = UUID()
    let originalURL: URL

    @Published var currentURL: URL
    @Published var status: BookFileStatus = .scanning
    @Published var isbn: String?
    @Published var manualISBN = ""
    @Published var metadata: BookMetadata?
    @Published var isSelected = true
    private var hasSecurityScopedAccess = false

    init(url: URL) {
        originalURL = url
        currentURL = url
        hasSecurityScopedAccess = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if hasSecurityScopedAccess {
            originalURL.stopAccessingSecurityScopedResource()
        }
    }

    var format: BookFileFormat? { BookFileFormat(url: currentURL) }
    var canImportToZotero: Bool { format == .pdf && status.canImportToZotero }
    var isComplete: Bool { status == .done || (format == .epub && status == .renamed) }

    var filename: String {
        currentURL.lastPathComponent
    }

    var titleForEditing: String {
        metadata?.fullTitle ?? ""
    }

    func stopAccessingFile() {
        if hasSecurityScopedAccess {
            originalURL.stopAccessingSecurityScopedResource()
            hasSecurityScopedAccess = false
        }
    }
}
