import SwiftUI
import AVFoundation

struct ReadingReaderView: View {
    let id: String
    let store: ReadingStore
    let beforeAudio: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("reading-theme") private var themeID = "system"
    @AppStorage("reading-format") private var formatName = ReadingFormat.reflow.rawValue
    @State private var pageIndex = 0
    @State private var selectedSentence: Int?
    @State private var initialized = false
    @State private var player = ReadingAudioPlayer()
    @State private var syncTask: Task<Void, Never>?

    private var theme: ReadingTheme { .resolve(themeID, dark: colorScheme == .dark) }
    private var format: ReadingFormat { .init(rawValue: formatName) ?? .reflow }
    private var reading: ReadingDetail? { store.document(id) }

    var body: some View {
        Group {
            if let reading, reading.document.pages.indices.contains(pageIndex) {
                reader(reading)
            } else {
                VStack(spacing: 16) {
                    if let message = store.errorMessage {
                        Text(message).font(.callout)
                        Button("Try again") { Task { await openReading() } }
                    } else { ProgressView("Opening reading") }
                }.padding()
            }
        }
        .background(theme.background)
        .tint(theme.accent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(theme.background, for: .navigationBar)
        .toolbarColorScheme(theme.isDark ? .dark : .light, for: .navigationBar)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { controls } }
        .task { await openReading() }
        .onDisappear { finish() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if type == AVAudioSession.InterruptionType.began.rawValue { player.stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { player.stop() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { finish() }
        }
        .alert("Audio unavailable", isPresented: Binding(get: { player.errorMessage != nil }, set: { if !$0 { player.errorMessage = nil } })) {
            Button("OK", role: .cancel) { player.errorMessage = nil }
        } message: { Text(player.errorMessage ?? "") }
    }

    private func reader(_ reading: ReadingDetail) -> some View {
        VStack(spacing: 0) {
            if player.preparing { ProgressView().controlSize(.mini).accessibilityLabel("Preparing narration") }
            ReadingWebView(reading: reading, pageIndex: pageIndex, format: format, theme: theme,
                           selectedSentence: selectedSentence, store: store) { event, index in
                guard reading.document.pages[pageIndex].sentenceIndices.contains(index) else { return }
                if event == "play" {
                    player.play(reading: reading, sentence: index, store: store, beforeAudio: beforeAudio)
                } else {
                    selectedSentence = index
                    record(reading)
                }
            }
            .simultaneousGesture(DragGesture(minimumDistance: 65).onEnded { gesture in
                guard format != .original,
                      abs(gesture.translation.width) > abs(gesture.translation.height) * 2 else { return }
                movePage(gesture.translation.width < 0 ? 1 : -1)
            })
            if let message = store.errorMessage {
                ReadingErrorNotice(message: message) { store.errorMessage = nil }
                    .foregroundStyle(theme.foreground)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 4) {
            pagePicker
            Menu {
                Picker("Reading format", selection: $formatName) {
                    ForEach(ReadingFormat.allCases) { format in Label(format.rawValue, systemImage: format.icon).tag(format.rawValue) }
                }
            } label: { Image(systemName: format.icon).frame(width: 40, height: 44) }
                .accessibilityLabel("Format: \(format.rawValue)")
            Menu {
                Button("Use device theme") { themeID = "system" }
                Section("Light") { themeOptions(dark: false) }
                Section("Dark") { themeOptions(dark: true) }
            } label: { Image(systemName: "circle.lefthalf.filled").frame(width: 40, height: 44) }
                .accessibilityLabel("Theme: \(theme.name)")
        }
    }

    private var pagePicker: some View {
        Menu {
            if let reading {
                Button("Previous page") { movePage(-1) }.disabled(pageIndex == 0)
                Button("Next page") { movePage(1) }.disabled(pageIndex >= reading.document.pages.count - 1)
                Divider()
                ForEach(Array(reading.document.pages.enumerated()), id: \.element.number) { index, page in
                    Button("Page \(page.number)") { changePage(index) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(pageNumber.map(String.init) ?? "—").monospacedDigit()
                Image(systemName: "chevron.down").font(.caption2)
            }.frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("Page \(pageNumber ?? 0), choose page")
    }

    private var pageNumber: Int? {
        guard let reading, reading.document.pages.indices.contains(pageIndex) else { return nil }
        return reading.document.pages[pageIndex].number
    }

    private func themeOptions(dark: Bool) -> some View {
        ForEach(ReadingTheme.all.filter { $0.isDark == dark }) { option in
            Button { themeID = option.id } label: {
                Label(option.name, systemImage: option.id == theme.id ? "checkmark" : "circle")
            }
        }
    }

    private func openReading() async {
        restorePosition()
        await store.loadDocument(id)
        if let reading, !reading.document.pages.indices.contains(pageIndex) {
            pageIndex = 0
            selectedSentence = nil
        }
        guard !initialized else { return }
        restorePosition()
        if reading != nil { initialized = true }
    }

    private func restorePosition() {
        guard !initialized, let reading, !reading.document.pages.isEmpty else { return }
        let position = store.position(id)
        pageIndex = reading.document.pages.firstIndex { $0.number == position?.pageNumber } ?? 0
        selectedSentence = position?.sentenceIndex
        if !reading.document.pages[pageIndex].sentenceIndices.contains(selectedSentence ?? -1) { selectedSentence = nil }
    }

    private func movePage(_ offset: Int) { changePage(pageIndex + offset) }

    private func changePage(_ index: Int) {
        guard let reading, reading.document.pages.indices.contains(index) else { return }
        player.stop()
        pageIndex = index
        selectedSentence = nil
        record(reading)
    }

    private func record(_ reading: ReadingDetail) {
        initialized = true
        store.record(reading, pageNumber: reading.document.pages[pageIndex].number, sentence: selectedSentence)
        syncTask?.cancel()
        syncTask = Task {
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            await store.synchronizePositions()
        }
    }

    private func finish() {
        player.stop()
        syncTask?.cancel()
        Task { await store.synchronizePositions() }
    }
}
