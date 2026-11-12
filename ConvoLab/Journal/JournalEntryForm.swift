import SwiftUI

struct JournalEntryForm: View {
    let model: JournalEntryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Untitled entry", text: binding(\.title, fallback: ""))
                .font(.title.bold()).accessibilityLabel("Title (optional)")
            DatePicker("Entry date", selection: date, displayedComponents: .date)
            TextEditor(text: bodyText)
                .font(.title3).frame(minHeight: 260)
                .scrollContentBackground(.hidden)
                .padding(8).background(.white, in: .rect(cornerRadius: 12))
                .accessibilityLabel("Journal entry")
            if model.isSavedOnDevice {
                Text("Draft saved on this device").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Save draft") { Task { await model.save(submit: false) } }.buttonStyle(.bordered)
                Spacer()
                Button("Submit") { Task { await model.save(submit: true) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.draft?.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)
            }
        }
        .disabled(model.isBusy || model.analysis?.status.isPending == true)
    }

    private var bodyText: Binding<String> {
        Binding(get: { model.draft?.body ?? "" }, set: { value in model.change { $0.body = String(value.prefix(20_000)) } })
    }

    private func binding(_ key: WritableKeyPath<JournalDraft, String?>, fallback: String) -> Binding<String> {
        Binding(get: { model.draft?[keyPath: key] ?? fallback }, set: { value in model.change { $0[keyPath: key] = value.isEmpty ? nil : String(value.prefix(255)) } })
    }

    private var date: Binding<Date> {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return Binding(get: { formatter.date(from: model.draft?.entryDate ?? "") ?? .now },
                       set: { value in model.change { $0.entryDate = formatter.string(from: value) } })
    }
}
