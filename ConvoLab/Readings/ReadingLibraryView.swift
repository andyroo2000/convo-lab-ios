import SwiftUI

struct ReadingLibraryView: View {
    @State private var store: ReadingStore
    let beforeAudio: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    init(api: APIClient, userID: Int, beforeAudio: @escaping () -> Void) {
        _store = State(initialValue: ReadingStore(api: api, userID: userID))
        self.beforeAudio = beforeAudio
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let resume = store.resume { continueCard(resume) }
                    librarySection
                    if let message = store.errorMessage {
                        ReadingErrorNotice(message: message) { store.errorMessage = nil }
                    }
                }
                .padding(20)
            }
            .foregroundStyle(ConvoLabTheme.navy)
            .paperBackground()
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await store.loadLibrary() }
            .task { await store.loadLibrary() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await store.loadLibrary() } }
            }
        }
    }

    private func continueCard(_ reading: ReadingContinue) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Continue").font(.headline).foregroundStyle(.secondary)
            NavigationLink {
                ReadingReaderView(id: reading.id, store: store, beforeAudio: beforeAudio)
            } label: {
                HStack(spacing: 16) {
                    Image(systemName: "bookmark.fill").font(.title2).foregroundStyle(ConvoLabTheme.coral)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(reading.title).font(.title3.weight(.semibold))
                        Text("Page \(reading.position.pageNumber)").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .padding(20)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 20))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("reading-continue")
        }
    }

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Library").font(.title2.bold())
                Spacer()
                if store.isLoading { ProgressView() }
                Button { Task { await store.loadLibrary() } } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Refresh readings")
            }
            if let library = store.library {
                ForEach(library.data) { item in libraryRow(item) }
                if library.data.isEmpty {
                    ContentUnavailableView("Your readings will appear here", systemImage: "books.vertical", description: Text("Your books and readings will be kept together here."))
                }
                if library.lastPage > 1 { pagination(library) }
            } else if !store.isLoading {
                Button("Try again") { Task { await store.loadLibrary() } }
            }
        }
    }

    private func libraryRow(_ item: ReadingLibraryItem) -> some View {
        NavigationLink {
            if item.isBook {
                ReadingBookView(id: item.id, store: store, beforeAudio: beforeAudio)
            } else {
                ReadingReaderView(id: item.id, store: store, beforeAudio: beforeAudio)
            }
        } label: {
            HStack(spacing: 16) {
                Image(systemName: item.isBook ? "books.vertical" : "doc.text")
                    .font(.title2).frame(width: 32).foregroundStyle(ConvoLabTheme.navy)
                Text(item.title).font(.headline).multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("reading-library-\(item.id)")
        .accessibilityHint(item.isBook ? "Opens contents" : "Opens reading")
    }

    private func pagination(_ library: ReadingLibraryPage) -> some View {
        HStack {
            Button("Previous") { Task { await store.loadLibrary(page: library.currentPage - 1) } }
                .disabled(library.currentPage <= 1 || store.isLoading)
            Spacer()
            Text("\(library.currentPage) / \(library.lastPage)").font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Button("Next") { Task { await store.loadLibrary(page: library.currentPage + 1) } }
                .disabled(library.currentPage >= library.lastPage || store.isLoading)
        }
        .frame(minHeight: 44)
    }
}

struct ReadingErrorNotice: View {
    let message: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top) {
            Label(message, systemImage: "exclamationmark.circle").font(.footnote)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                .accessibilityLabel("Dismiss message")
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
