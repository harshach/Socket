// WebStoreInjector.js
// Injects "Add to Socket" functionality into Chrome Web Store pages

(function () {
  "use strict";

  const CHROME_STORE_PATTERNS = [
    /^https?:\/\/chrome\.google\.com\/webstore\/.+?\/([a-z]{32})(?=[\/#?]|$)/,
    /^https?:\/\/chromewebstore\.google\.com\/detail\/.+?\/([a-z]{32})(?=[\/#?]|$)/,
  ];

  const EDGE_STORE_PATTERN =
    /^https?:\/\/microsoftedge\.microsoft\.com\/addons\/detail\/.+?\/([a-z]{32})(?=[\/#?]|$)/;

  function getExtensionId() {
    const url = window.location.href;

    // Try Chrome Web Store patterns
    for (const pattern of CHROME_STORE_PATTERNS) {
      const match = pattern.exec(url);
      if (match && match[1]) {
        return { id: match[1], store: "chrome" };
      }
    }

    // Try Edge Store pattern
    const edgeMatch = EDGE_STORE_PATTERN.exec(url);
    if (edgeMatch && edgeMatch[1]) {
      return { id: edgeMatch[1], store: "edge" };
    }

    return null;
  }

  function createSocketButton(extensionId, store) {
    const button = document.createElement("button");
    button.className = "socket-install-button";
    button.textContent = "Add to Socket";
    button.style.cssText = `
            background-color: #0A57D0;
            color: white;
            border: none;
            padding: 12px 24px;
            font-size: 14px;
            font-weight: 600;
            border-radius: 9999px;
            cursor: pointer;
            box-shadow: 0 1px 3px rgba(0, 0, 0, 0.12), 0 1px 2px rgba(0, 0, 0, 0.08);
            transition: all 0.2s ease;
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            min-width: 140px;
        `;

    button.addEventListener("mouseenter", () => {
      button.style.transform = "translateY(-1px)";
      button.style.boxShadow =
        "0 4px 8px rgba(0, 0, 0, 0.15), 0 2px 4px rgba(0, 0, 0, 0.1)";
    });

    button.addEventListener("mouseleave", () => {
      button.style.transform = "translateY(0)";
      button.style.boxShadow =
        "0 1px 3px rgba(0, 0, 0, 0.12), 0 1px 2px rgba(0, 0, 0, 0.08)";
    });

    button.addEventListener("click", () => {
      button.disabled = true;
      button.textContent = "Installing...";
      button.style.opacity = "0.7";

      // Send message to native app
      if (
        window.webkit &&
        window.webkit.messageHandlers &&
        window.webkit.messageHandlers.socketWebStore
      ) {
        window.webkit.messageHandlers.socketWebStore.postMessage({
          action: "installExtension",
          extensionId: extensionId,
          store: store,
          url: window.location.href,
        });
      } else {
        button.disabled = false;
        button.textContent = "Add to Socket";
        button.style.opacity = "1";
        alert("Unable to install extension. Please try again.");
      }
    });

    return button;
  }

  function replaceInstallButton() {
    const extensionInfo = getExtensionId();
    if (!extensionInfo) {
      return;
    }

    // Selectors for Chrome Web Store buttons
    const selectors = [
      'div[role="button"]', // New Chrome Web Store
      "button", // Generic buttons
      ".webstore-test-button-label", // Old Chrome Web Store
      '[aria-label*="Add to Chrome"]', // Aria label
      '[aria-label*="Remove from Chrome"]', // Already installed
    ];

    // Try to find and replace the install button
    for (const selector of selectors) {
      const buttons = document.querySelectorAll(selector);
      for (const button of buttons) {
        const text = button.textContent?.trim().toLowerCase() || "";
        const ariaLabel =
          button.getAttribute("aria-label")?.toLowerCase() || "";

        if (
          text.includes("add to chrome") ||
          text.includes("remove from chrome") ||
          ariaLabel.includes("add to chrome") ||
          ariaLabel.includes("remove from chrome") ||
          text === "unavailable" ||
          button.hasAttribute("disabled")
        ) {
          // Found the Chrome button - replace it
          const socketButton = createSocketButton(
            extensionInfo.id,
            extensionInfo.store
          );

          // Try to maintain the same parent structure
          if (button.parentElement) {
            button.parentElement.insertBefore(socketButton, button);
            button.style.display = "none";
            return;
          }
        }
      }
    }

    // If no button found, try to inject into common locations
    const headerSelectors = [
      ".e-f-oh", // Chrome Web Store header
      ".h-C-b-p", // Alternative header
      '[role="main"] > div:first-child', // Main content first child
    ];

    for (const selector of headerSelectors) {
      const container = document.querySelector(selector);
      if (container) {
        const socketButton = createSocketButton(
          extensionInfo.id,
          extensionInfo.store
        );
        const wrapper = document.createElement("div");
        wrapper.style.cssText = "display: inline-block; margin: 12px;";
        wrapper.appendChild(socketButton);
        container.appendChild(wrapper);
        return;
      }
    }
  }

  // Handle installation completion from native app
  window.addEventListener("socketInstallComplete", (event) => {
    const button = document.querySelector(".socket-install-button");
    if (button) {
      if (event.detail?.success) {
        // Keep the blue look, just update text
        button.textContent = "Added to Socket";
        button.disabled = true;
        button.style.opacity = "1";
        button.style.cursor = "default";
      } else {
        // Show error briefly, then reset
        button.textContent = "Installation Failed";
        button.style.opacity = "0.7";
        setTimeout(() => {
          button.disabled = false;
          button.textContent = "Add to Socket";
          button.style.opacity = "1";
          button.style.cursor = "pointer";
        }, 2000);
      }
    }
  });

  // Run on page load
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", replaceInstallButton);
  } else {
    replaceInstallButton();
  }

  // Watch for dynamic changes (SPA navigation)
  const observer = new MutationObserver((mutations) => {
    for (const mutation of mutations) {
      if (mutation.addedNodes.length > 0) {
        // Check if we're on a new extension page
        const extensionInfo = getExtensionId();
        if (extensionInfo && !document.querySelector(".socket-install-button")) {
          replaceInstallButton();
          break;
        }
      }
    }
  });

  observer.observe(document.body, {
    childList: true,
    subtree: true,
  });
})();
