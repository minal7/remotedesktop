(function (root) {
  "use strict";
  const VERSION = 1;
  const NATIVE_APP_ID = "com.threadmark.remotedesktop";
  const ERRORS = new Set(["bridgeUnavailable", "invalidPayload", "unauthorizedTask", "staleTask", "wrongTab",
    "missingPageAccess", "tabNotFound", "operationFailed", "unsupported", "targetGone", "targetChanged",
    "targetCovered", "disabledTarget", "credentialHandoff", "inactiveTab", "fileInjectionUnsupported"]);
  const OPERATIONS = new Set(["ping", "openTab", "endTask", "snapshot", "click", "type", "key", "scroll",
    "select", "drag", "navigate", "wait", "captureVisibleTab", "setFiles"]);
  const PAGE_OPERATIONS = new Set(["ping", "snapshot", "click", "type", "key", "scroll", "select", "drag", "wait", "setFiles"]);
  const MAX_COMMAND_BYTES = 400 * 1024;

  function createBridge(api) {
    let nativePort = null, activeTaskToken = null, boundTab = null, active = false;
    const fileTransfers = new Map();
    const validUUID = (value) => typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
    const validToken = (value) => typeof value === "string" && /^[0-9a-f]{32}$/.test(value);

    function validURL(value) {
      if (typeof value !== "string" || value.length > 4096) return false;
      let url; try { url = new URL(value); } catch (_) { return false; }
      if (url.username || url.password) return false;
      if (url.protocol === "https:") return true;
      if (url.protocol !== "http:") return false;
      if (url.hostname === "localhost" || url.hostname === "[::1]") return true;
      const octets = url.hostname.split(".");
      return octets.length === 4 && octets[0] === "127" && octets.every((part) => /^\d{1,3}$/.test(part) && Number(part) <= 255);
    }

    function validCommand(command) {
      if (!command || typeof command !== "object" || Array.isArray(command) || command.schemaVersion !== VERSION ||
          !validUUID(command.commandId) || !validToken(command.taskToken) || !OPERATIONS.has(command.operation)) return false;
      const allowed = new Set(["schemaVersion", "commandId", "taskToken", "operation", "tabId", "windowId", "nonce", "url", "payloadJSON"]);
      if (Object.keys(command).some((key) => !allowed.has(key))) return false;
      if (command.operation === "openTab" || command.operation === "navigate") {
        if (!validURL(command.url)) return false;
      } else if (command.url !== undefined) return false;
      if (command.operation === "openTab" || command.operation === "endTask") {
        return command.tabId === undefined && command.windowId === undefined && command.nonce === undefined && command.payloadJSON === undefined;
      }
      if (command.operation === "navigate") return Number.isSafeInteger(command.tabId) && command.tabId >= 0 &&
        Number.isSafeInteger(command.windowId) && command.windowId >= 0 && command.nonce === undefined && command.payloadJSON === undefined;
      if (!Number.isSafeInteger(command.tabId) || command.tabId < 0 || !Number.isSafeInteger(command.windowId) || command.windowId < 0) return false;
      if (command.operation === "ping") return typeof command.nonce === "string" && command.nonce.length > 0 && command.nonce.length <= 128 && command.payloadJSON === undefined;
      if (command.nonce !== undefined) return false;
      if (command.operation === "captureVisibleTab") return command.payloadJSON === undefined;
      if (typeof command.payloadJSON !== "string" || command.payloadJSON.length > MAX_COMMAND_BYTES) return false;
      try { const payload = JSON.parse(command.payloadJSON); return !!payload && typeof payload === "object" && !Array.isArray(payload); }
      catch (_) { return false; }
    }

    const payloadOf = (command) => command.payloadJSON ? JSON.parse(command.payloadJSON) : {};
    function resultFor(command, status, fields = {}) {
      return { schemaVersion: VERSION, commandId: command && command.commandId, taskToken: command && command.taskToken,
        operation: command && command.operation, status, ...fields };
    }
    function errorResult(command, error) { return resultFor(command, "error", { error: ERRORS.has(error) ? error : "operationFailed" }); }
    function activateNativePort() {
      if (nativePort) return nativePort;
      if (!api.runtime || typeof api.runtime.connectNative !== "function") return null;
      try {
        nativePort = api.runtime.connectNative(NATIVE_APP_ID);
        nativePort.onMessage.addListener((message) => receiveHostMessage(message));
        nativePort.onDisconnect.addListener(() => { nativePort = null; clearTaskBinding(); });
        return nativePort;
      } catch (_) { nativePort = null; return null; }
    }
    function sendResult(result) {
      if (!api.runtime || typeof api.runtime.sendNativeMessage !== "function") return;
      try { api.runtime.sendNativeMessage(NATIVE_APP_ID, result, function () {}); } catch (_) {}
    }
    function receiveHostMessage(message) {
      if (!message || typeof message !== "object" || message.schemaVersion !== VERSION) return;
      handleCommand(message).then(sendResult).catch(() => sendResult(errorResult(message, "operationFailed")));
    }

    async function handleCommand(command) {
      if (!validCommand(command)) return errorResult(command, "invalidPayload");
      if (command.operation === "openTab") return openTab(command);
      if (command.operation === "endTask") return endTask(command);
      if (command.operation === "ping") return ping(command);
      if (!active || activeTaskToken !== command.taskToken) return errorResult(command, "unauthorizedTask");
      if (!boundTab || command.tabId !== boundTab.tabId || command.windowId !== boundTab.windowId) return errorResult(command, "wrongTab");
      if (command.operation === "navigate") return navigate(command);
      if (command.operation === "captureVisibleTab") return captureVisibleTab(command);
      return pageOperation(command);
    }

    function openTab(command) {
      if (activeTaskToken && activeTaskToken !== command.taskToken) return errorResult(command, "unauthorizedTask");
      if (activeTaskToken === command.taskToken && boundTab) return errorResult(command, "staleTask");
      activeTaskToken = command.taskToken; active = true;
      return new Promise((resolve) => {
        try { api.tabs.create({ url: command.url, active: true }, (tab) => {
          if (api.runtime.lastError || !tab || !Number.isSafeInteger(tab.id) || !Number.isSafeInteger(tab.windowId)) {
            clearTaskBinding(); resolve(errorResult(command, "tabNotFound")); return;
          }
          if (!active || activeTaskToken !== command.taskToken) { resolve(errorResult(command, "staleTask")); return; }
          boundTab = { tabId: tab.id, windowId: tab.windowId };
          resolve(resultFor(command, "ok", { tabId: tab.id, windowId: tab.windowId }));
        }); } catch (_) { clearTaskBinding(); resolve(errorResult(command, "operationFailed")); }
      });
    }

    async function withTab(command, requireActive) {
      if (!active || activeTaskToken !== command.taskToken || !boundTab ||
          command.tabId !== boundTab.tabId || command.windowId !== boundTab.windowId) throw "wrongTab";
      const tab = await getTab(command.tabId);
      if (!tab || tab.windowId !== command.windowId || !validURL(tab.url)) throw "wrongTab";
      if (requireActive && !tab.active) throw "inactiveTab";
      return tab;
    }
    function getTab(tabId) { return new Promise((resolve, reject) => {
      try { api.tabs.get(tabId, (tab) => api.runtime.lastError ? reject("tabNotFound") : resolve(tab || null)); }
      catch (_) { reject("tabNotFound"); }
    }); }

    async function ping(command) {
      if (activeTaskToken && command.taskToken !== activeTaskToken) return errorResult(command, "unauthorizedTask");
      if (boundTab && (command.tabId !== boundTab.tabId || command.windowId !== boundTab.windowId)) return errorResult(command, "wrongTab");
      try {
        const tab = await getTab(command.tabId);
        if (!tab || tab.windowId !== command.windowId || !validURL(tab.url)) return errorResult(command, "wrongTab");
        activeTaskToken = command.taskToken; boundTab = { tabId: command.tabId, windowId: command.windowId }; active = true;
        const pageResult = await sendToPage(command, "ping", { nonce: command.nonce }, false);
        if (pageResult.status !== "ok") return pageResult;
        return resultFor(command, "ok", { tabId: command.tabId, windowId: command.windowId,
          nonce: command.nonce, documentId: pageResult.documentId });
      } catch (error) { return errorResult(command, error); }
    }

    async function pageOperation(command) {
      if (!PAGE_OPERATIONS.has(command.operation)) return errorResult(command, "unsupported");
      try {
        await withTab(command, true);
        const payload = payloadOf(command);
        if (command.operation === "setFiles") return await setFiles(command, payload);
        return await sendToPage(command, command.operation, payload, command.operation !== "snapshot" && command.operation !== "wait");
      } catch (error) { return errorResult(command, typeof error === "string" ? error : "operationFailed"); }
    }

    async function sendToPage(command, operation, payload, mutation) {
      const expected = { ...boundTab };
      return new Promise((resolve) => {
        try { api.tabs.sendMessage(expected.tabId, { kind: "remoteDesktop.command.v1", schemaVersion: VERSION,
          commandId: command.commandId, taskToken: command.taskToken, operation, payload,
          tabId: expected.tabId, windowId: expected.windowId }, { frameId: 0 }, async (reply) => {
          if (api.runtime.lastError) { resolve(errorResult(command, "missingPageAccess")); return; }
          if (!active || activeTaskToken !== command.taskToken || !boundTab || boundTab.tabId !== expected.tabId || boundTab.windowId !== expected.windowId) {
            resolve(errorResult(command, "staleTask")); return;
          }
          if (reply && reply.schemaVersion === VERSION && reply.commandId === command.commandId &&
              reply.taskToken === command.taskToken && reply.operation === operation && reply.status === "error" && ERRORS.has(reply.error)) {
            resolve(errorResult(command, reply.error)); return;
          }
          if (!validPageReply(command, operation, reply, expected)) { resolve(errorResult(command, "operationFailed")); return; }
          if (mutation) {
            try { const current = await withTab(command, true); if (!current.active) throw "inactiveTab"; }
            catch (error) { resolve(errorResult(command, typeof error === "string" ? error : "wrongTab")); return; }
          }
          resolve(resultFor(command, "ok", { tabId: expected.tabId, windowId: expected.windowId,
            documentId: reply.documentId, resultJSON: JSON.stringify(reply.result || {}) }));
        }); } catch (_) { resolve(errorResult(command, "missingPageAccess")); }
      });
    }
    function validPageReply(command, operation, reply, expected) {
      return !!reply && reply.schemaVersion === VERSION && reply.status === "ok" && reply.commandId === command.commandId &&
        reply.taskToken === command.taskToken && reply.operation === operation && reply.tabId === expected.tabId &&
        reply.windowId === expected.windowId && typeof reply.documentId === "string" && reply.documentId.length > 0 &&
        (operation !== "ping" || reply.result?.nonce === command.nonce) &&
        JSON.stringify(reply.result || {}).length <= 2 * 1024 * 1024;
    }

    async function navigate(command) {
      try {
        await withTab(command, true);
        const tab = await new Promise((resolve, reject) => api.tabs.update(command.tabId, { url: command.url, active: true },
          (value) => api.runtime.lastError ? reject("operationFailed") : resolve(value)));
        if (!tab || tab.id !== command.tabId || tab.windowId !== command.windowId) return errorResult(command, "wrongTab");
        return resultFor(command, "ok", { tabId: tab.id, windowId: tab.windowId });
      } catch (error) { return errorResult(command, typeof error === "string" ? error : "operationFailed"); }
    }

    async function captureVisibleTab(command) {
      try {
        await withTab(command, true);
        const pageCommand = { ...command, operation: "snapshot" };
        const masked = await sendToPage(pageCommand, "maskSecure", {}, false);
        const maskID = (() => { try { return JSON.parse(masked.resultJSON || "{}").maskId; } catch (_) { return null; } })();
        if (!maskID) return errorResult(command, "missingPageAccess");
        try {
          await new Promise((resolve) => setTimeout(resolve, 25));
          const dataURL = await new Promise((resolve, reject) => api.tabs.captureVisibleTab(command.windowId, { format: "png" },
            (image) => api.runtime.lastError ? reject("operationFailed") : resolve(image)));
          const tab = await withTab(command, true);
          if (!tab.active || typeof dataURL !== "string" || !dataURL.startsWith("data:image/png;base64,")) return errorResult(command, "inactiveTab");
          const resultJSON = JSON.stringify({ screenshot: dataURL.slice("data:image/png;base64,".length) });
          return resultFor(command, "ok", { tabId: command.tabId, windowId: command.windowId, resultJSON });
        } finally { await sendToPage(pageCommand, "unmaskSecure", { maskId: maskID }, false); }
      } catch (error) { return errorResult(command, typeof error === "string" ? error : "operationFailed"); }
    }

    async function setFiles(command, payload) {
      // File material is assembled only from host-issued, ordered, hash-checked chunks.
      if (!payload || !["begin", "chunk", "finish"].includes(payload.stage)) return errorResult(command, "invalidPayload");
      if (payload.stage === "begin") {
        if (typeof payload.transferId !== "string" || payload.transferId.length > 128 || typeof payload.targetId !== "number" ||
            !Number.isSafeInteger(payload.targetId) || !Array.isArray(payload.files) || !payload.files.length || payload.files.length > 32 ||
            !payload.files.every((file) => file && typeof file.name === "string" && file.name.length > 0 && file.name.length <= 255 &&
              typeof file.mimeType === "string" && file.mimeType.length <= 255 && Number.isSafeInteger(file.size) && file.size >= 0 && file.size <= 20 * 1024 * 1024 &&
              Number.isFinite(file.lastModified) && /^[0-9a-f]{64}$/.test(file.sha256))) return errorResult(command, "invalidPayload");
        if (payload.files.reduce((total, file) => total + file.size, 0) > 50 * 1024 * 1024) return errorResult(command, "invalidPayload");
      fileTransfers.set(payload.transferId, { taskToken: command.taskToken, tabId: command.tabId, targetId: payload.targetId,
        expected: payload.expected, expectedAuthorityDigest: payload.expectedAuthorityDigest,
          files: payload.files.map((file) => ({ ...file, chunks: [], next: 0 })) });
        const result = await sendToPage(command, "setFiles", payload, true);
        if (result.status !== "ok") fileTransfers.delete(payload.transferId);
        return result;
      }
      const transfer = fileTransfers.get(payload.transferId);
      if (!transfer || transfer.taskToken !== command.taskToken || transfer.tabId !== command.tabId) return errorResult(command, "staleTask");
      if (payload.stage === "chunk") {
        const file = transfer.files[payload.fileIndex];
        if (!file || payload.index !== file.next || typeof payload.base64 !== "string" || payload.base64.length > 350000) return errorResult(command, "invalidPayload");
        file.chunks.push(payload.base64); file.next += 1;
      }
      const result = await sendToPage(command, "setFiles", payload, true);
      if (result.status !== "ok") { fileTransfers.delete(payload.transferId); return result; }
      if (payload.stage === "finish") {
        let strategy = ""; try { strategy = JSON.parse(result.resultJSON || "{}").strategy || ""; } catch (_) {}
        if (strategy === "unsupported") {
          try {
            const output = await runMainWorldFileClick(command, transfer);
            fileTransfers.delete(payload.transferId);
            return resultFor(command, "ok", { tabId: command.tabId, windowId: command.windowId,
              documentId: result.documentId, resultJSON: JSON.stringify(output) });
          } catch (error) {
            fileTransfers.delete(payload.transferId);
            const reason = typeof error === "string" ? error : (error && typeof error.message === "string" ? error.message : "fileInjectionUnsupported");
            return errorResult(command, ERRORS.has(reason) ? reason : "fileInjectionUnsupported");
          }
        }
        fileTransfers.delete(payload.transferId);
      }
      return result;
    }

    async function runMainWorldFileClick(command, transfer) {
      if (!api.scripting || typeof api.scripting.executeScript !== "function") throw "fileInjectionUnsupported";
      await withTab(command, true);
      const files = transfer.files.map((file) => ({ ...file, chunks: file.chunks }));
      const result = await api.scripting.executeScript({ target: { tabId: command.tabId }, world: "MAIN",
        args: [transfer.targetId, transfer.expected, transfer.expectedAuthorityDigest, files],
        func: async (targetId, expected, expectedAuthorityDigest, fileEntries) => {
          const secure = (element) => {
            const type = (element.getAttribute("type") || "").toLowerCase();
            const autocomplete = (element.getAttribute("autocomplete") || "").toLowerCase();
            const role = (element.getAttribute("role") || "").toLowerCase();
            const semantic = [role, autocomplete, type, element.getAttribute("name") || "", nameOf(element)].join(" ").toLowerCase();
            return type === "password" || /(^|\\s)(password|one-time-code|otp|username|cc-number|cc-csc|cc-exp|cc-exp-month|cc-exp-year)(\\s|$)/.test(autocomplete) ||
              role === "password" || role === "one-time-code" || element.hasAttribute("data-private") ||
              /\\b(password|passcode|one[ -]?time code|otp|secret|auth(?:entication)? token|security code|username|user name|credit card|card number|expiration|expiry|cvv|cvc)\\b/.test(semantic);
          };
          const normalize = (value) => (value || "").trim().replace(/\\s+/g, " ").slice(0, 384);
          const nameOf = (element) => {
            const by = element.getAttribute("aria-labelledby");
            const labelled = by && by.split(/\\s+/).map((id) => document.getElementById(id)?.textContent || "").join(" ");
            return normalize(element.getAttribute("aria-label") || labelled || element.getAttribute("title") ||
              element.labels?.[0]?.innerText || element.innerText || element.textContent || element.getAttribute("placeholder") || "");
          };
          const roleOf = (element) => {
            if (element.getAttribute("role")) return element.getAttribute("role").toLowerCase();
            const tag = element.tagName.toLowerCase();
            if (tag === "button") return "button";
            if (tag === "a") return "link";
            if (tag === "select") return "combobox";
            if (tag === "textarea") return "textbox";
            if (tag === "input") return ({ checkbox: "checkbox", radio: "radio", submit: "button", button: "button", file: "button" })[element.type] || "textbox";
            if (/^h[1-6]$/.test(tag)) return "heading";
            return "generic";
          };
          const authorityPayload = () => {
            const fields = [];
            for (const element of Array.from(document.querySelectorAll("input,textarea,select,[contenteditable=true],[role=textbox],[role=checkbox],[role=radio],[role=combobox]"))) {
              if (secure(element) || !element.isConnected) continue;
              const tag = element.tagName.toLowerCase(), type = (element.getAttribute("type") || "").toLowerCase();
              if (tag === "input" && ["hidden", "button", "submit", "reset", "image"].includes(type)) continue;
              let value;
              if (tag === "select") value = Array.from(element.options).filter((option) => option.selected).map((option) => [option.value, (option.textContent || "").trim()]);
              else if (tag === "input" && type === "file") value = Array.from(element.files || []).map((file) => [file.name, file.size, file.type, file.lastModified]);
              else if (type === "checkbox" || type === "radio" || ["checkbox", "radio"].includes((element.getAttribute("role") || "").toLowerCase())) {
                value = [element.checked === true || element.getAttribute("aria-checked") === "true", element.value || element.getAttribute("aria-valuetext") || ""];
              } else if (tag === "input" || tag === "textarea") value = element.value || "";
              else if (element.isContentEditable || element.getAttribute("role") === "textbox") value = element.innerText || element.textContent || "";
              else if (element.getAttribute("role") === "combobox") value = element.getAttribute("aria-valuetext") || element.getAttribute("aria-valuenow") || "";
              else continue;
              fields.push({ id: Number(element.getAttribute("data-rd-cu-ref")), role: roleOf(element), name: nameOf(element), value });
            }
            fields.sort((a, b) => a.id - b.id);
            return JSON.stringify(fields);
          };
          const assertAuthority = async () => {
            const before = authorityPayload();
            const bytes = new TextEncoder().encode(before);
            const digest = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))).map((byte) => byte.toString(16).padStart(2, "0")).join("");
            if (authorityPayload() !== before || digest !== expectedAuthorityDigest) throw new Error("targetChanged");
          };
          const target = document.querySelector(`[data-rd-cu-ref="${targetId}"]`);
          if (!target || !target.isConnected || target.getAttribute("data-rd-cu-ref") !== String(targetId)) throw new Error("targetGone");
          const tag = target.tagName.toLowerCase();
          const role = target.getAttribute("role") || (tag === "input" && ["file", "submit", "button"].includes(target.type) ? "button" : tag === "textarea" ? "textbox" : tag === "select" ? "combobox" : tag);
          const labelledBy = target.getAttribute("aria-labelledby");
          const labelled = labelledBy && labelledBy.split(/\s+/).map((id) => document.getElementById(id)?.textContent || "").join(" ");
          const name = (target.getAttribute("aria-label") || labelled || target.getAttribute("title") || target.labels?.[0]?.innerText || target.innerText || target.textContent || target.getAttribute("placeholder") || "").trim().replace(/\s+/g, " ").slice(0, 384);
          const rect = target.getBoundingClientRect(), center = document.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2);
          const style = getComputedStyle(target);
          if (role.toLowerCase() !== expected?.role || name !== expected?.name || secure(target) || target.disabled || target.getAttribute("aria-disabled") === "true" ||
              style.display === "none" || style.visibility === "hidden" || !rect.width || !rect.height || (center && center !== target && !target.contains(center)) ||
              target.type === "password") throw new Error("targetChanged");
          const data = new DataTransfer(), names = [];
          for (const entry of fileEntries) {
            const encoded = entry.chunks.join("");
            const bytes = Uint8Array.from(atob(encoded), (character) => character.charCodeAt(0));
            const digest = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))).map((byte) => byte.toString(16).padStart(2, "0")).join("");
            if (digest !== entry.sha256 || bytes.length !== entry.size) throw new Error("invalidPayload");
            data.items.add(new File([bytes], entry.name, { type: entry.mimeType || "application/octet-stream", lastModified: entry.lastModified || Date.now() }));
            names.push(entry.name);
          }
          const proto = HTMLInputElement.prototype, original = proto.click;
          let supplied = false;
          proto.click = function (...args) {
            if (!supplied && this instanceof HTMLInputElement && this.type === "file") {
              this.files = data.files;
              this.dispatchEvent(new Event("input", { bubbles: true }));
              this.dispatchEvent(new Event("change", { bubbles: true }));
              supplied = true;
              return;
            }
            return original.apply(this, args);
          };
          try {
            target.focus();
            if (document.activeElement !== target) throw new Error("targetChanged");
            await assertAuthority();
            if (document.activeElement !== target) throw new Error("targetChanged");
            target.click();
          } finally { proto.click = original; }
          if (!supplied) throw new Error("fileInjectionUnsupported");
          return { strategy: "main_click", names };
        } });
      await withTab(command, true);
      if (!Array.isArray(result) || !result.length || !result[0].result) throw "fileInjectionUnsupported";
      return result[0].result;
    }

    function endTask(command) {
      if (!activeTaskToken || command.taskToken !== activeTaskToken) return errorResult(command, "unauthorizedTask");
      const fields = boundTab ? { tabId: boundTab.tabId, windowId: boundTab.windowId } : {};
      for (const [id, transfer] of fileTransfers) if (transfer.taskToken === command.taskToken) fileTransfers.delete(id);
      clearTaskBinding(); return resultFor(command, "ok", fields);
    }
    function clearTaskBinding() { activeTaskToken = null; boundTab = null; active = false; fileTransfers.clear(); }
    return { activateNativePort, handleCommand, receiveHostMessage,
      getState: () => ({ active, activeTaskToken, boundTab: boundTab && { ...boundTab }, hasNativePort: !!nativePort }) };
  }
  if (typeof module !== "undefined" && module.exports) module.exports = { createBridge };
  if (root.browser && root.browser.runtime) createBridge(root.browser).activateNativePort();
  root.SafariComputerUseBridge = { createBridge };
})(typeof globalThis === "object" ? globalThis : this);
