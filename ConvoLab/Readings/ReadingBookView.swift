import SwiftUI

struct ReadingBookView: View {
    let id: String
    let store: ReadingStore
    let beforeAudio: () -> Void

    var body: some View {
        List {
            if let book = store.book(id) {
                Section {
                    ForEach(book.readings) { reading in
                        NavigationLink {
                            ReadingReaderView(id: reading.id, store: store, beforeAudio: beforeAudio)
                        } label: {
                            HStack {
                                Text(reading.title).font(.headline)
                                Spacer()
                                if let number = reading.pageNumbers?.first {
                                    Text("\(number)").foregroundStyle(.secondary).monospacedDigit()
                                        .accessibilityLabel("Page \(number)")
                                }
                            }
                            .padding(.vertical, 10)
                            .foregroundStyle(ConvoLabTheme.navy)
                        }
                        .listRowBackground(Color.white)
                    }
                } header: {
                    Text(book.title).font(.title2.bold()).textCase(nil).foregroundStyle(ConvoLabTheme.navy)
                }
                if book.readings.isEmpty {
                    ContentUnavailableView("No readings yet", systemImage: "book.closed")
                }
            } else { ProgressView() }
            if let message = store.errorMessage {
                ReadingErrorNotice(message: message) { store.errorMessage = nil }
                Button("Try again") { Task { await store.loadBook(id) } }
            }
        }
        .paperBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarColorScheme(.light, for: .navigationBar)
        .task { await store.loadBook(id) }
        .refreshable { await store.loadBook(id) }
    }
}
