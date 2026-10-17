import SwiftUI

struct ReadingBookView: View {
    @Environment(\.dismiss) private var dismiss
    let id: String
    let store: ReadingStore
    let beforeAudio: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            backControl
            chapters
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var backControl: some View {
        HStack {
            Button { dismiss() } label: { Label("Back", systemImage: "chevron.left") }
                .frame(minHeight: 44)
                .accessibilityIdentifier("reading-book-back")
            Spacer()
        }
        .padding(.horizontal, 16)
        .foregroundStyle(ConvoLabTheme.navy)
        .background(ConvoLabTheme.cream)
    }

    private var chapters: some View {
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
        .task { await store.loadBook(id) }
        .refreshable { await store.loadBook(id) }
    }
}
