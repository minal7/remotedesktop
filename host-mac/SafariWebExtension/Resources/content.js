(function (root) {
  "use strict";
  const VERSION = 1, MAX_TEXT = 4096;
  function createContentBridge(api, doc, win) {
    const documentId = win.crypto.randomUUID();
    const ids = new WeakMap();
    let nextId = 1;
    const transfers = new Map(), masks = new Map();
    const idFor = (element) => {
      if (!ids.has(element)) { const id = nextId++; ids.set(element, id); element.setAttribute("data-rd-cu-ref", String(id)); }
      return ids.get(element);
    };
    const fail = (message, error) => ({ schemaVersion: VERSION, commandId: message.commandId, taskToken: message.taskToken,
      operation: message.operation, status: "error", error });

    function secure(element) {
      const type = (element.getAttribute("type") || "").toLowerCase();
      const autocomplete = (element.getAttribute("autocomplete") || "").toLowerCase();
      const role = (element.getAttribute("role") || "").toLowerCase();
      const semantic = [role, autocomplete, type, element.getAttribute("name") || "", nameOf(element)].join(" ").toLowerCase();
      return type === "password" || /(^|\s)(password|one-time-code|otp|username|cc-number|cc-csc|cc-exp|cc-exp-month|cc-exp-year)(\s|$)/.test(autocomplete) ||
        role === "password" || role === "one-time-code" || element.hasAttribute("data-private") ||
        /\b(password|passcode|one[ -]?time code|otp|secret|auth(?:entication)? token|security code|username|user name|credit card|card number|expiration|expiry|cvv|cvc)\b/.test(semantic);
    }
    function visible(element) {
      if (!element || !element.isConnected) return false;
      const style = win.getComputedStyle(element), rect = element.getBoundingClientRect();
      return style.display !== "none" && style.visibility !== "hidden" && Number(style.opacity) > 0 && rect.width > 0 && rect.height > 0;
    }
    function bounds(element) {
      const r = element.getBoundingClientRect();
      return [r.left, r.top, r.width, r.height].map((n) => Math.round(n * (win.devicePixelRatio || 1) * 100) / 100);
    }
    function roleOf(element) {
      if (element.getAttribute("role")) return element.getAttribute("role").toLowerCase();
      const tag = element.tagName.toLowerCase();
      if (tag === "button") return "button";
      if (tag === "a") return "link";
      if (tag === "select") return "combobox";
      if (tag === "textarea") return "textbox";
      if (tag === "input") return ({ checkbox: "checkbox", radio: "radio", submit: "button", button: "button", file: "button" })[element.type] || "textbox";
      if (/^h[1-6]$/.test(tag)) return "heading";
      return "generic";
    }
    function nameOf(element) {
      const by = element.getAttribute("aria-labelledby");
      const labelled = by && by.split(/\s+/).map((id) => doc.getElementById(id)?.textContent || "").join(" ");
      return (element.getAttribute("aria-label") || labelled || element.getAttribute("title") ||
        element.labels?.[0]?.innerText || element.innerText || element.textContent || element.getAttribute("placeholder") || "").trim().replace(/\s+/g, " ").slice(0, 384);
    }
    function readValue(element) {
      if (secure(element)) return null;
      if (element instanceof win.HTMLInputElement || element instanceof win.HTMLTextAreaElement) return (element.value || "").slice(0, 512);
      if (element instanceof win.HTMLSelectElement) return (element.selectedOptions[0]?.textContent || "").trim().slice(0, 512);
      if (element.isContentEditable) return (element.innerText || "").slice(0, 512);
      return null;
    }
    function authorityPayload() {
      const fields = [];
      for (const element of Array.from(doc.querySelectorAll("input,textarea,select,[contenteditable=true],[role=textbox],[role=checkbox],[role=radio],[role=combobox]"))) {
        if (secure(element) || !element.isConnected) continue;
        const tag = element.tagName.toLowerCase(), type = (element.getAttribute("type") || "").toLowerCase();
        if (tag === "input" && ["hidden", "button", "submit", "reset", "image"].includes(type)) continue;
        let value;
        if (tag === "select") value = Array.from(element.options).filter((option) => option.selected)
          .map((option) => [option.value, (option.textContent || "").trim()]);
        else if (tag === "input" && type === "file") value = Array.from(element.files || [])
          .map((file) => [file.name, file.size, file.type, file.lastModified]);
        else if (type === "checkbox" || type === "radio" || ["checkbox", "radio"].includes((element.getAttribute("role") || "").toLowerCase())) {
          value = [element.checked === true || element.getAttribute("aria-checked") === "true", element.value || element.getAttribute("aria-valuetext") || ""];
        } else if (element instanceof win.HTMLInputElement || element instanceof win.HTMLTextAreaElement) value = element.value || "";
        else if (element.isContentEditable || element.getAttribute("role") === "textbox") value = element.innerText || element.textContent || "";
        else if (element.getAttribute("role") === "combobox") value = element.getAttribute("aria-valuetext") || element.getAttribute("aria-valuenow") || "";
        else continue;
        fields.push({ id: idFor(element), role: roleOf(element), name: nameOf(element), value });
      }
      fields.sort((a, b) => a.id - b.id);
      return JSON.stringify(fields);
    }
    async function authorityDigest() {
      const before = authorityPayload();
      const bytes = new win.TextEncoder().encode(before);
      const digest = Array.from(new Uint8Array(await win.crypto.subtle.digest("SHA-256", bytes)))
        .map((byte) => byte.toString(16).padStart(2, "0")).join("");
      if (authorityPayload() !== before) throw "targetChanged";
      return digest;
    }
    async function assertAuthority(expected) {
      if (typeof expected !== "string" || !/^[0-9a-f]{64}$/.test(expected) || await authorityDigest() !== expected) throw "targetChanged";
    }
    function isDisabled(element) { return !!element.disabled || element.getAttribute("aria-disabled") === "true"; }
    function occluded(element) {
      const r = element.getBoundingClientRect();
      const top = doc.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
      return !!top && top !== element && !element.contains(top);
    }
    function elementRecord(element) {
      const id = idFor(element), role = roleOf(element), name = nameOf(element), state = [];
      if (visible(element)) state.push("visible");
      if (!isDisabled(element)) state.push("enabled"); else state.push("disabled");
      if (element === doc.activeElement) state.push("focused");
      if (element.checked === true || element.getAttribute("aria-checked") === "true") state.push("checked");
      if (element.getAttribute("aria-selected") === "true" || (element instanceof win.HTMLOptionElement && element.selected)) state.push("selected");
      if (secure(element)) state.push("secure");
      const box = bounds(element), inView = box[0] + box[2] > 0 && box[1] + box[3] > 0 && box[0] < win.innerWidth * win.devicePixelRatio && box[1] < win.innerHeight * win.devicePixelRatio;
      const out = { id, role, name, value: readValue(element), state, bbox: box, in_view: inView };
      if (occluded(element)) out.state.push("covered");
      return out;
    }
    function candidateElements() {
      return Array.from(doc.querySelectorAll("button,a[href],input,textarea,select,[contenteditable=true],[role],summary,[tabindex]:not([tabindex='-1'])"))
        .filter(visible);
    }
    function addVisibleText(records, byteBudget) {
      const walker = doc.createTreeWalker(doc.body || doc.documentElement, win.NodeFilter.SHOW_TEXT);
      const seen = new Set(); let node, bytes = records.reduce((n, item) => n + JSON.stringify(item).length, 0), visitedTextBytes = 0;
      while ((node = walker.nextNode()) && bytes < byteBudget && visitedTextBytes < byteBudget * 16) {
        visitedTextBytes += (node.nodeValue || "").length;
        const text = (node.nodeValue || "").trim().replace(/\s+/g, " ");
        if (!text || text.length < 2 || text.length > 384 || seen.has(text)) continue;
        const parent = node.parentElement;
        if (!visible(parent) || parent.closest("script,style,noscript,template,[aria-hidden=true]") || secure(parent)) continue;
        const range = doc.createRange(); range.selectNodeContents(node);
        const rect = range.getBoundingClientRect();
        if (!rect.width || !rect.height || rect.right <= 0 || rect.bottom <= 0 || rect.left >= win.innerWidth || rect.top >= win.innerHeight) continue;
        const element = { id: idFor(parent), role: "text", name: text, value: null, state: ["visible"],
          bbox: [rect.left, rect.top, rect.width, rect.height].map((n) => Math.round(n * (win.devicePixelRatio || 1) * 100) / 100), in_view: true };
        if (!records.some((item) => item.id === element.id)) {
          const cost = JSON.stringify(element).length;
          if (bytes + cost > byteBudget) break;
          records.push(element); seen.add(text); bytes += cost;
        }
      }
    }
    async function snapshot(payload = {}) {
      const byteBudget = Math.min(256 * 1024, Math.max(4096, Number(payload.maxBytes) || 65536));
      const records = []; let bytes = 0;
      for (const element of candidateElements()) {
        const record = elementRecord(element), cost = JSON.stringify(record).length;
        if (bytes + cost > byteBudget) continue;
        records.push(record); bytes += cost;
      }
      addVisibleText(records, byteBudget);
      const activeElement = doc.activeElement;
      let focus = null;
      if (activeElement && activeElement !== doc.body && activeElement !== doc.documentElement) {
        const record = elementRecord(activeElement);
        const value = secure(activeElement) ? "" : (readValue(activeElement) || "");
        focus = { id: record.id, role: record.role, name: record.name, value_prefix: value.slice(0, 128), selection: [0, 0] };
        if (typeof activeElement.selectionStart === "number") focus.selection = [activeElement.selectionStart, activeElement.selectionEnd || 0];
        if (!records.some((item) => item.id === record.id)) records.push(record);
      }
      const pageText = (doc.body?.innerText || "").replace(/\s+/g, " ").slice(0, MAX_TEXT);
      return { documentId, url: win.location.href, title: doc.title || "", pageText, elements: records, focus,
        viewport: [win.innerWidth * (win.devicePixelRatio || 1), win.innerHeight * (win.devicePixelRatio || 1)],
        authorityDigest: await authorityDigest() };
    }
    function byId(id) { return candidateElements().find((element) => idFor(element) === id) || null; }
    function target(element, payload) {
      if (!element || !visible(element)) throw "targetGone";
      if (secure(element)) throw "credentialHandoff";
      if (isDisabled(element)) throw "disabledTarget";
      if (occluded(element)) throw "targetCovered";
      if (payload.expected) {
        const record = elementRecord(element), expected = payload.expected;
        if (record.role !== expected.role || record.name !== expected.name) throw "targetChanged";
      }
      return element;
    }
    function elementFor(payload, key = "id") {
      const id = payload[key];
      if (!Number.isSafeInteger(id) || id < 0) throw "invalidPayload";
      return target(byId(id), payload);
    }
    function pointFor(payload) {
      if (!Array.isArray(payload.point) || payload.point.length !== 2 || !payload.point.every(Number.isFinite)) return null;
      const x = payload.point[0] * win.innerWidth, y = payload.point[1] * win.innerHeight;
      let element = doc.elementFromPoint(x, y);
      if (!element) throw "targetGone";
      const expected = payload.expected || {};
      while (element && element !== doc.documentElement) {
        if (secure(element)) throw "credentialHandoff";
        const record = elementRecord(element);
        if (record.role === expected.role && record.name === expected.name) return target(element, payload);
        element = element.parentElement;
      }
      throw "targetChanged";
    }
    function result(message, value = {}) {
      return { schemaVersion: VERSION, commandId: message.commandId, taskToken: message.taskToken,
        operation: message.operation, status: "ok", tabId: message.tabId, windowId: message.windowId, documentId, result: value };
    }
    function dispatch(element, name) { element.dispatchEvent(new win.Event(name, { bubbles: true, composed: true })); }
    async function click(payload) {
      const element = payload.point ? pointFor(payload) : elementFor(payload);
      const button = ({ left: 0, middle: 1, right: 2 })[payload.button || "left"];
      if (button === undefined) throw "invalidPayload";
      const count = Math.min(2, Math.max(1, Number(payload.count) || 1));
      element.scrollIntoView({ block: "center", inline: "center" });
      const r = element.getBoundingClientRect();
      const clientX = payload.point ? payload.point[0] * win.innerWidth : r.left + r.width / 2;
      const clientY = payload.point ? payload.point[1] * win.innerHeight : r.top + r.height / 2;
      for (let i = 0; i < count; i++) {
        await assertAuthority(payload.expectedAuthorityDigest);
        const common = { bubbles: true, cancelable: true, view: win, button, clientX, clientY, detail: i + 1 };
        element.dispatchEvent(new win.MouseEvent("mousedown", common));
        element.dispatchEvent(new win.MouseEvent("mouseup", common));
        element.dispatchEvent(new win.MouseEvent(button === 1 ? "auxclick" : "click", common));
        if (button === 2) element.dispatchEvent(new win.MouseEvent("contextmenu", common));
      }
      return { clicked: true };
    }
    async function type(payload) {
      const element = payload.id == null ? doc.activeElement : elementFor(payload);
      if (payload.focus && (element !== doc.activeElement || elementRecord(element).role !== payload.expected?.role || elementRecord(element).name !== payload.expected?.name)) throw "targetChanged";
      if (!element || secure(element) || isDisabled(element)) throw secure(element || doc.body) ? "credentialHandoff" : "targetGone";
      if (!(element instanceof win.HTMLInputElement || element instanceof win.HTMLTextAreaElement || element.isContentEditable)) throw "targetChanged";
      if (payload.text === undefined || typeof payload.text !== "string" || payload.text.length > 16384 || !["replace", "append"].includes(payload.mode)) throw "invalidPayload";
      element.focus();
      await assertAuthority(payload.expectedAuthorityDigest);
      if (element !== doc.activeElement || secure(element) || isDisabled(element)) throw secure(element) ? "credentialHandoff" : "targetChanged";
      if (element.isContentEditable) {
        if (payload.mode === "replace") element.textContent = payload.text;
        else element.append(doc.createTextNode(payload.text));
      } else {
        const proto = element instanceof win.HTMLTextAreaElement ? win.HTMLTextAreaElement.prototype : win.HTMLInputElement.prototype;
        const setter = Object.getOwnPropertyDescriptor(proto, "value")?.set;
        setter.call(element, payload.mode === "replace" ? payload.text : element.value + payload.text);
      }
      dispatch(element, "input"); dispatch(element, "change");
      return { value: secure(element) ? null : readValue(element) };
    }
    async function key(payload) {
      if (typeof payload.chord !== "string" || payload.chord.length > 64 || !/^(cmd|ctrl|alt|shift\+)*(enter|tab|escape|backspace|delete|arrow(up|down|left|right)|home|end|a|c|v|x|z|l)$/i.test(payload.chord)) throw "invalidPayload";
      const focus = payload.id == null ? doc.activeElement : elementFor(payload);
      if (payload.focus && (focus !== doc.activeElement || elementRecord(focus).role !== payload.expected?.role || elementRecord(focus).name !== payload.expected?.name)) throw "targetChanged";
      if (secure(focus)) throw "credentialHandoff";
      await assertAuthority(payload.expectedAuthorityDigest);
      if (focus !== doc.activeElement || secure(focus)) throw secure(focus) ? "credentialHandoff" : "targetChanged";
      const parts = payload.chord.toLowerCase().split("+"); const keyName = parts.pop();
      const keyMap = { enter: "Enter", tab: "Tab", escape: "Escape", backspace: "Backspace", delete: "Delete", arrowup: "ArrowUp", arrowdown: "ArrowDown", arrowleft: "ArrowLeft", arrowright: "ArrowRight", home: "Home", end: "End", a: "a", c: "c", v: "v", x: "x", z: "z", l: "l" };
      const modifiers = { ctrlKey: parts.includes("ctrl"), metaKey: parts.includes("cmd"), altKey: parts.includes("alt"), shiftKey: parts.includes("shift") };
      const event = new win.KeyboardEvent("keydown", { key: keyMap[keyName], bubbles: true, cancelable: true, ...modifiers });
      focus?.dispatchEvent(event); focus?.dispatchEvent(new win.KeyboardEvent("keyup", { key: keyMap[keyName], bubbles: true, ...modifiers }));
      if (keyName === "enter" && focus?.form) focus.form.requestSubmit?.();
      return { key: keyMap[keyName] };
    }
    async function scroll(payload) {
      const direction = payload.direction, amount = Math.min(2000, Math.max(1, Number(payload.amount) || 0));
      if (!["up", "down", "left", "right"].includes(direction)) throw "invalidPayload";
      const element = payload.point ? pointFor(payload) : payload.id == null ? doc.scrollingElement : elementFor(payload);
      const d = { up: [0, -amount], down: [0, amount], left: [-amount, 0], right: [amount, 0] }[direction];
      await assertAuthority(payload.expectedAuthorityDigest);
      element.scrollBy({ left: d[0], top: d[1], behavior: "instant" }); return { scrolled: true };
    }
    async function select(payload) {
      const element = elementFor(payload);
      if (!(element instanceof win.HTMLSelectElement) || typeof payload.option !== "string") throw "targetChanged";
      const option = Array.from(element.options).find((item) => item.textContent.trim() === payload.option || item.value === payload.option);
      if (!option || option.disabled) throw "targetGone";
      await assertAuthority(payload.expectedAuthorityDigest);
      element.value = option.value; dispatch(element, "input"); dispatch(element, "change"); return { selected: option.textContent.trim() };
    }
    async function drag(payload) {
      const from = payload.fromPoint ? pointFor({ point: payload.fromPoint, expected: payload.fromExpected }) : elementFor({ id: payload.fromId, expected: payload.fromExpected });
      const to = payload.toPoint ? pointFor({ point: payload.toPoint, expected: payload.toExpected }) : elementFor({ id: payload.toId, expected: payload.toExpected });
      await assertAuthority(payload.expectedAuthorityDigest);
      const transfer = new win.DataTransfer();
      for (const type of ["dragstart", "dragenter", "dragover", "drop", "dragend"]) {
        const target = type === "dragstart" || type === "dragend" ? from : to;
        target.dispatchEvent(new win.DragEvent(type, { bubbles: true, cancelable: true, dataTransfer: transfer }));
      }
      return { dragged: true };
    }
    async function wait(payload) {
      const seconds = Math.min(10, Math.max(0.1, Number(payload.seconds) || 0));
      await new Promise((resolve) => { let timer = setTimeout(done, seconds * 1000); const observer = new win.MutationObserver(() => { clearTimeout(timer); timer = setTimeout(done, Math.min(0.25, seconds * 100)); });
        function done() { observer.disconnect(); resolve(); } observer.observe(doc.documentElement, { subtree: true, childList: true, attributes: true }); });
      return await snapshot();
    }
    async function setFiles(message, payload) {
      if (payload.stage === "begin") {
        if (typeof payload.transferId !== "string" || !Number.isSafeInteger(payload.targetId) || !Array.isArray(payload.files) || !payload.files.length) throw "invalidPayload";
        await assertAuthority(payload.expectedAuthorityDigest);
        const element = payload.point ? pointFor(payload) : elementFor({ id: payload.targetId, expected: payload.expected });
        transfers.set(payload.transferId, { targetId: idFor(element), expected: payload.expected,
          expectedAuthorityDigest: payload.expectedAuthorityDigest, files: payload.files.map((f) => ({ ...f, chunks: [], next: 0 })) });
        return { stage: "begin" };
      }
      const transfer = transfers.get(payload.transferId); if (!transfer) throw "staleTask";
      if (payload.stage === "chunk") {
        const file = transfer.files[payload.fileIndex];
        if (!file || payload.index !== file.next || typeof payload.base64 !== "string" || payload.base64.length > 350000) throw "invalidPayload";
        file.chunks.push(payload.base64); file.next += 1; return { stage: "chunk" };
      }
      if (payload.stage !== "finish") throw "invalidPayload";
      const files = [];
      for (const file of transfer.files) {
        const bytes = Uint8Array.from(win.atob(file.chunks.join("")), (c) => c.charCodeAt(0));
        const digest = Array.from(new Uint8Array(await win.crypto.subtle.digest("SHA-256", bytes))).map((b) => b.toString(16).padStart(2, "0")).join("");
        if (digest !== file.sha256 || bytes.length !== file.size) { transfers.delete(payload.transferId); throw "invalidPayload"; }
        files.push(new win.File([bytes], file.name, { type: file.mimeType || "application/octet-stream", lastModified: file.lastModified || Date.now() }));
      }
      const element = elementFor({ id: transfer.targetId, expected: transfer.expected }), data = new win.DataTransfer(); files.forEach((file) => data.items.add(file));
      await assertAuthority(transfer.expectedAuthorityDigest);
      if (element instanceof win.HTMLInputElement && element.type === "file") {
        element.files = data.files; dispatch(element, "input"); dispatch(element, "change"); transfers.delete(payload.transferId);
        return { strategy: "input", names: files.map((file) => file.name) };
      }
      element.scrollIntoView({ block: "center" });
      let accepted = false;
      for (const type of ["dragenter", "dragover"]) {
        await assertAuthority(transfer.expectedAuthorityDigest);
        const event = new win.DragEvent(type, { bubbles: true, cancelable: true, dataTransfer: data });
        element.dispatchEvent(event);       }
      await assertAuthority(transfer.expectedAuthorityDigest);
      const drop = new win.DragEvent("drop", { bubbles: true, cancelable: true, dataTransfer: data });
      const dispatchAccepted = element.dispatchEvent(drop);
      accepted = !dispatchAccepted || drop.defaultPrevented;
      if (accepted) { transfers.delete(payload.transferId); return { strategy: "drop", names: files.map((file) => file.name) }; }
      return { strategy: "unsupported", names: files.map((file) => file.name), transferId: payload.transferId };
    }

    function maskSecure() {
      const id = win.crypto.randomUUID(), overlays = [];
      for (const element of Array.from(doc.querySelectorAll("input,textarea,[role],[contenteditable=true]"))) {
        if (!secure(element) || !visible(element)) continue;
        const rect = element.getBoundingClientRect(), overlay = doc.createElement("div");
        Object.assign(overlay.style, { position: "fixed", left: `${rect.left}px`, top: `${rect.top}px`, width: `${rect.width}px`, height: `${rect.height}px`,
          background: "#000", zIndex: "2147483647", pointerEvents: "auto", margin: "0", padding: "0" });
        overlay.setAttribute("aria-hidden", "true"); (doc.documentElement || doc.body).appendChild(overlay); overlays.push(overlay);
      }
      masks.set(id, overlays); return { maskId: id, count: overlays.length };
    }
    function unmaskSecure(payload) {
      const overlays = masks.get(payload.maskId); if (!overlays) throw "staleTask";
      overlays.forEach((overlay) => overlay.remove()); masks.delete(payload.maskId); return { restored: true };
    }

    async function handle(message) {
      try {
        let value;
        switch (message.operation) {
        case "ping": value = { nonce: message.payload?.nonce }; break;
        case "snapshot": value = await snapshot(message.payload || {}); break;
        case "click": value = await click(message.payload || {}); break;
        case "type": value = await type(message.payload || {}); break;
        case "key": value = await key(message.payload || {}); break;
        case "scroll": value = await scroll(message.payload || {}); break;
        case "select": value = await select(message.payload || {}); break;
        case "drag": value = await drag(message.payload || {}); break;
        case "wait": value = await wait(message.payload || {}); break;
        case "setFiles": value = await setFiles(message, message.payload || {}); break;
        case "maskSecure": value = maskSecure(); break;
        case "unmaskSecure": value = unmaskSecure(message.payload || {}); break;
        default: return fail(message, "unsupported");
        }
        return result(message, value);
      } catch (error) { return fail(message, typeof error === "string" ? error : "operationFailed"); }
    }
    api.runtime.onMessage.addListener((message, sender, sendResponse) => {
      if (win.top !== win || !message || message.kind !== "remoteDesktop.command.v1" || sender.tab?.id == null) return false;
      handle(message).then(sendResponse); return true;
    });
    return { handle, snapshot, getState: () => ({ documentId, nextId, transfers: transfers.size }) };
  }
  if (typeof module !== "undefined" && module.exports) module.exports = { createContentBridge };
  if (root.browser && root.browser.runtime && root.document) createContentBridge(root.browser, root.document, root);
})(typeof globalThis === "object" ? globalThis : this);
