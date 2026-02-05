// Copyright (c) 2022 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

"use strict";

(function() {
  const messageHandler = '$<message_handler>';
  const windowOrigin = window.location.origin;
  let sendInfo = [];
  let sendInfoTimeout = null;

  function postNativeMessage(payload) {
    const handler = window.webkit && window.webkit.messageHandlers
      ? window.webkit.messageHandlers[messageHandler]
      : null;
    if (!handler || typeof handler.postMessage !== 'function') {
      return;
    }
    handler.postMessage(payload);
  }

  function sendMessage(urlString, resourceType) {
    if (!urlString) {
      return;
    }

    let resourceURL = null;
    try {
      resourceURL = new URL(urlString, document.location.href);
      if (document.location.host === resourceURL.host) {
        return;
      }
    } catch (error) {
      return;
    }

    sendInfo.push({
      resourceURL: resourceURL.href,
      sourceURL: windowOrigin,
      resourceType: resourceType
    });

    if (sendInfoTimeout) {
      return;
    }

    sendInfoTimeout = setTimeout(() => {
      sendInfoTimeout = null;
      if (sendInfo.length === 0) {
        return;
      }
      postNativeMessage({
        securityToken: SECURITY_TOKEN,
        data: sendInfo
      });
      sendInfo = [];
    }, 500);
  }

  function onLoadNativeCallback() {
    Array.from(document.scripts).forEach(el => {
      sendMessage(el.src, "script");
    });
    Array.from(document.images).forEach(el => {
      sendMessage(el.src, "image");
    });
    Array.from(document.getElementsByTagName("subdocument")).forEach(el => {
      sendMessage(el.src, "subdocument");
    });
  }

  let originalXHROpen = null;
  let originalXHRSend = null;
  let originalFetch = null;
  let originalImageSrc = null;
  let mutationObserver = null;

  function injectStatsTracking(enabled) {
    if (enabled) {
      if (originalXHROpen) {
        return;
      }
      window.addEventListener("load", onLoadNativeCallback, false);
    } else {
      window.removeEventListener("load", onLoadNativeCallback, false);

      if (originalXHROpen) {
        XMLHttpRequest.prototype.open = originalXHROpen;
        XMLHttpRequest.prototype.send = originalXHRSend;
        window.fetch = originalFetch;
        if (mutationObserver) {
          mutationObserver.disconnect();
        }

        originalXHROpen = null;
        originalXHRSend = null;
        originalFetch = null;
        originalImageSrc = null;
        mutationObserver = null;
      }
      return;
    }

    const localURLProp = Symbol("url");
    const localErrorHandlerProp = Symbol("tpErrorHandler");

    if (!originalXHROpen) {
      originalXHROpen = XMLHttpRequest.prototype.open;
      originalXHRSend = XMLHttpRequest.prototype.send;
    }

    XMLHttpRequest.prototype.open = function(method, url, isAsync) {
      if (isAsync === undefined || isAsync) {
        return originalXHROpen.apply(this, arguments);
      }
      this[localURLProp] = url;
      return originalXHROpen.apply(this, arguments);
    };

    XMLHttpRequest.prototype.send = function(body) {
      let url = this[localURLProp];
      if (!url) {
        return originalXHRSend.apply(this, arguments);
      }

      if (!this[localErrorHandlerProp]) {
        this[localErrorHandlerProp] = function() {
          sendMessage(url, "xmlhttprequest");
        };
        this.addEventListener("error", this[localErrorHandlerProp]);
      }
      return originalXHRSend.apply(this, arguments);
    };

    if (!originalFetch) {
      originalFetch = window.fetch;
    }

    window.fetch = function(input, init) {
      if (typeof input === "string") {
        sendMessage(input, "xmlhttprequest");
      } else if (input instanceof Request) {
        sendMessage(input.url, "xmlhttprequest");
      }
      return originalFetch.apply(window, arguments);
    };

    if (!originalImageSrc) {
      originalImageSrc = Object.getOwnPropertyDescriptor(Image.prototype, "src");
    }

    delete Image.prototype.src;

    Object.defineProperty(Image.prototype, "src", {
      get: function() {
        return originalImageSrc.get.call(this);
      },
      set: function(value) {
        if (!this[localErrorHandlerProp]) {
          this[localErrorHandlerProp] = function() {
            sendMessage(this.src, "image");
          };
          this.addEventListener("error", this[localErrorHandlerProp]);
        }
        originalImageSrc.set.call(this, value);
      },
      enumerable: true,
      configurable: true
    });

    mutationObserver = new MutationObserver(function(mutations) {
      mutations.forEach(function(mutation) {
        mutation.addedNodes.forEach(function(node) {
          if (node.tagName === "SCRIPT" && node.src) {
            sendMessage(node.src, "script");
            return;
          }
          if (node.tagName === "IMG" && node.src) {
            sendMessage(node.src, "image");
            return;
          }
          if (node.tagName === "IFRAME" && node.src) {
            if (node.src === "about:blank") {
              return;
            }
            sendMessage(node.src, "subdocument");
            return;
          }
        });
      });
    });

    mutationObserver.observe(document.documentElement, {
      childList: true,
      subtree: true
    });
  }

  injectStatsTracking(true);
})();
