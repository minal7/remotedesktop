const test = require("node:test");
const assert = require("node:assert/strict");
const { createBridge } = require("../../../SafariWebExtension/Resources/background.js");

const TOKEN = "0123456789abcdef0123456789abcdef";
const COMMAND_ID = "123e4567-e89b-42d3-a456-426614174000";

function event() {
  const listeners = [];
  return {
    addListener(listener) { listeners.push(listener); },
    emit(...args) { for (const listener of [...listeners]) listener(...args); }
  };
}

function fixture() {
  const port = { onMessage: event(), onDisconnect: event(), disconnectCount: 0 };
  port.disconnect = () => { port.disconnectCount += 1; };
  const results = [];
  const createdTabs = [];
  const sentMessages = [];
  const lookedUpTabs = [];
  const tabsById = new Map();
  let connectCount = 0;
  let contentResponse = null;
  const runtime = {
    lastError: null,
    connectNative() { connectCount += 1; return port; },
    sendNativeMessage(_applicationId, message, callback) {
      results.push(message);
      if (callback) callback(undefined);
    }
  };
  const api = {
    runtime,
    tabs: {
      create(options, callback) {
        const tab = { id: 11, windowId: 4, url: options.url };
        createdTabs.push(tab);
        tabsById.set(tab.id, tab);
        callback(tab);
      },
      get(tabId, callback) {
        lookedUpTabs.push(tabId);
        callback(tabsById.get(tabId));
      },
      sendMessage(tabId, message, options, callback) {
        sentMessages.push({ tabId, message, options });
        callback(contentResponse || {
          schemaVersion: 1,
          commandId: message.commandId,
          taskToken: message.taskToken,
          operation: "ping",
          status: "ok",
          tabId: message.tabId,
          windowId: message.windowId,
          nonce: message.nonce,
          documentId: "doc-001"
        });
      }
    }
  };
  return {
    bridge: createBridge(api), port, results, createdTabs, sentMessages,
    lookedUpTabs, tabsById, setContentResponse(value) { contentResponse = value; },
    connectCount: () => connectCount
  };
}

function command(operation, fields = {}) {
  return { schemaVersion: 1, commandId: COMMAND_ID, taskToken: TOKEN, operation, ...fields };
}

test("native port connects once on background start and idles without polling", () => {
  const f = fixture();
  f.bridge.activateNativePort();
  f.bridge.activateNativePort();
  assert.equal(f.connectCount(), 1);
  assert.equal(f.bridge.getState().active, false);
  assert.equal(f.bridge.getState().hasNativePort, true);
  assert.equal(f.results.length, 0);
});

test("disconnected native port retires task authority without starting a reconnect loop", async () => {
  const f = fixture();
  f.bridge.activateNativePort();
  await f.bridge.handleCommand(command("openTab", { url: "https://drive.google.com/drive/my-drive" }));
  f.port.onDisconnect.emit();
  assert.equal(f.connectCount(), 1);
  assert.deepEqual(f.bridge.getState(), {
    active: false, activeTaskToken: null, boundTab: null, hasNativePort: false
  });
  assert.equal(f.sentMessages.length, 0);
});

test("openTab binds the new tab and ping returns correlated document metadata", async () => {
  const f = fixture();
  const opened = await f.bridge.handleCommand(command("openTab", { url: "https://drive.google.com/drive/my-drive" }));
  assert.deepEqual({ status: opened.status, tabId: opened.tabId, windowId: opened.windowId }, { status: "ok", tabId: 11, windowId: 4 });

  const ping = await f.bridge.handleCommand(command("ping", { tabId: 11, windowId: 4, nonce: "n-1" }));
  assert.deepEqual({ status: ping.status, tabId: ping.tabId, windowId: ping.windowId, nonce: ping.nonce, documentId: ping.documentId }, {
    status: "ok", tabId: 11, windowId: 4, nonce: "n-1", documentId: "doc-001"
  });
  assert.deepEqual(f.sentMessages[0].options, { frameId: 0 });
  assert.equal(f.sentMessages[0].tabId, 11);
});

test("openTab rejects URLs outside the four approved beta site scopes", async () => {
  const f = fixture();
  const result = await f.bridge.handleCommand(command("openTab", { url: "https://example.com/" }));
  assert.equal(result.error, "invalidPayload");
  assert.equal(f.createdTabs.length, 0);
});

test("openTab allows nested paths on Gmail, Drive, and Dropbox", async () => {
  for (const url of [
    "https://mail.google.com/mail/u/0/#inbox",
    "https://drive.google.com/drive/my-drive",
    "https://www.dropbox.com/home/Folder"
  ]) {
    const f = fixture();
    const result = await f.bridge.handleCommand(command("openTab", { url }));
    assert.equal(result.status, "ok", url);
    assert.equal(f.createdTabs.length, 1, url);
  }
});

test("openTab rejects Google paths outside the travel subtree and nondefault HTTPS ports", async () => {
  for (const url of [
    "https://www.google.com/travelogue/",
    "https://mail.google.com:8443/mail/",
    "https://drive.google.com:444/drive/",
    "https://www.dropbox.com:8443/home/"
  ]) {
    const f = fixture();
    const result = await f.bridge.handleCommand(command("openTab", { url }));
    assert.equal(result.error, "invalidPayload", url);
    assert.equal(f.createdTabs.length, 0, url);
  }
});

test("ping cannot reach an unrelated or mismatched tab", async () => {
  const f = fixture();
  await f.bridge.handleCommand(command("openTab", { url: "https://mail.google.com/" }));
  const result = await f.bridge.handleCommand(command("ping", { tabId: 12, windowId: 4, nonce: "n-2" }));
  assert.equal(result.error, "wrongTab");
  assert.equal(f.sentMessages.length, 0);
});

test("explicit host resume looks up only the supplied task tab and validates its site", async () => {
  const f = fixture();
  f.tabsById.set(27, { id: 27, windowId: 8, url: "https://www.dropbox.com/home" });
  const result = await f.bridge.handleCommand(command("ping", { tabId: 27, windowId: 8, nonce: "resume-1" }));
  assert.equal(result.status, "ok");
  assert.deepEqual(f.lookedUpTabs, [27]);
  assert.equal(f.sentMessages[0].tabId, 27);
  assert.deepEqual(f.bridge.getState().boundTab, { tabId: 27, windowId: 8 });
});

test("content-script correlation mismatch is rejected", async () => {
  const f = fixture();
  await f.bridge.handleCommand(command("openTab", { url: "https://drive.google.com/" }));
  f.setContentResponse({
    schemaVersion: 1,
    commandId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    taskToken: TOKEN,
    operation: "ping",
    status: "ok",
    tabId: 11,
    windowId: 4,
    nonce: "n-3",
    documentId: "doc-001"
  });
  const result = await f.bridge.handleCommand(command("ping", { tabId: 11, windowId: 4, nonce: "n-3" }));
  assert.equal(result.error, "operationFailed");
});

test("endTask detaches the task binding without closing a tab or disconnecting the idle port", async () => {
  const f = fixture();
  f.bridge.activateNativePort();
  await f.bridge.handleCommand(command("openTab", { url: "https://www.google.com/travel/" }));
  const result = await f.bridge.handleCommand(command("endTask"));
  assert.equal(result.status, "ok");
  assert.equal(f.bridge.getState().activeTaskToken, null);
  assert.equal(f.bridge.getState().hasNativePort, true);
  assert.equal(f.port.disconnectCount, 0);
  assert.equal(f.createdTabs.length, 1);
});

test("port-delivered host command result is returned through sendNativeMessage", async () => {
  const f = fixture();
  f.bridge.activateNativePort();
  f.port.onMessage.emit(command("openTab", { url: "https://drive.google.com/" }));
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(f.results.length, 1);
  assert.equal(f.results[0].commandId, COMMAND_ID);
  assert.equal(f.results[0].taskToken, TOKEN);
  assert.equal(f.results[0].operation, "openTab");
  assert.equal(f.results[0].status, "ok");
});
