import SwiftUI
import SwiftData
import UniformTypeIdentifiers

@Model
final class Book {
    var title: String
    var content: String
    var dateAdded: Date
    var fileExtension: String

    @Relationship(deleteRule: .cascade)
    var readingSession: ReadingSession?

    init(title: String, content: String, fileExtension: String) {
        self.title = title
        self.content = content
        self.dateAdded = .now
        self.fileExtension = fileExtension
    }
}

@Model
final class ReadingSession {
    var scrollOffset: Double
    var lastOpened: Date

    init(scrollOffset: Double = 0, lastOpened: Date = .now) {
        self.scrollOffset = scrollOffset
        self.lastOpened = lastOpened
    }
}

struct ContentView: View {

    @State private var isImporting = false
    @State private var bookTitle: String = ""
    @State private var bookText: String?
    @State private var errorMessage: String?

    private var markdownType: UTType {
        UTType(filenameExtension: "md") ?? .plainText
    }

    var body: some View {
        Group {
            if let bookText {
                readerView(text: bookText)
            } else {
                emptyStateView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isImporting = true
                } label: {
                    Label("Открыть книгу", systemImage: "folder")
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.plainText, markdownType],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    loadBook(from: url)
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "book.pages")
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(.tint)

            Text("BookReaderSwift")
                .font(.system(size: 32, weight: .semibold, design: .serif))

            if let errorMessage {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            } else {
                Text("Открой файл .txt или .md, чтобы начать чтение")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button {
                isImporting = true
            } label: {
                Label("Открыть книгу", systemImage: "folder")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 8)
        }
    }

    private func readerView(text: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(bookTitle)
                    .font(.system(size: 24, weight: .bold, design: .serif))

                Text(text)
                    .font(.system(size: 17, weight: .regular, design: .serif))
                    .lineSpacing(8)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.vertical, 48)
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    private func loadBook(from url: URL) {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            bookText = try String(contentsOf: url, encoding: .utf8)
            bookTitle = url.deletingPathExtension().lastPathComponent
            errorMessage = nil
        } catch {
            errorMessage = "Файл повреждён или имеет неподдерживаемую кодировку."
            bookText = nil
        }
    }
}

#Preview {
    ContentView()
}
