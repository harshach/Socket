//
//  URLBarLoadingStrip.swift
//  Socket
//
//  Created by Codex on 14/04/2026.
//

import Combine
import SwiftUI
import WebKit

struct URLBarLoadingStrip: View {
    @Environment(\.colorScheme) private var colorScheme

    let tab: Tab?
    let webView: WKWebView?

    @StateObject private var observer = URLBarLoadingObserver()

    private var resolvedWebView: WKWebView? {
        webView ?? tab?.assignedWebView ?? tab?.existingWebView
    }

    private var webViewIdentity: ObjectIdentifier? {
        resolvedWebView.map(ObjectIdentifier.init)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(trackColor)
                    .opacity(observer.isLoading ? 1 : 0)

                Capsule(style: .continuous)
                    .fill(progressGradient)
                    .frame(width: progressWidth(for: geo.size.width))
                    .opacity(observer.isLoading ? 1 : 0)
                    .animation(.easeOut(duration: 0.16), value: observer.progress)
            }
        }
        .frame(height: 2.5)
        .padding(.horizontal, 4)
        .padding(.bottom, 1.5)
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.16), value: observer.isLoading)
        .onAppear {
            observer.attach(to: resolvedWebView)
        }
        .onChange(of: tab?.id) { _, _ in
            observer.attach(to: resolvedWebView)
        }
        .onChange(of: webViewIdentity) { _, _ in
            observer.attach(to: resolvedWebView)
        }
        .onReceive(tab?.objectWillChange.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { _ in
            observer.attach(to: resolvedWebView)
        }
    }

    private var trackColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }

    private var progressGradient: LinearGradient {
        LinearGradient(
            colors: [
                progressColor.opacity(0.95),
                progressColor.opacity(0.70)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var progressColor: Color {
        colorScheme == .dark ? Color.white : Color.black
    }

    private func progressWidth(for totalWidth: CGFloat) -> CGFloat {
        guard observer.isLoading else { return 0 }
        let scaledWidth = totalWidth * max(observer.progress, 0.04)
        return min(totalWidth, max(12, scaledWidth))
    }
}

@MainActor
private final class URLBarLoadingObserver: ObservableObject {
    @Published var progress: CGFloat = 0
    @Published var isLoading: Bool = false

    private(set) weak var webView: WKWebView?
    private var progressObservation: NSKeyValueObservation?
    private var loadingObservation: NSKeyValueObservation?
    private var hideTask: Task<Void, Never>?

    func attach(to webView: WKWebView?) {
        guard webView !== self.webView else { return }

        hideTask?.cancel()
        progressObservation?.invalidate()
        loadingObservation?.invalidate()
        self.webView = webView

        guard let webView else {
            progress = 0
            isLoading = false
            return
        }

        progress = clampedProgress(for: webView.estimatedProgress)
        isLoading = webView.isLoading

        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor [weak self] in
                self?.progress = self?.clampedProgress(for: webView.estimatedProgress) ?? 0
            }
        }

        loadingObservation = webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if webView.isLoading {
                    self.hideTask?.cancel()
                    self.isLoading = true
                } else {
                    self.progress = 1
                    self.hideTask?.cancel()
                    self.hideTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 220_000_000)
                        guard let self, !Task.isCancelled else { return }
                        self.isLoading = false
                        self.progress = 0
                    }
                }
            }
        }
    }

    deinit {
        progressObservation?.invalidate()
        loadingObservation?.invalidate()
        hideTask?.cancel()
    }

    private func clampedProgress(for estimatedProgress: Double) -> CGFloat {
        CGFloat(min(max(estimatedProgress, 0), 1))
    }
}
