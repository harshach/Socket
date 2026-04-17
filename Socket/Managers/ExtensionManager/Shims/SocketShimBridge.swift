//
//  SocketShimBridge.swift
//  Socket
//
//  WKScriptMessageHandlerWithReply that sits between extension/page JavaScript
//  and `SocketShimRouter`. Every fresh `WKUserContentController` registers
//  this handler under the name `socketShimBridge` so `window.webkit.messageHandlers
//  .socketShimBridge.postMessage(envelope)` reaches Swift.
//
//  The paired user script (`installerJS`) is added to the shared
//  `WKUserContentController` at document-start. It is a no-op on non-extension
//  pages (it exits when `chrome`/`browser` is undefined).
//

import Foundation
import WebKit
import os

@MainActor
final class SocketShimBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = SocketShimBridge()

    /// Name under which the handler is registered. Must match the JS side.
    static let handlerName = "socketShimBridge"

    private static let logger = Logger(subsystem: "com.socket.browser", category: "SocketShim")

    private override init() { super.init() }

    // MARK: - WKScriptMessageHandlerWithReply

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard message.name == Self.handlerName else {
            replyHandler(nil, "Unknown handler")
            return
        }
        guard let request = ShimRequest.decode(message.body) else {
            Self.logger.debug("Rejected malformed shim envelope: \(String(describing: message.body), privacy: .public)")
            replyHandler(nil, "Malformed shim envelope")
            return
        }

        Task { @MainActor in
            let response = await SocketShimRouter.shared.dispatch(request)
            if let error = response.error {
                replyHandler(nil, error)
            } else {
                // WKScriptMessageHandlerWithReply requires JSON-encodable
                // values; `result` must already be a primitive / array / dict
                // of primitives. Shims are responsible for that shape.
                replyHandler(response.result ?? NSNull(), nil)
            }
        }
    }

    // MARK: - Client-side installer

    /// JS installer script added to the shared `WKUserContentController` at
    /// document-start. It:
    ///   1. Exits quietly when neither `chrome` nor `browser` is defined
    ///      (normal web pages — we don't pollute the window).
    ///   2. Installs a `__socketShim` facade with a `callNative(namespace,
    ///      method, args)` function that routes via the handler.
    ///   3. Monkey-patches the chrome/browser namespaces that the native
    ///      router advertises via the runtime-injected `__socketShimNamespaces`
    ///      global (populated by `ExtensionManager.setupExtensionController`).
    static let installerJS: String = """
    (function() {
      if (typeof window.webkit === 'undefined'
          || !window.webkit.messageHandlers
          || !window.webkit.messageHandlers.\(handlerName)) return;
      if (typeof window.chrome === 'undefined' && typeof window.browser === 'undefined') return;
      if (window.__socketShimsInstalled) return;
      window.__socketShimsInstalled = true;

      var chromeNs = window.chrome;
      if (typeof chromeNs === 'undefined') {
        // Some extension contexts only expose `browser`. Alias so shims can
        // install onto a stable name; the browser global is a separate object.
        chromeNs = window.chrome = window.browser;
      }

      function currentExtensionId() {
        try {
          if (chromeNs && chromeNs.runtime && typeof chromeNs.runtime.id === 'string') {
            return chromeNs.runtime.id;
          }
        } catch (_) {}
        return null;
      }

      function callNative(namespace, method, args) {
        var envelope = {
          namespace: String(namespace),
          method: String(method),
          args: Array.prototype.slice.call(args || []),
          extensionId: currentExtensionId(),
          requestId: Math.random().toString(36).slice(2) + Date.now().toString(36)
        };
        try {
          return window.webkit.messageHandlers.\(handlerName).postMessage(envelope);
        } catch (error) {
          return Promise.reject(error);
        }
      }

      // Wraps a (callback, promise) hybrid, matching Chrome's convention:
      //   chrome.x.y(args..., cb?) -> Promise
      // If a callback is supplied, it's invoked; either way we return the Promise.
      function makeMethod(namespace, method, arity) {
        return function () {
          var rawArgs = Array.prototype.slice.call(arguments);
          var callback = null;
          // Chrome calls are classically callback-last. If the arg after the
          // expected arity is a function, treat it as the callback. `arity`
          // may be undefined — in that case we look at the trailing arg.
          if (typeof arity === 'number' && rawArgs.length > arity && typeof rawArgs[arity] === 'function') {
            callback = rawArgs.splice(arity, 1)[0];
          } else if (rawArgs.length > 0 && typeof rawArgs[rawArgs.length - 1] === 'function') {
            callback = rawArgs.pop();
          }
          var promise = callNative(namespace, method, rawArgs);
          if (typeof callback === 'function') {
            Promise.resolve(promise).then(function(v) {
              try { callback(v); } catch (e) { /* swallow: matches Chrome */ }
            }, function(_err) {
              try { callback(undefined); } catch (e) {}
            });
          }
          return Promise.resolve(promise);
        };
      }

      window.__socketShim = {
        call: callNative,
        makeMethod: makeMethod
      };

      // `__socketShimNamespaces` is a JSON array of namespace names the native
      // router advertises. Installed by `ExtensionManager.setupExtensionController`.
      var advertised = [];
      try { advertised = (window.__socketShimNamespaces || []).slice(); } catch (_) {}
      // Per-namespace method tables. Keep in sync with the native shims.
      // `arity` is the count of fixed positional args the method accepts BEFORE
      // an optional trailing callback; pass undefined when methods vary.
      var tables = {
        management: {
          getAll: 0,
          get: 1,
          getSelf: 0,
          getPermissionWarningsById: 1,
          getPermissionWarningsByManifest: 1,
          setEnabled: 2,
          uninstall: 2,
          uninstallSelf: 1
        },
        proxy: {
          settings: {
            get: 1,
            set: 1,
            clear: 1
          }
        },
        sidePanel: {
          setOptions: 1,
          getOptions: 1,
          setPanelBehavior: 1,
          getPanelBehavior: 0,
          open: 1
        },
        tabGroups: {
          get: 1,
          query: 1,
          update: 2,
          move: 2
        },
        identity: {
          getAuthToken: 1,
          removeCachedAuthToken: 1,
          clearAllCachedAuthTokens: 0
        }
      };

      function installTable(namespaceName, table) {
        if (advertised.indexOf(namespaceName) === -1) return;
        var ns = chromeNs[namespaceName];
        if (!ns) { ns = chromeNs[namespaceName] = {}; }
        if (window.browser && !window.browser[namespaceName]) {
          window.browser[namespaceName] = ns;
        }
        for (var method in table) {
          if (!Object.prototype.hasOwnProperty.call(table, method)) continue;
          // Skip if the host already implements this method (Apple may expose
          // it in a future Safari release).
          if (typeof ns[method] === 'function') continue;
          var entry = table[method];
          if (typeof entry === 'number') {
            ns[method] = makeMethod(namespaceName, method, entry);
          } else if (entry && typeof entry === 'object') {
            // Nested (e.g. proxy.settings.*)
            var sub = ns[method] || {};
            for (var subMethod in entry) {
              if (!Object.prototype.hasOwnProperty.call(entry, subMethod)) continue;
              if (typeof sub[subMethod] === 'function') continue;
              var dotted = method + '.' + subMethod;
              sub[subMethod] = makeMethod(namespaceName, dotted, entry[subMethod]);
            }
            ns[method] = sub;
          }
        }
      }

      for (var key in tables) {
        if (Object.prototype.hasOwnProperty.call(tables, key)) {
          installTable(key, tables[key]);
        }
      }
    })();
    """
}
