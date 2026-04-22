// PasswordFormDetector.js
// Socket — native password manager content script
//
// Runs on every frame at document_end. Responsibilities:
//   • Tag password fields + best-guess username fields with a stable data-socket-fid
//   • On password-field focus, post `passwordFormDetected` (no values) so Swift
//     can surface the autofill popover (see PasswordAutofillPopover)
//   • On submit / submit-button click, post `passwordFormSubmitted` with the
//     plaintext credential — Swift consumes this to prompt Save/Update
//   • `requestAutofill` (reply handler) — JS asks for suggestions; Swift replies
//     with {username, recordRefBase64} entries but never a password
//
// Design notes:
//   • No external deps. Under ~5 KB unminified.
//   • Injected once per frame via shared UCC (BrowserConfig.webViewConfiguration).
//   • MutationObserver catches SPA route changes + late-mounted forms.
//   • Never emits password values on focus/detect — only on explicit submit.

(function () {
    "use strict";

    if (window.__socketPasswordDetectorInstalled) { return; }
    window.__socketPasswordDetectorInstalled = true;

    var ATTR = "data-socket-fid";
    var USERNAME_ATTR = "data-socket-fid-user";
    var RECENT_SUBMIT_TTL_MS = 400;
    var FOCUS_DEBOUNCE_MS = 150;
    var MUTATION_DEBOUNCE_MS = 300;

    // Only the top frame gets heavy work (scan + mutation observer + inline
    // icon overlay). Child frames still get submit/focus detection so e.g.
    // Stripe Checkout iframes can save creds, but we don't run
    // document-wide querySelectorAll in them, which was tanking page perf
    // on heavy apps (Google Slides' file picker was spinning forever).
    var isTopFrame = (function () {
        try { return window === window.top; } catch (_) { return false; }
    })();

    function postMessage(name, payload) {
        try {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[name]) {
                window.webkit.messageHandlers[name].postMessage(payload);
            }
        } catch (_) { /* channel not installed on this frame */ }
    }

    function requestReply(name, payload) {
        try {
            var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[name];
            if (h && typeof h.postMessage === "function") {
                return h.postMessage(payload);
            }
        } catch (_) {}
        return Promise.resolve(null);
    }

    function host() {
        try {
            return window.location.hostname || "";
        } catch (_) { return ""; }
    }

    function randomId() {
        if (window.crypto && window.crypto.getRandomValues) {
            var a = new Uint32Array(2);
            window.crypto.getRandomValues(a);
            return "sf-" + a[0].toString(36) + a[1].toString(36);
        }
        return "sf-" + Math.random().toString(36).slice(2) + Date.now().toString(36);
    }

    function ensureFid(el, attrName) {
        attrName = attrName || ATTR;
        if (!el.getAttribute(attrName)) {
            el.setAttribute(attrName, randomId());
        }
        return el.getAttribute(attrName);
    }

    // Heuristics for the username field paired with a password input:
    //   1. explicit autocomplete=username|email
    //   2. nearest preceding text|email input inside the same form
    //   3. first text|email input on the form above the password
    //   4. input whose name/id matches /user|email|login/i
    function findUsernameInput(passwordEl) {
        var form = passwordEl.form;
        var candidates;
        if (form) {
            candidates = Array.prototype.slice.call(
                form.querySelectorAll("input")
            );
        } else {
            candidates = Array.prototype.slice.call(
                document.querySelectorAll("input")
            );
        }
        var textLike = candidates.filter(function (n) {
            if (n === passwordEl) { return false; }
            var t = (n.type || "").toLowerCase();
            if (t === "hidden" || t === "submit" || t === "button" || t === "checkbox" || t === "radio") {
                return false;
            }
            if (t === "password") { return false; }
            if (n.disabled || n.readOnly) { return false; }
            return true;
        });
        if (textLike.length === 0) { return null; }

        // pass 1: explicit autocomplete
        var explicit = textLike.filter(function (n) {
            var ac = (n.getAttribute("autocomplete") || "").toLowerCase();
            return ac === "username" || ac === "email";
        });
        if (explicit.length > 0) {
            return nearestPreceding(explicit, passwordEl) || explicit[0];
        }

        // pass 2: nearest preceding text/email input by document order
        var preceding = textLike.filter(function (n) {
            return n.compareDocumentPosition(passwordEl) & Node.DOCUMENT_POSITION_FOLLOWING;
        });
        if (preceding.length > 0) {
            return preceding[preceding.length - 1];
        }

        // pass 3: name/id heuristic
        var heuristic = textLike.filter(function (n) {
            var hay = ((n.name || "") + " " + (n.id || "") + " " + (n.placeholder || "")).toLowerCase();
            return /user|email|login|account/.test(hay);
        });
        if (heuristic.length > 0) { return heuristic[0]; }

        // fallback: first text/email
        return textLike[0];
    }

    function nearestPreceding(list, target) {
        var best = null;
        for (var i = 0; i < list.length; i++) {
            var n = list[i];
            if (n.compareDocumentPosition(target) & Node.DOCUMENT_POSITION_FOLLOWING) {
                best = n;
            }
        }
        return best;
    }

    function rectOf(el) {
        try {
            var r = el.getBoundingClientRect();
            return { x: r.left, y: r.top, width: r.width, height: r.height };
        } catch (_) {
            return { x: 0, y: 0, width: 0, height: 0 };
        }
    }

    function collectPasswordFields() {
        // Light-DOM only. The previous shadow-DOM walk did `querySelectorAll("*")`
        // across the whole document + each shadow root; that's O(N) per scan
        // and on heavy apps (Google Slides, VS Code for Web) it blocked the
        // main thread for seconds. 99% of sign-in forms live in the light DOM;
        // the handful of shadow-root logins still get submit/focus capture
        // via the document-level bubble listeners below.
        try {
            return Array.prototype.slice.call(
                document.querySelectorAll("input[type=password]")
            );
        } catch (_) {
            return [];
        }
    }

    function describeFieldsForFocus(passwordEl) {
        var username = findUsernameInput(passwordEl);
        var passwordFid = ensureFid(passwordEl);
        var usernameFid = username ? ensureFid(username, USERNAME_ATTR) : null;
        return {
            usernameFid: usernameFid,
            passwordFid: passwordFid,
            rect: rectOf(passwordEl)
        };
    }

    // Maps an arbitrary input (either a username or password field) to the
    // same { usernameFid, passwordFid, rect } shape that Swift expects.
    // Used when the inline icon is anchored to the username field — we still
    // need to know which password input to eventually fill.
    function describeFieldsForInput(el) {
        var passwordEl, usernameEl;
        if (el.matches && el.matches("input[type=password]")) {
            passwordEl = el;
            usernameEl = findUsernameInput(el);
        } else {
            usernameEl = el;
            var form = el.form;
            var root = form || document;
            passwordEl = root.querySelector("input[type=password]");
        }
        if (!passwordEl) { return null; }
        var passwordFid = ensureFid(passwordEl);
        var usernameFid = usernameEl ? ensureFid(usernameEl, USERNAME_ATTR) : null;
        return {
            usernameFid: usernameFid,
            passwordFid: passwordFid,
            rect: rectOf(el)
        };
    }

    // ----- Focus → passwordFormDetected (no values) -----

    var focusTimer = null;
    function onPasswordFocus(e) {
        if (!e || !e.target) { return; }
        var el = e.target;
        if (!el.matches || !el.matches("input[type=password]")) { return; }
        if (focusTimer) { clearTimeout(focusTimer); }
        focusTimer = setTimeout(function () {
            focusTimer = null;
            var info = describeFieldsForFocus(el);
            postMessage("passwordFormDetected", {
                host: host(),
                frameURL: (function () { try { return window.location.href; } catch (_) { return ""; } })(),
                fields: [info]
            });
            // If Swift already hinted that we have saved credentials for this
            // host, open the reply channel so Swift can render the popover.
            if (hasHintsForCurrentHost()) {
                requestAutofill(info, "focus"); // fire-and-forget; Swift handles UI
            }
        }, FOCUS_DEBOUNCE_MS);
    }

    // ----- Submit → passwordFormSubmitted (carries values, short-lived) -----

    // Track values at the moment of interactive press so React-controlled forms
    // that clear inputs on submit still give us a credential to save.
    var lastKnown = { username: "", password: "", host: "", ts: 0 };

    function updateLastKnown(passwordEl) {
        var pw = (passwordEl && passwordEl.value) || "";
        if (!pw) { return; }
        var user = findUsernameInput(passwordEl);
        lastKnown = {
            username: (user && user.value) || "",
            password: pw,
            host: host(),
            ts: Date.now()
        };
    }

    function emitSubmit(username, password) {
        if (!password) { return; }
        postMessage("passwordFormSubmitted", {
            host: host(),
            username: username || "",
            password: password
        });
        lastKnown = { username: "", password: "", host: "", ts: 0 };
    }

    function onSubmit(e) {
        try {
            var form = e.target;
            if (!form || form.tagName !== "FORM") { return; }
            var pwEl = form.querySelector("input[type=password]");
            if (!pwEl) {
                if (lastKnown.password && (Date.now() - lastKnown.ts) < RECENT_SUBMIT_TTL_MS) {
                    emitSubmit(lastKnown.username, lastKnown.password);
                }
                return;
            }
            updateLastKnown(pwEl);
            emitSubmit(lastKnown.username, lastKnown.password);
        } catch (_) {}
    }

    function onDocumentClickCapture(e) {
        // Heuristic submit-button handler (for SPAs that don't fire "submit")
        var t = e.target;
        if (!t) { return; }
        var btn = t.closest && t.closest("button, [role=button], input[type=submit]");
        if (!btn) { return; }
        var text = ((btn.innerText || "") + " " + (btn.getAttribute("aria-label") || "")).toLowerCase();
        // Only engage for buttons that look like sign-in actions.
        if (!/sign\s?in|log\s?in|continue|submit|enter/.test(text)) { return; }

        // Capture values NOW; React may clear them before the form-submit we can hook.
        var pwEl = document.querySelector("input[type=password]");
        if (pwEl && pwEl.value) { updateLastKnown(pwEl); }

        // Re-emit slightly later — gives React a chance to actually fire submit;
        // if it does, `onSubmit` consumes lastKnown and zeros it, so this is a no-op.
        setTimeout(function () {
            if (lastKnown.password) {
                emitSubmit(lastKnown.username, lastKnown.password);
            }
        }, 250);
    }

    // Keydown on password field can also indicate imminent submit (Enter).
    function onPasswordKeydown(e) {
        if (!e.target || !e.target.matches) { return; }
        if (!e.target.matches("input[type=password]")) { return; }
        if (e.key === "Enter") { updateLastKnown(e.target); }
    }

    // ----- Autofill (reply channel) -----
    //
    // The Swift side posts `window.__socketPasswordHints = [{username}, ...]`
    // via evaluateJavaScript when a username is available for this host — this
    // is a cheap hint so we don't spam the reply channel on every focus.
    //
    // When a password field focuses AND hints exist, we fire `passwordAutofillRequest`
    // on a reply-capable message handler. Swift replies with a list of
    // CredentialSuggestion (username + base64 persistentRef) — NOT passwords.
    // Choosing an entry triggers a separate `injectAutofill` from Swift that
    // writes into the DOM via `evaluateJavaScript`.
    //
    // We intentionally do NOT auto-inject: the user always confirms via popover.

    function hasHintsForCurrentHost() {
        try {
            return Array.isArray(window.__socketPasswordHints)
                && window.__socketPasswordHints.length > 0;
        } catch (_) { return false; }
    }

    async function requestAutofill(info, trigger) {
        try {
            var h = window.webkit
                && window.webkit.messageHandlers
                && window.webkit.messageHandlers.passwordAutofillRequest;
            if (!h || typeof h.postMessage !== "function") { return []; }
            var result = await h.postMessage({
                host: host(),
                frameURL: (function () { try { return window.location.href; } catch (_) { return ""; } })(),
                usernameFid: info.usernameFid,
                passwordFid: info.passwordFid,
                rect: info.rect,
                trigger: trigger || "focus"
            });
            return Array.isArray(result) ? result : [];
        } catch (_) {
            return [];
        }
    }

    // ----- Inline key icon (manual autofill invocation) -----
    //
    // Focus-triggered autofill only fires when Swift has hinted that saved
    // creds exist for this host. Users also want an explicit way to invoke
    // the picker — e.g. on a new host, or to switch between accounts. We
    // inject a small key icon anchored to each detected password field;
    // clicking it fires `requestAutofill(..., "icon")` which Swift treats
    // as "always show the popover, even with no suggestions."
    //
    // Positioning uses `position: fixed` against the viewport, with rect
    // recomputed on scroll/resize and via ResizeObserver. Light-DOM only
    // for v1 — shadow-root fields still work for submit/focus detection
    // but don't get a visible icon (the overlay element would need to
    // live inside the shadow root to render over shadow-scoped styles).

    // Subtle tile so the icon is visible on both white and light-gray fields,
    // without being as loud as the emoji was. Stronger stroke on the SVG + a
    // darker foreground so it reads even when the tile blends with the field.
    var ICON_STYLE = [
        "position: fixed",
        "width: 22px",
        "height: 22px",
        "display: flex",
        "align-items: center",
        "justify-content: center",
        "border-radius: 6px",
        "background: rgba(255, 255, 255, 0.92)",
        "box-shadow: 0 0 0 1px rgba(0, 0, 0, 0.08), 0 1px 2px rgba(0, 0, 0, 0.05)",
        "cursor: pointer",
        "z-index: 2147483647",
        "color: rgba(30, 30, 35, 0.85)",
        "user-select: none",
        "pointer-events: auto",
        "transition: background 120ms ease, color 120ms ease, box-shadow 120ms ease",
        "box-sizing: border-box"
    ].join(";");

    // Monochrome SF-Symbols-adjacent key glyph. Inherits color from the tile
    // via `currentColor` so it reads on both light and dark page backgrounds.
    var ICON_SVG = '<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="6" cy="10" r="3"/><path d="M9 10h9"/><path d="M15 10v2.6"/><path d="M17.6 10v3.2"/></svg>';

    // Attach an inline key icon to an input field. Pass the username input
    // when one exists (users look there first, matching Brave / Arc / 1Password
    // extension behavior). Fall back to the password field only when no
    // username is detected.
    function ensureInlineIcon(inputEl) {
        if (inputEl.__socketIconInstalled) { return; }
        inputEl.__socketIconInstalled = true;
        if (inputEl.ownerDocument !== document) { return; } // shadow/other

        var icon = document.createElement("div");
        icon.setAttribute("data-socket-autofill-icon", "1");
        icon.setAttribute("aria-hidden", "true");
        icon.style.cssText = ICON_STYLE;
        icon.innerHTML = ICON_SVG;
        icon.title = "Fill from Socket";

        icon.addEventListener("mousedown", function (e) {
            e.preventDefault();
            e.stopPropagation();
        }, true);
        icon.addEventListener("click", function (e) {
            e.preventDefault();
            e.stopPropagation();
            var info = describeFieldsForInput(inputEl);
            if (info) { requestAutofill(info, "icon"); }
        }, true);
        icon.addEventListener("mouseenter", function () {
            icon.style.background = "rgba(245, 245, 247, 1)";
            icon.style.boxShadow = "0 0 0 1px rgba(0, 0, 0, 0.14), 0 2px 4px rgba(0, 0, 0, 0.08)";
        });
        icon.addEventListener("mouseleave", function () {
            icon.style.background = "rgba(255, 255, 255, 0.92)";
            icon.style.boxShadow = "0 0 0 1px rgba(0, 0, 0, 0.08), 0 1px 2px rgba(0, 0, 0, 0.05)";
        });

        document.body.appendChild(icon);

        // Password fields often have a site-rendered show/hide eye icon at the
        // far right — reserve room for it. Username fields almost never do,
        // so we can park ours closer to the edge.
        var isPassword = inputEl.matches && inputEl.matches("input[type=password]");
        var gutterRight = isPassword ? 36 : 6;

        function updatePosition() {
            var rect = inputEl.getBoundingClientRect();
            // Hide when the field is detached, invisible, or too small
            // to accommodate the icon without clobbering the text.
            if (rect.width < 80 || rect.height < 18) {
                icon.style.display = "none";
                return;
            }
            icon.style.display = "flex";
            icon.style.left = (rect.right - 22 - gutterRight) + "px";
            icon.style.top = (rect.top + (rect.height - 22) / 2) + "px";
        }
        updatePosition();

        var ro = null;
        try {
            ro = new ResizeObserver(updatePosition);
            ro.observe(inputEl);
        } catch (_) { /* Safari < 13.1 */ }

        window.addEventListener("scroll", updatePosition, true);
        window.addEventListener("resize", updatePosition);

        // Detach when the input leaves the document. Re-check on DOM mutations.
        var detachObserver = new MutationObserver(function () {
            if (!document.contains(inputEl)) {
                icon.remove();
                if (ro) { ro.disconnect(); }
                window.removeEventListener("scroll", updatePosition, true);
                window.removeEventListener("resize", updatePosition);
                detachObserver.disconnect();
                inputEl.__socketIconInstalled = false;
            } else {
                updatePosition();
            }
        });
        detachObserver.observe(document.documentElement || document, {
            childList: true, subtree: true
        });
    }

    // ----- Wire + observe -----

    function install() {
        document.addEventListener("focusin", onPasswordFocus, true);
        document.addEventListener("submit", onSubmit, true);
        document.addEventListener("click", onDocumentClickCapture, true);
        document.addEventListener("keydown", onPasswordKeydown, true);
        scan();
    }

    function scan() {
        var pwFields = collectPasswordFields();
        for (var i = 0; i < pwFields.length; i++) {
            ensureFid(pwFields[i]);
            var user = findUsernameInput(pwFields[i]);
            if (user) { ensureFid(user, USERNAME_ATTR); }
            if (isTopFrame) {
                // Prefer the username field as the icon's host — that's what
                // users focus first and matches the Brave / 1Password pattern.
                // Fall back to the password field for "just password" forms.
                ensureInlineIcon(user || pwFields[i]);
            }
        }
    }

    // Filter: only rescan when mutations likely affect form state. Subtree
    // observers on `documentElement` fire for every DOM change on the page,
    // which is punishing on doc-editor apps. We skip the scan unless the
    // mutations added something that looks like an input (or its container).
    function mutationsAreRelevant(mutations) {
        for (var i = 0; i < mutations.length; i++) {
            var m = mutations[i];
            if (m.type !== "childList") { continue; }
            for (var j = 0; j < m.addedNodes.length; j++) {
                var node = m.addedNodes[j];
                if (!node || node.nodeType !== 1) { continue; }
                if (node.tagName === "INPUT" || node.tagName === "FORM") { return true; }
                if (node.querySelector && node.querySelector("input")) { return true; }
            }
        }
        return false;
    }

    var mutationTimer = null;
    var observer = new MutationObserver(function (mutations) {
        if (mutationTimer) { return; }
        if (!mutationsAreRelevant(mutations)) { return; }
        mutationTimer = setTimeout(function () {
            mutationTimer = null;
            scan();
        }, MUTATION_DEBOUNCE_MS);
    });

    function startup() {
        install();
        // Child frames: only do submit/focus capture. No mutation observer —
        // iframed apps can mutate heavily and we don't need dynamic form
        // discovery there (initial scan at install catches the common cases).
        if (!isTopFrame) { return; }
        observer.observe(document.documentElement || document, { childList: true, subtree: true });
    }

    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", startup);
    } else {
        startup();
    }
})();
