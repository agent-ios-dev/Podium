import SwiftUI

/// Placeholder shown before the guest framebuffer is available. Once iOS
/// starts, EmulatorScreen shows the real iBoot/iOS display, including its
/// native boot logo. Progress and time estimates belong in Podium's chrome.
struct BootProgressView: View {
    let stage: EmulatorCore.BootStage?

    var body: some View {
        ZStack {
            Color.black
            Image(systemName: "apple.logo")
                .font(.system(size: 54))
                .foregroundStyle(.white.opacity(stage == nil ? 0.25 : 0.72))
        }
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 10 { return "a few seconds" }
        if total < 60 { return "\(total) s" }
        let minutes = total / 60, rest = total % 60
        return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s"
    }
}
