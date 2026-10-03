import SwiftUI

/// A drawn enclosure around the actual guest display. Controls use the
/// same press/release events as the regular control bar.
struct ClassicIPodCase<Display: View>: View {
    let width: CGFloat
    let onEvent: (InputEvent) -> Void
    @ViewBuilder let display: (CGSize) -> Display

    var body: some View {
        let screenSize = CGSize(width: width * 0.846, height: width * 0.846 * 1.5)
        ZStack {
            RoundedRectangle(cornerRadius: width * 0.20, style: .continuous)
                .fill(LinearGradient(colors: [.white, Color(white: 0.38), Color(white: 0.9), Color(white: 0.32), .white], startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: .black.opacity(0.4), radius: 12, y: 5)
            RoundedRectangle(cornerRadius: width * 0.19, style: .continuous)
                .fill(.black)
                .padding(width * 0.011)
                .overlay {
                    RoundedRectangle(cornerRadius: width * 0.19, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.20), lineWidth: 1)
                        .padding(width * 0.016)
                }
                .allowsHitTesting(false)
            // Front camera and the small glass highlight above the display.
            Circle()
                .fill(RadialGradient(colors: [Color(red: 0.05, green: 0.18, blue: 0.32), .black], center: .center, startRadius: 0, endRadius: width * 0.018))
                .frame(width: width * 0.035, height: width * 0.035)
                .overlay(Circle().strokeBorder(Color(white: 0.14), lineWidth: 1))
                .position(x: width / 2, y: width * 0.115)
                .allowsHitTesting(false)
            display(screenSize)
                .frame(width: screenSize.width, height: screenSize.height)
                .clipped()
                .overlay(Rectangle().strokeBorder(Color(white: 0.16), lineWidth: 1).allowsHitTesting(false))
                .position(x: width / 2, y: width * 0.23 + screenSize.height / 2)
            physicalButton("Home", event: { .homeButton(pressed: $0) }) {
                Circle()
                    .fill(LinearGradient(colors: [.black, Color(white: 0.15)], startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().strokeBorder(Color(white: 0.22), lineWidth: 1))
                    .overlay {
                        RoundedRectangle(cornerRadius: width * 0.009)
                            .strokeBorder(Color(white: 0.48), lineWidth: 1.5)
                            .frame(width: width * 0.048, height: width * 0.048)
                    }
                    .frame(width: width * 0.145, height: width * 0.145)
            }
            .frame(width: max(44, width * 0.145), height: max(44, width * 0.145))
            .position(x: width / 2, y: width * 1.76)
            physicalButton("Sleep/Wake", event: { .powerButton(pressed: $0) }) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(colors: [.white, .gray], startPoint: .top, endPoint: .bottom))
                    .frame(width: width * 0.15, height: 4)
            }
            .frame(width: 56, height: 24)
            .position(x: width * 0.78, y: 1)
            ForEach(0..<2) { index in
                physicalButton(index == 0 ? "Volume Up" : "Volume Down", event: {
                    index == 0 ? .volumeUp(pressed: $0) : .volumeDown(pressed: $0)
                }) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(colors: [.white, .gray], startPoint: .leading, endPoint: .trailing))
                        .frame(width: 4, height: width * 0.075)
                }
                .frame(width: 24, height: 44)
                .position(x: 1, y: width * (0.40 + CGFloat(index) * 0.15))
            }
        }
        .frame(width: width, height: width * 2)
    }
    private func physicalButton<Label: View>(_ title: String, event: @escaping (Bool) -> InputEvent,
                                            @ViewBuilder label: () -> Label) -> some View {
        Button(action: {}) { label().frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle()) }
            .buttonStyle(CaseButtonStyle { onEvent(event($0)) })
            .accessibilityLabel(title)
            .accessibilityAction { onEvent(event(true)); onEvent(event(false)) }
    }
}

private struct CaseButtonStyle: ButtonStyle {
    let changed: (Bool) -> Void
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .onChange(of: configuration.isPressed) { _, pressed in changed(pressed) }
            .onDisappear { changed(false) }
    }
}
