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

@Model
final class Bookmark {
    var scrollOffset: Double
    var snippet: String
    var dateCreated: Date
    var book: Book?

    init(scrollOffset: Double, snippet: String, book: Book?) {
        self.scrollOffset = scrollOffset
        self.snippet = snippet
        self.dateCreated = .now
        self.book = book
    }
}

enum ReadingTheme: String, CaseIterable, Identifiable {
    case light
    case dark
    case sepia

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .light: "Светлая"
        case .dark: "Тёмная"
        case .sepia: "Сепия"
        }
    }

    var iconName: String {
        switch self {
        case .light: "sun.max"
        case .dark: "moon"
        case .sepia: "book.closed"
        }
    }

    var backgroundColor: Color {
        switch self {
        case .light: Color(red: 1.0, green: 1.0, blue: 1.0)
        case .dark: Color(red: 0.11, green: 0.11, blue: 0.12)
        case .sepia: Color(red: 0.96, green: 0.91, blue: 0.79)
        }
    }

    var textColor: Color {
        switch self {
        case .light: Color(red: 0.1, green: 0.1, blue: 0.1)
        case .dark: Color(red: 0.92, green: 0.92, blue: 0.90)
        case .sepia: Color(red: 0.30, green: 0.22, blue: 0.13)
        }
    }
}

enum ReadingFont: String, CaseIterable, Identifiable {
    case serif
    case sans
    case monospace

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .serif: "Serif"
        case .sans: "Sans"
        case .monospace: "Monospace"
        }
    }

    var design: Font.Design {
        switch self {
        case .serif: .serif
        case .sans: .default
        case .monospace: .monospaced
        }
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
    var progress: Double = 0

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
            .overlay(alignment: .bottom) {
                if progress > 0.01 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(.white.opacity(0.25))
                            Rectangle()
                                .fill(.white)
                                .frame(width: geo.size.width * progress)
                        }
                    }
                    .frame(height: 4)
                    .clipShape(RoundedCorner(radius: 12, corners: [.bottomLeft, .bottomRight]))
                }
            }
            .shadow(color: .black.opacity(0.15), radius: 6, y: 4)
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat
    var corners: NSRectCorner

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let topLeft = corners.contains(.topLeft) ? radius : 0
        let topRight = corners.contains(.topRight) ? radius : 0
        let bottomLeft = corners.contains(.bottomLeft) ? radius : 0
        let bottomRight = corners.contains(.bottomRight) ? radius : 0

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topRight, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - topRight, y: rect.minY + topRight), radius: topRight, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRight))
        path.addArc(center: CGPoint(x: rect.maxX - bottomRight, y: rect.maxY - bottomRight), radius: bottomRight, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY - bottomLeft), radius: bottomLeft, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeft))
        path.addArc(center: CGPoint(x: rect.minX + topLeft, y: rect.minY + topLeft), radius: topLeft, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}

struct NSRectCorner: OptionSet {
    let rawValue: Int
    static let topLeft = NSRectCorner(rawValue: 1 << 0)
    static let topRight = NSRectCorner(rawValue: 1 << 1)
    static let bottomLeft = NSRectCorner(rawValue: 1 << 2)
    static let bottomRight = NSRectCorner(rawValue: 1 << 3)
}

struct LibraryBookCell: View {
    let book: Book
    let onOpen: () -> Void

    @State private var isHovering = false

    private var progress: Double {
        book.readingSession?.scrollOffset ?? 0
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                BookCoverView(title: book.title, progress: progress)
                    .scaleEffect(isHovering ? 1.03 : 1.0)
                    .shadow(
                        color: .black.opacity(isHovering ? 0.25 : 0.15),
                        radius: isHovering ? 10 : 6,
                        y: isHovering ? 6 : 4
                    )

                Text(book.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

struct ReaderView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var book: Book
    var initialScrollOverride: Double?
    let onClose: () -> Void

    @AppStorage("readingTheme") private var themeRawValue: String = ReadingTheme.light.rawValue
    @AppStorage("readingFont") private var fontRawValue: String = ReadingFont.serif.rawValue
    @State private var fontSize: Double = 17
    @State private var scrollProgress: Double = 0
    @State private var scrollPosition = ScrollPosition()
    @State private var hasRestoredPosition = false
    @State private var lastScrollGeometry: ScrollGeometry?

    private var theme: ReadingTheme {
        ReadingTheme(rawValue: themeRawValue) ?? .light
    }

    private var font: ReadingFont {
        ReadingFont(rawValue: fontRawValue) ?? .serif
    }

    var body: some View {
        VStack(spacing: 0) {
            ProgressView(value: scrollProgress)
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .frame(height: 2)
                .opacity(scrollProgress > 0 ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: scrollProgress)

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text(book.title)
                        .font(.system(size: 26, weight: .bold, design: font.design))
                        .foregroundStyle(theme.textColor)
                        .padding(.bottom, 4)

                    Text(book.content)
                        .font(.system(size: fontSize, weight: .regular, design: font.design))
                        .lineSpacing(fontSize * 0.5)
                        .foregroundStyle(theme.textColor.opacity(0.9))
                        .textSelection(.enabled)
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.vertical, 64)
                .padding(.horizontal, 40)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geometry in
                handleScrollChange(geometry)
            }
        }
        .background(theme.backgroundColor)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    addBookmark()
                } label: {
                    Image(systemName: "bookmark")
                }

                Menu {
                    Picker("Тема", selection: $themeRawValue) {
                        ForEach(ReadingTheme.allCases) { theme in
                            Label(theme.displayName, systemImage: theme.iconName)
                                .tag(theme.rawValue)
                        }
                    }
                    .pickerStyle(.inline)

                    Picker("Шрифт", selection: $fontRawValue) {
                        ForEach(ReadingFont.allCases) { font in
                            Text(font.displayName)
                                .tag(font.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: theme.iconName)
                }

                Button {
                    fontSize = max(13, fontSize - 1)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                .disabled(fontSize <= 13)

                Button {
                    fontSize = min(28, fontSize + 1)
                } label: {
                    Image(systemName: "textformat.size.larger")
                }
                .disabled(fontSize >= 28)
            }
        }
    }

    private func handleScrollChange(_ geometry: ScrollGeometry) {
        lastScrollGeometry = geometry

        let maxOffset = geometry.contentSize.height - geometry.containerSize.height
        guard maxOffset > 0 else { return }

        let progress = min(max(geometry.contentOffset.y / maxOffset, 0), 1)
        scrollProgress = progress

        if !hasRestoredPosition {
            hasRestoredPosition = true
            let savedProgress = initialScrollOverride ?? book.readingSession?.scrollOffset ?? 0
            if savedProgress > 0.01 {
                scrollPosition.scrollTo(y: savedProgress * maxOffset)
            }
            return
        }

        saveProgress(progress)
    }

    private func saveProgress(_ progress: Double) {
        if let session = book.readingSession {
            session.scrollOffset = progress
            session.lastOpened = .now
        } else {
            book.readingSession = ReadingSession(scrollOffset: progress)
        }
    }

    private func addBookmark() {
        let progress = scrollProgress
        let totalLength = book.content.count
        let approximateIndex = Int(Double(totalLength) * progress)
        let startIndex = book.content.index(
            book.content.startIndex,
            offsetBy: min(approximateIndex, max(totalLength - 1, 0))
        )
        let snippetText = book.content[startIndex...]
            .prefix(80)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let bookmark = Bookmark(
            scrollOffset: progress,
            snippet: snippetText.isEmpty ? "Начало книги" : snippetText,
            book: book
        )
        modelContext.insert(bookmark)
    }
}

struct ContentView: View {

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Book.dateAdded, order: .reverse) private var books: [Book]
    @Query(sort: \Bookmark.dateCreated, order: .reverse) private var bookmarks: [Bookmark]

    @State private var isImporting = false
    @State private var currentBook: Book?
    @State private var pendingScrollTarget: Double?
    @State private var errorMessage: String?
    @State private var sidebarSelection: String? = "library"

    private var markdownType: UTType {
        UTType(filenameExtension: "md") ?? .plainText
    }

    private let gridColumns = [
        GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 20)
    ]

    var body: some View {
        NavigationSplitView {
            sidebarView
        } detail: {
            Group {
                if let currentBook {
                    ReaderView(book: currentBook, initialScrollOverride: pendingScrollTarget) {
                        self.currentBook = nil
                        self.pendingScrollTarget = nil
                    }
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

    private var sidebarView: some View {
        List(selection: $sidebarSelection) {
            Section("Моя коллекция") {
                Label {
                    HStack {
                        Text("Библиотека")
                        Spacer()
                        Text("\(books.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                } icon: {
                    Image(systemName: "books.vertical")
                }
                .tag("library" as String?)
            }

            if !bookmarks.isEmpty {
                Section("Закладки") {
                    ForEach(bookmarks) { bookmark in
                        Button {
                            openBookmark(bookmark)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bookmark.book?.title ?? "Неизвестная книга")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(bookmark.snippet)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) {
                                deleteBookmark(bookmark)
                            } label: {
                                Label("Удалить", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        .listStyle(.sidebar)
    }
    
    private var libraryView: some View {
        Group {
            if books.isEmpty {
                emptyStateView
            } else {
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: 28) {
                        ForEach(books) { book in
                            LibraryBookCell(book: book) {
                                currentBook = book
                            }
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
            ZStack {
                Circle()
                    .fill(.tint.opacity(0.12))
                    .frame(width: 120, height: 120)

                Image(systemName: "book.pages")
                    .font(.system(size: 52, weight: .thin))
                    .foregroundStyle(.tint)
            }

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
    
    private func openBookmark(_ bookmark: Bookmark) {
        guard let book = bookmark.book else { return }
        pendingScrollTarget = bookmark.scrollOffset
        currentBook = book
    }

    private func deleteBookmark(_ bookmark: Bookmark) {
        modelContext.delete(bookmark)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Book.self, ReadingSession.self], inMemory: true)
}
