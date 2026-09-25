import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {

    @State private var isImporting = false
    @State private var selectedFileURL: URL?

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

            if let selectedFileURL {
                Text(selectedFileURL.lastPathComponent)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
                selectedFileURL = urls.first
            case .failure(let error):
                print("Import failed: \(error.localizedDescription)")
            }
        }
    }
}

#Preview {
    ContentView()
}
