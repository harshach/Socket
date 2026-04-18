import AppKit
import WebKit

final class PopupConsole: NSObject, WKScriptMessageHandler {
    static let shared = PopupConsole()
    private static let handlerName = "popupConsole"

    private var window: NSWindow?
    private var textView: NSTextView?
    private var inputField: NSTextField?
    private weak var targetWebView: WKWebView?
    private var bufferedLines: [String] = []
    private var attachedControllers: Set<ObjectIdentifier> = []

    private override init() { super.init() }

    func attach(to webView: WKWebView) {
        targetWebView = webView
        let userContentController = webView.configuration.userContentController
        let controllerID = ObjectIdentifier(userContentController)
        let consoleScript = """
        (function() {
            if (window.__socketPopupConsoleInstalled) return;
            window.__socketPopupConsoleInstalled = true;
            const originalLog = console.log;
            const originalError = console.error;
            const originalWarn = console.warn;
            const originalStringify = JSON.stringify;
            
            function sendToNative(level, args) {
                try {
                    const message = args.map(arg => 
                        typeof arg === 'object' ? safeDescribe(arg) : String(arg)
                    ).join(' ');
                    window.webkit?.messageHandlers?.\(Self.handlerName)?.postMessage({
                        level: level,
                        message: message,
                        timestamp: new Date().toISOString()
                    });
                } catch (e) {
                    // Fallback if webkit messaging isn't available
                }
            }

            function safeDescribe(value) {
                try {
                    return originalStringify(value, null, 2);
                } catch (error) {
                    return String(value);
                }
            }

            function preview(value) {
                if (typeof value === 'string') {
                    return value.length > 500 ? value.slice(0, 500) + '…' : value;
                }
                return safeDescribe(value);
            }

            function installMessageDiagnostics(apiRoot, apiName) {
                if (!apiRoot || !apiRoot.runtime || typeof apiRoot.runtime.sendMessage !== 'function') {
                    return;
                }

                if (apiRoot.runtime.__socketSendMessageWrapped) {
                    return;
                }

                const originalSendMessage = apiRoot.runtime.sendMessage.bind(apiRoot.runtime);
                apiRoot.runtime.__socketSendMessageWrapped = true;
                apiRoot.runtime.sendMessage = function(...args) {
                    sendToNative('log', [
                        '[diag] runtime.sendMessage request',
                        apiName,
                        preview(args)
                    ]);

                    const callbackIndex = args.length - 1;
                    if (callbackIndex >= 0 && typeof args[callbackIndex] === 'function') {
                        const originalCallback = args[callbackIndex];
                        args[callbackIndex] = function(...callbackArgs) {
                            const lastError = apiRoot.runtime.lastError;
                            sendToNative('log', [
                                '[diag] runtime.sendMessage callback',
                                apiName,
                                preview({
                                    args: callbackArgs,
                                    lastError: lastError ? {
                                        message: lastError.message || String(lastError)
                                    } : null
                                })
                            ]);
                            return originalCallback.apply(this, callbackArgs);
                        };
                    }

                    let result;
                    try {
                        result = originalSendMessage(...args);
                    } catch (error) {
                        sendToNative('error', [
                            '[diag] runtime.sendMessage threw',
                            apiName,
                            error && (error.stack || error.message || String(error))
                        ]);
                        throw error;
                    }

                    if (result && typeof result.then === 'function') {
                        return result.then(function(value) {
                            sendToNative('log', [
                                '[diag] runtime.sendMessage resolved',
                                apiName,
                                preview(value)
                            ]);
                            return value;
                        }).catch(function(error) {
                            sendToNative('error', [
                                '[diag] runtime.sendMessage rejected',
                                apiName,
                                error && (error.stack || error.message || String(error))
                            ]);
                            throw error;
                        });
                    }

                    sendToNative('log', [
                        '[diag] runtime.sendMessage return',
                        apiName,
                        preview(result)
                    ]);
                    return result;
                };
            }

            function installTabsDiagnostics(apiRoot, apiName) {
                if (!apiRoot || !apiRoot.tabs || apiRoot.tabs.__socketTabsWrapped) {
                    return;
                }

                apiRoot.tabs.__socketTabsWrapped = true;
                ['create', 'update', 'remove', 'query', 'sendMessage'].forEach(function(methodName) {
                    const originalMethod = apiRoot.tabs[methodName];
                    if (typeof originalMethod !== 'function') {
                        return;
                    }

                    apiRoot.tabs[methodName] = function(...args) {
                        sendToNative('log', [
                            '[diag] tabs.' + methodName + ' request',
                            apiName,
                            preview(args)
                        ]);

                        const callbackIndex = args.length - 1;
                        if (callbackIndex >= 0 && typeof args[callbackIndex] === 'function') {
                            const originalCallback = args[callbackIndex];
                            args[callbackIndex] = function(...callbackArgs) {
                                const lastError = apiRoot.runtime?.lastError;
                                sendToNative('log', [
                                    '[diag] tabs.' + methodName + ' callback',
                                    apiName,
                                    preview({
                                        args: callbackArgs,
                                        lastError: lastError ? {
                                            message: lastError.message || String(lastError)
                                        } : null
                                    })
                                ]);
                                return originalCallback.apply(this, callbackArgs);
                            };
                        }

                        let result;
                        try {
                            result = originalMethod.apply(this, args);
                        } catch (error) {
                            sendToNative('error', [
                                '[diag] tabs.' + methodName + ' threw',
                                apiName,
                                error && (error.stack || error.message || String(error))
                            ]);
                            throw error;
                        }

                        if (result && typeof result.then === 'function') {
                            return result.then(function(value) {
                                sendToNative('log', [
                                    '[diag] tabs.' + methodName + ' resolved',
                                    apiName,
                                    preview(value)
                                ]);
                                return value;
                            }).catch(function(error) {
                                sendToNative('error', [
                                    '[diag] tabs.' + methodName + ' rejected',
                                    apiName,
                                    error && (error.stack || error.message || String(error))
                                ]);
                                throw error;
                            });
                        }

                        sendToNative('log', [
                            '[diag] tabs.' + methodName + ' return',
                            apiName,
                            preview(result)
                        ]);
                        return result;
                    };
                });
            }

            function installNativeMessagingDiagnostics(apiRoot, apiName) {
                if (!apiRoot || !apiRoot.runtime || apiRoot.runtime.__socketNativeMessagingWrapped) {
                    return;
                }

                apiRoot.runtime.__socketNativeMessagingWrapped = true;
                ['connectNative', 'sendNativeMessage'].forEach(function(methodName) {
                    const originalMethod = apiRoot.runtime[methodName];
                    if (typeof originalMethod !== 'function') {
                        return;
                    }

                    apiRoot.runtime[methodName] = function(...args) {
                        sendToNative('log', [
                            '[diag] runtime.' + methodName + ' request',
                            apiName,
                            preview(args)
                        ]);

                        try {
                            const result = originalMethod.apply(this, args);

                            if (result && typeof result.postMessage === 'function') {
                                const originalPostMessage = result.postMessage.bind(result);
                                result.postMessage = function(message) {
                                    sendToNative('log', [
                                        '[diag] native port postMessage',
                                        apiName,
                                        preview(message)
                                    ]);
                                    return originalPostMessage(message);
                                };
                            }

                            if (result && typeof result.then === 'function') {
                                return result.then(function(value) {
                                    sendToNative('log', [
                                        '[diag] runtime.' + methodName + ' resolved',
                                        apiName,
                                        preview(value)
                                    ]);
                                    return value;
                                }).catch(function(error) {
                                    sendToNative('error', [
                                        '[diag] runtime.' + methodName + ' rejected',
                                        apiName,
                                        error && (error.stack || error.message || String(error))
                                    ]);
                                    throw error;
                                });
                            }

                            sendToNative('log', [
                                '[diag] runtime.' + methodName + ' return',
                                apiName,
                                preview(result)
                            ]);
                            return result;
                        } catch (error) {
                            sendToNative('error', [
                                '[diag] runtime.' + methodName + ' threw',
                                apiName,
                                error && (error.stack || error.message || String(error))
                            ]);
                            throw error;
                        }
                    };
                });
            }

            function installExtensionSpecificDiagnostics() {
                const runtimeId = (window.chrome?.runtime && window.chrome.runtime.id)
                    || (window.browser?.runtime && window.browser.runtime.id)
                    || '';
                const runtimeAPI = window.browser?.runtime || window.chrome?.runtime;

                if (!runtimeAPI || window.__socketExtensionSpecificDiagnosticsRan) {
                    return;
                }

                window.__socketExtensionSpecificDiagnosticsRan = true;

                if (runtimeId === '9f7e8f8d-d750-4516-b82f-785f47cfa8a6') {
                    setTimeout(function() {
                        const requests = [
                            { name: 'get-popup-restore-point' },
                            { name: 'get-popup-config' }
                        ];

                        requests.forEach(function(request) {
                            try {
                                runtimeAPI.sendMessage(request).then(function(value) {
                                    sendToNative('log', [
                                        '[diag] direct probe resolved',
                                        request.name,
                                        preview({
                                            type: typeof value,
                                            value: value
                                        })
                                    ]);
                                }).catch(function(error) {
                                    sendToNative('error', [
                                        '[diag] direct probe rejected',
                                        request.name,
                                        error && (error.stack || error.message || String(error))
                                    ]);
                                });
                            } catch (error) {
                                sendToNative('error', [
                                    '[diag] direct probe threw',
                                    request.name,
                                    error && (error.stack || error.message || String(error))
                                ]);
                            }
                        });
                    }, 0);
                }
            }
            
            console.log = function(...args) {
                originalLog.apply(console, args);
                sendToNative('log', args);
            };
            
            console.error = function(...args) {
                originalError.apply(console, args);
                sendToNative('error', args);
            };
            
            console.warn = function(...args) {
                originalWarn.apply(console, args);
                sendToNative('warn', args);
            };

            window.addEventListener('error', function(event) {
                sendToNative('error', [
                    '[window.error]',
                    event.message || '(no message)',
                    event.filename || '',
                    String(event.lineno || 0),
                    String(event.colno || 0)
                ]);
            });

            window.addEventListener('unhandledrejection', function(event) {
                const reason = event.reason;
                let description = '';
                if (reason && typeof reason === 'object') {
                    description = reason.stack || reason.message || JSON.stringify(reason);
                } else {
                    description = String(reason);
                }
                sendToNative('error', ['[unhandledrejection]', description]);
            });
            
            console.log('Popup bootstrap:', {
                href: location.href,
                title: document.title,
                runtimeId: (chrome?.runtime && chrome.runtime.id) || (browser?.runtime && browser.runtime.id) || null,
                userAgent: navigator.userAgent
            });

            // Log initial extension API availability
            console.log('Extension APIs available:', {
                browser: typeof browser !== 'undefined',
                chrome: typeof chrome !== 'undefined',
                runtime: typeof (browser?.runtime || chrome?.runtime) !== 'undefined',
                storage: typeof (browser?.storage || chrome?.storage) !== 'undefined',
                tabs: typeof (browser?.tabs || chrome?.tabs) !== 'undefined'
            });

            installMessageDiagnostics(window.chrome, 'chrome');
            installMessageDiagnostics(window.browser, 'browser');
            installTabsDiagnostics(window.chrome, 'chrome');
            installTabsDiagnostics(window.browser, 'browser');
            installNativeMessagingDiagnostics(window.chrome, 'chrome');
            installNativeMessagingDiagnostics(window.browser, 'browser');
            installExtensionSpecificDiagnostics();
        })();
        """

        guard attachedControllers.insert(controllerID).inserted else {
            evaluateDiagnostics(in: webView, source: consoleScript)
            log("[PopupConsole] Reattached to existing WebView")
            return
        }

        userContentController.add(self, name: Self.handlerName)
        
        let script = WKUserScript(source: consoleScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        userContentController.addUserScript(script)
        evaluateDiagnostics(in: webView, source: consoleScript)
        
        log("[PopupConsole] Attached to WebView with console logging")
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.handlerName else { return }

        if let payload = message.body as? [String: Any] {
            let level = (payload["level"] as? String)?.uppercased() ?? "LOG"
            let line = payload["message"] as? String ?? String(describing: payload)
            log("[\(level)] \(line)")
            return
        }

        log("[LOG] \(String(describing: message.body))")
    }

    func show() {
        if window == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 720, height: 420),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            win.title = "Popup Console"

            let content = NSView(frame: win.contentLayoutRect)
            content.autoresizingMask = [.width, .height]

            let scroll = NSScrollView(frame: NSRect(x: 0, y: 44, width: content.bounds.width, height: content.bounds.height - 44))
            scroll.autoresizingMask = [.width, .height]
            let tv = NSTextView(frame: scroll.bounds)
            tv.isEditable = false
            tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            scroll.documentView = tv

            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: content.bounds.width - 80, height: 24))
            input.autoresizingMask = [.width, .maxYMargin]
            input.placeholderString = "Enter JS to evaluate in popup context"

            let runButton = NSButton(frame: NSRect(x: content.bounds.width - 75, y: 0, width: 75, height: 24))
            runButton.autoresizingMask = [.minXMargin, .maxYMargin]
            runButton.title = "Run"
            runButton.bezelStyle = .rounded
            runButton.target = self
            runButton.action = #selector(runJS)

            content.addSubview(scroll)
            content.addSubview(input)
            content.addSubview(runButton)

            win.contentView = content
            window = win
            textView = tv
            inputField = input
            tv.string = bufferedLines.joined(separator: "\n")
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func log(_ line: String) {
        bufferedLines.append(line)
        NSLog("%@", line)
        guard let tv = textView else { return }
        tv.string = bufferedLines.joined(separator: "\n")
        tv.scrollToEndOfDocument(nil)
    }

    @objc private func runJS() {
        guard let js = inputField?.stringValue, js.isEmpty == false else { return }
        guard let webView = targetWebView else { log("[error] No popup webview attached"); return }
        webView.evaluateJavaScript(js) { [weak self] result, error in
            if let error = error {
                self?.log("[error] \(error.localizedDescription)")
            } else if let result = result {
                self?.log("[result] \(result)")
            } else {
                self?.log("[result] undefined")
            }
        }
    }

    private func evaluateDiagnostics(in webView: WKWebView, source: String) {
        webView.evaluateJavaScript(source) { [weak self] _, error in
            guard let error else { return }
            self?.log("[PopupConsole] Immediate diagnostics eval failed: \(error.localizedDescription)")
        }
    }
}
