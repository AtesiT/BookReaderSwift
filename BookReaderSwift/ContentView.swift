import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {

    @State private var isImporting = false
    @State private var selectedFileURL: URL?
    @State private var bookText: String?
    @State private var errorMessage: String?

    private var markdownType: UTType {
        UTType(filenameExtension: "md") ?? .plainText
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "book.pages")
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(.tint)

            Text("BookReaderSwift")
                .font(.system(size: 32, weight: .semibold, design: .serif))

            if let bookText {
                Text(bookText.prefix(200) + "…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(.horizontal, 40)
            } else if let errorMessage {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
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

    private func loadBook(from url: URL) {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            bookText = try String(contentsOf: url, encoding: .utf8)
            selectedFileURL = url
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
