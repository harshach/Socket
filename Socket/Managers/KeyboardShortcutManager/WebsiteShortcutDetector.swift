//
//  WebsiteShortcutDetector.swift
//  Socket
//
//  Created by AI Assistant on 2025.
//
//  Detects keyboard shortcut conflicts between Socket and websites.
//  Implements the "double-press" system: first press goes to website,
//  second press within 1 second goes to Socket.
//

import Foundation
import AppKit

// MARK: - Website Shortcut Detector

@MainActor
@Observable
class WebsiteShortcutDetector {
    
    // MARK: - Properties
    
    /// The currently detected website profile based on URL
    private(set) var currentProfile: WebsiteShortcutProfile?
    
    /// The current URL being monitored
    private(set) var currentURL: URL?

    /// Tracks whether the active page focus is inside an editable element.
    private(set) var isEditableElementFocused: Bool = false
    
    /// Pending shortcut presses waiting for a second press (windowId -> pending info)
    private var pendingShortcuts: [UUID: PendingShortcut] = [:]
    
    /// Cache of detected shortcuts from JS injection (URL -> Set of lookup keys)
    private var jsDetectedShortcuts: [String: Set<String>] = [:]
    
    /// The timeout duration for double-press detection (1 second as specified)
    let conflictTimeout: TimeInterval = 1.0
    
    /// Timer for cleaning up expired pending shortcuts
    nonisolated(unsafe) private var cleanupTimer: Timer?
    
    /// Weak reference to browser manager for notifications
    weak var browserManager: BrowserManager?
    
    // MARK: - Initialization
    
    init() {
        startCleanupTimer()
    }
    
    deinit {
        cleanupTimer?.invalidate()
    }
    
    // MARK: - Public Interface
    
    /// Update the current website profile based on URL
    /// Called when the active tab's URL changes
    func updateCurrentURL(_ url: URL?) {
        currentURL = url
        isEditableElementFocused = false
        
        // Find matching profile
        if let url = url {
            let matchedProfile = WebsiteShortcutProfile.knownProfiles.first { $0.matches(url: url) }
            currentProfile = matchedProfile
            print("⌨️ [Detector] URL updated: \(url.host ?? "nil"), matched profile: \(matchedProfile?.name ?? "none")")
        } else {
            currentProfile = nil
            isEditableElementFocused = false
            print("⌨️ [Detector] URL cleared, no profile")
        }
    }
    
    /// Check if a key combination is a known website shortcut
    /// Returns the website shortcut info if found, nil otherwise
    func isKnownWebsiteShortcut(_ keyCombination: KeyCombination) -> WebsiteShortcut? {
        guard WebsiteShortcutProfile.isFeatureEnabled else { 
            print("⌨️ [Detector] Feature disabled, not checking shortcuts")
            return nil 
        }
        
        print("⌨️ [Detector] Checking shortcut: \(keyCombination.lookupKey)")
        print("⌨️ [Detector] Current URL: \(currentURL?.host ?? "nil")")
        print("⌨️ [Detector] Current profile: \(currentProfile?.name ?? "nil")")
        
        // Check known profile first
        if let profile = currentProfile,
           let shortcut = profile.hasShortcut(matching: keyCombination) {
            print("⌨️ [Detector] ✅ Found matching shortcut in profile: \(profile.name)")
            return shortcut
        }
        
        // Check JS-detected shortcuts
        if let urlKey = currentURL?.absoluteString,
           let detectedKeys = jsDetectedShortcuts[urlKey],
           detectedKeys.contains(keyCombination.lookupKey) {
            print("⌨️ [Detector] ✅ Found matching shortcut in JS-detected: \(keyCombination.lookupKey)")
            // Return a generic detected shortcut
            return WebsiteShortcut(key: keyCombination.key, modifiers: keyCombination.modifiers, description: nil)
        }
        
        print("⌨️ [Detector] ❌ No matching shortcut found")
        return nil
    }
    
    /// Determine if this key press should pass through to the website
    /// Returns true if this is the FIRST press of a conflicting shortcut
    /// Also triggers the conflict toast and sets pending state
    func shouldPassToWebsite(
        _ keyCombination: KeyCombination,
        windowId: UUID,
        socketActionName: String
    ) -> Bool {
        guard WebsiteShortcutProfile.isFeatureEnabled else { 
            print("⌨️ [Detector] Feature disabled, not passing through")
            return false 
        }
        
        guard let websiteShortcut = isKnownWebsiteShortcut(keyCombination) else { 
            print("⌨️ [Detector] No matching website shortcut for: \(keyCombination.lookupKey)")
            return false 
        }
        
        let now = Date()
        
        // Check if there's already a pending shortcut for this window
        if let pending = pendingShortcuts[windowId],
           pending.keyCombination == keyCombination,
           now.timeIntervalSince(pending.timestamp) <= conflictTimeout {
            // This is the SECOND press within timeout - clear pending and return false
            // so Socket can capture it
            print("⌨️ [Detector] SECOND press detected - capturing for Socket")
            pendingShortcuts.removeValue(forKey: windowId)
            return false
        }
        
        // This is the FIRST press - set pending state and show toast
        let websiteName = currentProfile?.name ?? "Website"
        print("⌨️ [Detector] FIRST press - passing to website: \(websiteName)")
        pendingShortcuts[windowId] = PendingShortcut(
            keyCombination: keyCombination,
            timestamp: now,
            websiteName: websiteName
        )
        
        // Show conflict toast via notification
        let conflictInfo = ShortcutConflictInfo(
            keyCombination: keyCombination,
            websiteName: websiteName,
            websiteShortcutDescription: websiteShortcut.description,
            socketActionName: socketActionName,
            windowId: windowId
        )
        postConflictNotification(conflictInfo)
        
        return true
    }
    
    /// Check if there's a pending shortcut for the given window
    func hasPendingShortcut(for windowId: UUID) -> Bool {
        guard let pending = pendingShortcuts[windowId] else { return false }
        return Date().timeIntervalSince(pending.timestamp) <= conflictTimeout
    }
    
    /// Clear pending shortcut for a window (e.g., when switching tabs)
    func clearPendingShortcut(for windowId: UUID) {
        pendingShortcuts.removeValue(forKey: windowId)
    }
    
    /// Clear all pending shortcuts
    func clearAllPendingShortcuts() {
        pendingShortcuts.removeAll()
    }
    
    /// Update JS-detected shortcuts for a URL
    /// Called from Tab when JS injection reports detected listeners
    func updateJSDetectedShortcuts(for url: String, shortcuts: Set<String>) {
        jsDetectedShortcuts[url] = shortcuts
    }

    func updateEditableFocus(_ isFocused: Bool) {
        isEditableElementFocused = isFocused
    }
    
    // MARK: - Private Methods
    
    private func startCleanupTimer() {
        // Clean up expired pending shortcuts every 500ms
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.cleanupExpiredPendingShortcuts()
            }
        }
    }
    
    private func cleanupExpiredPendingShortcuts() {
        let now = Date()
        let expiredWindows = pendingShortcuts.filter { now.timeIntervalSince($0.value.timestamp) > 1.5 }
            .map { $0.key }
        
        for windowId in expiredWindows {
            pendingShortcuts.removeValue(forKey: windowId)
        }
    }
    
    private func postConflictNotification(_ info: ShortcutConflictInfo) {
        NotificationCenter.default.post(
            name: .shortcutConflictDetected,
            object: nil,
            userInfo: ["conflictInfo": info]
        )
    }
}

// MARK: - Pending Shortcut

private struct PendingShortcut {
    let keyCombination: KeyCombination
    let timestamp: Date
    let websiteName: String
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when a keyboard shortcut conflict is detected
    /// UserInfo contains "conflictInfo": ShortcutConflictInfo
    static let shortcutConflictDetected = Notification.Name("shortcutConflictDetected")
    
    /// Posted when a shortcut conflict toast should be dismissed
    static let shortcutConflictDismissed = Notification.Name("shortcutConflictDismissed")
}

// MARK: - JS Detection Script

extension WebsiteShortcutDetector {
    
    /// JavaScript to inject into web pages for runtime shortcut detection
    /// This attempts to detect keydown listeners that websites register
    static var jsDetectionScript: String {
        """
        (function() {
            // Only run once per page
            if (window.__socketShortcutDetectionActive) return;
            window.__socketShortcutDetectionActive = true;
            
            // Track detected shortcuts
            const detectedShortcuts = new Set();
            let editableRoles = new Set(['textbox', 'searchbox', 'combobox', 'spinbutton']);
            let nonEditableInputTypes = new Set(['button', 'checkbox', 'color', 'file', 'hidden', 'image', 'radio', 'range', 'reset', 'submit']);
            let focusState = {
                editable: null,
                shortcutSignature: ''
            };
            
            // Hook into addEventListener to catch keydown/keyup listeners
            const originalAddEventListener = EventTarget.prototype.addEventListener;
            EventTarget.prototype.addEventListener = function(type, listener, options) {
                if (type === 'keydown') {
                    // Try to parse the listener to extract key combinations
                    // This is best-effort and won't catch all cases
                    try {
                        const listenerStr = listener.toString();
                        
                        // Look for patterns like e.key === 'k', e.code === 'KeyK', etc.
                        const keyMatches = listenerStr.match(/(?:e|event)\\.key\\s*===\\s*['"]([\\w]+)['"]/g);
                        const codeMatches = listenerStr.match(/(?:e|event)\\.code\\s*===\\s*['"]([\\w]+)['"]/g);
                        
                        if (keyMatches) {
                            keyMatches.forEach(m => {
                                const key = m.match(/['"]([\\w]+)['"]/)?.[1]?.toLowerCase();
                                if (key) detectedShortcuts.add(key);
                            });
                        }
                        
                        // Look for modifier checks
                        const hasCmd = listenerStr.includes('.metaKey') || listenerStr.includes('.ctrlKey');
                        const hasShift = listenerStr.includes('.shiftKey');
                        const hasAlt = listenerStr.includes('.altKey');
                        const hasCtrl = listenerStr.includes('.ctrlKey') && !listenerStr.includes('.metaKey');
                        
                        // Store modifier patterns for later
                        if (hasCmd || hasShift || hasAlt || hasCtrl) {
                            // Mark that this listener uses modifiers
                            window.__socketUsesModifiers = true;
                        }
                    } catch (e) {
                        // Ignore parsing errors
                    }
                }
                return originalAddEventListener.call(this, type, listener, options);
            };
            
            // Also try to detect accesskey attributes
            function checkAccessKeys() {
                const elements = document.querySelectorAll('[accesskey]');
                elements.forEach(el => {
                    const key = el.getAttribute('accesskey')?.toLowerCase();
                    if (key && key.length === 1) {
                        detectedShortcuts.add('accesskey:' + key);
                    }
                });
            }
            
            // Check accesskeys after DOM loads
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', checkAccessKeys);
            } else {
                checkAccessKeys();
            }
            
            // Monitor for dynamic accesskey additions
            const observer = new MutationObserver(() => checkAccessKeys());
            observer.observe(document.body || document.documentElement, { 
                childList: true, 
                subtree: true,
                attributes: true,
                attributeFilter: ['accesskey']
            });
            
            function activeElementForRoot(root) {
                try {
                    if (!root) return null;
                    let active = root.activeElement || null;

                    while (active) {
                        if (active.shadowRoot && active.shadowRoot.activeElement) {
                            active = active.shadowRoot.activeElement;
                            continue;
                        }

                        if (active.tagName === 'IFRAME') {
                            try {
                                const frameDocument = active.contentDocument;
                                if (frameDocument && frameDocument.activeElement) {
                                    active = frameDocument.activeElement;
                                    continue;
                                }
                            } catch (error) {
                                // Cross-origin frames are not inspectable. Keep the iframe itself.
                            }
                        }

                        break;
                    }

                    return active;
                } catch (error) {
                    return document.activeElement || null;
                }
            }

            function isEditableElement(element) {
                if (!element) return false;
                if (document.designMode === 'on') return true;

                let current = element;

                while (current) {
                    if (current.isContentEditable) return true;

                    const tagName = (current.tagName || '').toUpperCase();
                    const role = (current.getAttribute?.('role') || '').toLowerCase();
                    const inputMode = (current.getAttribute?.('inputmode') || '').toLowerCase();
                    const isDisabled = current.hasAttribute?.('disabled') || current.getAttribute?.('aria-disabled') === 'true';
                    const isReadOnly = current.hasAttribute?.('readonly') || current.getAttribute?.('aria-readonly') === 'true';

                    if (!isDisabled && !isReadOnly) {
                        if (tagName === 'IFRAME') {
                            return true;
                        }

                        if (tagName === 'TEXTAREA' || tagName === 'SELECT') {
                            return true;
                        }

                        if (tagName === 'INPUT') {
                            const type = (current.getAttribute('type') || 'text').toLowerCase();
                            if (!nonEditableInputTypes.has(type)) {
                                return true;
                            }
                        }

                        if (editableRoles.has(role)) {
                            return true;
                        }

                        if (inputMode && inputMode !== 'none') {
                            return true;
                        }
                    }

                    current = current.parentElement || current.assignedSlot || current.parentNode?.host || null;
                }

                return false;
            }

            // Report detected shortcuts and editable focus state to native.
            function reportState(force) {
                if (!window.webkit?.messageHandlers?.socketShortcutDetect) {
                    return;
                }

                const activeElement = activeElementForRoot(document);
                const isEditableFocused = isEditableElement(activeElement);
                const shortcuts = Array.from(detectedShortcuts).sort();
                const shortcutSignature = shortcuts.join(',');

                if (!force &&
                    focusState.editable === isEditableFocused &&
                    focusState.shortcutSignature === shortcutSignature) {
                    return;
                }

                focusState.editable = isEditableFocused;
                focusState.shortcutSignature = shortcutSignature;

                window.webkit.messageHandlers.socketShortcutDetect.postMessage({
                    shortcuts: shortcuts,
                    isEditableElementFocused: isEditableFocused
                });
            }

            let stateQueue = { timer: null };
            function queueReport(force) {
                if (force) {
                    if (stateQueue.timer) {
                        clearTimeout(stateQueue.timer);
                    }
                    stateQueue.timer = null;
                    reportState(true);
                    return;
                }

                if (stateQueue.timer) return;
                stateQueue.timer = setTimeout(() => {
                    stateQueue.timer = null;
                    reportState(false);
                }, 0);
            }
            
            // Report periodically and on common focus/input transitions used by SPAs.
            setInterval(() => reportState(false), 750);
            document.addEventListener('visibilitychange', () => queueReport(true), true);
            document.addEventListener('focusin', () => queueReport(true), true);
            document.addEventListener('focusout', () => queueReport(true), true);
            document.addEventListener('beforeinput', () => queueReport(true), true);
            document.addEventListener('input', () => queueReport(true), true);
            document.addEventListener('keydown', () => queueReport(true), true);
            document.addEventListener('keyup', () => queueReport(true), true);
            document.addEventListener('mousedown', () => queueReport(false), true);
            document.addEventListener('mouseup', () => queueReport(false), true);
            document.addEventListener('click', () => queueReport(false), true);
            document.addEventListener('selectionchange', () => queueReport(false), true);
            window.addEventListener('focus', () => queueReport(true), true);
            window.addEventListener('blur', () => queueReport(true), true);

            const editableObserver = new MutationObserver(() => queueReport(false));
            editableObserver.observe(document.documentElement, {
                childList: true,
                subtree: true,
                attributes: true,
                attributeFilter: ['contenteditable', 'role', 'type', 'inputmode', 'readonly', 'disabled', 'aria-readonly', 'aria-disabled']
            });
            
            // Initial report after a short delay
            queueReport(true);
            setTimeout(() => queueReport(true), 150);
            setTimeout(() => queueReport(true), 1000);
        })();
        """
    }
}
