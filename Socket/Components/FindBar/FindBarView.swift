//
//  FindBarView.swift
//  Socket
//
//  Created by Assistant on 28/12/2024.
//

import AppKit
import SwiftUI
import UniversalGlass

struct FindBarView: View {
    @ObservedObject var findManager: FindManager
    @State private var focusRequestID: Int = 0

    // Hover states for buttons
    @State private var isUpButtonHovered = false
    @State private var isDownButtonHovered = false
    @State private var isCloseButtonHovered = false

    var body: some View {
        // Transparent background for tap-outside-to-dismiss
        ZStack {
            // Use a GeometryReader to place tap area only around the findbar
            Color.clear
                .allowsHitTesting(false)

            VStack {
                HStack {
                    Spacer()
                    HStack(spacing: 8) {
                        // Search icon + text field - integrated without sub-box
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                                .font(.system(size: 13))

                            FindBarTextField(
                                placeholder: "Find in page",
                                text: $findManager.searchText,
                                focusRequestID: focusRequestID,
                                onTextChange: { newValue in
                                    findManager.search(for: newValue, in: findManager.currentTab)
                                },
                                onSubmit: {
                                    findManager.findNext()
                                },
                                onEscape: {
                                    findManager.hideFindBar()
                                }
                            )
                                .frame(width: 160)
                        }

                        // Match count - always present to maintain consistent width
                        Group {
                            if findManager.matchCount > 0 {
                                Text("\(findManager.currentMatchIndex) of \(findManager.matchCount)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else if !findManager.searchText.isEmpty {
                                Text("0/0")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                // Placeholder to maintain width when empty
                                Text("0/0")
                                    .font(.caption)
                                    .foregroundColor(.clear)
                            }
                        }
                        .frame(minWidth: 40)

                        Divider()
                            .frame(height: 16)

                        // Navigation buttons - with hover reactivity
                        HStack(spacing: 2) {
                            Button(action: {
                                findManager.findPrevious()
                            }) {
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 11, weight: .medium))
                                    .frame(width: 22, height: 22)
                                    .background(isUpButtonHovered ? Color.secondary.opacity(0.2) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(findManager.searchText.isEmpty)
                            .onHover { hovering in
                                withAnimation(.easeInOut(duration: 0.1)) {
                                    isUpButtonHovered = hovering
                                }
                            }

                            Button(action: {
                                findManager.findNext()
                            }) {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 11, weight: .medium))
                                    .frame(width: 22, height: 22)
                                    .background(isDownButtonHovered ? Color.secondary.opacity(0.2) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(findManager.searchText.isEmpty)
                            .onHover { hovering in
                                withAnimation(.easeInOut(duration: 0.1)) {
                                    isDownButtonHovered = hovering
                                }
                            }
                        }

                        Divider()
                            .frame(height: 16)

                        // Close button - with hover reactivity
                        Button(action: {
                            findManager.hideFindBar()
                        }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .medium))
                                .frame(width: 22, height: 22)
                                .background(isCloseButtonHovered ? Color.secondary.opacity(0.2) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            withAnimation(.easeInOut(duration: 0.1)) {
                                isCloseButtonHovered = hovering
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    // Pill-shaped liquid glass styling
                    .background(Color(.windowBackgroundColor).opacity(0.35))
                    .clipShape(Capsule())
                    .universalGlassEffect(
                        .regular.tint(Color(.windowBackgroundColor).opacity(0.35)),
                        in: .capsule
                    )
                    .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 2)
                    .padding(.trailing, 16)
                }
                .padding(.top, 12)

                Spacer()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        findManager.hideFindBar()
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Liquid Glass dissipate effect for visibility changes
        .opacity(findManager.isFindBarVisible ? 1 : 0)
        .blur(radius: findManager.isFindBarVisible ? 0 : 8)
        .allowsHitTesting(findManager.isFindBarVisible)
        .animation(.smooth(duration: 0.25), value: findManager.isFindBarVisible)
        // Focus management
        .onChange(of: findManager.isFindBarVisible) { _, isVisible in
            if isVisible {
                requestFieldFocus()
            } else {
                focusRequestID = 0
            }
        }
        .onAppear {
            if findManager.isFindBarVisible {
                requestFieldFocus()
            }
        }
    }

    private func requestFieldFocus() {
        focusRequestID += 1

        // AppKit responder changes can race with the web view after Cmd+F.
        // Nudging once more on the next tick makes focus deterministic.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            focusRequestID += 1
        }
    }
}

private struct FindBarTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let focusRequestID: Int
    let onTextChange: (String) -> Void
    let onSubmit: () -> Void
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField(string: text)
        textField.delegate = context.coordinator
        textField.placeholderString = placeholder
        textField.isBordered = false
        textField.isBezeled = false
        textField.isEditable = true
        textField.isSelectable = true
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: 13)
        textField.textColor = .labelColor
        textField.maximumNumberOfLines = 1
        textField.lineBreakMode = .byTruncatingTail
        textField.usesSingleLineMode = true
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self

        if nsView.stringValue != text {
            nsView.stringValue = text
        }

        guard context.coordinator.lastFocusRequestID != focusRequestID else { return }
        context.coordinator.lastFocusRequestID = focusRequestID

        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            window.makeFirstResponder(nsView)

            if let editor = window.fieldEditor(true, for: nsView) as? NSTextView {
                editor.selectAll(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FindBarTextField
        var lastFocusRequestID: Int = -1

        init(parent: FindBarTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            let newValue = textField.stringValue
            if parent.text != newValue {
                parent.text = newValue
            }
            parent.onTextChange(newValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            default:
                return false
            }
        }
    }
}
