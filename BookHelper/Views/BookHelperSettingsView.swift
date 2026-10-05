import SwiftUI

enum BookHelperPreferenceKey {
    static let switchToZotero = "switchToZoteroAfterImporting"
    static let removeImportedBooks = "removeImportedBooksAfterZoteroImport"
}

struct BookHelperSettingsView: View {
    @AppStorage(BookHelperPreferenceKey.removeImportedBooks)
    private var removeImportedBooks = false

    @AppStorage(BookHelperPreferenceKey.switchToZotero)
    private var switchToZotero = true

    var body: some View {
        Form {
            Toggle("Switch to Zotero after importing", isOn: $switchToZotero)

            Toggle("Remove books after importing to Zotero", isOn: $removeImportedBooks)

            Text("Successfully imported books will disappear from Book Helper. Their PDF files and Zotero items are not deleted.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 440)
    }
}
