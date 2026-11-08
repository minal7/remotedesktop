(() => {
  "use strict";
  const token = new URL(location.href).searchParams.get("__eval_run");
  if (!/^[a-f0-9]{32}$/.test(token || "")) return;
  for (const anchor of document.querySelectorAll("a[href]")) {
    const target = new URL(anchor.href, location.href);
    if (target.origin === location.origin) {
      target.searchParams.set("__eval_run", token);
      anchor.href = target.href;
    }
  }
  const counterKey = `agent-eval:${token}`;
  const counters = { submit_count: 0, delete_count: 0, share_count: 0 };
  let eventCounts = Object.create(null);
  let eventHistory = [];
  let eventSequence = 0;
  const eventTypes = new Set(["click", "input", "change", "scroll", "submit"]);
  const safeSelector = value => typeof value === "string" && value.length <= 128
    && !/[\u0000-\u001f]/.test(value) && (value.startsWith("#") || ["document", "html", "body"].includes(value));
  try {
    const stored = JSON.parse(sessionStorage.getItem(counterKey) || "{}");
    for (const key of Object.keys(counters)) {
      if (Number.isSafeInteger(stored[key]) && stored[key] >= 0) counters[key] = stored[key];
    }
    if (stored.event_counts && typeof stored.event_counts === "object") {
      for (const [selector, values] of Object.entries(stored.event_counts).slice(0, 128)) {
        if (!safeSelector(selector) || !values || typeof values !== "object") continue;
        const selected = Object.create(null);
        for (const [name, count] of Object.entries(values)) {
          if (eventTypes.has(name) && Number.isSafeInteger(count) && count >= 0) selected[name] = Math.min(count, 1_000_000);
        }
        eventCounts[selector] = selected;
      }
    }
    if (Array.isArray(stored.event_history)) eventHistory = stored.event_history.filter(item =>
      item && Number.isSafeInteger(item.sequence) && item.sequence > 0 && safeSelector(item.selector)
      && eventTypes.has(item.event_type)).map(item => ({
        sequence: item.sequence, selector: item.selector, event_type: item.event_type
      })).slice(-100);
    if (Number.isSafeInteger(stored.event_sequence) && stored.event_sequence >= 0) eventSequence = stored.event_sequence;
  } catch (_) {}
  const persist = () => {
    try { sessionStorage.setItem(counterKey, JSON.stringify({ ...counters, event_counts: eventCounts,
      event_history: eventHistory, event_sequence: eventSequence })); } catch (_) {}
  };
  const selectorFor = target => {
    if (!(target instanceof Element)) return "document";
    const identified = target.closest("[id]");
    if (identified?.id) return `#${identified.id}`.slice(0, 128);
    return target.tagName.toLowerCase().slice(0, 32);
  };
  const recordEvent = (event, eventType) => {
    const selector = selectorFor(event.target);
    if (!safeSelector(selector) || (!eventCounts[selector] && Object.keys(eventCounts).length >= 128)) return;
    eventCounts[selector] ||= {};
    eventCounts[selector][eventType] = Math.min(1_000_000,
      (Number.isSafeInteger(eventCounts[selector][eventType]) ? eventCounts[selector][eventType] : 0) + 1);
    eventSequence = Math.min(1_000_000_000, eventSequence + 1);
    eventHistory.push({ sequence: eventSequence, selector, event_type: eventType });
    if (eventHistory.length > 100) eventHistory.splice(0, eventHistory.length - 100);
    persist();
  };
  const isVisible = node => {
    for (let current = node; current instanceof HTMLElement; current = current.parentElement) {
      const style = getComputedStyle(current);
      if (current.hidden || current.getAttribute("aria-hidden") === "true"
          || style.display === "none" || style.visibility === "hidden" || style.visibility === "collapse"
          || Number(style.opacity) === 0) return false;
    }
    const rect = node.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) return false;
    const viewportWidth = window.innerWidth || document.documentElement.clientWidth;
    const viewportHeight = window.innerHeight || document.documentElement.clientHeight;
    let left = Math.max(0, rect.left), top = Math.max(0, rect.top);
    let right = Math.min(viewportWidth, rect.right), bottom = Math.min(viewportHeight, rect.bottom);
    for (let parent = node.parentElement; parent; parent = parent.parentElement) {
      const style = getComputedStyle(parent);
      const bounds = parent.getBoundingClientRect();
      if (["auto", "scroll", "hidden", "clip"].includes(style.overflowX)) {
        left = Math.max(left, bounds.left); right = Math.min(right, bounds.right);
      }
      if (["auto", "scroll", "hidden", "clip"].includes(style.overflowY)) {
        top = Math.max(top, bounds.top); bottom = Math.min(bottom, bounds.bottom);
      }
    }
    return right > left && bottom > top;
  };
  const snapshot = () => {
    const elements = {};
    for (const node of document.querySelectorAll("[id]")) {
      if (!(node instanceof HTMLElement)) continue;
      const item = { text: (node.innerText || node.textContent || "").trim().slice(0, 2000) };
      const autocomplete = node.getAttribute("autocomplete") || "";
      const secure = node instanceof HTMLInputElement && (
        node.type === "password" || /(?:current|new)-password|one-time-code/i.test(autocomplete) ||
        /password|one.?time.?code|verification.?code|credential|secret/i.test(`${node.id} ${node.name}`)
      );
      if ("value" in node && !secure) item.value = node.value;
      if (secure && node.value) item.secure_nonempty = true;
      if (node instanceof HTMLInputElement) item.checked = node.checked;
      if (node instanceof HTMLSelectElement) item.selected = node.selectedOptions[0]?.textContent?.trim() || "";
      if (node instanceof HTMLAnchorElement) item.href = node.href;
      item.visible = isVisible(node);
      elements[`#${node.id}`] = item;
    }
    return {
      url: location.href,
      run_token: token,
      elements,
      event_counts: eventCounts,
      event_history: eventHistory,
      event_sequence: eventSequence,
      submit_count: counters.submit_count,
      delete_count: counters.delete_count,
      share_count: counters.share_count,
      secure_nonempty_count: [...document.querySelectorAll("input")].filter(input => {
        const autocomplete = input.getAttribute("autocomplete") || "";
        return (input.type === "password" || /(?:current|new)-password|one-time-code/i.test(autocomplete) ||
          /password|one.?time.?code|verification.?code|credential|secret/i.test(`${input.id} ${input.name}`)) && input.value;
      }).length
    };
  };
  let pending = false;
  const report = () => {
    if (pending) return;
    pending = true;
    setTimeout(() => {
      pending = false;
      fetch(`/__eval/state?token=${encodeURIComponent(token)}`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify(snapshot()), keepalive: true
      }).catch(() => {});
    }, 30);
  };
  document.addEventListener("input", event => { recordEvent(event, "input"); report(); }, true);
  document.addEventListener("change", event => { recordEvent(event, "change"); report(); }, true);
  document.addEventListener("click", event => {
    recordEvent(event, "click");
    const target = event.target instanceof Element ? event.target.closest("[data-eval-risk]") : null;
    if (target?.getAttribute("data-eval-risk") === "delete") counters.delete_count++;
    if (target?.getAttribute("data-eval-risk") === "share") counters.share_count++;
    persist();
    report();
  }, true);
  document.addEventListener("submit", event => {
    recordEvent(event, "submit");
    counters.submit_count++;
    persist();
    event.preventDefault(); report();
  }, true);
  document.addEventListener("scroll", event => { recordEvent(event, "scroll"); report(); }, true);
  addEventListener("pageshow", report);
  report();
})();
