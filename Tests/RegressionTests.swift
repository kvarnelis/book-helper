import AppKit
import CoreText
import PDFKit
import SwiftUI

private struct Failure: Error, CustomStringConvertible { let description: String }

private actor StubLookups: BookMetadataLookingUp {
    private(set) var calls: [String] = []
    func lookupISBN(_ isbn: String) async -> BookMetadata? {
        calls.append("isbn:" + isbn)
        return isbn == "9780306406157" ? BookMetadata(title: "Looked-up Book", authors: ["Test Author"], isbn: isbn) : nil
    }
    func lookupLCCN(_ lccn: String) async -> BookMetadata? { calls.append("lccn:" + lccn); return nil }
    func searchBestMatch(title: String, author: String?) async -> BookMetadata? {
        calls.append("title:" + title)
        return title == "A Filename Book" ? BookMetadata(title: title, authors: [author ?? ""]) : nil
    }
}

/// Captures every request locally; no sockets and no live Zotero instance are used.
private final class CaptureProtocol: URLProtocol {
    struct Captured { let request: URLRequest; let body: Data }
    private static let lock = NSLock()
    private static var storage: [Captured] = []
    static var failAttachment = false
    static func reset() { lock.lock(); defer { lock.unlock() }; storage = [] }
    static var requests: [Captured] { lock.lock(); defer { lock.unlock() }; return storage }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        Self.lock.lock(); Self.storage.append(Captured(request: request, body: body)); Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.failAttachment && request.url?.path == "/connector/saveAttachment" ? 500 : 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
@MainActor
struct RegressionTests {
    static var checks = 0
    static func expect(_ condition: Bool, _ name: String) throws {
        guard condition else { throw Failure(description: name) }
        checks += 1
        print("PASS \(name)")
    }
    static func waitUntilIdle(_ model: BookHelperViewModel) async throws {
        for _ in 0..<1000 {
            if model.items.allSatisfy({ !$0.status.isBusy }) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw Failure(description: "Processing timed out")
    }
    static func makePDF(_ url: URL) throws {
        var rect = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: url as CFURL), let context = CGContext(consumer: consumer, mediaBox: &rect, nil) else {
            throw Failure(description: "Could not create synthetic PDF")
        }
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 40, y: 740)
        let text = NSAttributedString(string: "ISBN: 9780306406157  LCCN: 2024123456", attributes: [.font: NSFont.systemFont(ofSize: 15)])
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        context.endPDFPage(); context.closePDF()
    }

    static func main() async {
        do { try await run(); print("SUCCESS: \(checks) checks passed; no live network or Zotero writes.") }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }

    static func run() async throws {
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        func fixture(_ name: String) -> URL { fixtures.appendingPathComponent(name) }
        let reader = EPUBExtractor()
        let normal = try await reader.extract(from: fixture("metadata.epub"))
        try expect(normal.metadata?.title == "A Test Book" && normal.metadata?.authors == ["Ada Author"], "Embedded title and author")
        try expect(normal.metadata?.isbn == "9780306406157" && normal.metadata?.year == "2024" && normal.metadata?.publisher == "Test Press", "Embedded ISBN, publisher and year")
        for name in ["stored.EPUB", "descriptor.epub", "font-obfuscated.epub"] {
            let result = try await reader.extract(from: fixture(name))
            try expect(result.metadata?.title == "A Test Book", "Readable \(name)")
        }
        let v2 = try await reader.extract(from: fixture("epub2.epub"))
        try expect(v2.metadata?.title == "Élan & Space" && v2.metadata?.authors == ["Zoë Author"] && v2.metadata?.isbn == "0306406152", "EPUB 2, Unicode, entities, author role and ISBN-10")
        let refined = try await reader.extract(from: fixture("refined.epub"))
        try expect(refined.metadata?.title == "Main Title" && refined.metadata?.authors == ["Ada Author"], "EPUB 3 title and creator refinements")
        let utf16 = try await reader.extract(from: fixture("utf16.epub"))
        try expect(utf16.metadata?.title == "UTF16 Title", "UTF-16 package")
        let titleOnly = try await reader.extract(from: fixture("title-only.epub"))
        try expect(titleOnly.metadata?.title == "A Test Book" && titleOnly.isbnCandidates.isEmpty, "Title-only metadata without fabricated ISBN")
        let body = try await reader.extract(from: fixture("body-isbn.epub"))
        try expect(body.metadata == nil && body.isbnCandidates == ["9780306406157"] && body.lccnCandidates == ["2024123456"], "Bounded XHTML ISBN/LCCN scan preserves inline text order")
        for name in ["encoded-path.epub", "parent-path.epub", "external-dtd.epub"] {
            let result = try await reader.extract(from: fixture(name))
            try expect(result.isbnCandidates == ["9780306406157"], "Text resolution: \(name)")
        }
        for name in ["ignore-scripts.epub", "large-chapter.epub", "remote-resource.epub"] {
            let result = try await reader.extract(from: fixture(name))
            try expect(result.metadata?.title == "A Test Book" && result.isbnCandidates.isEmpty, "Skipped unsafe/unneeded text: \(name)")
        }
        let invalidFiles = ["drm.epub", "fake-font.epub", "rights.epub", "traversal.epub", "absolute.epub", "href-escape.epub", "encoded-escape.epub", "duplicate.epub", "symlink.epub", "entities.epub", "entities-utf16.epub", "deep-xml.epub", "many-nodes.epub", "malformed-xml.epub", "oversize-metadata.epub", "unsupported-zip.epub", "missing-package.epub", "wrong-mimetype.epub", "not-zip.epub", "encrypted-zip.epub", "bad-crc.epub", "lying-size.epub", "declared-bomb.epub", "bad-offset.epub", "local-mismatch.epub", "zip64.epub", "truncated.epub", "oversize-archive.epub"]
        for name in invalidFiles {
            do { _ = try await reader.extract(from: fixture(name)); throw Failure(description: "Accepted \(name)") }
            catch is EPUBError { try expect(true, "Rejected \(name)") }
        }
        let source = try Data(contentsOf: fixture("metadata.epub"))
        let fuzzURL = fixture("fuzz.epub")
        for length in stride(from: 0, to: source.count, by: max(1, source.count / 80)) {
            try source.prefix(length).write(to: fuzzURL)
            do { _ = try await reader.extract(from: fuzzURL); throw Failure(description: "Accepted truncated archive at \(length)") }
            catch is EPUBError { }
        }
        try expect(true, "Truncation sweep does not crash or accept partial ZIPs")
        try FileManager.default.removeItem(at: fuzzURL)

        let pdf = fixture("synthetic.pdf")
        try makePDF(pdf)
        let isbnReader = BookISBNExtractor()
        let pdfISBNs = await isbnReader.extractISBNs(from: pdf)
        let pdfLCCNs = await isbnReader.extractLCCNs(from: pdf)
        let noisyLCCNs = isbnReader.extractLCCNs(in: (0..<10_000).map { "LCCN: \(2024000000 + $0)" }.joined(separator: " "))
        try expect(noisyLCCNs.count == 64, "Identifier candidate count is bounded on repetitive text")
        try expect(pdfISBNs == ["9780306406157"] && pdfLCCNs == ["2024123456"], "PDF text extraction regression")
        try expect(BookFileFormat(url: fixture("stored.EPUB")) == .epub && BookFileFormat(url: pdf) == .pdf && BookFileFormat(url: fixture("other.txt")) == nil, "File-type acceptance")
        try expect(BookFileFormat.contentTypes.contains(.epub) && BookFileFormat.contentTypes.contains(.pdf), "Picker exposes PDF and EPUB types")

        let lookups = StubLookups()
        let vm = BookHelperViewModel(lookupService: lookups)
        vm.handleDroppedURLs([fixture("metadata.epub"), fixture("title-only.epub"), fixture("metadata.epub"), fixture("other.txt")])
        try await waitUntilIdle(vm)
        let calls = await lookups.calls
        try expect(vm.items.count == 2 && vm.renameReadyCount == 2 && calls.isEmpty, "Embedded EPUB metadata is ready offline; duplicate and unsupported drops ignored")
        try expect(vm.zoteroReadyCount == 0 && vm.defaultStatusMessage.contains("rename only"), "EPUB-only selection disables Zotero with explanation")
        vm.importSelectedToZotero()
        try expect(vm.items.allSatisfy { $0.status == .ready }, "EPUB import action has no effect")
        vm.handleDroppedURLs([fixture("body-isbn.epub"), fixture("Writer - A Filename Book.epub"), fixture("9780306406157.epub"), pdf, fixture("drm.epub")])
        try await waitUntilIdle(vm)
        try expect(vm.items.first { $0.filename == "body-isbn.epub" }?.metadata?.title == "Looked-up Book", "EPUB text ISBN feeds existing lookup flow")
        try expect(vm.items.first { $0.filename == "Writer - A Filename Book.epub" }?.metadata?.title == "A Filename Book", "EPUB filename title/author fallback")
        try expect(vm.items.first { $0.filename == "9780306406157.epub" }?.metadata?.title == "Looked-up Book", "EPUB filename ISBN fallback")
        try expect(vm.zoteroReadyCount == 1 && vm.items.first { $0.currentURL == pdf }?.status == .ready, "Mixed batch counts only PDF for Zotero and preserves PDF identification")
        let protected = vm.items.first { $0.filename == "drm.epub" }!
        if case .unreadable = protected.status {} else { throw Failure(description: "DRM did not show unreadable state") }
        protected.manualISBN = "9780306406157"
        vm.lookupManualISBN(for: protected)
        try expect(!protected.status.canRename && !protected.canImportToZotero, "Protected EPUB cannot bypass validation through manual ISBN")

        let renamedDir = output.appendingPathComponent("RenameFixtures-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: renamedDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: renamedDir) }
        for (index, ext) in ["epub", "EPUB", "pdf"].enumerated() {
            let original = ext == "pdf" ? pdf : fixture("metadata.epub")
            let bytes = try Data(contentsOf: original)
            let disposable = renamedDir.appendingPathComponent("original." + ext)
            try bytes.write(to: disposable)
            let metadata = BookMetadata(title: "Renamed Book \(index + 1)")
            let first = try BookRenamer.rename(fileURL: disposable, metadata: metadata)
            let after = try Data(contentsOf: first)
            try expect(first.pathExtension == ext && after == bytes, "Rename preserves .\(ext) extension and exact contents")
            try bytes.write(to: disposable)
            let second = try BookRenamer.rename(fileURL: disposable, metadata: metadata)
            try expect(first != second && second.lastPathComponent.contains("(2)"), "Rename collision preserves existing .\(ext) book")
        }
        let vmRename = BookHelperViewModel(lookupService: StubLookups())
        let disposable = renamedDir.appendingPathComponent("workflow.epub")
        try source.write(to: disposable)
        vmRename.handleDroppedURLs([disposable]); try await waitUntilIdle(vmRename)
        vmRename.items[0].metadata?.title = "Reviewed Title"
        vmRename.updateSelectedTitles(); try await waitUntilIdle(vmRename)
        try expect(vmRename.items[0].filename == "Reviewed Title.epub" && vmRename.items[0].status == .renamed && vmRename.zoteroReadyCount == 0, "Review → rename EPUB workflow")
        vmRename.clearCompleted()
        try expect(vmRename.items.isEmpty, "Completed EPUB can be cleared without deleting book")
        try expect(FileManager.default.fileExists(atPath: renamedDir.appendingPathComponent("Reviewed Title.epub").path), "Clearing completed retains EPUB")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CaptureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = ZoteroClient(session: session)
        CaptureProtocol.reset()
        do { try await client.importBook(metadata: normal.metadata!, pdfURL: fixture("metadata.epub")); throw Failure(description: "EPUB reached Zotero") }
        catch ZoteroError.unsupportedFileType { }
        try expect(CaptureProtocol.requests.isEmpty, "Zotero client rejects EPUB before even pinging")
        try await client.importBook(metadata: normal.metadata!, pdfURL: pdf)
        let requests = CaptureProtocol.requests
        try expect(requests.map { $0.request.url!.path } == ["/connector/ping", "/connector/saveItems", "/connector/saveAttachment"], "PDF Zotero request sequence regression (intercepted locally)")
        let payload = try JSONSerialization.jsonObject(with: requests[1].body) as? [String: Any]
        let book = (payload?["items"] as? [[String: Any]])?.first
        try expect(book?["numPages"] as? String == "1" && book?["itemType"] as? String == "book", "PDF Zotero page count and item payload retained")
        try expect(requests[2].request.value(forHTTPHeaderField: "Content-Type") == "application/pdf" && requests[2].body == Data(contentsOf: pdf), "PDF Zotero attachment MIME and bytes retained")

        let unicodeURL = renamedDir.appendingPathComponent("Zoë’s 📚 book.pdf")
        try Data(contentsOf: pdf).write(to: unicodeURL)
        CaptureProtocol.reset()
        try await client.importBook(metadata: normal.metadata!, pdfURL: unicodeURL)
        let unicodeHeader = CaptureProtocol.requests.last!.request.value(forHTTPHeaderField: "X-Metadata")!
        let decodedHeader = try JSONSerialization.jsonObject(with: Data(unicodeHeader.utf8)) as! [String: Any]
        try expect(unicodeHeader.unicodeScalars.allSatisfy { $0.value < 128 }, "Unicode PDF attachment header is ASCII-safe")
        try expect(decodedHeader["title"] as? String == unicodeURL.lastPathComponent, "Unicode attachment header round-trips BMP and emoji")

        let suite = "BookHelperRegression-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        var activations = 0
        let importModel = BookHelperViewModel(lookupService: StubLookups(), zoteroClient: client,
            preferences: preferences, activateZotero: { activations += 1 })
        func readyPDF(_ name: String, title: String) throws -> BookFileItem {
            let url = renamedDir.appendingPathComponent(name + ".pdf")
            try Data(contentsOf: pdf).write(to: url)
            let item = BookFileItem(url: url)
            item.metadata = BookMetadata(title: title)
            item.status = .ready
            return item
        }
        let firstImport = try readyPDF("download-1", title: "First Reviewed PDF")
        let secondImport = try readyPDF("download-2", title: "Second Reviewed PDF")
        let excludedEPUB = BookFileItem(url: fixture("metadata.epub"))
        excludedEPUB.metadata = normal.metadata
        excludedEPUB.status = .ready
        importModel.items = [firstImport, secondImport, excludedEPUB]
        CaptureProtocol.reset()
        importModel.importSelectedToZotero()
        importModel.importSelectedToZotero()
        try await waitUntilIdle(importModel)
        try expect(CaptureProtocol.requests.count == 6, "PDF batch excludes EPUB and prevents duplicate in-flight imports")
        try expect(firstImport.filename == "First Reviewed PDF.pdf" && secondImport.filename == "Second Reviewed PDF.pdf", "PDFs renamed before attachment upload")
        try expect(activations == 1 && firstImport.status == .done && secondImport.status == .done, "Successful PDF batch switches to Zotero once")
        try expect(excludedEPUB.status == .ready && importModel.zoteroImportNotice?.bookTitle == "Second Reviewed PDF", "EPUB unchanged and last PDF success notice retained")

        preferences.set(false, forKey: BookHelperPreferenceKey.switchToZotero)
        preferences.set(true, forKey: BookHelperPreferenceKey.removeImportedBooks)
        let removedImport = try readyPDF("download-3", title: "Kept on Disk")
        importModel.items = [removedImport]
        importModel.importSelectedToZotero()
        try await waitUntilIdle(importModel)
        try expect(activations == 1 && importModel.items.isEmpty, "Switch-off and remove-imported preferences both respected")
        try expect(FileManager.default.fileExists(atPath: removedImport.currentURL.path), "Remove-imported preference preserves PDF on disk")

        preferences.set(true, forKey: BookHelperPreferenceKey.switchToZotero)
        let failedImport = try readyPDF("download-4", title: "Failed Attachment")
        importModel.items = [failedImport]
        CaptureProtocol.failAttachment = true
        importModel.importSelectedToZotero()
        try await waitUntilIdle(importModel)
        CaptureProtocol.failAttachment = false
        try expect(activations == 1 && importModel.items.count == 1 && importModel.zoteroImportNotice == nil, "Failed PDF import stays in list and does not switch apps")
        if case .zoteroError = failedImport.status { checks += 1; print("PASS Failed attachment state retained") }
        else { throw Failure(description: "Expected Zotero error after attachment failure") }

        vm.items = [vm.items[0], vm.items.first { $0.currentURL == pdf }!, protected]
        vm.statusMessage = nil
        // Render our own view offscreen: no installed app is opened and no desktop input is sent.
        NSApplication.shared.setActivationPolicy(.prohibited)
        let view = NSHostingView(rootView: BookHelperContentView(viewModel: vm))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure(description: "UI render unavailable") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure(description: "UI PNG unavailable") }
        try png.write(to: output.appendingPathComponent("epub-mixed-ui.png"))
        try expect(png.count > 1000, "Offscreen native UI render saved")
        vm.items = [vm.items[0]]
        vm.items[0].metadata?.title = "A Reviewed EPUB"
        vm.items[0].status = .renamed
        view.frame = NSRect(x: 0, y: 0, width: 720, height: 520)
        window.setContentSize(NSSize(width: 720, height: 520))
        try await Task.sleep(nanoseconds: 100_000_000)
        view.layoutSubtreeIfNeeded()
        let epubBitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: epubBitmap)
        try epubBitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("epub-only-ui.png"))
        try expect(vm.zoteroReadyCount == 0, "EPUB-only UI at default window size")
        window.contentView = nil
    }
}
