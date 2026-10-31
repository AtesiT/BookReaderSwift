import SwiftUI
import SwiftData
import PDFKit
import UniformTypeIdentifiers
import Compression
import AppKit

extension Notification.Name {
    static let openBookRequested = Notification.Name("openBookRequested")
    static let focusSearchRequested = Notification.Name("focusSearchRequested")
    static let closeBookRequested = Notification.Name("closeBookRequested")
    static let addBookmarkRequested = Notification.Name("addBookmarkRequested")
    static let nextMatchRequested = Notification.Name("nextMatchRequested")
    static let previousMatchRequested = Notification.Name("previousMatchRequested")
    static let increaseFontSizeRequested = Notification.Name("increaseFontSizeRequested")
    static let decreaseFontSizeRequested = Notification.Name("decreaseFontSizeRequested")
    static let jumpToProgressRequested = Notification.Name("jumpToProgressRequested")
}

enum BookFormat: String, Codable, CaseIterable {
    case txt
    case md
    case pdf
    case epub

    var displayName: String {
        switch self {
        case .txt: return "TXT"
        case .md: return "Markdown"
        case .pdf: return "PDF"
        case .epub: return "EPUB"
        }
    }

    var systemImage: String {
        switch self {
        case .txt: return "doc.text"
        case .md: return "doc.richtext"
        case .pdf: return "doc.fill"
        case .epub: return "books.vertical"
        }
    }
}

enum ReadingTheme: String, Codable, CaseIterable, Identifiable {
    case light
    case sepia
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .light: return "Светлая"
        case .sepia: return "Сепия"
        case .dark: return "Тёмная"
        }
    }

    var backgroundColor: Color {
        switch self {
        case .light: return Color.white
        case .sepia: return Color(red: 0.96, green: 0.92, blue: 0.82)
        case .dark: return Color(red: 0.11, green: 0.11, blue: 0.12)
        }
    }

    var textColor: Color {
        switch self {
        case .light: return Color.black
        case .sepia: return Color(red: 0.25, green: 0.18, blue: 0.1)
        case .dark: return Color(white: 0.92)
        }
    }
}

enum ReadingFont: String, Codable, CaseIterable, Identifiable {
    case system
    case serif
    case monospaced

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "Системный"
        case .serif: return "С засечками"
        case .monospaced: return "Моноширинный"
        }
    }

    func font(size: CGFloat) -> Font {
        switch self {
        case .system: return .system(size: size)
        case .serif: return .system(size: size, design: .serif)
        case .monospaced: return .system(size: size, design: .monospaced)
        }
    }
}

enum LibrarySortOrder: String, CaseIterable, Identifiable {
    case title
    case author
    case recentlyAdded
    case recentlyOpened

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .title: return "По названию"
        case .author: return "По автору"
        case .recentlyAdded: return "По дате добавления"
        case .recentlyOpened: return "По последнему чтению"
        }
    }
}

@Model
final class Book {
    var title: String
    var author: String?
    var formatRaw: String
    var content: String
    @Attribute(.externalStorage) var pdfData: Data?
    @Attribute(.externalStorage) var epubData: Data?
    var importedAt: Date
    var lastProgress: Double
    var lastPageIndex: Int
    var coverSeed: String

    @Relationship(deleteRule: .cascade, inverse: \Bookmark.book)
    var bookmarks: [Bookmark] = []

    @Relationship(deleteRule: .cascade, inverse: \ReadingSession.book)
    var readingSession: ReadingSession?

    var format: BookFormat {
        get { BookFormat(rawValue: formatRaw) ?? .txt }
        set { formatRaw = newValue.rawValue }
    }

    var lastOpenedDate: Date? {
        readingSession?.lastOpened
    }

    init(title: String, author: String? = nil, format: BookFormat, content: String = "", pdfData: Data? = nil, epubData: Data? = nil) {
        self.title = title
        self.author = author
        self.formatRaw = format.rawValue
        self.content = content
        self.pdfData = pdfData
        self.epubData = epubData
        self.importedAt = .now
        self.lastProgress = 0
        self.lastPageIndex = 0
        self.coverSeed = UUID().uuidString
    }
}

@Model
final class ReadingSession {
    var lastOpened: Date
    var openCount: Int
    var book: Book?

    init(lastOpened: Date = .now, openCount: Int = 0) {
        self.lastOpened = lastOpened
        self.openCount = openCount
    }
}

@Model
final class Bookmark {
    var label: String
    var progress: Double
    var createdAt: Date
    var book: Book?

    init(label: String, progress: Double, createdAt: Date = .now, book: Book? = nil) {
        self.label = label
        self.progress = progress
        self.createdAt = createdAt
        self.book = book
    }
}

struct ZipArchive {
    struct Entry {
        let name: String
        let compressionMethod: UInt16
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localHeaderOffset: UInt32
    }

    private let data: Data
    let entries: [Entry]

    init?(data: Data) {
        self.data = data
        guard let entries = ZipArchive.parseCentralDirectory(data: data) else { return nil }
        self.entries = entries
    }

    private static func parseCentralDirectory(data: Data) -> [Entry]? {
        guard let eocdOffset = findEndOfCentralDirectory(in: data) else { return nil }
        guard eocdOffset + 22 <= data.count else { return nil }

        let entryCount = data.readUInt16(at: eocdOffset + 10)
        let centralDirectorySize = data.readUInt32(at: eocdOffset + 12)
        let centralDirectoryOffset = data.readUInt32(at: eocdOffset + 16)

        guard centralDirectoryOffset != 0xFFFFFFFF, entryCount != 0xFFFF else {
            return nil
        }

        var entries: [Entry] = []
        var offset = Int(centralDirectoryOffset)
        let endOffset = offset + Int(centralDirectorySize)

        for _ in 0..<entryCount {
            guard offset + 46 <= data.count, offset + 46 <= endOffset else { break }
            let signature = data.readUInt32(at: offset)
            guard signature == 0x02014b50 else { break }

            let compressionMethod = data.readUInt16(at: offset + 10)
            let compressedSize = data.readUInt32(at: offset + 20)
            let uncompressedSize = data.readUInt32(at: offset + 24)
            let nameLength = Int(data.readUInt16(at: offset + 28))
            let extraLength = Int(data.readUInt16(at: offset + 30))
            let commentLength = Int(data.readUInt16(at: offset + 32))
            let localHeaderOffset = data.readUInt32(at: offset + 42)

            let nameStart = offset + 46
            guard nameStart + nameLength <= data.count else { break }
            let nameData = data.subdata(in: nameStart..<nameStart + nameLength)
            let name = String(data: nameData, encoding: .utf8) ?? ""

            entries.append(Entry(
                name: name,
                compressionMethod: compressionMethod,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset
            ))

            offset = nameStart + nameLength + extraLength + commentLength
        }

        return entries
    }

    private static func findEndOfCentralDirectory(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let searchRange = max(0, data.count - 65557)
        var i = data.count - 22
        while i >= searchRange {
            if data.readUInt32(at: i) == 0x06054b50 {
                return i
            }
            i -= 1
        }
        return nil
    }

    func contents(of entry: Entry) -> Data? {
        let offset = Int(entry.localHeaderOffset)
        guard offset + 30 <= data.count else { return nil }
        guard data.readUInt32(at: offset) == 0x04034b50 else { return nil }

        let nameLength = Int(data.readUInt16(at: offset + 26))
        let extraLength = Int(data.readUInt16(at: offset + 28))
        let dataStart = offset + 30 + nameLength + extraLength
        guard dataStart + Int(entry.compressedSize) <= data.count else { return nil }

        let compressedData = data.subdata(in: dataStart..<dataStart + Int(entry.compressedSize))

        switch entry.compressionMethod {
        case 0:
            return compressedData
        case 8:
            return ZipArchive.inflate(compressedData, expectedSize: Int(entry.uncompressedSize))
        default:
            return nil
        }
    }

    private static func inflate(_ data: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0 else { return Data() }
        var destBuffer = [UInt8](repeating: 0, count: expectedSize)
        let result = data.withUnsafeBytes { (srcPtr: UnsafeRawBufferPointer) -> Int in
            guard let srcBase = srcPtr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return destBuffer.withUnsafeMutableBufferPointer { destPtr -> Int in
                guard let destBase = destPtr.baseAddress else { return 0 }
                return compression_decode_buffer(destBase, expectedSize, srcBase, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard result > 0 else { return nil }
        return Data(destBuffer[0..<result])
    }
}

private extension Data {
    func readUInt16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[self.startIndex + offset]) | (UInt16(self[self.startIndex + offset + 1]) << 8)
    }

    func readUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        let b0 = UInt32(self[self.startIndex + offset])
        let b1 = UInt32(self[self.startIndex + offset + 1])
        let b2 = UInt32(self[self.startIndex + offset + 2])
        let b3 = UInt32(self[self.startIndex + offset + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }
}

struct EPUBParser {
    struct ParsedBook {
        let title: String?
        let author: String?
        let content: String
    }

    static func parse(data: Data) -> ParsedBook? {
        guard let archive = ZipArchive(data: data) else { return nil }

        guard let containerEntry = archive.entries.first(where: { $0.name == "META-INF/container.xml" }),
              let containerData = archive.contents(of: containerEntry),
              let containerXML = String(data: containerData, encoding: .utf8) else {
            return nil
        }

        guard let opfPath = extractOPFPath(from: containerXML) else { return nil }

        guard let opfEntry = archive.entries.first(where: { $0.name == opfPath }),
              let opfData = archive.contents(of: opfEntry),
              let opfXML = String(data: opfData, encoding: .utf8) else {
            return nil
        }

        let basePath = (opfPath as NSString).deletingLastPathComponent

        let title = extractTag("dc:title", from: opfXML)
        let author = extractTag("dc:creator", from: opfXML)

        let manifest = extractManifest(from: opfXML)
        let spine = extractSpine(from: opfXML)

        var fullText = ""
        for idref in spine {
            guard let href = manifest[idref] else { continue }
            let fullPath = basePath.isEmpty ? href : "\(basePath)/\(href)"
            guard let entry = archive.entries.first(where: { $0.name == fullPath || $0.name == href }),
                  let itemData = archive.contents(of: entry),
                  let html = String(data: itemData, encoding: .utf8) else { continue }

            fullText += stripHTML(html)
            fullText += "\n\n"
        }

        return ParsedBook(title: title, author: author, content: fullText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func extractOPFPath(from xml: String) -> String? {
        guard let range = xml.range(of: "full-path=\"") else { return nil }
        let rest = xml[range.upperBound...]
        guard let endRange = rest.range(of: "\"") else { return nil }
        return String(rest[..<endRange.lowerBound])
    }

    private static func extractTag(_ tag: String, from xml: String) -> String? {
        guard let startRange = xml.range(of: "<\(tag)") else { return nil }
        guard let contentStart = xml.range(of: ">", range: startRange.upperBound..<xml.endIndex) else { return nil }
        guard let endRange = xml.range(of: "</\(tag)>", range: contentStart.upperBound..<xml.endIndex) else { return nil }
        let rawValue = String(xml[contentStart.upperBound..<endRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return decodeEntities(rawValue)
    }

    private static func extractManifest(from xml: String) -> [String: String] {
        var manifest: [String: String] = [:]
        let scanner = Scanner(string: xml)
        while scanner.scanUpToString("<item ") != nil {
            guard scanner.scanString("<item ") != nil else { break }
            guard let tagEnd = scanner.scanUpToString("/>") ?? scanner.scanUpToString(">") else { continue }
            let attrs = parseAttributes(from: tagEnd)
            if let id = attrs["id"], let href = attrs["href"] {
                manifest[id] = href
            }
        }
        return manifest
    }

    private static func extractSpine(from xml: String) -> [String] {
        guard let spineStartRange = xml.range(of: "<spine"),
              let spineOpenEnd = xml.range(of: ">", range: spineStartRange.upperBound..<xml.endIndex),
              let spineCloseRange = xml.range(of: "</spine>", range: spineOpenEnd.upperBound..<xml.endIndex) else {
            return []
        }

        let spineXML = String(xml[spineOpenEnd.upperBound..<spineCloseRange.lowerBound])

        var spine: [String] = []
        let scanner = Scanner(string: spineXML)
        while scanner.scanUpToString("<itemref ") != nil {
            guard scanner.scanString("<itemref ") != nil else { break }
            guard let tagEnd = scanner.scanUpToString("/>") ?? scanner.scanUpToString(">") else { continue }
            let attrs = parseAttributes(from: tagEnd)
            if let idref = attrs["idref"] {
                spine.append(idref)
            }
        }
        return spine
    }

    private static func parseAttributes(from fragment: String) -> [String: String] {
        var result: [String: String] = [:]
        let pattern = #"(\w[\w-]*)="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let nsString = fragment as NSString
        let matches = regex.matches(in: fragment, range: NSRange(location: 0, length: nsString.length))
        for match in matches {
            guard match.numberOfRanges == 3 else { continue }
            let key = nsString.substring(with: match.range(at: 1))
            let value = nsString.substring(with: match.range(at: 2))
            result[key] = value
        }
        return result
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "&nbsp;", with: " ")
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&#39;", with: "'")
        return result
    }

    private static func stripHTML(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "</p>", with: "\n\n", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = decodeEntities(text)
        return text
    }
}

enum TextDecoding {
    static func decodeTextFile(_ data: Data) -> String {
        let encodings: [String.Encoding] = [.utf8, .windowsCP1251, .isoLatin1]
        for encoding in encodings {
            if let string = String(data: data, encoding: encoding) {
                return string
            }
        }
        return String(decoding: data, as: UTF8.self)
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var books: [Book]

    @State private var currentBook: Book?
    @State private var errorMessage: String?
    @State private var isProcessingImport = false
    @State private var isImporterPresented = false
    @State private var sortOrder: LibrarySortOrder = .recentlyAdded
    @State private var renamingBook: Book?
    @State private var renameText: String = ""

    private var sortedBooks: [Book] {
        switch sortOrder {
        case .title:
            return books.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        case .author:
            return books.sorted { lhs, rhs in
                switch (lhs.author, rhs.author) {
                case (nil, nil):
                    return false
                case (nil, _):
                    return false
                case (_, nil):
                    return true
                case let (l?, r?):
                    return l.localizedCompare(r) == .orderedAscending
                }
            }
        case .recentlyAdded:
            return books.sorted { $0.importedAt > $1.importedAt }
        case .recentlyOpened:
            return books.sorted {
                let lhs = $0.lastOpenedDate ?? .distantPast
                let rhs = $1.lastOpenedDate ?? .distantPast
                return lhs > rhs
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [
                .plainText,
                .pdf,
                UTType(filenameExtension: "md") ?? .plainText,
                UTType(filenameExtension: "epub") ?? .data
            ],
            allowsMultipleSelection: false
        ) { result in
            handleImportResult(result)
        }
        .alert("Переименовать книгу", isPresented: Binding(
            get: { renamingBook != nil },
            set: { if !$0 { renamingBook = nil } }
        )) {
            TextField("Название", text: $renameText)
            Button("Сохранить") {
                if let book = renamingBook {
                    renameBook(book, to: renameText)
                }
                renamingBook = nil
            }
            Button("Отмена", role: .cancel) { renamingBook = nil }
        }
        .overlay {
            if isProcessingImport {
                ProcessingOverlay()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openBookRequested)) { _ in
            isImporterPresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .dataStoreResetOccurred)) { notification in
            if let message = notification.userInfo?["message"] as? String {
                errorMessage = message
            }
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Сортировка", selection: $sortOrder) {
                    ForEach(LibrarySortOrder.allCases) { order in
                        Text(order.displayName).tag(order)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                Spacer()

                ToolbarIconButton(systemImage: "plus") {
                    isImporterPresented = true
                }
            }
            .padding(8)

            Divider()

            List(selection: $currentBook) {
                LibrarySectionView(
                    books: sortedBooks,
                    currentBook: $currentBook,
                    onRename: { book in
                        renamingBook = book
                        renameText = book.title
                    },
                    onDelete: deleteBook
                )

                if let currentBook {
                    BookmarksSectionView(
                        book: currentBook,
                        onSelect: { bookmark in
                            openBookmark(bookmark, in: currentBook)
                        },
                        onDelete: deleteBookmark
                    )
                }
            }
            .listStyle(.sidebar)
        }
        .frame(minWidth: 220)
    }

    @ViewBuilder
    private var detail: some View {
        if let currentBook {
            ReaderView(book: currentBook, onClose: {
                self.currentBook = nil
            })
            .id(currentBook.persistentModelID)
            .transition(.opacity)
            .onAppear {
                markBookOpened(currentBook)
            }
        } else if books.isEmpty {
            EmptyLibraryView(errorMessage: errorMessage) {
                isImporterPresented = true
            }
        } else {
            LibraryGridView(
                books: sortedBooks,
                currentBook: $currentBook,
                onRename: { book in
                    renamingBook = book
                    renameText = book.title
                },
                onDelete: deleteBook
            )
        }
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            importFile(at: url)
        case .failure(let error):
            errorMessage = "Не удалось выбрать файл: \(error.localizedDescription)"
        }
    }

    private func importFile(at url: URL) {
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "pdf":
            importPDF(at: url)
        case "epub":
            importEPUB(at: url)
        default:
            importPlainText(at: url, isMarkdown: ext == "md")
        }
    }

    private func importPDF(at url: URL) {
        isProcessingImport = true
        Task.detached(priority: .userInitiated) {
            let needsSecurityScope = url.startAccessingSecurityScopedResource()
            defer {
                if needsSecurityScope { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try Data(contentsOf: url)
                let title = url.deletingPathExtension().lastPathComponent
                await MainActor.run {
                    let book = Book(title: title, format: .pdf, pdfData: data)
                    modelContext.insert(book)
                    saveContext()
                    currentBook = book
                    isProcessingImport = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Не удалось импортировать PDF: \(error.localizedDescription)"
                    isProcessingImport = false
                }
            }
        }
    }

    private func importPlainText(at url: URL, isMarkdown: Bool) {
        isProcessingImport = true
        Task.detached(priority: .userInitiated) {
            let needsSecurityScope = url.startAccessingSecurityScopedResource()
            defer {
                if needsSecurityScope { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try Data(contentsOf: url)
                let text = TextDecoding.decodeTextFile(data)
                let title = url.deletingPathExtension().lastPathComponent
                await MainActor.run {
                    let book = Book(title: title, format: isMarkdown ? .md : .txt, content: text)
                    modelContext.insert(book)
                    saveContext()
                    currentBook = book
                    isProcessingImport = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Не удалось импортировать файл: \(error.localizedDescription)"
                    isProcessingImport = false
                }
            }
        }
    }

    private func importEPUB(at url: URL) {
        isProcessingImport = true
        Task.detached(priority: .userInitiated) {
            let needsSecurityScope = url.startAccessingSecurityScopedResource()
            defer {
                if needsSecurityScope { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try Data(contentsOf: url)
                guard let parsed = EPUBParser.parse(data: data) else {
                    await MainActor.run {
                        errorMessage = "Не удалось разобрать EPUB-файл"
                        isProcessingImport = false
                    }
                    return
                }
                let title = parsed.title ?? url.deletingPathExtension().lastPathComponent
                await MainActor.run {
                    let book = Book(title: title, author: parsed.author, format: .epub, content: parsed.content, epubData: data)
                    modelContext.insert(book)
                    saveContext()
                    currentBook = book
                    isProcessingImport = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Не удалось импортировать EPUB: \(error.localizedDescription)"
                    isProcessingImport = false
                }
            }
        }
    }

    private func openBookmark(_ bookmark: Bookmark, in book: Book) {
        if currentBook?.persistentModelID == book.persistentModelID {
            NotificationCenter.default.post(
                name: .jumpToProgressRequested,
                object: nil,
                userInfo: ["progress": bookmark.progress]
            )
        } else {
            currentBook = book
        }
        book.lastProgress = bookmark.progress
        saveContext()
    }

    private func deleteBookmark(_ bookmark: Bookmark) {
        modelContext.delete(bookmark)
        do {
            try modelContext.save()
        } catch {
            errorMessage = "Не удалось удалить закладку: \(error.localizedDescription)"
        }
    }

    private func deleteBook(_ book: Book) {
        if currentBook?.persistentModelID == book.persistentModelID {
            currentBook = nil
        }
        modelContext.delete(book)
        do {
            try modelContext.save()
        } catch {
            errorMessage = "Не удалось удалить книгу: \(error.localizedDescription)"
        }
    }

    private func renameBook(_ book: Book, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        book.title = trimmed
        do {
            try modelContext.save()
        } catch {
            errorMessage = "Не удалось переименовать книгу: \(error.localizedDescription)"
        }
    }

    private func markBookOpened(_ book: Book) {
        if let session = book.readingSession {
            session.lastOpened = .now
            session.openCount += 1
        } else {
            let session = ReadingSession(lastOpened: .now, openCount: 1)
            session.book = book
            book.readingSession = session
            modelContext.insert(session)
        }
        do {
            try modelContext.save()
        } catch {
            errorMessage = "Не удалось обновить историю чтения: \(error.localizedDescription)"
        }
    }

    private func saveContext() {
        do {
            try modelContext.save()
        } catch {
            errorMessage = "Не удалось сохранить изменения: \(error.localizedDescription)"
        }
    }
}

struct BookCoverView: View {
    let book: Book

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(generatedColor(from: book.coverSeed))

            VStack(alignment: .leading, spacing: 4) {
                Spacer()
                Image(systemName: book.format.systemImage)
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.9))
                Text(book.title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }
            .padding(10)
        }
        .aspectRatio(2 / 3, contentMode: .fit)
    }

    private func generatedColor(from seed: String) -> Color {
        var hasher = Hasher()
        hasher.combine(seed)
        let hashValue = hasher.finalize()
        let hue = Double(abs(hashValue) % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.65)
    }
}

struct LibraryBookCell: View {
    let book: Book
    let isSelected: Bool
    var onRename: () -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack {
            BookCoverView(book: book)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3)
                )

            Text(book.title)
                .font(.callout)
                .lineLimit(1)
        }
        .contextMenu {
            Button("Переименовать", action: onRename)
            Button("Удалить", role: .destructive, action: onDelete)
        }
    }
}

struct LibraryGridView: View {
    let books: [Book]
    @Binding var currentBook: Book?
    var onRename: (Book) -> Void
    var onDelete: (Book) -> Void

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 20)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(books) { book in
                    LibraryBookCell(
                        book: book,
                        isSelected: currentBook?.persistentModelID == book.persistentModelID,
                        onRename: { onRename(book) },
                        onDelete: { onDelete(book) }
                    )
                    .onTapGesture {
                        currentBook = book
                    }
                }
            }
            .padding(24)
        }
    }
}

struct LibrarySectionView: View {
    let books: [Book]
    @Binding var currentBook: Book?
    var onRename: (Book) -> Void
    var onDelete: (Book) -> Void

    var body: some View {
        Section("Библиотека") {
            ForEach(books) { book in
                SidebarRow(book: book, isSelected: currentBook?.persistentModelID == book.persistentModelID)
                    .tag(book)
                    .contextMenu {
                        Button("Переименовать") { onRename(book) }
                        Button("Удалить", role: .destructive) { onDelete(book) }
                    }
            }
        }
    }
}

struct SidebarRow: View {
    let book: Book
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: book.format.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .lineLimit(1)
                if let author = book.author, !author.isEmpty {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if book.lastProgress > 0 {
                Text("\(Int(book.lastProgress * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct BookmarksSectionView: View {
    let book: Book
    var onSelect: (Bookmark) -> Void
    var onDelete: (Bookmark) -> Void

    var body: some View {
        if !book.bookmarks.isEmpty {
            Section("Закладки — \(book.title)") {
                ForEach(book.bookmarks.sorted(by: { $0.createdAt < $1.createdAt })) { bookmark in
                    BookmarkRow(bookmark: bookmark)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onSelect(bookmark)
                        }
                        .contextMenu {
                            Button("Удалить", role: .destructive) {
                                onDelete(bookmark)
                            }
                        }
                }
            }
        }
    }
}

struct BookmarkRow: View {
    let bookmark: Bookmark

    var body: some View {
        HStack {
            Image(systemName: "bookmark.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(bookmark.label)
                    .lineLimit(1)
                Text("\(Int(bookmark.progress * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

struct EmptyLibraryView: View {
    let errorMessage: String?
    var onImport: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Библиотека пуста")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Импортируйте книгу в формате TXT, Markdown, PDF или EPUB")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }

            Button("Импортировать книгу", action: onImport)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: 400)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ToolbarIconButton: View {
    let systemImage: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(.plain)
    }
}

struct ProcessingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text("Импорт книги…")
                    .foregroundStyle(.white)
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct ReaderToolbarContent: View {
    @Bindable var book: Book
    @Binding var theme: ReadingTheme
    @Binding var font: ReadingFont
    @Binding var fontSize: CGFloat
    @Binding var isSearchActive: Bool
    @Binding var searchText: String
    let matchCount: Int
    @Binding var currentMatchIndex: Int
    let searchFocusTrigger: Int
    var onClose: () -> Void
    var onAddBookmark: () -> Void

    @FocusState private var isSearchFieldFocused: Bool

    private var isSearchAvailable: Bool {
        book.format != .pdf
    }

    var body: some View {
        HStack(spacing: 12) {
            ToolbarIconButton(systemImage: "chevron.left", action: onClose)

            Text(book.title)
                .font(.headline)
                .lineLimit(1)

            Spacer()

            if isSearchActive && isSearchAvailable {
                HStack {
                    TextField("Поиск по тексту", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .focused($isSearchFieldFocused)

                    if matchCount > 0 {
                        Text("\(currentMatchIndex + 1)/\(matchCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        guard matchCount > 0 else { return }
                        currentMatchIndex = (currentMatchIndex + matchCount - 1) % matchCount
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(matchCount == 0)

                    Button {
                        guard matchCount > 0 else { return }
                        currentMatchIndex = (currentMatchIndex + 1) % matchCount
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(matchCount == 0)
                }
            }

            if isSearchAvailable {
                ToolbarIconButton(systemImage: isSearchActive ? "xmark.circle" : "magnifyingglass") {
                    isSearchActive.toggle()
                    if !isSearchActive { searchText = "" }
                }
            }

            ToolbarIconButton(systemImage: "bookmark") {
                onAddBookmark()
            }

            Menu {
                Picker("Тема", selection: $theme) {
                    ForEach(ReadingTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                Picker("Шрифт", selection: $font) {
                    ForEach(ReadingFont.allCases) { font in
                        Text(font.displayName).tag(font)
                    }
                }
                Stepper("Размер шрифта: \(Int(fontSize))", value: $fontSize, in: 12...28)
            } label: {
                Image(systemName: "textformat.size")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .onChange(of: isSearchActive) { _, newValue in
            if !newValue {
                isSearchFieldFocused = false
            }
        }
        .onChange(of: searchFocusTrigger) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isSearchFieldFocused = true
            }
        }
    }
}

struct ReaderView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var book: Book
    var onClose: () -> Void

    @AppStorage("readingTheme") private var themeRawValue: String = ReadingTheme.light.rawValue
    @AppStorage("readingFont") private var fontRawValue: String = ReadingFont.serif.rawValue

    @State private var paragraphs: [String] = []
    @State private var totalContentLength: Int = 0
    @State private var fontSize: CGFloat = 17
    @State private var searchText: String = ""
    @State private var searchMatches: [SearchMatch] = []
    @State private var currentMatchIndex: Int = 0
    @State private var isSearchActive = false
    @State private var searchFocusTrigger: Int = 0
    @State private var isAddingBookmark = false
    @State private var newBookmarkLabel = ""
    @State private var pdfDocument: PDFDocument?
    @State private var pdfProgress: Double = 0
    @State private var pdfPageIndex: Int = 0
    @State private var isLoadingContent = true
    @State private var progressSaveTask: Task<Void, Never>?
    @State private var scrollProxy: ScrollViewProxy?
    @State private var viewportHeight: CGFloat = 0

    private struct ReaderTaskID: Equatable {
        let bookID: PersistentIdentifier
    }

    private struct SearchMatch {
        let paragraphIndex: Int
        let range: Range<String.Index>
    }

    private var currentTheme: ReadingTheme {
        ReadingTheme(rawValue: themeRawValue) ?? .light
    }

    private var currentFont: ReadingFont {
        ReadingFont(rawValue: fontRawValue) ?? .serif
    }

    private var themeBinding: Binding<ReadingTheme> {
        Binding(
            get: { currentTheme },
            set: { themeRawValue = $0.rawValue }
        )
    }

    private var fontBinding: Binding<ReadingFont> {
        Binding(
            get: { currentFont },
            set: { fontRawValue = $0.rawValue }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ReaderToolbarContent(
                book: book,
                theme: themeBinding,
                font: fontBinding,
                fontSize: $fontSize,
                isSearchActive: $isSearchActive,
                searchText: $searchText,
                matchCount: searchMatches.count,
                currentMatchIndex: $currentMatchIndex,
                searchFocusTrigger: searchFocusTrigger,
                onClose: onClose,
                onAddBookmark: { isAddingBookmark = true }
            )

            Divider()

            content
        }
        .background(currentTheme.backgroundColor)
        .task(id: ReaderTaskID(bookID: book.persistentModelID)) {
            await loadContent()
        }
        .onChange(of: searchText) { _, _ in
            recomputeSearchMatches()
        }
        .onChange(of: currentMatchIndex) { _, _ in
            scrollToCurrentMatch()
        }
        .onChange(of: pdfProgress) { _, newValue in
            guard book.format == .pdf else { return }
            book.lastProgress = newValue
            scheduleProgressSave()
        }
        .onChange(of: pdfPageIndex) { _, newValue in
            guard book.format == .pdf else { return }
            book.lastPageIndex = newValue
            scheduleProgressSave()
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearchRequested)) { _ in
            guard book.format != .pdf else { return }
            isSearchActive = true
            searchFocusTrigger += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .increaseFontSizeRequested)) { _ in
            fontSize = min(fontSize + 1, 28)
        }
        .onReceive(NotificationCenter.default.publisher(for: .decreaseFontSizeRequested)) { _ in
            fontSize = max(fontSize - 1, 12)
        }
        .onReceive(NotificationCenter.default.publisher(for: .jumpToProgressRequested)) { notification in
            guard book.format != .pdf,
                  let progress = notification.userInfo?["progress"] as? Double,
                  !paragraphs.isEmpty else { return }
            let index = min(Int(Double(paragraphs.count) * progress), paragraphs.count - 1)
            withAnimation {
                scrollProxy?.scrollTo(index, anchor: .top)
            }
        }
        .sheet(isPresented: $isAddingBookmark) {
            addBookmarkSheet
        }
        .onDisappear {
            progressSaveTask?.cancel()
            saveProgress()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch book.format {
        case .pdf:
            if let pdfDocument {
                PDFKitView(document: pdfDocument, currentPageIndex: $pdfPageIndex, progress: $pdfProgress)
            } else {
                ProgressView("Загрузка PDF…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        default:
            if isLoadingContent {
                ProgressView("Загрузка книги…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                textReader
            }
        }
    }

    private var textReader: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                        Text(highlightedText(for: paragraph, paragraphIndex: index))
                            .font(currentFont.font(size: fontSize))
                            .foregroundStyle(currentTheme.textColor)
                            .textSelection(.enabled)
                            .id(index)
                            .padding(.horizontal)
                    }
                }
                .padding(.vertical, 24)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onChange(of: geo.frame(in: .named("scroll")).minY) { _, minY in
                                updateProgress(minY: minY, contentHeight: geo.size.height)
                            }
                    }
                )
            }
            .coordinateSpace(name: "scroll")
            .background(
                GeometryReader { outerGeo in
                    Color.clear
                        .onAppear { viewportHeight = outerGeo.size.height }
                        .onChange(of: outerGeo.size.height) { _, newValue in
                            viewportHeight = newValue
                        }
                }
            )
            .onAppear {
                scrollProxy = proxy
                restoreTextPosition(proxy: proxy)
            }
        }
    }

    private var addBookmarkSheet: some View {
        VStack(spacing: 16) {
            Text("Новая закладка")
                .font(.headline)
            TextField("Название закладки", text: $newBookmarkLabel)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Отмена", role: .cancel) {
                    isAddingBookmark = false
                    newBookmarkLabel = ""
                }
                Spacer()
                Button("Сохранить") {
                    addBookmark()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func loadContent() async {
        isLoadingContent = true
        switch book.format {
        case .pdf:
            let data = book.pdfData
            let document = await Task.detached(priority: .userInitiated) {
                data.flatMap { PDFDocument(data: $0) }
            }.value
            await MainActor.run {
                self.pdfDocument = document
                self.pdfProgress = book.lastProgress
                self.isLoadingContent = false
            }
        default:
            let content = book.content
            let computedParagraphs = await Task.detached(priority: .userInitiated) {
                content
                    .components(separatedBy: "\n\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }.value
            await MainActor.run {
                self.paragraphs = computedParagraphs
                self.totalContentLength = content.count
                self.isLoadingContent = false
            }
        }
    }

    private func updateProgress(minY: CGFloat, contentHeight: CGFloat) {
        let scrollableHeight = contentHeight - viewportHeight
        guard scrollableHeight > 0 else {
            book.lastProgress = 1
            scheduleProgressSave()
            return
        }
        let scrolled = max(0, -minY)
        let progress = min(max(Double(scrolled / scrollableHeight), 0), 1)
        book.lastProgress = progress
        scheduleProgressSave()
    }

    private func scheduleProgressSave() {
        progressSaveTask?.cancel()
        progressSaveTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                saveProgress()
            }
        }
    }

    private func restoreTextPosition(proxy: ScrollViewProxy) {
        guard book.lastProgress > 0, !paragraphs.isEmpty else { return }
        let index = min(Int(Double(paragraphs.count) * book.lastProgress), paragraphs.count - 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            proxy.scrollTo(index, anchor: .top)
        }
    }

    private func saveProgress() {
        do {
            try modelContext.save()
        } catch {
            print("Не удалось сохранить прогресс чтения: \(error.localizedDescription)")
        }
    }

    private func recomputeSearchMatches() {
        guard !searchText.isEmpty, book.format != .pdf else {
            searchMatches = []
            currentMatchIndex = 0
            return
        }
        var matches: [SearchMatch] = []
        for (index, paragraph) in paragraphs.enumerated() {
            var searchStart = paragraph.startIndex
            while let range = paragraph.range(of: searchText, options: .caseInsensitive, range: searchStart..<paragraph.endIndex) {
                matches.append(SearchMatch(paragraphIndex: index, range: range))
                searchStart = range.upperBound
            }
        }
        searchMatches = matches
        currentMatchIndex = 0
        scrollToCurrentMatch()
    }

    private func scrollToCurrentMatch() {
        guard searchMatches.indices.contains(currentMatchIndex) else { return }
        let paragraphIndex = searchMatches[currentMatchIndex].paragraphIndex
        withAnimation {
            scrollProxy?.scrollTo(paragraphIndex, anchor: .center)
        }
    }

    private func highlightedText(for paragraph: String, paragraphIndex: Int) -> AttributedString {
        guard isSearchActive, !searchText.isEmpty else {
            return AttributedString(paragraph)
        }

        var attributed = AttributedString(paragraph)
        var searchStart = paragraph.startIndex

        while let range = paragraph.range(of: searchText, options: .caseInsensitive, range: searchStart..<paragraph.endIndex) {
            if let attrRange = Range(range, in: attributed) {
                let isCurrent = searchMatches.indices.contains(currentMatchIndex)
                    && searchMatches[currentMatchIndex].paragraphIndex == paragraphIndex
                    && searchMatches[currentMatchIndex].range == range
                attributed[attrRange].backgroundColor = isCurrent ? .orange : .yellow.opacity(0.5)
            }
            searchStart = range.upperBound
        }

        return attributed
    }

    private func addBookmark() {
        let label = newBookmarkLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalLabel = label.isEmpty ? "Закладка \(book.bookmarks.count + 1)" : label
        let progress = book.format == .pdf ? pdfProgress : book.lastProgress
        let bookmark = Bookmark(label: finalLabel, progress: progress, book: book)
        modelContext.insert(bookmark)
        do {
            try modelContext.save()
        } catch {
            print("Не удалось сохранить закладку: \(error.localizedDescription)")
        }
        isAddingBookmark = false
        newBookmarkLabel = ""
    }
}

struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument
    @Binding var currentPageIndex: Int
    @Binding var progress: Double

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.document = document

        context.coordinator.attachObservers(to: pdfView)

        if progress > 0 {
            context.coordinator.restoreProgress(progress, in: pdfView, document: document)
        }

        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        if pdfView.document !== document {
            pdfView.document = document
            context.coordinator.lastReportedProgress = -1
            context.coordinator.attachObservers(to: pdfView)
            if progress > 0 {
                DispatchQueue.main.async {
                    context.coordinator.restoreProgress(progress, in: pdfView, document: document)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject {
        var parent: PDFKitView
        weak var pdfView: PDFView?
        var lastReportedProgress: Double = -1
        private var isRestoring = false

        init(_ parent: PDFKitView) {
            self.parent = parent
        }

        func attachObservers(to pdfView: PDFView) {
            self.pdfView = pdfView
            NotificationCenter.default.removeObserver(self)

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pageChanged),
                name: Notification.Name.PDFViewPageChanged,
                object: pdfView
            )

            if let scrollView = pdfView.documentView?.enclosingScrollView {
                scrollView.contentView.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(scrollChanged),
                    name: NSView.boundsDidChangeNotification,
                    object: scrollView.contentView
                )
            }

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleJumpRequest(_:)),
                name: .jumpToProgressRequested,
                object: nil
            )
        }

        @objc func pageChanged() {
            updateProgress()
        }

        @objc func scrollChanged() {
            updateProgress()
        }

        @objc func handleJumpRequest(_ notification: Notification) {
            guard let pdfView = pdfView,
                  let document = pdfView.document,
                  let progress = notification.userInfo?["progress"] as? Double else { return }
            restoreProgress(progress, in: pdfView, document: document)
        }

        private func updateProgress() {
            guard !isRestoring,
                  let pdfView = pdfView,
                  let document = pdfView.document,
                  document.pageCount > 0,
                  let currentPage = pdfView.currentPage else { return }

            let pageIndex = document.index(for: currentPage)

            let visibleRect = pdfView.convert(pdfView.bounds, to: currentPage)
            let pageBounds = currentPage.bounds(for: pdfView.displayBox)
            let pageHeight = pageBounds.height

            var fractionWithinPage: Double = 0
            if pageHeight > 0 {
                let distanceFromTop = pageBounds.maxY - visibleRect.maxY
                fractionWithinPage = min(max(Double(distanceFromTop / pageHeight), 0), 1)
            }

            let newProgress = min(max((Double(pageIndex) + fractionWithinPage) / Double(document.pageCount), 0), 1)

            if abs(newProgress - lastReportedProgress) > 0.001 {
                lastReportedProgress = newProgress
                let parent = self.parent
                DispatchQueue.main.async {
                    parent.currentPageIndex = pageIndex
                    parent.progress = newProgress
                }
            }
        }

        func restoreProgress(_ progress: Double, in pdfView: PDFView, document: PDFDocument) {
            isRestoring = true
            defer { isRestoring = false }

            let pageCount = document.pageCount
            guard pageCount > 0 else { return }

            let rawPage = progress * Double(pageCount)
            let pageIndex = min(max(Int(rawPage), 0), pageCount - 1)
            let fractionWithinPage = rawPage - Double(pageIndex)

            guard let page = document.page(at: pageIndex) else { return }

            let pageBounds = page.bounds(for: pdfView.displayBox)
            let y = pageBounds.maxY - CGFloat(fractionWithinPage) * pageBounds.height
            let point = CGPoint(x: pageBounds.minX, y: y)

            let destination = PDFDestination(page: page, at: point)
            pdfView.go(to: destination)

            lastReportedProgress = progress
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Book.self, Bookmark.self, ReadingSession.self], inMemory: true)
}
