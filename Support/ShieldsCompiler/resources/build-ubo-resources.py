#!/usr/bin/env python3
"""
Generate `ubo-resources.json` containing hand-written, MVP-quality
implementations of the most-referenced uBlock Origin scriptlets.

Why hand-written? adblock-rust's `assemble_scriptlet_resources` reads
uBlock Origin's historical `scriptlets.js` aggregate file, but that
format was retired in 2022+ — uBO now ships modular ES files we can't
feed to adblock-rust without reimplementing their build pipeline.
Bundling the 6-7 most-impactful scriptlets manually unlocks the
`ubo-quick-fixes` filter list (which references these) without taking
on the full uBO build dep.

Coverage targets (top patterns we see in uBO Quick Fixes):
  * noeval        — neutralise window.eval
  * noeval-if     — neutralise window.eval if arg matches
  * aopr          — abort on property read (throw ReferenceError)
  * set-constant  — pin a property to a constant value (noopFunc, etc.)
  * nostif        — neutralise setTimeout if body matches needle
  * nofiif        — neutralise fetch if URL matches needle
  * trusted_types — bypass document.policy CSP "trusted types"

These are intentionally simplified vs. uBO's production versions.
False-positive risk is low because the filter list authors only invoke
them with conservative arguments. False-negative risk is moderate but
acceptable — sites that need exotic options keep their unblocked state
(no regression from where we are today).

Run:
    python3 build-ubo-resources.py
Outputs:
    ubo-resources.json (alongside this script)

Re-run whenever a scriptlet body is edited below.
"""

import base64
import json
import os

# Each entry: (name, aliases, body)
# Body uses `{{1}}`, `{{2}}` etc. for adblock-rust template substitution.
SCRIPTLETS = [
    (
        "noeval.js",
        ["noeval", "silent-noeval", "noeval-silent"],
        r"""
(function() {
  try {
    Object.defineProperty(window, 'eval', {
      configurable: false,
      enumerable: false,
      writable: false,
      value: function() { /* swallowed by Socket Shields */ }
    });
  } catch (e) {}
})();
""",
    ),
    (
        "noeval-if.js",
        ["noeval-if"],
        r"""
(function() {
  try {
    var raw = '{{1}}';
    var needle = null;
    if (raw && raw !== '{{1}}') {
      try { needle = new RegExp(raw); } catch (e) {}
    }
    var original = window.eval;
    Object.defineProperty(window, 'eval', {
      configurable: false,
      enumerable: false,
      writable: false,
      value: function(src) {
        if (needle && typeof src === 'string' && needle.test(src)) return;
        return original.apply(this, arguments);
      }
    });
  } catch (e) {}
})();
""",
    ),
    (
        "abort-on-property-read.js",
        ["aopr", "abort-on-property-read"],
        r"""
(function() {
  try {
    var raw = '{{1}}';
    if (!raw || raw === '{{1}}') return;
    var chain = raw.split('.');
    var owner = window;
    for (var i = 0; i < chain.length - 1; i++) {
      owner = owner[chain[i]];
      if (!owner || typeof owner !== 'object') return;
    }
    var prop = chain[chain.length - 1];
    var token = 'shields-aopr-' + Math.floor(Math.random() * 1e9);
    Object.defineProperty(owner, prop, {
      configurable: false,
      get: function() { throw new ReferenceError(token); },
      set: function() {}
    });
    var origOnError = window.onerror;
    window.onerror = function(msg) {
      if (typeof msg === 'string' && msg.indexOf(token) !== -1) return true;
      if (origOnError) return origOnError.apply(this, arguments);
    };
  } catch (e) {}
})();
""",
    ),
    (
        "set-constant.js",
        ["set-constant", "set"],
        r"""
(function() {
  try {
    var rawChain = '{{1}}';
    var rawValue = '{{2}}';
    if (!rawChain || rawChain === '{{1}}') return;
    var value;
    switch (rawValue) {
      case 'noopFunc': value = function() {}; break;
      case 'trueFunc': value = function() { return true; }; break;
      case 'falseFunc': value = function() { return false; }; break;
      case 'true': value = true; break;
      case 'false': value = false; break;
      case 'null': value = null; break;
      case 'undefined': value = undefined; break;
      case '': value = ''; break;
      case '{}': value = {}; break;
      case '[]': value = []; break;
      default:
        if (/^-?\d+$/.test(rawValue)) value = +rawValue;
        else value = rawValue;
    }
    var chain = rawChain.split('.');
    var owner = window;
    for (var i = 0; i < chain.length - 1; i++) {
      if (owner[chain[i]] === undefined || owner[chain[i]] === null) {
        owner[chain[i]] = {};
      }
      owner = owner[chain[i]];
      if (typeof owner !== 'object') return;
    }
    var prop = chain[chain.length - 1];
    Object.defineProperty(owner, prop, {
      configurable: false,
      get: function() { return value; },
      set: function() {}
    });
  } catch (e) {}
})();
""",
    ),
    (
        "no-setTimeout-if.js",
        ["nostif", "no-setTimeout-if", "prevent-setTimeout"],
        r"""
(function() {
  try {
    var raw = '{{1}}';
    var rawDelay = '{{2}}';
    var delay = -1;
    if (rawDelay && rawDelay !== '{{2}}') {
      var n = parseInt(rawDelay, 10);
      if (!isNaN(n)) delay = n;
    }
    var needle = null;
    if (raw && raw !== '{{1}}') {
      try { needle = new RegExp(raw); } catch (e) {}
    }
    var orig = window.setTimeout;
    window.setTimeout = function(fn, ms) {
      try {
        var fnStr = typeof fn === 'function' ? fn.toString() : String(fn);
        var matchBody = needle ? needle.test(fnStr) : true;
        var matchDelay = delay < 0 ? true : ms === delay;
        if (matchBody && matchDelay) return 0;
      } catch (e) {}
      return orig.apply(this, arguments);
    };
  } catch (e) {}
})();
""",
    ),
    (
        "no-fetch-if.js",
        ["nofiif", "no-fetch-if", "prevent-fetch"],
        r"""
(function() {
  try {
    var raw = '{{1}}';
    var needle = null;
    if (raw && raw !== '{{1}}') {
      try { needle = new RegExp(raw); } catch (e) {}
    }
    if (!needle) return;
    var orig = window.fetch;
    if (typeof orig !== 'function') return;
    window.fetch = function(input, init) {
      try {
        var url = typeof input === 'string'
          ? input
          : (input && typeof input === 'object' && input.url ? input.url : '');
        if (needle.test(url)) {
          return Promise.resolve(new Response(null, {
            status: 200,
            statusText: 'OK'
          }));
        }
      } catch (e) {}
      return orig.apply(this, arguments);
    };
  } catch (e) {}
})();
""",
    ),
    (
        "no-xhr-if.js",
        ["noxhrif", "no-xhr-if", "prevent-xhr"],
        r"""
(function() {
  try {
    var raw = '{{1}}';
    var needle = null;
    if (raw && raw !== '{{1}}') {
      try { needle = new RegExp(raw); } catch (e) {}
    }
    if (!needle) return;
    var XHR = window.XMLHttpRequest;
    if (!XHR || !XHR.prototype) return;
    var origOpen = XHR.prototype.open;
    XHR.prototype.open = function(method, url) {
      try {
        if (typeof url === 'string' && needle.test(url)) {
          this._socketShieldsBlock = true;
        }
      } catch (e) {}
      return origOpen.apply(this, arguments);
    };
    var origSend = XHR.prototype.send;
    XHR.prototype.send = function() {
      if (this._socketShieldsBlock) return;
      return origSend.apply(this, arguments);
    };
  } catch (e) {}
})();
""",
    ),
]


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out_path = os.path.join(here, "ubo-resources.json")

    entries = []
    for name, aliases, body in SCRIPTLETS:
        encoded = base64.b64encode(body.strip().encode("utf-8")).decode("ascii")
        entries.append(
            {
                "name": name,
                "aliases": aliases,
                "kind": {"mime": "application/javascript"},
                "content": encoded,
            }
        )

    with open(out_path, "w") as f:
        json.dump(entries, f, indent=2)
        f.write("\n")
    print(f"Wrote {len(entries)} scriptlet entries to {out_path}")


if __name__ == "__main__":
    main()
