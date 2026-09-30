import SwiftUI

@main
struct BookHelperApp: App {
    @StateObject private var viewModel = BookHelperViewModel()

    var body: some Scene {
        WindowGroup {
            BookHelperContentView(viewModel: viewModel)
                .onOpenURL { url in
                    viewModel.handleDroppedURLs([url])
                }
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 720, height: 520)
    }
}
