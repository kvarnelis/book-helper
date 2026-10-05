import Foundation
import PDFKit

actor ZoteroClient {
    static let shared = ZoteroClient()

    private let baseURL = URL(string: "http://127.0.0.1:23119")!
    private let connectorAPIVersion = "3"
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func importBook(metadata: BookMetadata, pdfURL: URL) async throws {
        guard BookFileFormat(url: pdfURL) == .pdf else {
            throw ZoteroError.unsupportedFileType
        }
        try await ping()

        let sessionID = UUID().uuidString.lowercased()
        let itemID = UUID().uuidString.lowercased()

        var item: [String: Any] = [
            "id": itemID,
            "itemType": "book",
            "title": metadata.fullTitle
        ]
        add(metadata.year, to: &item, as: "date")
        add(metadata.publisher, to: &item, as: "publisher")
        add(metadata.isbn, to: &item, as: "ISBN")
        if let pageCount = PDFDocument(url: pdfURL)?.pageCount, pageCount > 0 {
            item["numPages"] = String(pageCount)
        }

        let creators = metadata.authors.compactMap(Self.creator(from:))
        if !creators.isEmpty {
            item["creators"] = creators
        }

        let itemPayload: [String: Any] = [
            "sessionID": sessionID,
            "uri": "http://localhost/book-helper",
            "items": [item]
        ]
        let itemBody = try JSONSerialization.data(withJSONObject: itemPayload)
        try await post(
            path: "/connector/saveItems",
            contentType: "application/json",
            body: itemBody,
            timeout: 15
        )

        let attachmentMetadata: [String: Any] = [
            "sessionID": sessionID,
            "parentItemID": itemID,
            "url": pdfURL.absoluteString,
            "title": pdfURL.lastPathComponent
        ]
        let attachmentHeader = try JSONSerialization.data(withJSONObject: attachmentMetadata)
        guard let attachmentHeaderValue = String(data: attachmentHeader, encoding: .utf8) else {
            throw ZoteroError.invalidAttachmentMetadata
        }

        do {
            try await uploadPDF(
                at: pdfURL,
                metadataHeader: attachmentHeaderValue,
                timeout: 120
            )
        } catch {
            throw ZoteroError.attachmentFailed(error.localizedDescription)
        }
    }

    private func ping() async throws {
        do {
            try await post(
                path: "/connector/ping",
                contentType: "application/json",
                body: Data("{}".utf8),
                timeout: 3
            )
        } catch {
            throw ZoteroError.notRunning
        }
    }

    private func post(
        path: String,
        contentType: String,
        body: Data,
        timeout: TimeInterval
    ) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(connectorAPIVersion, forHTTPHeaderField: "X-Zotero-Connector-API-Version")

        let (_, response) = try await session.upload(for: request, from: body)
        try Self.validate(response)
    }

    private func uploadPDF(
        at pdfURL: URL,
        metadataHeader: String,
        timeout: TimeInterval
    ) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("/connector/saveAttachment"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/pdf", forHTTPHeaderField: "Content-Type")
        request.setValue(connectorAPIVersion, forHTTPHeaderField: "X-Zotero-Connector-API-Version")
        request.setValue(Self.escapeNonASCII(metadataHeader), forHTTPHeaderField: "X-Metadata")

        let (_, response) = try await session.upload(for: request, fromFile: pdfURL)
        try Self.validate(response)
    }

    private func add(_ value: String?, to item: inout [String: Any], as key: String) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return
        }
        item[key] = value
    }

    private static func validate(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ZoteroError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ZoteroError.httpError(httpResponse.statusCode)
        }
    }

    private static func creator(from name: String) -> [String: String]? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let comma = trimmed.firstIndex(of: ",") {
            let lastName = String(trimmed[..<comma]).trimmingCharacters(in: .whitespaces)
            let firstName = String(trimmed[trimmed.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
            return [
                "creatorType": "author",
                "firstName": firstName,
                "lastName": lastName
            ]
        }

        let parts = trimmed.split(whereSeparator: \Character.isWhitespace).map(String.init)
        guard parts.count > 1 else {
            return ["creatorType": "author", "name": trimmed]
        }

        return [
            "creatorType": "author",
            "firstName": parts.dropLast().joined(separator: " "),
            "lastName": parts.last ?? ""
        ]
    }
    /// Escapes all non-ASCII characters in a string as \uXXXX escape sequences.
    /// This ensures the string can be safely transmitted in HTTP headers, which require ASCII-only values.
    /// For characters above U+FFFF, uses UTF-16 surrogate pairs as per JSON spec.
    private static func escapeNonASCII(_ str: String) -> String {
        var result = ""
        for scalar in str.unicodeScalars {
            if scalar.value < 128 {
                // ASCII character: pass through
                result.append(Character(scalar))
            } else if scalar.value <= 0xFFFF {
                // BMP character: single \uXXXX escape
                result.append(String(format: "\\u%04x", scalar.value))
            } else {
                // Non-BMP character: convert to UTF-16 surrogate pair
                let codePoint = scalar.value
                let adjusted = codePoint - 0x10000
                let high = 0xD800 + (adjusted >> 10)
                let low = 0xDC00 + (adjusted & 0x3FF)
                result.append(String(format: "\\u%04x\\u%04x", high, low))
            }
        }
        return result
    }
}

enum ZoteroError: LocalizedError {
    case unsupportedFileType
    case notRunning
    case invalidResponse
    case invalidAttachmentMetadata
    case httpError(Int)
    case attachmentFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType:
            return "Zotero import currently supports PDF files only. EPUBs can be renamed."
        case .notRunning:
            return "Zotero is not running or its local connector is unavailable. Open Zotero and try again."
        case .invalidResponse:
            return "Zotero returned an invalid response."
        case .invalidAttachmentMetadata:
            return "Could not prepare the PDF attachment metadata."
        case .httpError(let statusCode):
            return "Zotero rejected the import (HTTP \(statusCode))."
        case .attachmentFailed(let message):
            return "The book was created in Zotero, but the PDF could not be attached: \(message)"
        }
    }
}
