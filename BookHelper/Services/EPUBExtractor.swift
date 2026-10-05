import Foundation

enum EPUBError: LocalizedError {
    case invalid, unsupported, protectedBook, tooLarge

    var errorDescription: String? {
        switch self {
        case .invalid: return "This EPUB is damaged or has an invalid book structure."
        case .unsupported: return "This EPUB uses an unsupported archive or document format."
        case .protectedBook: return "Protected EPUBs are not supported. Add a DRM-free copy."
        case .tooLarge: return "This EPUB exceeds the safe archive or metadata size limits."
        }
    }
}

struct EPUBExtraction: Sendable {
    let metadata: BookMetadata?
    let isbnCandidates: [String]
    let lccnCandidates: [String]
}

// A non-suspending actor operation keeps batch archive processing serial and its
// memory budget bounded, even when many files are dropped together.
actor EPUBExtractor {
    private let isbnExtractor = BookISBNExtractor()

    func extract(from url: URL) throws -> EPUBExtraction {
        var archive = try BoundedZIPArchive(url: url)
        guard try archive.read("mimetype", limit: 128) == Data("application/epub+zip".utf8) else { throw EPUBError.invalid }
        let container = try EPUBXML.parse(archive.read("META-INF/container.xml", limit: 256 * 1024))
        guard container.name == "container",
              let rootfile = container.child("rootfiles")?.children.first(where: {
                  $0.name == "rootfile" && $0.attributes["media-type"] == "application/oebps-package+xml"
              }), let packagePath = rootfile.attributes["full-path"] else { throw EPUBError.invalid }
        let packageName = try Self.resolve(packagePath, relativeTo: "")
        let package = try EPUBXML.parse(archive.read(packageName, limit: 1024 * 1024))
        guard package.name == "package", let metadataNode = package.child("metadata"),
              let manifest = package.child("manifest"), let spine = package.child("spine") else { throw EPUBError.invalid }
        let version = package.attributes["version"] ?? ""
        guard version == "2.0" || version.hasPrefix("3.") else { throw EPUBError.unsupported }

        var resources: [String: (path: String, type: String)] = [:]
        for item in manifest.children where item.name == "item" {
            guard let id = item.attributes["id"], let href = item.attributes["href"],
                  let type = item.attributes["media-type"], resources[id] == nil else { throw EPUBError.invalid }
            // Remote resources are never fetched. They cannot supply fallback text.
            if URLComponents(string: href)?.scheme != nil || href.hasPrefix("//") { continue }
            resources[id] = (try Self.resolve(href, relativeTo: packageName), type)
        }
        try Self.checkEncryption(in: &archive, resources: Array(resources.values))
        // Adobe rights metadata is a reliable protected-book marker even when no readable encryption descriptor is present.
        if archive.contains("META-INF/rights.xml") { throw EPUBError.protectedBook }

        let dc = metadataNode.children.filter { $0.namespace == "http://purl.org/dc/elements/1.1/" }
        let refinements = metadataNode.children.filter { $0.name == "meta" }
        let titles = dc.filter { $0.name == "title" && !$0.value.isEmpty }
        let title = titles.first(where: { node in
            refinements.contains { $0.attributes["refines"] == "#\(node.attributes["id"] ?? "")" &&
                $0.attributes["property"] == "title-type" && $0.value == "main" }
        })?.value ?? titles.first?.value
        let authors = dc.filter { node in
            guard node.name == "creator", !node.value.isEmpty else { return false }
            let role = node.attributes["opf:role"] ?? refinements.first(where: {
                $0.attributes["refines"] == "#\(node.attributes["id"] ?? "")" && $0.attributes["property"] == "role"
            })?.value
            return role == nil || role == "aut"
        }.map(\.value)
        var isbns: [String] = []
        for identifier in dc where identifier.name == "identifier" {
            let value = identifier.value.replacingOccurrences(of: "urn:isbn:", with: "", options: .caseInsensitive)
            Self.appendUnique(isbnExtractor.extractISBNs(in: "ISBN: " + value), to: &isbns)
        }
        var lccns: [String] = []
        // Only scan text if the package lacks a usable title or ISBN. Covers, scripts,
        // stylesheets and remote resources are never rendered or executed.
        if title == nil || isbns.isEmpty {
            let readingOrder = spine.children.filter { $0.name == "itemref" }.compactMap { $0.attributes["idref"] }
            var seen = Set<String>()
            var textBytes = 0
            for id in Array(readingOrder.prefix(10)) + Array(readingOrder.suffix(3)) {
                guard let resource = resources[id], resource.type == "application/xhtml+xml",
                      seen.insert(resource.path).inserted else { continue }
                guard let size = archive.size(of: resource.path) else { throw EPUBError.invalid }
                // Large chapters are skipped; local metadata and filename fallback remain usable.
                guard size <= 2 * 1024 * 1024, textBytes + size <= 8 * 1024 * 1024 else { continue }
                textBytes += size
                let chapter = try EPUBXML.parse(archive.read(resource.path, limit: 2 * 1024 * 1024))
                let text = chapter.readableText
                Self.appendUnique(isbnExtractor.extractISBNs(in: text), to: &isbns)
                Self.appendUnique(isbnExtractor.extractLCCNs(in: text), to: &lccns)
            }
        }
        let date = dc.first(where: { $0.name == "date" })?.value ?? ""
        let year = date.range(of: #"\b\d{4}\b"#, options: .regularExpression).map { String(date[$0]) }
        let metadata = title.map { BookMetadata(title: $0, authors: authors,
            year: year, publisher: dc.first(where: { $0.name == "publisher" })?.value,
            isbn: isbns.first, source: "EPUB metadata") }
        return EPUBExtraction(metadata: metadata, isbnCandidates: isbns, lccnCandidates: lccns)
    }

    private static func checkEncryption(in archive: inout BoundedZIPArchive, resources: [(path: String, type: String)]) throws {
        guard archive.contains("META-INF/encryption.xml") else { return }
        let encryption = try EPUBXML.parse(archive.read("META-INF/encryption.xml", limit: 256 * 1024))
        guard encryption.name == "encryption" else { throw EPUBError.invalid }
        let fontAlgorithms = ["http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC"]
        for entry in encryption.children where entry.name == "EncryptedData" {
            guard let algorithm = entry.child("EncryptionMethod")?.attributes["Algorithm"],
                  fontAlgorithms.contains(algorithm),
                  let uri = entry.child("CipherData")?.child("CipherReference")?.attributes["URI"] else {
                throw EPUBError.protectedBook
            }
            let path = try resolve(uri, relativeTo: "")
            guard resources.contains(where: { $0.path == path &&
                ($0.type.hasPrefix("font/") || ["application/vnd.ms-opentype", "application/font-sfnt", "application/font-woff"].contains($0.type))
            }) else { throw EPUBError.protectedBook }
        }
    }

    /// Resolve EPUB URI references without permitting escape from the archive root.
    private static func resolve(_ reference: String, relativeTo base: String) throws -> String {
        guard let decoded = reference.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.flatMap({ String($0).removingPercentEncoding }),
              !decoded.isEmpty, !decoded.hasPrefix("/"), !decoded.contains("\\"), !decoded.contains(":"), !decoded.contains("?"),
              !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw EPUBError.invalid }
        var components = base.split(separator: "/").dropLast().map(String.init)
        for part in decoded.split(separator: "/", omittingEmptySubsequences: false) {
            if part == ".." {
                guard !components.isEmpty else { throw EPUBError.invalid }
                components.removeLast()
            } else if part != "." {
                guard !part.isEmpty else { throw EPUBError.invalid }
                components.append(String(part))
            }
        }
        guard !components.isEmpty else { throw EPUBError.invalid }
        return components.joined(separator: "/")
    }

    private static func appendUnique(_ values: [String], to output: inout [String]) {
        for value in values where !output.contains(value) { output.append(value) }
    }
}

/// Small bounded XML tree used only for package metadata and selected XHTML.
/// Custom entities are rejected before parsing; external entities are never resolved.
private final class EPUBXML: NSObject, XMLParserDelegate {
    final class Node {
        let name: String
        let namespace: String?
        let attributes: [String: String]
        enum Content { case text(String), child(Node) }
        var content: [Content] = []
        var children: [Node] = []
        init(_ name: String, _ namespace: String?, _ attributes: [String: String]) {
            self.name = name; self.namespace = namespace; self.attributes = attributes
        }
        func append(_ text: String) {
            if case .text(let previous) = content.last {
                content[content.count - 1] = .text(previous + text)
            } else { content.append(.text(text)) }
        }
        var value: String { readableText.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
        func child(_ name: String) -> Node? { children.first { $0.name == name } }
        var readableText: String {
            guard !["head", "script", "style"].contains(name) else { return "" }
            let text = content.map { part -> String in
                switch part {
                case .text(let value): return value
                case .child(let node): return node.readableText
                }
            }.joined()
            return ["p", "div", "br", "section", "li", "h1", "h2"].contains(name) ? " " + text + " " : text
        }
    }
    private var stack: [Node] = []
    private var root: Node?
    private var nodeCount = 0
    private var exceededLimits = false

    static func parse(_ data: Data) throws -> Node {
        let decoded: String?
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) {
            decoded = String(data: data, encoding: .utf16)
        } else {
            decoded = String(data: data, encoding: .utf8)
        }
        guard let decoded, !decoded.contains("\0"), decoded.range(of: "<!ENTITY", options: .caseInsensitive) == nil else {
            throw EPUBError.unsupported
        }
        let delegate = EPUBXML()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root else {
            throw delegate.exceededLimits ? EPUBError.tooLarge : EPUBError.invalid
        }
        return root
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        nodeCount += 1
        guard stack.count < 64, nodeCount <= 50_000 else {
            exceededLimits = true; parser.abortParsing(); return
        }
        let node = Node(elementName, namespaceURI, attributes)
        if let parent = stack.last {
            parent.children.append(node)
            parent.content.append(.child(node))
        } else { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.append(string) }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.append(String(decoding: CDATABlock, as: UTF8.self))
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) { _ = stack.popLast() }
}
