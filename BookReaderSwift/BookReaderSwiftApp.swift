import SwiftUI
import SwiftData

@main
struct BookReaderSwiftApp: App {

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Открыть книгу…") {
                    NotificationCenter.default.post(name: .openBookRequested, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
        .modelContainer(for: [Book.self, ReadingSession.self, Bookmark.self])
    }
}
