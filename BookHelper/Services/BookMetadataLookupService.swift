import Foundation

protocol BookMetadataLookingUp {
    func lookupISBN(_ isbn: String) async -> BookMetadata?
    func lookupLCCN(_ lccn: String) async -> BookMetadata?
    func searchBestMatch(title: String, author: String?) async -> BookMetadata?
}

actor BookMetadataLookupService: BookMetadataLookingUp {
    static let shared = BookMetadataLookupService()

    private init() {}

    func lookupISBN(_ isbn: String) async -> BookMetadata? {
        let normalized = normalizeISBN(isbn)
        guard !normalized.isEmpty else { return nil }

        if let metadata = await lookupOpenLibrary(isbn: normalized) {
            return metadata
        }

        return await lookupGoogleBooks(isbn: normalized)
    }

    func lookupLCCN(_ lccn: String) async -> BookMetadata? {
        let normalized = normalizeLCCN(lccn)
        guard !normalized.isEmpty else { return nil }

        return await optionalRequest {
            try await fetchLibraryOfCongress(lccn: normalized)
        }
    }

    func searchBestMatch(title: String, author: String?) async -> BookMetadata? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }

        for candidateTitle in titleCandidates(from: trimmedTitle) {
            guard let first = await searchOpenLibrary(title: candidateTitle, author: author) else { continue }
            let isbn = first.isbn?.first(where: { $0.count == 13 }) ?? first.isbn?.first
            if let isbn, let metadata = await lookupISBN(isbn) {
                return metadata
            }

            return BookMetadata(
                title: first.title,
                authors: first.authorName ?? [],
                year: first.firstPublishYear.map(String.init),
                publisher: first.publisher?.first,
                isbn: isbn,
                source: "Open Library"
            )
        }

        return nil
    }

    private func searchOpenLibrary(title: String, author: String?) async -> OpenLibrarySearchDoc? {
        var components = URLComponents(string: "https://openlibrary.org/search.json")
        var items = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "fields", value: "title,author_name,first_publish_year,publisher,isbn,edition_key"),
            URLQueryItem(name: "limit", value: "5")
        ]

        if let author = author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
            items.append(URLQueryItem(name: "author", value: author))
        }

        components?.queryItems = items
        guard let url = components?.url else { return nil }

        guard let (data, response) = await optionalRequest({
            try await fetchData(from: url, timeoutSeconds: 10)
        }) else {
            return nil
        }

        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            return nil
        }

        guard let search = try? JSONDecoder().decode(OpenLibrarySearchResponse.self, from: data),
              let first = search.docs.first else {
            return nil
        }

        return first
    }

    private func lookupOpenLibrary(isbn: String) async -> BookMetadata? {
        await optionalRequest {
            try await fetchOpenLibrary(isbn: isbn)
        }
    }

    private func lookupGoogleBooks(isbn: String) async -> BookMetadata? {
        await optionalRequest {
            try await fetchGoogleBooks(isbn: isbn)
        }
    }

    private func fetchOpenLibrary(isbn: String) async throws -> BookMetadata? {
        guard let url = URL(string: "https://openlibrary.org/api/books?bibkeys=ISBN:\(isbn)&format=json&jscmd=data") else {
            return nil
        }

        let (data, response) = try await fetchData(from: url, timeoutSeconds: 10)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            return nil
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bookData = json["ISBN:\(isbn)"] as? [String: Any] else {
            return nil
        }

        let title = (bookData["title"] as? String) ?? ""
        guard !title.isEmpty else { return nil }

        let subtitle = bookData["subtitle"] as? String
        let authors = (bookData["authors"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        let year = (bookData["publish_date"] as? String).map { String($0.prefix(4)) }
        let publisher = (bookData["publishers"] as? [[String: Any]])?.first?["name"] as? String

        return BookMetadata(
            title: title,
            subtitle: subtitle,
            authors: authors,
            year: year,
            publisher: publisher,
            isbn: isbn,
            source: "Open Library"
        )
    }

    private func fetchGoogleBooks(isbn: String) async throws -> BookMetadata? {
        guard let url = URL(string: "https://www.googleapis.com/books/v1/volumes?q=isbn:\(isbn)") else {
            return nil
        }

        let (data, response) = try await fetchData(from: url, timeoutSeconds: 4)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            return nil
        }

        guard let response = try? JSONDecoder().decode(GoogleBooksResponse.self, from: data),
              let first = response.items?.first else {
            return nil
        }

        var metadata = first.volumeInfo.toBookMetadata()
        metadata.isbn = isbn
        metadata.source = "Google Books"
        return metadata.title.isEmpty ? nil : metadata
    }

    private func fetchLibraryOfCongress(lccn: String) async throws -> BookMetadata? {
        guard let url = URL(string: "https://lccn.loc.gov/\(lccn)/marcxml") else {
            return nil
        }

        let (data, response) = try await fetchData(from: url, timeoutSeconds: 10)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            return nil
        }

        return LibraryOfCongressMARCParser.parse(data: data, lccn: lccn)
    }

    private func normalizeISBN(_ isbn: String) -> String {
        let cleaned = isbn
            .replacingOccurrences(of: #"ISBN[-\s]?1[03][:\s]*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"ISBN[:\s]*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[Oo]"#, with: "0", options: .regularExpression)
            .replacingOccurrences(of: #"[\s\-\x{2010}\x{2011}\x{2012}\x{2013}\x{2014}\x{2015}\x{2212}]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard cleaned.count == 10 || cleaned.count == 13 else {
            return ""
        }

        return cleaned
    }

    private func normalizeLCCN(_ lccn: String) -> String {
        let cleaned = lccn
            .replacingOccurrences(of: #"[^0-9]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard (8...12).contains(cleaned.count) else {
            return ""
        }

        return cleaned
    }

    private func optionalRequest<T>(_ operation: () async throws -> T?) async -> T? {
        try? await operation()
    }

    private func fetchData(from url: URL, timeoutSeconds: UInt64) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = TimeInterval(timeoutSeconds)

        return try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask {
                try await URLSession.shared.data(for: request)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                throw URLError(.timedOut)
            }

            guard let result = try await group.next() else {
                throw URLError(.unknown)
            }

            group.cancelAll()
            return result
        }
    }

    private func titleCandidates(from title: String) -> [String] {
        let cleaned = title
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var candidates: [String] = []
        appendUnique(cleaned, to: &candidates)

        for marker in [":", " - ", " -- "] {
            if let range = cleaned.range(of: marker) {
                appendUnique(String(cleaned[..<range.lowerBound]), to: &candidates)
            }
        }

        let words = cleaned.split(separator: " ")
        for count in [6, 5] where words.count > count {
            appendUnique(words.prefix(count).joined(separator: " "), to: &candidates)
        }

        return candidates.filter { $0.count >= 8 }
    }

    private func appendUnique(_ value: String, to values: inout [String]) {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !values.contains(cleaned) else { return }
        values.append(cleaned)
    }
}

private final class LibraryOfCongressMARCParser: NSObject, XMLParserDelegate {
    private var currentTag: String?
    private var currentCode: String?
    private var currentText = ""
    private var fields: [String: [String: [String]]] = [:]

    static func parse(data: Data, lccn: String) -> BookMetadata? {
        let parserDelegate = LibraryOfCongressMARCParser()
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate
        guard parser.parse() else { return nil }

        return parserDelegate.metadata(lccn: lccn)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "datafield":
            currentTag = attributeDict["tag"]
        case "subfield":
            currentCode = attributeDict["code"]
            currentText = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard currentTag != nil, currentCode != nil else { return }
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "subfield":
            if let currentTag, let currentCode {
                let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    fields[currentTag, default: [:]][currentCode, default: []].append(value)
                }
            }
            currentCode = nil
            currentText = ""
        case "datafield":
            currentTag = nil
        default:
            break
        }
    }

    private func metadata(lccn: String) -> BookMetadata? {
        guard let title = cleanTitle(field("245", "a")) else {
            return nil
        }

        let subtitle = cleanSubtitle(field("245", "b"))
        let authors = authorCandidates().compactMap(cleanAuthor)
        let isbn = isbnCandidates().first
        let year = cleanYear(field("264", "c") ?? field("260", "c"))
        let publisher = cleanPublisher(field("264", "b") ?? field("260", "b"))

        return BookMetadata(
            title: title,
            subtitle: subtitle,
            authors: authors,
            year: year,
            publisher: publisher,
            isbn: isbn,
            source: "Library of Congress"
        )
    }

    private func field(_ tag: String, _ code: String) -> String? {
        fields[tag]?[code]?.first
    }

    private func authorCandidates() -> [String] {
        var authors: [String] = []
        for tag in ["100", "110", "111", "700"] {
            if let values = fields[tag]?["a"] {
                authors.append(contentsOf: values)
            }
        }

        return authors
    }

    private func isbnCandidates() -> [String] {
        guard let values = fields["020"]?["a"] else { return [] }
        return values.compactMap { value in
            let cleaned = value.replacingOccurrences(of: #"[^0-9Xx]"#, with: "", options: .regularExpression)
            return (cleaned.count == 10 || cleaned.count == 13) ? cleaned : nil
        }
    }

    private func cleanTitle(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = trimTrailingPunctuation(value)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func cleanSubtitle(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = trimTrailingPunctuation(value)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func cleanAuthor(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = trimTrailingPunctuation(value)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func cleanPublisher(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = trimTrailingPunctuation(value)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func cleanYear(_ value: String?) -> String? {
        guard let value else { return nil }
        let match = value.range(of: #"[0-9]{4}"#, options: .regularExpression)
        guard let match else { return nil }
        return String(value[match])
    }

    private func trimTrailingPunctuation(_ value: String) -> String {
        var cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = cleaned.last, ["/", ":", ",", ".", ";"].contains(String(last)) {
            cleaned.removeLast()
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }
}

private struct GoogleBooksResponse: Codable {
    let items: [GoogleBookItem]?
}

private struct OpenLibrarySearchResponse: Codable {
    let docs: [OpenLibrarySearchDoc]
}

private struct OpenLibrarySearchDoc: Codable {
    let title: String
    let authorName: [String]?
    let firstPublishYear: Int?
    let publisher: [String]?
    let isbn: [String]?

    enum CodingKeys: String, CodingKey {
        case title
        case authorName = "author_name"
        case firstPublishYear = "first_publish_year"
        case publisher
        case isbn
    }
}

private struct GoogleBookItem: Codable {
    let volumeInfo: GoogleVolumeInfo
}

private struct GoogleVolumeInfo: Codable {
    let title: String?
    let subtitle: String?
    let authors: [String]?
    let publisher: String?
    let publishedDate: String?
    let industryIdentifiers: [IndustryIdentifier]?

    struct IndustryIdentifier: Codable {
        let type: String
        let identifier: String
    }

    func toBookMetadata() -> BookMetadata {
        let isbn = industryIdentifiers?.first(where: {
            $0.type == "ISBN_13" || $0.type == "ISBN_10"
        })?.identifier

        return BookMetadata(
            title: title ?? "",
            subtitle: subtitle,
            authors: authors ?? [],
            year: publishedDate.map { String($0.prefix(4)) },
            publisher: publisher,
            isbn: isbn,
            source: "Google Books"
        )
    }
}
