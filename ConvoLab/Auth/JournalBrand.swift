import SwiftUI

enum JournalBrandStyle {
    static let green = Color(red: 96 / 255, green: 176 / 255, blue: 72 / 255)
    static let yellow = Color(red: 255 / 255, green: 242 / 255, blue: 156 / 255)
    static let spine = Color(red: 64 / 255, green: 124 / 255, blue: 53 / 255)
    static let blue = Color(red: 53 / 255, green: 110 / 255, blue: 220 / 255)
    static let ink = Color(white: 0.14)
}

struct JournalBrandView: View {
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("CONVO-LAB")
                .font(.custom("Anton-Regular", size: compact ? 24 : 38))
                .tracking(compact ? -0.4 : -0.6)
                .foregroundStyle(JournalBrandStyle.yellow)
                .frame(height: compact ? 25 : 40)
            Text("コンボ・ラボ")
                .font(.custom("NotoSansJP-Thin_Black", size: compact ? 11 : 27))
                .tracking(compact ? -0.5 : -1.8)
                .frame(height: compact ? 14 : 33)
                .padding(.top, compact ? 3 : 12)
            if !compact {
                Text("JOURNAL")
                    .font(.custom("BarlowCondensed-ExtraBold", size: 18))
                    .tracking(5)
                    .padding(.top, 22)
                Text("ジャーナル")
                    .font(.custom("NotoSansJP-Thin_Bold", size: 12))
                    .tracking(2.5)
                    .padding(.top, 7)
            }
        }
        .foregroundStyle(.white)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("ConvoLab Journal")
    }
}

struct JournalAuthHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.custom("Nunito-Black", size: 32, relativeTo: .largeTitle))
            .tracking(-1)
            .accessibilityAddTraits(.isHeader)
    }
}

struct JournalAuthField<Content: View>: View {
    let title: String
    var onReset: (() -> Void)? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.custom("Inter-Regular", size: 12, relativeTo: .caption))
                Spacer()
                if let onReset {
                    Button("Forgot password?", action: onReset)
                        .font(.custom("Inter-Regular", size: 11, relativeTo: .caption))
                        .underline()
                        .foregroundStyle(JournalBrandStyle.blue)
                        .frame(minHeight: 44)
                }
            }
            content
                .font(.custom("Inter-Regular", size: 16, relativeTo: .body))
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(.white, in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color(white: 0.74)))
        }
    }
}

struct JournalAuthSubmitStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom("Inter-Regular_SemiBold", size: 13, relativeTo: .body))
            .padding(.horizontal, 22)
            .frame(minHeight: 44)
            .foregroundStyle(.white)
            .background(JournalBrandStyle.blue, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.5)
    }
}

struct JournalAuthError: View {
    let message: String?

    var body: some View {
        if let message {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .accessibilityIdentifier("auth-error")
        }
    }
}

struct JournalAuthScreen<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                Group {
                    if geometry.size.width >= 740 {
                        HStack(spacing: 40) {
                            JournalBrandView().frame(maxWidth: .infinity, alignment: .leading)
                            panel.frame(width: 390)
                        }
                        .padding(54)
                        .frame(minHeight: geometry.size.height)
                    } else {
                        VStack(alignment: .leading, spacing: 32) {
                            JournalBrandView().padding(.horizontal, 8)
                            panel
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 32)
                        .frame(maxWidth: 438)
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background {
                JournalBrandStyle.green.overlay {
                UnevenRoundedRectangle(topLeadingRadius: 26, bottomLeadingRadius: 3,
                                       bottomTrailingRadius: 26, topTrailingRadius: 3)
                    .stroke(Color(red: 239 / 255, green: 243 / 255, blue: 199 / 255).opacity(0.55), lineWidth: 2)
                    .padding(8)
                    .allowsHitTesting(false)
                }
            }
        }
        .background(JournalBrandStyle.green.ignoresSafeArea())
        .foregroundStyle(JournalBrandStyle.ink)
        .font(.custom("Inter-Regular", size: 14, relativeTo: .body))
        .tint(JournalBrandStyle.blue)
        .preferredColorScheme(.light)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 22) { content }
            .padding(.horizontal, 24)
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 4))
    }
}

