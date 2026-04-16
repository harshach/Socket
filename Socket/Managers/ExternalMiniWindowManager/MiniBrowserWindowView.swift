import SwiftUI
import AppKit

struct MiniBrowserWindowView: View {
    @Environment(\.colorScheme) private var colorScheme

    let session: MiniWindowSession
    let adoptAction: () -> Void
    let dismissAction: () -> Void

    @State private var hostingWindow: NSWindow?

    var body: some View {
        VStack(spacing: 0) {
            chromeBar
            webContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .ignoresSafeArea()
        .background(WindowAccessor { window in
            guard hostingWindow !== window else { return }
            hostingWindow = window
            window?.titlebarAppearsTransparent = true
            window?.titleVisibility = .hidden
            window?.titlebarSeparatorStyle = .none
            window?.standardWindowButton(.closeButton)?.isHidden = true
            window?.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window?.standardWindowButton(.zoomButton)?.isHidden = true
        })
        .frame(minWidth: 760, minHeight: 560)
    }

    private var chromeBar: some View {
        VStack(spacing: 0) {
            MiniWindowToolbar(
                session: session,
                adoptAction: adoptAction,
                dismissAction: dismissWindow
            )
            .padding(.top, 2)

            MiniWindowLoadingStrip(
                progress: session.estimatedProgress,
                isLoading: session.isLoading,
                isDarkToolbar: resolvedToolbarIsDark
            )
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    @ViewBuilder private var webContent: some View {
        if isRunningInPreviews {
            ZStack {
                LinearGradient(colors: [Color.black.opacity(0.08), Color.black.opacity(0.02)], startPoint: .top, endPoint: .bottom)
                VStack(spacing: 8) {
                    Image(systemName: "safari")
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(.secondary)
                    Text("Web Content Placeholder")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.clear.opacity(0.08), lineWidth: 1)
                    .padding(8)
            )
            .background(Color.blue.opacity(0.3))
        } else {
            MiniWindowWebView(session: session)
        }
    }

    private func dismissWindow() {
        if let hostingWindow {
            hostingWindow.close()
        } else {
            dismissAction()
        }
    }

    private var resolvedToolbarIsDark: Bool {
        (session.toolbarColor ?? (colorScheme == .dark ? .windowBackgroundColor : .windowBackgroundColor))
            .isPerceivedDark
    }

    private var isRunningInPreviews: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }
}

private struct MiniWindowLoadingStrip: View {
    let progress: Double
    let isLoading: Bool
    let isDarkToolbar: Bool

    @State private var displayedProgress: CGFloat = 0
    @State private var isVisible = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(trackColor)
                    .opacity(isVisible ? 1 : 0)

                Capsule(style: .continuous)
                    .fill(progressGradient)
                    .frame(width: progressWidth(for: geo.size.width))
                    .opacity(isVisible ? 1 : 0)
                    .animation(.easeOut(duration: 0.16), value: displayedProgress)
            }
        }
        .frame(height: 2.5)
        .padding(.horizontal, 8)
        .padding(.top, 1)
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.16), value: isVisible)
        .onAppear {
            syncState()
        }
        .onChange(of: progress) { _, _ in
            syncState()
        }
        .onChange(of: isLoading) { _, _ in
            syncState()
        }
    }

    private var trackColor: Color {
        isDarkToolbar ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }

    private var progressGradient: LinearGradient {
        LinearGradient(
            colors: [
                progressColor.opacity(0.95),
                progressColor.opacity(0.70),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var progressColor: Color {
        isDarkToolbar ? .white : .black
    }

    private func progressWidth(for totalWidth: CGFloat) -> CGFloat {
        guard isVisible else { return 0 }
        let scaledWidth = totalWidth * max(displayedProgress, 0.04)
        return min(totalWidth, max(12, scaledWidth))
    }

    private func syncState() {
        hideTask?.cancel()

        if isLoading {
            isVisible = true
            displayedProgress = CGFloat(min(max(progress, 0.04), 1))
            return
        }

        displayedProgress = max(displayedProgress, 1)
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            isVisible = false
            displayedProgress = 0
        }
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        DispatchQueue.main.async {
            callback(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            callback(nsView.window)
        }
    }
}

#if DEBUG
#Preview {
    // Provide a mock session for preview
    let session = MiniWindowSession(
        url: URL(string: "https://apple.com")!,
        profile: nil,
        originName: "Preview",
        currentSpaceLabel: "Preview Space",
        currentSpaceProfileName: "Default",
        availableDestinations: [
            MiniWindowSpaceDestination(id: UUID(), name: "Work", profileName: "Work", isCurrent: false),
            MiniWindowSpaceDestination(id: UUID(), name: "Research", profileName: "Default", isCurrent: false)
        ],
        alwaysUseExternalView: true,
        adoptCurrentSpaceHandler: { _ in },
        adoptDestinationHandler: { _, _ in },
        alwaysUseExternalViewHandler: { _ in }
    )
    MiniBrowserWindowView(session: session, adoptAction: {}, dismissAction: {})
        .environmentObject(GradientColorManager())
}
#endif
