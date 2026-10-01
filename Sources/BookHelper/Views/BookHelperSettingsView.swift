import SwiftUI

struct BookHelperSettingsView: View {
    @AppStorage("switchToZoteroAfterImporting")
    private var switchToZoteroAfterImporting = true

    var body: some View {
        Form {
            Section("Import") {
                Toggle("Switch to Zotero after importing", isOn: $switchToZoteroAfterImporting)
            }
        }
        .padding()
        .frame(width: 400)
    }
}

#Preview {
    BookHelperSettingsView()
}
