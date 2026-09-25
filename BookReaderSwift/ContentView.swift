import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "book.pages")
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(.tint)

            Text("SwiftBookReader")
                .font(.system(size: 32, weight: .semibold, design: .serif))

            Text("Твоя минималистичная библиотека")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

#Preview {
    ContentView()
}
