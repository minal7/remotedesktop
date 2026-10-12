(function (root) {
  "use strict";

  const SCHEMA_VERSION = 1;
  const NATIVE_APP_ID = "com.threadmark.remotedesktop";
  const PING_MESSAGE_KIND = "remoteDesktop.ping.v1";
  const ERRORS = new Set([
    "bridgeUnavailable",
    "invalidPayload",
    "unauthorizedTask",
    "staleTask",
    "wrongTab",
    "missingPageAccess",
    "tabNotFound",
    "operationFailed",
    "unsupported"
  ]);
  const ALLOWED_HOSTS = new Map([
    ["mail.google.com", ["/"]],
    ["drive.google.com", ["/"]],
    ["www.dropbox.com", ["/"]],
    ["www.google.com", ["/travel"]]
  ]);

  function createBridge(api) {
    let nativePort = null;
    let activeTaskToken = null;
    let boundTab = null;
    let active = false;

    function validUUID(value) {
      return typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
    }

    function validTaskToken(value) {
      return typeof value === "string" && /^[0-9a-f]{32}$/.test(value);
    }

    function validURL(value) {
      if (typeof value !== "string" || value.length > 4096) return false;
      let url;
      try {
        url = new URL(value);
      } catch (_) {
        return false;
      }
      if (url.protocol !== "https:" || url.port !== "" || url.username || url.password) return false;
      const paths = ALLOWED_HOSTS.get(url.hostname);
      return !!paths && paths.some((prefix) => prefix === "/" || url.pathname === prefix || url.pathname.startsWith(`${prefix}/`));
    }

    function validateCommand(command) {
      if (!command || typeof command !== "object" || Array.isArray(command)) return "invalidPayload";
      if (command.schemaVersion !== SCHEMA_VERSION || !validUUID(command.commandId) || !validTaskToken(command.taskToken)) return "invalidPayload";
      if (!["ping", "openTab", "endTask"].includes(command.operation)) return "unsupported";
      const allowed = new Set(["schemaVersion", "commandId", "taskToken", "operation", "tabId", "windowId", "nonce", "url"]);
      if (Object.keys(command).some((key) => !allowed.has(key))) return "invalidPayload";

      if (command.operation === "openTab") {
        if (command.tabId !== undefined || command.windowId !== undefined || command.nonce !== undefined || !validURL(command.url)) return "invalidPayload";
      } else if (command.operation === "ping") {
        if (!Number.isSafeInteger(command.tabId) || command.tabId < 0 || !Number.isSafeInteger(command.windowId) || command.windowId < 0 || typeof command.nonce !== "string" || command.nonce.length < 1 || command.nonce.length > 128 || command.url !== undefined) return "invalidPayload";
      } else if (command.operation === "endTask") {
        if (command.tabId !== undefined || command.windowId !== undefined || command.nonce !== undefined || command.url !== undefined) return "invalidPayload";
      }
      return null;
    }

    function resultFor(command, status, fields) {
      const result = {
        schemaVersion: SCHEMA_VERSION,
        commandId: command && command.commandId,
        taskToken: command && command.taskToken,
        operation: command && command.operation,
        status
      };
      if (fields) Object.assign(result, fields);
      return result;
    }

    function errorResult(command, error) {
      return resultFor(command, "error", { error: ERRORS.has(error) ? error : "operationFailed" });
    }

    function activateNativePort() {
      if (nativePort) return nativePort;
      if (!api.runtime || typeof api.runtime.connectNative !== "function") return null;
      try {
        nativePort = api.runtime.connectNative(NATIVE_APP_ID);
        nativePort.onMessage.addListener((message) => receiveHostMessage(message));
        nativePort.onDisconnect.addListener(() => {
          nativePort = null;
          clearTaskBinding();
          // Repeated native failures must stay unavailable, not continually
          // relaunch the appex. A fresh background lifecycle opens a new port.
        });
        return nativePort;
      } catch (_) {
        nativePort = null;
        return null;
      }
    }

    function sendResult(result) {
      if (!api.runtime || typeof api.runtime.sendNativeMessage !== "function") return;
      try {
        // Safari ignores the application identifier and routes to this app's
        // SafariWebExtensionHandler. Keep the callback form for Safari API compatibility.
        api.runtime.sendNativeMessage(NATIVE_APP_ID, result, function () {});
      } catch (_) {
        // The native side has its own one-second command deadline and reports
        // bridgeUnavailable if no correlated response arrives.
      }
    }

    function respond(command, result) {
      sendResult(result);
      return result;
    }

    function receiveHostMessage(message) {
      const command = unwrapHostMessage(message);
      if (!command) return;
      handleCommand(command).then((result) => respond(command, result));
    }

    function unwrapHostMessage(message) {
      if (!message || typeof message !== "object" || Array.isArray(message)) return null;
      // SFSafariApplication's fixed message name selects the extension route;
      // its userInfo arrives on the native port as the raw command object.
      if (message.schemaVersion === SCHEMA_VERSION) return message;
      return null;
    }

    async function handleCommand(command) {
      const validationError = validateCommand(command);
      if (validationError) return errorResult(command, validationError);

      if (command.operation === "openTab") return openTab(command);
      if (command.operation === "endTask") return endTask(command);
      return ping(command);
    }

    function openTab(command) {
      if (activeTaskToken && activeTaskToken !== command.taskToken) return errorResult(command, "unauthorizedTask");
      if (activeTaskToken === command.taskToken && boundTab) return errorResult(command, "staleTask");
      activeTaskToken = command.taskToken;
      active = true;
      return new Promise((resolve) => {
        try {
          api.tabs.create({ url: command.url, active: true }, (tab) => {
            const lastError = api.runtime && api.runtime.lastError;
            if (lastError || !tab || !Number.isSafeInteger(tab.id) || !Number.isSafeInteger(tab.windowId)) {
              if (activeTaskToken === command.taskToken) clearTaskBinding();
              resolve(errorResult(command, lastError ? "operationFailed" : "tabNotFound"));
              return;
            }
            if (!active || activeTaskToken !== command.taskToken) {
              resolve(errorResult(command, "staleTask"));
              return;
            }
            boundTab = { tabId: tab.id, windowId: tab.windowId };
            resolve(resultFor(command, "ok", { tabId: tab.id, windowId: tab.windowId }));
          });
        } catch (_) {
          if (activeTaskToken === command.taskToken) clearTaskBinding();
          resolve(errorResult(command, "operationFailed"));
        }
      });
    }

    async function ping(command) {
      if (activeTaskToken && command.taskToken !== activeTaskToken) return errorResult(command, "unauthorizedTask");
      if (boundTab) {
        if (command.tabId !== boundTab.tabId || command.windowId !== boundTab.windowId) return errorResult(command, "wrongTab");
        return pingBound(command);
      }

      // A ping is also the explicit host-resume handshake after Safari or its
      // service worker restarts. It can rebind only the one tab id the
      // authenticated host supplies; the bridge never enumerates tabs.
      return new Promise((resolve) => {
        try {
          api.tabs.get(command.tabId, (tab) => {
            const lastError = api.runtime && api.runtime.lastError;
            if (lastError || !tab) {
              resolve(errorResult(command, "tabNotFound"));
              return;
            }
            if (tab.windowId !== command.windowId || !validURL(tab.url)) {
              resolve(errorResult(command, "wrongTab"));
              return;
            }
            activeTaskToken = command.taskToken;
            boundTab = { tabId: tab.id, windowId: tab.windowId };
            active = true;
            pingBound(command).then(resolve);
          });
        } catch (_) {
          resolve(errorResult(command, "tabNotFound"));
        }
      });
    }

    function pingBound(command) {
      const expectedTab = { ...boundTab };
      const pingMessage = {
        kind: PING_MESSAGE_KIND,
        commandId: command.commandId,
        taskToken: command.taskToken,
        nonce: command.nonce,
        tabId: expectedTab.tabId,
        windowId: expectedTab.windowId
      };
      return new Promise((resolve) => {
        try {
          api.tabs.sendMessage(expectedTab.tabId, pingMessage, { frameId: 0 }, (contentResult) => {
            const lastError = api.runtime && api.runtime.lastError;
            if (!active || activeTaskToken !== command.taskToken || !boundTab || boundTab.tabId !== expectedTab.tabId || boundTab.windowId !== expectedTab.windowId) {
              resolve(errorResult(command, "staleTask"));
              return;
            }
            if (lastError) {
              resolve(errorResult(command, "missingPageAccess"));
              return;
            }
            if (!validContentResult(command, contentResult, expectedTab)) {
              resolve(errorResult(command, "operationFailed"));
              return;
            }
            resolve(resultFor(command, "ok", {
              tabId: expectedTab.tabId,
              windowId: expectedTab.windowId,
              nonce: command.nonce,
              documentId: contentResult.documentId
            }));
          });
        } catch (_) {
          resolve(errorResult(command, "missingPageAccess"));
        }
      });
    }

    function validContentResult(command, response, expectedTab) {
      return !!response && response.schemaVersion === SCHEMA_VERSION && response.status === "ok" &&
        response.commandId === command.commandId && response.taskToken === command.taskToken &&
        response.operation === "ping" && response.tabId === expectedTab.tabId &&
        response.windowId === expectedTab.windowId && response.nonce === command.nonce &&
        typeof response.documentId === "string" && response.documentId.length >= 1 && response.documentId.length <= 128;
    }

    function endTask(command) {
      if (!activeTaskToken || command.taskToken !== activeTaskToken) return errorResult(command, "unauthorizedTask");
      const fields = boundTab ? { tabId: boundTab.tabId, windowId: boundTab.windowId } : {};
      // R1.0 detaches authority. Closing a tab requires a separately agreed
      // ownership proof contract, so this slice never closes browser tabs.
      clearTaskBinding();
      return resultFor(command, "ok", fields);
    }

    function clearTaskBinding() {
      activeTaskToken = null;
      boundTab = null;
      active = false;
    }

    return {
      activateNativePort,
      handleCommand,
      receiveHostMessage,
      getState: () => ({ active, activeTaskToken, boundTab: boundTab && { ...boundTab }, hasNativePort: !!nativePort })
    };
  }

  if (typeof module !== "undefined" && module.exports) {
    module.exports = { createBridge };
  }

  if (root.browser && root.browser.runtime) {
    const bridge = createBridge(root.browser);
    // Safari delivers the containing app's dispatchMessage userInfo through
    // this native port. The idle connection performs no polling or tab work.
    bridge.activateNativePort();
  }

  root.SafariComputerUseBridge = { createBridge };
})(typeof globalThis === "object" ? globalThis : this);
