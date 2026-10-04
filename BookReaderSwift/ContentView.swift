import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import PDFKit
import Compression

extension Notification.Name {
    static let openBookRequested = Notification.Name("openBookRequested")
    static let increaseFontSizeRequested = Notification.Name("increaseFontSizeRequested")
    static let decreaseFontSizeRequested = Notification.Name("decreaseFontSizeRequested")
    static let focusSearchRequested = Notification.Name("focusSearchRequested")
}

enum BookFormat: String, Codable {
    case text
    case markdown
    case pdf
    case epub
}

struct ZipEntry {
    let name: String
    let compressionMethod: UInt16
    let compressedSize: UInt32
    let uncompressedSize: UInt32
    let localHeaderOffset: UInt32
}

enum ZipArchiveError: Error {
    case invalidArchive
    case entryNotFound
    case decompressionFailed
}

struct ZipArchive {
    private let data: Data
    private let entries: [String: ZipEntry]

    init(data: Data) throws {
        self.data = data
        self.entries = try ZipArchive.parseCentralDirectory(data: data)
    }

    func contains(_ path: String) -> Bool {
        entries[path] != nil
    }

    func fileNames() -> [String] {
        Array(entries.keys)
    }

    func data(for path: String) throws -> Data {
        guard let entry = entries[path] else {
            throw ZipArchiveError.entryNotFound
        }
        return try extract(entry)
    }

    private static func parseCentralDirectory(data: Data) throws -> [String: ZipEntry] {
        guard let eocdOffset = findEndOfCentralDirectory(data: data) else {
            throw ZipArchiveError.invalidArchive
        }

        let eocd = data[eocdOffset...]
        let centralDirOffset = eocd.readUInt32(at: 16)
        let entryCount = eocd.readUInt16(at: 10)

        var entries: [String: ZipEntry] = [:]
        var cursor = Int(centralDirOffset)

        for _ in 0..<entryCount {
            guard cursor + 46 <= data.count else { break }
            let header = data[cursor...]
            guard header.readUInt32(at: 0) == 0x02014b50 else { break }

            let compressionMethod = header.readUInt16(at: 10)
            let compressedSize = header.readUInt32(at: 20)
            let uncompressedSize = header.readUInt32(at: 24)
            let nameLength = Int(header.readUInt16(at: 28))
            let extraLength = Int(header.readUInt16(at: 30))
            let commentLength = Int(header.readUInt16(at: 32))
            let localHeaderOffset = header.readUInt32(at: 42)

            let nameStart = cursor + 46
            guard nameStart + nameLength <= data.count else { break }
            let nameData = data[nameStart..<(nameStart + nameLength)]
            let name = String(data: nameData, encoding: .utf8) ?? ""

            entries[name] = ZipEntry(
                name: name,
                compressionMethod: compressionMethod,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset
            )

            cursor = nameStart + nameLength + extraLength + commentLength
        }

        return entries
    }

    private static func findEndOfCentralDirectory(data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let signature: [UInt8] = [0x50, 0x4b, 0x05, 0x06]
        let searchFloor = max(0, data.count - 65557)
        var i = data.count - 4

        while i >= searchFloor {
            if data[i] == signature[0], data[i + 1] == signature[1],
               data[i + 2] == signature[2], data[i + 3] == signature[3] {
                return i
            }
            i -= 1
        }
        return nil
    }

    private func extract(_ entry: ZipEntry) throws -> Data {
        guard Int(entry.localHeaderOffset) + 30 <= data.count else {
            throw ZipArchiveError.invalidArchive
        }

        let localHeader = data[Int(entry.localHeaderOffset)...]
        guard localHeader.readUInt32(at: 0) == 0x04034b50 else {
            throw ZipArchiveError.invalidArchive
        }

        let nameLength = Int(localHeader.readUInt16(at: 26))
        let extraLength = Int(localHeader.readUInt16(at: 28))
        let dataStart = Int(entry.localHeaderOffset) + 30 + nameLength + extraLength
        let dataEnd = dataStart + Int(entry.compressedSize)

        guard dataEnd <= data.count else { throw ZipArchiveError.invalidArchive }
        let compressedData = data[dataStart..<dataEnd]

        switch entry.compressionMethod {
        case 0:
            return Data(compressedData)
        case 8:
            return try inflate(compressedData, uncompressedSize: Int(entry.uncompressedSize))
        default:
            throw ZipArchiveError.decompressionFailed
        }
    }

    private func inflate(_ compressed: Data, uncompressedSize: Int) throws -> Data {
        guard uncompressedSize > 0 else { return Data() }

        var result = Data(count: uncompressedSize)
        let decodedCount = result.withUnsafeMutableBytes { destBuffer -> Int in
            compressed.withUnsafeBytes { srcBuffer -> Int in
                guard let destPointer = destBuffer.bindMemory(to: UInt8.self).baseAddress,
                      let srcPointer = srcBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    destPointer, uncompressedSize,
                    srcPointer, compressed.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }

        guard decodedCount == uncompressedSize else {
            throw ZipArchiveError.decompressionFailed
        }

        return result
    }
}

private extension Data {
    func readUInt16(at offset: Int) -> UInt16 {
        let start = self.startIndex + offset
        return UInt16(self[start]) | (UInt16(self[start + 1]) << 8)
    }

    func readUInt32(at offset: Int) -> UInt32 {
        let start = self.startIndex + offset
        var value: UInt32 = 0
        for i in 0..<4 {
            value |= UInt32(self[start + i]) << (8 * i)
        }
        return value
    }
}

struct EPUBDocument {
    let title: String
    let content: String
}

enum EPUBParserError: Error {
    case missingContainer
    case missingOPF
    case invalidStructure
}

struct EPUBParser {
    static func parse(data: Data) throws -> EPUBDocument {
        let archive = try ZipArchive(data: data)

        guard archive.contains("META-INF/container.xml") else {
            throw EPUBParserError.missingContainer
        }
        let containerData = try archive.data(for: "META-INF/container.xml")

        guard let opfPath = extractOPFPath(from: containerData) else {
            throw EPUBParserError.missingOPF
        }

        let opfData = try archive.data(for: opfPath)
        let basePath = (opfPath as NSString).deletingLastPathComponent

        let (manifest, spineOrder, parsedTitle) = parseOPF(data: opfData)

        var combinedText = ""
        for itemID in spineOrder {
            guard let href = manifest[itemID] else { continue }
            let fullPath = basePath.isEmpty ? href : "\(basePath)/\(href)"

            guard let chapterData = try? archive.data(for: fullPath),
                  let html = String(data: chapterData, encoding: .utf8) else { continue }

            combinedText += htmlToPlainText(html) + "\n\n"
        }

        let trimmed = combinedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EPUBParserError.invalidStructure }

        return EPUBDocument(title: parsedTitle ?? "Без названия", content: trimmed)
    }

    private static func extractOPFPath(from data: Data) -> String? {
        let delegate = ContainerXMLDelegate()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = delegate
        xmlParser.parse()
        return delegate.opfPath
    }

    private static func parseOPF(data: Data) -> (manifest: [String: String], spine: [String], title: String?) {
        let delegate = OPFXMLDelegate()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = delegate
        xmlParser.parse()
        return (delegate.manifest, delegate.spineOrder, delegate.title)
    }

    private static func htmlToPlainText(_ html: String) -> String {
        var text = html

        let blockTags = [
            "</p>", "<br>", "<br/>", "<br />",
            "</div>", "</li>",
            "</h1>", "</h2>", "</h3>", "</h4>", "</h5>", "</h6>"
        ]
        for tag in blockTags {
            text = text.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }

        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        let entities: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#39;": "'", "&nbsp;": " "
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }

        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class ContainerXMLDelegate: NSObject, XMLParserDelegate {
    var opfPath: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        if elementName == "rootfile" {
            opfPath = attributeDict["full-path"]
        }
    }
}

private final class OPFXMLDelegate: NSObject, XMLParserDelegate {
    var manifest: [String: String] = [:]
    var spineOrder: [String] = []
    var title: String?

    private var isInsideTitle = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        let tag = stripNamespace(elementName)

        switch tag {
        case "item":
            if let id = attributeDict["id"], let href = attributeDict["href"] {
                manifest[id] = href
            }
        case "itemref":
            if let idref = attributeDict["idref"] {
                spineOrder.append(idref)
            }
        case "title":
            isInsideTitle = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard isInsideTitle else { return }
        title = (title ?? "") + string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard stripNamespace(elementName) == "title" else { return }
        isInsideTitle = false
        title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stripNamespace(_ name: String) -> String {
        guard let colonRange = name.range(of: ":") else { return name }
        return String(name[colonRange.upperBound...])
    }
}

@Model
final class Book {
    var title: String
    var content: String
    var dateAdded: Date
    var fileExtension: String
    var formatRawValue: String
    var pdfData: Data?
    var epubData: Data?

    @Relationship(deleteRule: .cascade)
    var readingSession: ReadingSession?

    var format: BookFormat {
        get { BookFormat(rawValue: formatRawValue) ?? .text }
        set { formatRawValue = newValue.rawValue }
    }

    init(
        title: String,
        content: String,
        fileExtension: String,
        format: BookFormat,
        pdfData: Data? = nil,
        epubData: Data? = nil
    ) {
        self.title = title
        self.content = content
        self.dateAdded = .now
        self.fileExtension = fileExtension
        self.formatRawValue = format.rawValue
        self.pdfData = pdfData
        self.epubData = epubData
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
    
    var colorScheme: ColorScheme {
        switch self {
        case .light, .sepia: .light
        case .dark: .dark
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

struct PDFKitView: NSViewRepresentable {
    let data: Data
    let initialProgress: Double
    let onPageChanged: (Int, Int) -> Void

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        let document = PDFDocument(data: data)
        view.document = document

        if let document, document.pageCount > 0, initialProgress > 0 {
            let targetIndex = Int(initialProgress * Double(document.pageCount - 1))
            if let page = document.page(at: targetIndex) {
                view.go(to: page)
            }
        }

        context.coordinator.pdfView = view
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged),
            name: .PDFViewPageChanged,
            object: view
        )

        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPageChanged: onPageChanged)
    }

    final class Coordinator: NSObject {
        weak var pdfView: PDFView?
        let onPageChanged: (Int, Int) -> Void

        init(onPageChanged: @escaping (Int, Int) -> Void) {
            self.onPageChanged = onPageChanged
        }

        @objc func pageChanged() {
            guard let pdfView, let page = pdfView.currentPage,
                  let document = pdfView.document else { return }
            onPageChanged(document.index(for: page), document.pageCount)
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

struct BookmarkRow: View {
    let bookmark: Bookmark
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 2) {
                Text(bookmark.book?.title ?? "Неизвестная книга")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(bookmark.snippet)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering ? Color.primary.opacity(0.06) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}

struct ToolbarIconButton: View {
    let systemName: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .foregroundStyle(.primary)
                .opacity(isHovering ? 1.0 : 0.65)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}

struct ReaderToolbarContent: ToolbarContent {
    let onClose: () -> Void
    @Binding var isFocusMode: Bool
    let onAddBookmark: () -> Void
    @Binding var themeRawValue: String
    @Binding var fontRawValue: String
    let themeIcon: String
    @Binding var fontSize: Double
    let showsTextControls: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button(action: onClose) {
                Label("К библиотеке", systemImage: "chevron.left")
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            ToolbarIconButton(
                systemName: isFocusMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
            ) {
                isFocusMode.toggle()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])

            ToolbarIconButton(systemName: "bookmark", action: onAddBookmark)

            if showsTextControls {
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
                    Image(systemName: themeIcon)
                }

                ToolbarIconButton(systemName: "textformat.size.smaller") {
                    fontSize = max(13, fontSize - 1)
                }
                .disabled(fontSize <= 13)

                ToolbarIconButton(systemName: "textformat.size.larger") {
                    fontSize = min(28, fontSize + 1)
                }
                .disabled(fontSize >= 28)
            }
        }
    }
}

struct EmptyLibraryView: View {
    let errorMessage: String?
    let onOpenBook: () -> Void

    var body: some View {
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

            Button(action: onOpenBook) {
                Label("Открыть книгу", systemImage: "folder")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 8)
        }
    }
}

struct LibraryGridView: View {
    let books: [Book]
    let onSelect: (Book) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 20)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 28) {
                ForEach(books) { book in
                    LibraryBookCell(book: book) {
                        onSelect(book)
                    }
                }
            }
            .padding(32)
        }
        .scrollIndicators(.hidden)
    }
}

struct LibrarySectionView: View {
    let count: Int

    var body: some View {
        Section("Моя коллекция") {
            Label {
                HStack {
                    Text("Библиотека")
                    Spacer()
                    Text("\(count)")
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
    }
}

struct BookmarksSectionView: View {
    let bookmarks: [Bookmark]
    let onOpen: (Bookmark) -> Void
    let onDelete: (Bookmark) -> Void

    var body: some View {
        if !bookmarks.isEmpty {
            Section("Закладки") {
                ForEach(bookmarks) { bookmark in
                    BookmarkRow(bookmark: bookmark) {
                        onOpen(bookmark)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            onDelete(bookmark)
                        } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }
}

struct ReaderView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var book: Book
    var initialScrollOverride: Double?
    @Binding var isFocusMode: Bool
    let onClose: () -> Void

    @AppStorage("readingTheme") private var themeRawValue: String = ReadingTheme.light.rawValue
    @AppStorage("readingFont") private var fontRawValue: String = ReadingFont.serif.rawValue

    @State private var fontSize: Double = 17
    @State private var scrollProgress: Double = 0
    @State private var scrollPosition = ScrollPosition()
    @State private var hasRestoredPosition = false

    @State private var searchText = ""
    @State private var isSearching = false
    @State private var currentMatchIndex = 0
    @State private var lastScrollGeometry: ScrollGeometry?
    @State private var isHoveringTop = false

    private var theme: ReadingTheme {
        ReadingTheme(rawValue: themeRawValue) ?? .light
    }

    private var font: ReadingFont {
        ReadingFont(rawValue: fontRawValue) ?? .serif
    }

    private var searchMatches: [Range<String.Index>] {
        guard !searchText.isEmpty else { return [] }
        var matches: [Range<String.Index>] = []
        var searchStart = book.content.startIndex
        while let range = book.content.range(
            of: searchText,
            options: .caseInsensitive,
            range: searchStart..<book.content.endIndex
        ) {
            matches.append(range)
            searchStart = range.upperBound
        }
        return matches
    }

    private var attributedContent: AttributedString {
        var attributed = AttributedString(book.content)

        guard !searchMatches.isEmpty else { return attributed }

        for (index, range) in searchMatches.enumerated() {
            guard let attrRange = Range<AttributedString.Index>(range, in: attributed) else { continue }
            attributed[attrRange].backgroundColor = index == currentMatchIndex
                ? Color.orange.opacity(0.6)
                : Color.yellow.opacity(0.35)
        }

        return attributed
    }

    var body: some View {
        Group {
            if book.format == .pdf {
                pdfReaderBody
            } else {
                textReaderBody
            }
        }
        .preferredColorScheme(theme.colorScheme)
        .onReceive(NotificationCenter.default.publisher(for: .increaseFontSizeRequested)) { _ in
            fontSize = min(28, fontSize + 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .decreaseFontSizeRequested)) { _ in
            fontSize = max(13, fontSize - 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearchRequested)) { _ in
            if book.format != .pdf {
                isSearching = true
            }
        }
        .toolbar {
            ReaderToolbarContent(
                onClose: onClose,
                isFocusMode: $isFocusMode,
                onAddBookmark: addBookmark,
                themeRawValue: $themeRawValue,
                fontRawValue: $fontRawValue,
                themeIcon: theme.iconName,
                fontSize: $fontSize,
                showsTextControls: book.format != .pdf
            )
        }
    }

    private var pdfReaderBody: some View {
        ZStack(alignment: .top) {
            if let pdfData = book.pdfData {
                PDFKitView(
                    data: pdfData,
                    initialProgress: initialScrollOverride ?? book.readingSession?.scrollOffset ?? 0
                ) { page, pageCount in
                    savePDFProgress(page: page, pageCount: pageCount)
                }
            }

            focusModeOverlay
        }
    }

    private var textReaderBody: some View {
        ZStack(alignment: .top) {
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

                        Text(attributedContent)
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

            focusModeOverlay
        }
        .searchable(text: $searchText, isPresented: $isSearching, placement: .toolbar, prompt: "Поиск по книге")
        .safeAreaInset(edge: .bottom) {
            if !searchText.isEmpty {
                searchResultsBar
            }
        }
        .onChange(of: searchText) {
            currentMatchIndex = 0
            scrollToCurrentMatch()
        }
    }

    @ViewBuilder
    private var focusModeOverlay: some View {
        if isFocusMode {
            Color.clear
                .frame(height: 40)
                .contentShape(Rectangle())
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isHoveringTop = hovering
                    }
                }

            if isHoveringTop {
                HStack {
                    Spacer()
                    Button {
                        isFocusMode = false
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .foregroundStyle(.primary)
                            .padding(10)
                            .background(.thinMaterial, in: Circle())
                            .overlay(
                                Circle().strokeBorder(.primary.opacity(0.1), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 12)
                    .padding(.trailing, 16)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var searchResultsBar: some View {
        HStack {
            if searchMatches.isEmpty {
                Text("Ничего не найдено")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(currentMatchIndex + 1) из \(searchMatches.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    goToMatch(offset: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(searchMatches.count < 2)

                Button {
                    goToMatch(offset: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(searchMatches.count < 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    private func goToMatch(offset: Int) {
        guard !searchMatches.isEmpty else { return }
        let count = searchMatches.count
        currentMatchIndex = ((currentMatchIndex + offset) % count + count) % count
        scrollToCurrentMatch()
    }

    private func scrollToCurrentMatch() {
        guard let geometry = lastScrollGeometry, !searchMatches.isEmpty else { return }
        let maxOffset = geometry.contentSize.height - geometry.containerSize.height
        guard maxOffset > 0 else { return }

        let range = searchMatches[currentMatchIndex]
        let offset = book.content.distance(from: book.content.startIndex, to: range.lowerBound)
        let progress = Double(offset) / Double(book.content.count)

        scrollPosition.scrollTo(y: progress * maxOffset)
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

    private func savePDFProgress(page: Int, pageCount: Int) {
        guard pageCount > 0 else { return }
        let progress = Double(page) / Double(max(pageCount - 1, 1))

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
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var isFocusMode = false
    
    private var markdownType: UTType {
        UTType(filenameExtension: "md") ?? .plainText
    }
    
    private var epubType: UTType {
        UTType(filenameExtension: "epub") ?? UTType(importedAs: "org.idpf.epub-container")
    }

    private let gridColumns = [
        GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 20)
    ]

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarView
        } detail: {
            Group {
                if let currentBook {
                    ReaderView(
                        book: currentBook,
                        initialScrollOverride: pendingScrollTarget,
                        isFocusMode: $isFocusMode
                    ) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            self.currentBook = nil
                            self.pendingScrollTarget = nil
                        }
                    }
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.98)),
                        removal: .opacity
                    ))
                } else {
                    libraryView
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: currentBook)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isImporting = true
                    } label: {
                        Label("Открыть книгу", systemImage: "folder")
                    }
                }
            }
        }
        .toolbar(isFocusMode ? .hidden : .automatic, for: .windowToolbar)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.plainText, markdownType, .pdf, epubType],
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
        .onReceive(NotificationCenter.default.publisher(for: .openBookRequested)) { _ in
            isImporting = true
        }
        .onChange(of: isFocusMode) { _, newValue in
            withAnimation(.easeInOut(duration: 0.25)) {
                columnVisibility = newValue ? .detailOnly : .automatic
            }
        }
    }

    private var sidebarView: some View {
        List(selection: $sidebarSelection) {
            LibrarySectionView(count: books.count)

            BookmarksSectionView(bookmarks: bookmarks) { bookmark in
                openBookmark(bookmark)
            } onDelete: { bookmark in
                deleteBookmark(bookmark)
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        .listStyle(.sidebar)
    }
    
    private var libraryView: some View {
        Group {
            if books.isEmpty {
                EmptyLibraryView(errorMessage: errorMessage) {
                    isImporting = true
                }
            } else {
                LibraryGridView(books: books) { book in
                    withAnimation(.easeInOut(duration: 0.25)) {
                        currentBook = book
                    }
                }
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

        let fileExtension = url.pathExtension.lowercased()
        let title = url.deletingPathExtension().lastPathComponent

        switch fileExtension {
        case "pdf":
            importPDF(from: url, title: title)
        case "epub":
            importEPUB(from: url, title: title)
        default:
            importPlainText(from: url, title: title, fileExtension: fileExtension)
        }
    }
    
    private func importPlainText(from url: URL, title: String, fileExtension: String) {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let format: BookFormat = fileExtension == "md" ? .markdown : .text
            let book = Book(title: title, content: content, fileExtension: fileExtension, format: format)
            modelContext.insert(book)
            currentBook = book
            errorMessage = nil
        } catch {
            errorMessage = "Файл повреждён или имеет неподдерживаемую кодировку."
        }
    }

    private func importPDF(from url: URL, title: String) {
        do {
            let data = try Data(contentsOf: url)
            let book = Book(title: title, content: "", fileExtension: "pdf", format: .pdf, pdfData: data)
            modelContext.insert(book)
            currentBook = book
            errorMessage = nil
        } catch {
            errorMessage = "Не удалось прочитать PDF-файл."
        }
    }
    
    private func importEPUB(from url: URL, title: String) {
        do {
            let rawData = try Data(contentsOf: url)
            let document = try EPUBParser.parse(data: rawData)

            let resolvedTitle = document.title.isEmpty || document.title == "Без названия"
                ? title
                : document.title

            let book = Book(
                title: resolvedTitle,
                content: document.content,
                fileExtension: "epub",
                format: .epub,
                epubData: rawData
            )
            modelContext.insert(book)
            currentBook = book
            errorMessage = nil
        } catch {
            errorMessage = "Не удалось разобрать EPUB-файл. Возможно, он повреждён или использует нестандартную структуру."
        }
    }
    
    private func openBookmark(_ bookmark: Bookmark) {
        guard let book = bookmark.book else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            pendingScrollTarget = bookmark.scrollOffset
            currentBook = book
        }
    }
    
    private func deleteBookmark(_ bookmark: Bookmark) {
        modelContext.delete(bookmark)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Book.self, ReadingSession.self, Bookmark.self], inMemory: true)
}
