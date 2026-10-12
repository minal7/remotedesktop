const test = require("node:test");
const assert = require("node:assert/strict");
const vm = require("node:vm");
const { createHash } = require("node:crypto");
const { createBridge } = require("../../../SafariWebExtension/Resources/background.js");
const { createContentBridge } = require("../../../SafariWebExtension/Resources/content.js");

const TOKEN = "0123456789abcdef0123456789abcdef";
const COMMAND_ID = "123e4567-e89b-42d3-a456-426614174000";
const PNG = "data:image/png;base64,iVBORw0KGgo=";
const EMPTY_AUTHORITY_DIGEST = createHash("sha256").update("[]").digest("hex");

function event() {
  const listeners = [];
  return { addListener(listener) { listeners.push(listener); }, emit(...args) { for (const listener of [...listeners]) listener(...args); } };
}

function fixture() {
  const port = { onMessage: event(), onDisconnect: event(), disconnectCount: 0 };
  port.disconnect = () => { port.disconnectCount += 1; };
  const results = [], createdTabs = [], sentMessages = [], lookedUpTabs = [], captures = [], scriptCalls = [];
  const tabsById = new Map(); let connectCount = 0, contentOverride = null, image = PNG;
  const runtime = { lastError: null, connectNative() { connectCount += 1; return port; }, sendNativeMessage(_app, message, callback) { results.push(message); callback?.(); } };
  const api = {
    runtime,
    tabs: {
      create(options, callback) {
        const tab = { id: 11, windowId: 4, url: options.url, active: true };
        createdTabs.push(tab); tabsById.set(tab.id, tab); callback(tab);
      },
      get(tabId, callback) { lookedUpTabs.push(tabId); callback(tabsById.get(tabId)); },
      update(tabId, changes, callback) {
        const tab = tabsById.get(tabId); Object.assign(tab, changes); callback(tab);
      },
      sendMessage(tabId, message, options, callback) {
        sentMessages.push({ tabId, message, options });
        callback(contentOverride ? contentOverride(message) : {
          schemaVersion: 1, commandId: message.commandId, taskToken: message.taskToken, operation: message.operation,
          status: "ok", tabId: message.tabId, windowId: message.windowId, documentId: "doc-001",
          result: message.operation === "maskSecure" ? { maskId: "mask-1" }
            : message.operation === "ping" ? { nonce: message.payload.nonce }
              : message.operation === "setFiles" && message.payload.stage === "finish" ? { strategy: "unsupported" } : {}
        });
      },
      captureVisibleTab(windowId, options, callback) { captures.push({ windowId, options }); callback(image); }
    },
    scripting: { async executeScript(args) {
      scriptCalls.push(args);
      class Input {
        constructor() { this.isConnected = true; this.tagName = "INPUT"; this.type = "file"; this.disabled = false; this.autocomplete = ""; this.files = null; }
        getAttribute(name) { return name === "data-rd-cu-ref" ? "2" : name === "aria-label" ? "Upload" : null; }
        hasAttribute() { return false; }
        getBoundingClientRect() { return { left: 0, top: 0, width: 20, height: 20 }; }
        contains() { return false; }
        dispatchEvent() { return true; }
        click() { return Input.prototype.click.call(this); }
        focus() { document.activeElement = this; }
      }
      class Transfer { constructor() { this.items = { add: (file) => this._files.push(file) }; this._files = []; } get files() { return this._files; } }
      class FixtureFile { constructor(parts, name, options) { this.parts = parts; this.name = name; this.type = options.type; this.lastModified = options.lastModified; } }
      const target = new Input();
      const document = { activeElement: null, querySelector: () => target, querySelectorAll: () => [],
        elementFromPoint: () => target, getElementById: () => null };
      const digest = async (_algorithm, bytes) => { const result = createHash("sha256").update(Buffer.from(bytes)).digest(); return result.buffer.slice(result.byteOffset, result.byteOffset + result.byteLength); };
      const sandbox = { document,
        DataTransfer: Transfer, File: FixtureFile, HTMLInputElement: Input, Event: class {},
        atob: (value) => Buffer.from(value, "base64").toString("binary"), crypto: { subtle: { digest } },
        TextEncoder, getComputedStyle: () => ({ display: "block", visibility: "visible" }) };
      const func = vm.runInNewContext(`(${args.func.toString()})`, sandbox);
      return [{ result: await func(...args.args) }];
    } }
  };
  return { bridge: createBridge(api), port, results, createdTabs, sentMessages, lookedUpTabs, tabsById, captures, scriptCalls,
    setContentResponse(fn) { contentOverride = fn; }, setImage(value) { image = value; }, connectCount: () => connectCount };
}
function command(operation, fields = {}) { return { schemaVersion: 1, commandId: COMMAND_ID, taskToken: TOKEN, operation, ...fields }; }
function payload(value) { return { payloadJSON: JSON.stringify(value) }; }
async function open(f, url = "https://example.org/") { return f.bridge.handleCommand(command("openTab", { url })); }

function contentFixture() {
  class Input {
    constructor({ name, value = "", type = "text", autocomplete = "", visible = true } = {}) {
      this.tagName = "INPUT"; this.type = type; this.value = value; this.disabled = false; this.checked = false;
      this.isConnected = true; this.isContentEditable = false; this.autocomplete = autocomplete; this.attrs = { "aria-label": name, type, autocomplete };
      this.rect = visible ? { left: 1, top: 1, width: 50, height: 20 } : { left: 0, top: 0, width: 0, height: 0 };
      this.dispatched = []; this.scrollIntoView = () => {}; this.contains = () => false;
    }
    getAttribute(name) { return this.attrs[name] ?? null; }
    hasAttribute(name) { return Object.hasOwn(this.attrs, name); }
    setAttribute(name, value) { this.attrs[name] = String(value); }
    getBoundingClientRect() { return { ...this.rect, right: this.rect.left + this.rect.width, bottom: this.rect.top + this.rect.height }; }
    dispatchEvent(event) { this.dispatched.push(event.type); return true; }
    focus() { doc.activeElement = this; }
  }
  const elements = [new Input({ name: "Long answer", value: `a${"b".repeat(700)}` }),
    new Input({ name: "Extra field", value: "omitted" }), new Input({ name: "User name", value: "private", autocomplete: "username" })];
  const doc = { title: "fixture", body: { innerText: "Form" }, documentElement: {}, activeElement: null,
    querySelectorAll() { return elements; }, getElementById() { return null; },
    elementFromPoint() { return elements[0]; }, createTreeWalker() { return { nextNode: () => null }; } };
  const subtle = { async digest(_algorithm, bytes) {
    const digest = createHash("sha256").update(Buffer.from(bytes)).digest();
    return digest.buffer.slice(digest.byteOffset, digest.byteOffset + digest.byteLength);
  } };
  const win = { crypto: { randomUUID: () => "document-1", subtle }, TextEncoder, location: { href: "https://fixture.example/" }, devicePixelRatio: 1,
    innerWidth: 100, innerHeight: 100, top: null, NodeFilter: { SHOW_TEXT: 4 },
    getComputedStyle: () => ({ display: "block", visibility: "visible", opacity: "1" }),
    HTMLInputElement: Input, HTMLTextAreaElement: class {}, HTMLSelectElement: class {}, HTMLOptionElement: class {},
    Event: class { constructor(type) { this.type = type; } }, MouseEvent: class { constructor(type) { this.type = type; } },
    KeyboardEvent: class { constructor(type) { this.type = type; } }, DragEvent: class { constructor(type) { this.type = type; } },
    DataTransfer: class {} };
  win.top = win;
  const api = { runtime: { onMessage: { addListener() {} } } };
  return { bridge: createContentBridge(api, doc, win), elements };
}

async function contentMessage(bridge, operation, value = {}) {
  return bridge.handle({ schemaVersion: 1, commandId: COMMAND_ID, taskToken: TOKEN, operation, payload: value });
}

test("native port connects once and remains idle until a host command arrives", () => {
  const f = fixture(); f.bridge.activateNativePort(); f.bridge.activateNativePort();
  assert.equal(f.connectCount(), 1); assert.equal(f.bridge.getState().active, false); assert.equal(f.results.length, 0);
});

test("generic HTTPS and loopback HTTP URLs work, while credentials and unsafe schemes are rejected", async () => {
  for (const url of ["https://example.net/forms/basic", "https://example.org:8443/path", "http://localhost:8765/form", "http://127.0.0.1:8765/form"]) {
    const f = fixture(); assert.equal((await open(f, url)).status, "ok", url);
  }
  for (const url of ["file:///tmp/a", "javascript:alert(1)", "data:text/html,hi", "https://user:pass@example.org/", "http://example.org/", "http://127.attacker.example/"]) {
    const f = fixture(); assert.equal((await open(f, url)).error, "invalidPayload", url); assert.equal(f.createdTabs.length, 0);
  }
});

test("bound snapshots preserve command, task, tab, window, and document identity", async () => {
  const f = fixture(); await open(f);
  const result = await f.bridge.handleCommand(command("snapshot", { tabId: 11, windowId: 4, ...payload({ maxBytes: 65536, viewportOnly: false }) }));
  assert.equal(result.status, "ok"); assert.equal(result.tabId, 11); assert.equal(result.windowId, 4); assert.equal(result.documentId, "doc-001");
  assert.equal(f.sentMessages[0].message.operation, "snapshot"); assert.deepEqual(f.sentMessages[0].options, { frameId: 0 });
});

test("navigation and DOM operations reject unbound tabs and forward only typed payloads", async () => {
  const f = fixture();
  const unbound = await f.bridge.handleCommand(command("click", { tabId: 11, windowId: 4, ...payload({ id: 2 }) }));
  assert.equal(unbound.error, "unauthorizedTask"); assert.equal(f.sentMessages.length, 0);
  await open(f);
  const wrong = await f.bridge.handleCommand(command("click", { tabId: 12, windowId: 4, ...payload({ id: 2 }) }));
  assert.equal(wrong.error, "wrongTab");
  const nav = await f.bridge.handleCommand(command("navigate", { tabId: 11, windowId: 4, url: "http://127.0.0.1:8765/next" }));
  assert.equal(nav.status, "ok"); assert.equal(f.tabsById.get(11).url, "http://127.0.0.1:8765/next");
});

test("page errors for credentials, moved targets, covered controls, and stale IDs reach the host", async () => {
  const f = fixture(); await open(f);
  for (const error of ["credentialHandoff", "targetChanged", "targetCovered", "targetGone"]) {
    f.setContentResponse((message) => ({ schemaVersion: 1, commandId: message.commandId, taskToken: message.taskToken,
      operation: message.operation, status: "error", error, tabId: 11, windowId: 4, documentId: "doc-001" }));
    const result = await f.bridge.handleCommand(command("type", { tabId: 11, windowId: 4, ...payload({ id: 3, text: "x", mode: "replace" }) }));
    assert.equal(result.error, error);
  }
});

test("ping binds only the supplied tab and rejects a page correlation mismatch", async () => {
  const f = fixture();
  f.tabsById.set(27, { id: 27, windowId: 8, url: "https://example.org/", active: true });
  const result = await f.bridge.handleCommand(command("ping", { tabId: 27, windowId: 8, nonce: "resume-1" }));
  assert.equal(result.status, "ok"); assert.equal(result.nonce, "resume-1"); assert.deepEqual(f.lookedUpTabs, [27]);
  f.setContentResponse((message) => ({ schemaVersion: 1, commandId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    taskToken: message.taskToken, operation: "ping", status: "ok", tabId: 27, windowId: 8, documentId: "doc-2", result: { nonce: "resume-1" } }));
  assert.equal((await f.bridge.handleCommand(command("ping", { tabId: 27, windowId: 8, nonce: "resume-2" }))).error, "operationFailed");
});

test("capture refuses a task tab that is no longer active and captures only its bound window", async () => {
  const f = fixture(); await open(f); const tab = f.tabsById.get(11);
  const wrongWindow = await f.bridge.handleCommand(command("captureVisibleTab", { tabId: 11, windowId: 9 }));
  assert.equal(wrongWindow.error, "wrongTab"); assert.equal(f.captures.length, 0);
  tab.active = false;
  const inactive = await f.bridge.handleCommand(command("captureVisibleTab", { tabId: 11, windowId: 4 }));
  assert.equal(inactive.error, "inactiveTab"); assert.equal(f.captures.length, 0);
  tab.active = true;
  const capture = await f.bridge.handleCommand(command("captureVisibleTab", { tabId: 11, windowId: 4 }));
  assert.equal(capture.status, "ok"); assert.deepEqual(f.captures[0], { windowId: 4, options: { format: "png" } });
  assert.deepEqual(f.sentMessages.map((item) => item.message.operation), ["maskSecure", "unmaskSecure"]);
});

test("snapshot result size is bounded before the host receives page content", async () => {
  const f = fixture(); await open(f);
  f.setContentResponse((message) => ({ schemaVersion: 1, commandId: message.commandId, taskToken: message.taskToken,
    operation: message.operation, status: "ok", tabId: 11, windowId: 4, documentId: "doc-1", result: { text: "x".repeat(2 * 1024 * 1024 + 1) } }));
  const result = await f.bridge.handleCommand(command("snapshot", { tabId: 11, windowId: 4, ...payload({ maxBytes: 65536 }) }));
  assert.equal(result.error, "operationFailed");
});

test("authority digest covers full values and controls omitted from the model snapshot, but excludes credentials", async () => {
  const f = contentFixture();
  const first = await contentMessage(f.bridge, "snapshot", { maxBytes: 4096 });
  assert.equal(first.status, "ok", JSON.stringify(first));
  const digest = first.result.authorityDigest;
  f.elements[0].value = f.elements[0].value.slice(0, 512) + "changed suffix";
  const longValueChanged = await contentMessage(f.bridge, "snapshot", { maxBytes: 4096 });
  assert.notEqual(longValueChanged.result.authorityDigest, digest, "suffix after model-visible value prefix is authoritative");
  const secondDigest = longValueChanged.result.authorityDigest;
  f.elements[1].value = "changed omitted value";
  const omittedChanged = await contentMessage(f.bridge, "snapshot", { maxBytes: 4096 });
  assert.notEqual(omittedChanged.result.authorityDigest, secondDigest, "a non-rendered form control remains in the authority digest");
  const thirdDigest = omittedChanged.result.authorityDigest;
  f.elements[2].value = "different credential";
  const secureChanged = await contentMessage(f.bridge, "snapshot", { maxBytes: 4096 });
  assert.equal(secureChanged.result.authorityDigest, thirdDigest, "credential values are excluded from the digest");
});

test("stale authority digest rejects dispatch before a click reaches the target", async () => {
  const f = contentFixture();
  const snapshot = await contentMessage(f.bridge, "snapshot");
  const staleDigest = snapshot.result.authorityDigest;
  f.elements[0].value = "changed after approval";
  const result = await contentMessage(f.bridge, "click", { id: Number(f.elements[0].getAttribute("data-rd-cu-ref")),
    expected: { role: "textbox", name: "Long answer" }, expectedAuthorityDigest: staleDigest });
  assert.equal(result.status, "error"); assert.equal(result.error, "targetChanged");
  assert.equal(f.elements[0].dispatched.length, 0);
});

test("file chunks must arrive in order and finish uses bounded host-supplied data", async () => {
  const f = fixture(); await open(f);
  const tab = { tabId: 11, windowId: 4 };
  const begin = await f.bridge.handleCommand(command("setFiles", { ...tab, ...payload({ stage: "begin", transferId: "t1", targetId: 2,
    expectedAuthorityDigest: EMPTY_AUTHORITY_DIGEST,
    expected: { role: "button", name: "Upload" },
    files: [{ name: "fixture.txt", mimeType: "text/plain", lastModified: 1, size: 1, sha256: createHash("sha256").update("a").digest("hex") }] }) }));
  assert.equal(begin.status, "ok");
  const badOrder = await f.bridge.handleCommand(command("setFiles", { ...tab, ...payload({ stage: "chunk", transferId: "t1", fileIndex: 0, index: 1, base64: "YQ==" }) }));
  assert.equal(badOrder.error, "invalidPayload");
  const chunk = await f.bridge.handleCommand(command("setFiles", { ...tab, ...payload({ stage: "chunk", transferId: "t1", fileIndex: 0, index: 0, base64: "YQ==" }) }));
  assert.equal(chunk.status, "ok");
  const duplicate = await f.bridge.handleCommand(command("setFiles", { ...tab, ...payload({ stage: "chunk", transferId: "t1", fileIndex: 0, index: 0, base64: "YQ==" }) }));
  assert.equal(duplicate.error, "invalidPayload");
  const finish = await f.bridge.handleCommand(command("setFiles", { ...tab, ...payload({ stage: "finish", transferId: "t1" }) }));
  assert.equal(finish.status, "ok", JSON.stringify(finish)); assert.equal(JSON.parse(finish.resultJSON).strategy, "main_click");
  assert.equal(f.scriptCalls.length, 1); assert.equal(f.scriptCalls[0].world, "MAIN");
  assert.match(f.scriptCalls[0].func.toString(), /crypto\.subtle\.digest/);
  assert.equal(f.scriptCalls[0].args[3][0].sha256, createHash("sha256").update("a").digest("hex"));
});

test("ending a task cancels its staged file transfer", async () => {
  const f = fixture(); await open(f);
  const tab = { tabId: 11, windowId: 4 };
  const begin = await f.bridge.handleCommand(command("setFiles", { ...tab, ...payload({ stage: "begin", transferId: "cancel-me", targetId: 2,
    files: [{ name: "fixture.txt", mimeType: "text/plain", lastModified: 1, size: 1, sha256: "a".repeat(64) }] }) }));
  assert.equal(begin.status, "ok");
  assert.equal((await f.bridge.handleCommand(command("endTask"))).status, "ok");
  const chunk = await f.bridge.handleCommand(command("setFiles", { ...tab, ...payload({ stage: "chunk", transferId: "cancel-me", fileIndex: 0, index: 0, base64: "YQ==" }) }));
  assert.equal(chunk.error, "unauthorizedTask");
});

test("MAIN-world file handoff rejects bytes whose SHA-256 does not match host metadata", async () => {
  const f = fixture(); await open(f);
  const tab = { tabId: 11, windowId: 4 }, expected = { role: "button", name: "Upload" };
  await f.bridge.handleCommand(command("setFiles", { ...tab, ...payload({ stage: "begin", transferId: "bad-hash", targetId: 2, expected,
    expectedAuthorityDigest: EMPTY_AUTHORITY_DIGEST,
    files: [{ name: "fixture.txt", mimeType: "text/plain", lastModified: 1, size: 1, sha256: "0".repeat(64) }] }) }));
  await f.bridge.handleCommand(command("setFiles", { ...tab, ...payload({ stage: "chunk", transferId: "bad-hash", fileIndex: 0, index: 0, base64: "YQ==" }) }));
  const finish = await f.bridge.handleCommand(command("setFiles", { ...tab, ...payload({ stage: "finish", transferId: "bad-hash" }) }));
  assert.equal(finish.error, "invalidPayload", JSON.stringify(finish));
});

test("endTask retires the exact task binding but leaves its Safari tab and idle port alone", async () => {
  const f = fixture(); f.bridge.activateNativePort(); await open(f);
  const result = await f.bridge.handleCommand(command("endTask"));
  assert.equal(result.status, "ok"); assert.equal(f.bridge.getState().activeTaskToken, null);
  assert.equal(f.bridge.getState().hasNativePort, true); assert.equal(f.createdTabs.length, 1);
});

test("port-delivered results are returned over native messaging", async () => {
  const f = fixture(); f.bridge.activateNativePort(); f.port.onMessage.emit(command("openTab", { url: "https://example.org/" }));
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(f.results.length, 1); assert.equal(f.results[0].commandId, COMMAND_ID); assert.equal(f.results[0].status, "ok");
});
