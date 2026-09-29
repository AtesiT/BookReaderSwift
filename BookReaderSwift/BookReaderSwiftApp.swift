import SwiftUI
import SwiftData

@main
struct BookReaderSwiftApp: App {

    @AppStorage("readingTheme") private var themeRawValue: String = ReadingTheme.light.rawValue
    @AppStorage("readingFont") private var fontRawValue: String = ReadingFont.serif.rawValue

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

            CommandGroup(after: .textEditing) {
                Divider()
                Button("Найти в книге") {
                    NotificationCenter.default.post(name: .focusSearchRequested, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }

            CommandMenu("Чтение") {
                Picker("Тема", selection: $themeRawValue) {
                    ForEach(ReadingTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme.rawValue)
                    }
                }

                Picker("Шрифт", selection: $fontRawValue) {
                    ForEach(ReadingFont.allCases) { font in
                        Text(font.displayName).tag(font.rawValue)
                    }
                }

                Divider()

                Button("Увеличить шрифт") {
                    NotificationCenter.default.post(name: .increaseFontSizeRequested, object: nil)
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Уменьшить шрифт") {
                    NotificationCenter.default.post(name: .decreaseFontSizeRequested, object: nil)
                }
                .keyboardShortcut("-", modifiers: .command)
            }
        }
        .modelContainer(for: [Book.self, ReadingSession.self, Bookmark.self])
    }
}
