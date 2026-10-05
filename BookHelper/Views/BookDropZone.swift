import SwiftUI
import AppKit

struct BookDropZone: View {
    let onDrop: ([URL]) -> Void
    @State private var isTargeted = false

    var body: some View {
        ZStack {
            BookDropTargetView(isTargeted: $isTargeted, onDrop: onDrop)

            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
                )
                .allowsHitTesting(false)

            VStack(spacing: 12) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 42))
                    .foregroundColor(.accentColor)
                Text("Drop PDFs or EPUBs")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("Identify and rename books. EPUBs must be DRM-free.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, minHeight: 190)
    }
}

private struct BookDropTargetView: NSViewRepresentable {
    @Binding var isTargeted: Bool
    let onDrop: ([URL]) -> Void

    func makeNSView(context: Context) -> BookDropNSView {
        let view = BookDropNSView()
        view.onDrop = onDrop
        view.onTargetChange = { targeted in
            DispatchQueue.main.async {
                isTargeted = targeted
            }
        }
        return view
    }

    func updateNSView(_ nsView: BookDropNSView, context: Context) {
        nsView.onDrop = onDrop
    }
}

private final class BookDropNSView: NSView {
    var onDrop: (([URL]) -> Void)?
    var onTargetChange: ((Bool) -> Void)?

    private static let fileTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        NSPasteboard.PasteboardType("public.file-url"),
        NSPasteboard.PasteboardType("NSFilenamesPboardType")
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(Self.fileTypes)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes(Self.fileTypes)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard canReadBooks(from: sender.draggingPasteboard) else { return [] }
        onTargetChange?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        canReadBooks(from: sender.draggingPasteboard) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargetChange?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        canReadBooks(from: sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargetChange?(false)
        let urls = fileURLs(from: sender.draggingPasteboard)
        let books = urls.filter { BookFileFormat(url: $0) != nil }
        guard !books.isEmpty else { return false }
        onDrop?(books)
        return true
    }

    private func canReadBooks(from pasteboard: NSPasteboard) -> Bool {
        fileURLs(from: pasteboard).contains { BookFileFormat(url: $0) != nil }
    }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls
        }

        if let filenames = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            return filenames.map { URL(fileURLWithPath: $0) }
        }

        return []
    }
}
