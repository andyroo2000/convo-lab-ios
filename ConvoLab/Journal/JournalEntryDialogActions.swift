import SwiftUI

struct JournalEntryDialogActions<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { content }.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .trailing, spacing: 12) { content }
        }.frame(maxWidth: .infinity, alignment: .trailing)
    }
}
