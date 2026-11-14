import SwiftUI
import SwiftData
import os

private let appLogger = Logger(subsystem: "com.bookreaderswift.app", category: "Storage")

@main
struct BookReaderSwiftApp: App {

    @AppStorage("readingTheme") private var themeRawValue: String = ReadingTheme.light.rawValue
    @AppStorage("readingFont") private var fontRawValue: String = ReadingFont.serif.rawValue

    private struct StoreLoadResult {
        let container: ModelContainer
        let recoveryMessage: String?
    }

    private let storeLoadResult: StoreLoadResult = BookReaderSwiftApp.loadStore()

    private static func loadStore() -> StoreLoadResult {
        let schema = Schema([Book.self, ReadingSession.self, Bookmark.self])
        let configuration = ModelConfiguration(schema: schema)

        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            appLogger.info("Хранилище данных успешно загружено.")
            return StoreLoadResult(container: container, recoveryMessage: nil)
        } catch {
            appLogger.error("Не удалось создать ModelContainer: \(error.localizedDescription, privacy: .public)")

            let storeURL = configuration.url
            if FileManager.default.fileExists(atPath: storeURL.path) {
                backupCorruptedStore(at: storeURL)
            }

            do {
                let container = try ModelContainer(for: schema, configurations: [configuration])
                appLogger.warning("Хранилище пересоздано после сброса повреждённого стора.")
                let message = "Не удалось загрузить предыдущую библиотеку из-за повреждения или несовместимости данных. Была создана новая пустая библиотека. Копия старых данных сохранена на диске."
                return StoreLoadResult(container: container, recoveryMessage: message)
            } catch {
                appLogger.fault("Не удалось создать хранилище данных даже после сброса: \(error.localizedDescription, privacy: .public)")
                fatalError("Не удалось создать хранилище данных даже после сброса: \(error)")
            }
        }
    }

    private static func backupCorruptedStore(at storeURL: URL) {
        let fileManager = FileManager.default
        let timestamp = Int(Date().timeIntervalSince1970)
        let directory = storeURL.deletingLastPathComponent()
        let baseName = storeURL.lastPathComponent

        let suffixes = ["", "-shm", "-wal"]

        for suffix in suffixes {
            let originalName = baseName + suffix
            let originalURL = directory.appendingPathComponent(originalName)
            guard fileManager.fileExists(atPath: originalURL.path) else { continue }

            let backupURL = directory.appendingPathComponent("\(originalName).corrupted.\(timestamp)")

            do {
                try fileManager.moveItem(at: originalURL, to: backupURL)
                appLogger.info("Файл \(originalName, privacy: .public) перемещён в резервную копию \(backupURL.lastPathComponent, privacy: .public)")
            } catch {
                appLogger.error("Не удалось переместить \(originalName, privacy: .public) в резервную копию: \(error.localizedDescription, privacy: .public). Будет выполнено удаление.")
                try? fileManager.removeItem(at: originalURL)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(startupMessage: storeLoadResult.recoveryMessage)
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
        .modelContainer(storeLoadResult.container)
    }
}
