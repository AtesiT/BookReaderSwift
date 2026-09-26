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

private func generatedColor(from string: String) -> Color {
    var hasher = Hasher()
    hasher.combine(string)
    let hash = abs(hasher.finalize())

    let hue = Double(hash % 360) / 360.0
    return Color(hue: hue, saturation: 0.55, brightness: 0.85)
}

struct BookCoverView: View {
    let title: String

    private var initials: String {
        let words = title.split(separator: " ")
        let letters = words.prefix(2).compactMap { $0.first }
        return String(letters).uppercased()
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(
                LinearGradient(
                    colors: [
                        generatedColor(from: title),
                        generatedColor(from: title).opacity(0.7)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .aspectRatio(2/3, contentMode: .fit)
            .overlay {
                Text(initials)
                    .font(.system(size: 32, weight: .bold, design: .serif))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .shadow(color: .black.opacity(0.15), radius: 6, y: 4)
    }
}

struct ContentView: View {

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Book.dateAdded, order: .reverse) private var books: [Book]

    @State private var isImporting = false
    @State private var currentBook: Book?
    @State private var errorMessage: String?

    private var markdownType: UTType {
        UTType(filenameExtension: "md") ?? .plainText
    }

    private let gridColumns = [
        GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 20)
    ]

    var body: some View {
        Group {
            if let currentBook {
                readerView(book: currentBook)
            } else {
                libraryView
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
                    importBook(from: url)
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    private var libraryView: some View {
        Group {
            if books.isEmpty {
                emptyStateView
            } else {
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: 28) {
                        ForEach(books) { book in
                            Button {
                                currentBook = book
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    BookCoverView(title: book.title)

                                    Text(book.title)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(32)
                }
                .scrollIndicators(.hidden)
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

    private func readerView(book: Book) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(book.title)
                    .font(.system(size: 24, weight: .bold, design: .serif))

                Text(book.content)
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
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    currentBook = nil
                } label: {
                    Label("К библиотеке", systemImage: "chevron.left")
                }
            }
        }
    }

    private func importBook(from url: URL) {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let title = url.deletingPathExtension().lastPathComponent
            let fileExtension = url.pathExtension

            let book = Book(title: title, content: content, fileExtension: fileExtension)
            modelContext.insert(book)

            currentBook = book
            errorMessage = nil
        } catch {
            errorMessage = "Файл повреждён или имеет неподдерживаемую кодировку."
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Book.self, ReadingSession.self], inMemory: true)
}

