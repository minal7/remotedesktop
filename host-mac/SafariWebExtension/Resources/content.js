(function () {
  "use strict";

  // A new id is generated for each document execution. It is metadata only;
  // this first transport slice never reads page text or fields.
  const documentId = crypto.randomUUID();
  browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (window.top !== window || !message || message.kind !== "remoteDesktop.ping.v1") {
      return false;
    }

    const { commandId, taskToken, nonce, tabId, windowId } = message;
    if (!isUUID(commandId) || !isTaskToken(taskToken) || typeof nonce !== "string" || nonce.length < 1 || nonce.length > 128) {
      sendResponse({ status: "error", error: "invalidPayload" });
      return false;
    }
    if (!Number.isSafeInteger(tabId) || !Number.isSafeInteger(windowId) || tabId < 0 || windowId < 0) {
      sendResponse({ status: "error", error: "invalidPayload" });
      return false;
    }

    sendResponse({
      schemaVersion: 1,
      commandId,
      taskToken,
      operation: "ping",
      status: "ok",
      tabId,
      windowId,
      nonce,
      documentId
    });
    return false;
  });

  function isUUID(value) {
    return typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
  }

  function isTaskToken(value) {
    return typeof value === "string" && /^[0-9a-f]{32}$/.test(value);
  }
})();
