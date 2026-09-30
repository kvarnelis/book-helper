import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct BookHelperContentView: View {
    @ObservedObject var viewModel: BookHelperViewModel
    @State private var showingFileImporter = false

    var body: some View {
        VStack(spacing: 0) {
            topBar

            Divider()

            if viewModel.hasItems {
                itemList
            } else {
                BookDropZone { urls in
                    viewModel.handleDroppedURLs(urls)
                }
                .padding(18)
            }

            Divider()
            bottomBar
        }
        .frame(minWidth: 680, minHeight: 460)
        .navigationTitle("Book Helper")
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                viewModel.handleDroppedURLs(urls)
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                showingFileImporter = true
            } label: {
                Label("Add PDFs", systemImage: "plus")
            }

            Button {
                viewModel.updateSelectedTitles()
            } label: {
                Label("Rename PDFs", systemImage: "textformat")
            }
            .disabled(viewModel.renameReadyCount == 0)

            Button {
                viewModel.importSelectedToZotero()
            } label: {
                Label("Import to Zotero", systemImage: "books.vertical.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.zoteroReadyCount == 0)

            Spacer()

            Button {
                viewModel.clearCompleted()
            } label: {
                Image(systemName: "checkmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Clear completed")
            .disabled(!viewModel.items.contains { $0.status == .done })

            Button {
                viewModel.reset()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Clear all")
            .disabled(viewModel.items.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var itemList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(viewModel.items) { item in
                    BookItemRow(item: item, viewModel: viewModel)
                }
            }
            .padding(14)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var bottomBar: some View {
        HStack {
            Text(viewModel.statusMessage ?? "\(viewModel.zoteroReadyCount) ready for Zotero")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            Text("\(viewModel.items.count) PDFs")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct BookItemRow: View {
    @ObservedObject var item: BookFileItem
    @ObservedObject var viewModel: BookHelperViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: $item.isSelected)
                .labelsHidden()
                .frame(width: 24)
                .disabled(item.status == .done)

            statusView
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.filename)
                        .font(.headline)
                        .lineLimit(1)

                    Spacer()

                    Button {
                        viewModel.remove(item)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove")
                }

                metadataView
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    @ViewBuilder
    private var statusView: some View {
        if item.status.isBusy {
            ProgressView()
                .controlSize(.small)
        } else {
            Image(systemName: item.status.systemImage)
                .foregroundColor(statusColor)
        }
    }

    @ViewBuilder
    private var metadataView: some View {
        switch item.status {
        case .ready, .renamed, .done, .updating, .importingToZotero, .zoteroError:
            VStack(alignment: .leading, spacing: 6) {
                TextField("Title", text: titleBinding)
                    .textFieldStyle(.roundedBorder)
                    .disabled(item.status == .done || item.status == .updating || item.status == .importingToZotero)

                HStack(spacing: 12) {
                    if let authors = item.metadata?.authors, !authors.isEmpty {
                        Label(authors.joined(separator: ", "), systemImage: "person")
                    }
                    if let isbn = item.isbn ?? item.metadata?.isbn {
                        isbnView(isbn)
                    }
                    if let source = item.metadata?.source {
                        Label(source, systemImage: "books.vertical")
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)

                if case .zoteroError(let message) = item.status {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

        case .noISBNFound, .error:
            HStack(spacing: 8) {
                TextField("ISBN", text: $item.manualISBN)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 210)
                    .onSubmit {
                        viewModel.lookupManualISBN(for: item)
                    }

                Button {
                    viewModel.lookupManualISBN(for: item)
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help("Look up ISBN")
                .disabled(item.manualISBN.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Text(item.status.label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

        case .scanning, .lookingUp:
            Text(item.status.label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func isbnView(_ isbn: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "barcode")

            TextField("ISBN", text: Binding(
                get: { isbn },
                set: { _ in }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.caption.monospacedDigit())
            .frame(width: isbn.count > 10 ? 132 : 104)
            .help("Selectable ISBN")

            Button {
                copyToPasteboard(isbn)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .controlSize(.small)
            .help("Copy ISBN")
        }
        .contextMenu {
            Button("Copy ISBN") {
                copyToPasteboard(isbn)
            }
        }
    }

    private var titleBinding: Binding<String> {
        Binding {
            item.metadata?.fullTitle ?? ""
        } set: { value in
            guard var metadata = item.metadata else { return }
            metadata.title = value
            metadata.subtitle = nil
            item.metadata = metadata
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .done: return .green
        case .renamed: return .green
        case .error, .zoteroError: return .red
        case .ready: return .accentColor
        case .noISBNFound: return .orange
        default: return .secondary
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        viewModel.statusMessage = "Copied ISBN \(value)"
    }
}
