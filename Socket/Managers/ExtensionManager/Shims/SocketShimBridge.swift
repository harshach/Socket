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

    /// Chrome-compatible facade for extension contexts that only expose
    /// `browser.*`. A direct `window.chrome = window.browser` alias breaks
    /// callback-style extensions like 1Password and Zoom because Firefox-style
    /// Promise APIs do not accept Chrome's trailing callback contract.
    static let chromeCompatibilityJS: String = """
    (function() {
      var existingChrome = window.chrome;
      if (existingChrome && existingChrome.runtime && typeof existingChrome.runtime.id === 'string') {
        return;
      }
      if (typeof window.browser === 'undefined') return;
      if (window.__socketChromeCompatInstalled) return;
      window.__socketChromeCompatInstalled = true;

      var browserRoot = window.browser;
      var lastErrorValue = null;
      var proxyCache = new WeakMap();
      var wrapperCache = new WeakMap();

      function toErrorObject(error) {
        if (!error) return null;
        if (typeof error === 'object' && typeof error.message === 'string') {
          return { message: error.message };
        }
        return { message: String(error) };
      }

      function setLastError(error) {
        lastErrorValue = toErrorObject(error);
      }

      function clearLastErrorSoon() {
        setTimeout(function() {
          lastErrorValue = null;
        }, 0);
      }

      function isEventObject(value) {
        return !!value
          && typeof value === 'object'
          && typeof value.addListener === 'function'
          && typeof value.removeListener === 'function';
      }

      function wrapFunction(owner, fn, propName) {
        var cacheKey = owner && typeof owner === 'object' ? owner : fn;
        var ownerCache = wrapperCache.get(cacheKey);
        if (!ownerCache) {
          ownerCache = Object.create(null);
          wrapperCache.set(cacheKey, ownerCache);
        }
        if (ownerCache[propName]) {
          return ownerCache[propName];
        }

        var wrapper = function() {
          if (
            propName === 'addListener'
            || propName === 'removeListener'
            || propName === 'hasListener'
            || propName === 'hasListeners'
          ) {
            return fn.apply(owner, arguments);
          }

          var args = Array.prototype.slice.call(arguments);
          var callback = null;
          if (args.length && typeof args[args.length - 1] === 'function') {
            callback = args.pop();
          }

          var result;
          try {
            result = fn.apply(owner, args);
          } catch (error) {
            if (callback) {
              setLastError(error);
              try {
                callback();
              } finally {
                clearLastErrorSoon();
              }
              return;
            }
            throw error;
          }

          if (!callback) {
            return result;
          }

          if (result && typeof result.then === 'function') {
            return result.then(function(value) {
              setLastError(null);
              try {
                callback(value);
              } finally {
                clearLastErrorSoon();
              }
              return value;
            }).catch(function(error) {
              setLastError(error);
              try {
                callback();
              } finally {
                clearLastErrorSoon();
              }
              return undefined;
            });
          }

          setLastError(null);
          try {
            callback(result);
          } finally {
            clearLastErrorSoon();
          }
          return result;
        };

        ownerCache[propName] = wrapper;
        return wrapper;
      }

      function proxify(target, path) {
        if (!target || (typeof target !== 'object' && typeof target !== 'function')) {
          return target;
        }
        if (proxyCache.has(target)) {
          return proxyCache.get(target);
        }

        var proxy = new Proxy(target, {
          get: function(obj, prop) {
            if (path === 'runtime' && prop === 'lastError') {
              return lastErrorValue;
            }

            var value = obj[prop];
            if (typeof value === 'function') {
              if (isEventObject(obj)) {
                return value.bind(obj);
              }
              return wrapFunction(obj, value, String(prop));
            }

            if (value && typeof value === 'object') {
              var childPath = path ? path + '.' + String(prop) : String(prop);
              return proxify(value, childPath);
            }

            return value;
          },
          set: function(obj, prop, value) {
            if (path === 'runtime' && prop === 'lastError') {
              lastErrorValue = value;
              return true;
            }
            obj[prop] = value;
            return true;
          },
          has: function(obj, prop) {
            if (path === 'runtime' && prop === 'lastError') {
              return true;
            }
            return prop in obj;
          },
          ownKeys: function(obj) {
            var keys = Reflect.ownKeys(obj);
            if (path === 'runtime' && keys.indexOf('lastError') === -1) {
              keys.push('lastError');
            }
            return keys;
          },
          getOwnPropertyDescriptor: function(obj, prop) {
            if (path === 'runtime' && prop === 'lastError') {
              return {
                configurable: true,
                enumerable: true,
                writable: true,
                value: lastErrorValue
              };
            }
            return Object.getOwnPropertyDescriptor(obj, prop);
          }
        });

        proxyCache.set(target, proxy);
        return proxy;
      }

      var chromeRoot = proxify(browserRoot, '');
      try {
        window.chrome = chromeRoot;
      } catch (_) {}

      if (chromeRoot && chromeRoot.browserAction == null && chromeRoot.action != null) {
        chromeRoot.browserAction = chromeRoot.action;
      }
      if (chromeRoot && chromeRoot.pageAction == null && chromeRoot.action != null) {
        chromeRoot.pageAction = chromeRoot.action;
      }
    })();
    """

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

      \(chromeCompatibilityJS)

      var chromeNs = window.chrome;
      if (typeof chromeNs === 'undefined') return;

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

      // ===== Pure-client no-op shims =====
      // Some MV3 extensions (1Password, others) call APIs Apple's
      // WKWebExtension doesn't expose during background-service-worker
      // init. Without a stub, the SW throws ReferenceError or TypeError
      // before it can register `chrome.runtime.onConnect` listeners, so
      // every popup connection fails with "No runtime.onConnect listeners
      // found." A no-op stub doesn't fully implement these APIs, but it
      // lets the SW's init code run to the listener-registration step.
      //
      // chrome.offscreen — used by MV3 SWs to spawn offscreen documents
      // for cross-origin fetch / DOM parsing / WebRTC. We can't host a
      // real offscreen document, so report "no document exists" and
      // resolve quietly.
      if (!chromeNs.offscreen) {
        var stubReason = "Socket: chrome.offscreen is not implemented; treating as unavailable.";
        chromeNs.offscreen = {
          Reason: { TESTING: 'TESTING', DOM_PARSER: 'DOM_PARSER', AUDIO_PLAYBACK: 'AUDIO_PLAYBACK',
                    DOM_SCRAPING: 'DOM_SCRAPING', BLOBS: 'BLOBS', IFRAME_SCRIPTING: 'IFRAME_SCRIPTING',
                    BATTERY_STATUS: 'BATTERY_STATUS', WEB_RTC: 'WEB_RTC', CLIPBOARD: 'CLIPBOARD',
                    DISPLAY_MEDIA: 'DISPLAY_MEDIA', GEOLOCATION: 'GEOLOCATION', LOCAL_STORAGE: 'LOCAL_STORAGE',
                    MATCH_MEDIA: 'MATCH_MEDIA', USER_MEDIA: 'USER_MEDIA', WORKERS: 'WORKERS' },
          createDocument: function () { console.warn(stubReason); return Promise.resolve(); },
          closeDocument:  function () { return Promise.resolve(); },
          hasDocument:    function () { return Promise.resolve(false); }
        };
        if (window.browser && !window.browser.offscreen) window.browser.offscreen = chromeNs.offscreen;
      }

      // chrome.privacy — settings controllers used by some extensions to
      // read/adjust browser privacy preferences. Stub each leaf to a
      // no-op `Setting` whose .get returns { value: undefined,
      // levelOfControl: 'not_controllable' }, .set/.clear resolve. Better
      // than the SW crashing on `chrome.privacy.network.networkPredictionEnabled.get`.
      if (!chromeNs.privacy) {
        var noopSetting = {
          get: function () { return Promise.resolve({ value: undefined, levelOfControl: 'not_controllable' }); },
          set: function () { return Promise.resolve(); },
          clear: function () { return Promise.resolve(); },
          onChange: { addListener: function () {}, removeListener: function () {}, hasListener: function () { return false; } }
        };
        var bagOfNoops = function (keys) {
          var obj = {};
          for (var i = 0; i < keys.length; i += 1) { obj[keys[i]] = noopSetting; }
          return obj;
        };
        chromeNs.privacy = {
          network: bagOfNoops(['networkPredictionEnabled', 'webRTCIPHandlingPolicy', 'webRTCMultipleRoutesEnabled', 'webRTCNonProxiedUdpEnabled']),
          services: bagOfNoops(['alternateErrorPagesEnabled', 'autofillAddressEnabled', 'autofillCreditCardEnabled', 'autofillEnabled',
                                'passwordSavingEnabled', 'safeBrowsingEnabled', 'safeBrowsingExtendedReportingEnabled',
                                'searchSuggestEnabled', 'spellingServiceEnabled', 'translationServiceEnabled']),
          websites: bagOfNoops(['hyperlinkAuditingEnabled', 'referrersEnabled', 'doNotTrackEnabled', 'protectedContentEnabled',
                                'thirdPartyCookiesAllowed'])
        };
        if (window.browser && !window.browser.privacy) window.browser.privacy = chromeNs.privacy;
      }

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
