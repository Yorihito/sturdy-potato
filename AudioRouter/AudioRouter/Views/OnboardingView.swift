import SwiftUI

/// First-launch onboarding screen shown in a regular window.
struct OnboardingView: View {

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            stepsList
            Spacer()
            footer
        }
        .padding(32)
        .frame(width: 500, height: 420)
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to Audio Router")
                    .font(.title)
                    .fontWeight(.bold)
                Text("Route individual apps to different audio outputs.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var stepsList: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepRow(
                number: 1,
                icon: "arrow.triangle.branch",
                title: "Per-app routing",
                description: "Assign any running application to a specific speaker, headphones, or HDMI display."
            )
            stepRow(
                number: 2,
                icon: "lock.shield",
                title: "Driver installation requires admin privileges",
                description: "The AudioServerPlugin virtual device needs to be installed in /Library/Audio/Plug-Ins/HAL. You will be prompted for your password."
            )
            stepRow(
                number: 3,
                icon: "bookmark",
                title: "Save routing profiles",
                description: "Snapshot your current setup as a named profile and apply it with one click."
            )
        }
    }

    private func stepRow(number: Int, icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.semibold)
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Get Started") {
                UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
                NSApp.keyWindow?.close()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
    }
}

#if DEBUG
#Preview {
    OnboardingView()
}
#endif
