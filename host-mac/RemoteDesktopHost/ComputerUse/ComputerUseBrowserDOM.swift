import Foundation
import WebKit

enum ComputerUseBrowserDOMCommand: String {
    case fields, read, edit, receipt, reobserve, preflight, pageIdentity, pageSnapshot, validatePageSnapshot
}

/// Page evidence, not an action receipt or proof that the user's goal is met.
/// Destinations stay host-side: a later result adapter must review a selected
/// URL before exposing it as a shareable source. Never serialize this object
/// wholesale into a model prompt or a controller/log message.
struct ComputerUseBrowserPageSnapshot: Decodable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    struct Text: Decodable, Equatable, Sendable {
        let id: String
        /// DOM grouping only; it does not prove two facts describe one ticket.
        let containerID: String
        let text: String
    }
    struct Link: Decodable, Equatable, Sendable {
        let id: String
        let label: String
        let destination: String
        let textIDs: [String]
    }
    let id: String
    let texts: [Text]
    let links: [Link]
    let truncated: Bool
    let omittedEmbeddedContent: Bool

    var description: String {
        "ComputerUseBrowserPageSnapshot(texts: \(texts.count), links: \(links.count), truncated: \(truncated), omittedEmbeddedContent: \(omittedEmbeddedContent))"
    }
    var debugDescription: String { description }

    var isWellFormed: Bool {
        func identifier(_ value: String, prefix: String) -> Bool {
            value.hasPrefix(prefix) && value.utf8.count <= 32
                && !value.dropFirst(prefix.count).isEmpty
                && value.dropFirst(prefix.count).utf8.allSatisfy { (48...57).contains($0) }
        }
        guard id.utf8.count == 32,
              id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              texts.count <= 256, links.count <= 128,
              Set(texts.map(\.id)).count == texts.count, Set(links.map(\.id)).count == links.count,
              texts.allSatisfy({ identifier($0.id, prefix: "t") && identifier($0.containerID, prefix: "g")
                  && !$0.text.isEmpty && $0.text.utf8.count <= 2_048 }),
              links.allSatisfy({ identifier($0.id, prefix: "l") && !$0.label.isEmpty && $0.label.utf8.count <= 2_048
                  && URL(string: $0.destination).flatMap(ComputerUseOwnedBrowser.validatedURL) != nil
                  && Set($0.textIDs).count == $0.textIDs.count && $0.textIDs.count <= 256
                  && Set($0.textIDs).isSubset(of: Set(texts.map(\.id))) }) else { return false }
        return texts.reduce(0) { $0 + $1.text.utf8.count }
            + links.reduce(0) { $0 + $1.label.utf8.count + $1.destination.utf8.count } <= 65_536
    }
}

struct ComputerUseBrowserDOMReply: Decodable {
    struct Field: Decodable {
        let id: String
        let label: String
        let value: String
        let selectionStart: Int
        let selectionEnd: Int
    }
    let status: String
    let documentID: String
    let fields: [Field]?
    let page: ComputerUseBrowserPageSnapshot?
}

/// Fixed host code in a separate WebKit script world. Page text, model output
/// and edit payloads are arguments/data; none are evaluated as JavaScript.
enum ComputerUseBrowserDOM {
    @MainActor static let world = WKContentWorld.world(name: "RemoteDesktop.VerifiedText.v1")
    static let invocation = "return JSON.stringify(globalThis.__remoteDesktopTextV1.run(command, args));"
    static let source = #"""
    (() => {
      'use strict';
      const doc = document;
      const encoder = new TextEncoder();
      const nonce = () => Array.from(crypto.getRandomValues(new Uint8Array(16)), n => n.toString(16).padStart(2, '0')).join('');
      const pageID = nonce();
      let documentID = nonce(), root = null, nextID = 0;
      const bindings = new Map(), operations = new Map();
      let lastPageSnapshot = null;
      const protectedTypes = new Set(['password', 'hidden', 'file']);
      const textTypes = new Set(['text', 'search', 'url', 'tel', 'email']);
      const identityAttributes = new Set(['id', 'name', 'type', 'multiple', 'form', 'action', 'method', 'enctype', 'target', 'disabled', 'readonly', 'hidden', 'inert', 'aria-hidden', 'aria-label', 'aria-labelledby', 'placeholder', 'autocomplete']);
      const valueGetters = [HTMLInputElement, HTMLTextAreaElement].map(c => Object.getOwnPropertyDescriptor(c.prototype, 'value').get);
      const valueSetters = [HTMLInputElement, HTMLTextAreaElement].map(c => Object.getOwnPropertyDescriptor(c.prototype, 'value').set);
      const probeDocument = doc.implementation.createHTMLDocument('');
      const reply = (status, fields) => ({status, documentID, ...(fields ? {fields} : {})});
      const parent = node => node.parentElement || (node.getRootNode() instanceof ShadowRoot ? node.getRootNode().host : null);
      const contains = (ancestor, node) => {
        for (let i = 0; node && i < 128; i++, node = parent(node)) if (node === ancestor) return true;
        return false;
      };
      function retire(records) {
        if (records.length > 10000) { for (const binding of bindings.values()) binding.valid = false; return; }
        for (const record of records) {
          for (const binding of bindings.values()) {
            if (record.type === 'childList' && Array.from(record.removedNodes).some(node => node === binding.element || node.contains(binding.element) || contains(node, binding.element))) binding.valid = false;
            if (record.type === 'attributes' && identityAttributes.has(record.attributeName) && (record.target === binding.form || contains(record.target, binding.element))) binding.valid = false;
            if (record.type !== 'attributes' && binding.labels.some(label => label === record.target || label.contains(record.target))) binding.valid = false;
          }
        }
      }
      const observer = new MutationObserver(retire);
      const observationOptions = {subtree: true, childList: true, attributes: true, attributeFilter: Array.from(identityAttributes), characterData: true};
      observer.observe(doc, observationOptions);
      function synchronize() {
        retire(observer.takeRecords());
        if (root !== doc.documentElement) {
          if (root) { documentID = nonce(); bindings.clear(); operations.clear(); lastPageSnapshot = null; }
          root = doc.documentElement;
        }
      }
      function kind(element) {
        if (element instanceof HTMLTextAreaElement) return 1;
        if (!(element instanceof HTMLInputElement) || protectedTypes.has(element.type) || !textTypes.has(element.type)) return -1;
        return 0;
      }
      function rendered(element) {
        if (!element.isConnected || element.ownerDocument !== doc) return false;
        if (element.getClientRects().length === 0) return false;
        let node = element;
        for (let i = 0; node && i < 128; i++, node = parent(node)) {
          if (node.hidden) return false;
          const style = getComputedStyle(node);
          if (style.display === 'none' || style.visibility !== 'visible' || Number(style.opacity) === 0) return false;
          if (node === root) return true;
        }
        return false;
      }
      function editable(element) {
        if (kind(element) < 0 || element.matches(':disabled') || element.readOnly || !rendered(element)) return false;
        const autocomplete = (element.autocomplete || '').toLowerCase().split(/\s+/);
        if (autocomplete.some(t => t === 'one-time-code' || t.includes('password') || t.startsWith('cc-'))) return false;
        for (let node = element, i = 0; node && i < 128; i++, node = parent(node)) {
          if (node.inert || node.getAttribute('aria-hidden') === 'true') return false;
          if (node === root) return true;
        }
        return false;
      }
      function labelText(node) {
        const walker = doc.createTreeWalker(node, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
          acceptNode(n) {
            return n.nodeType === Node.ELEMENT_NODE && n.matches('input,textarea,select,button,script,style,noscript,[hidden],[aria-hidden="true"]')
              ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
          }
        });
        let text = '', count = 0, child;
        while ((child = walker.nextNode())) {
          if (++count > 512) return 'x'.repeat(257);
          if (child.nodeType === Node.TEXT_NODE) text += child.nodeValue || '';
          if (encoder.encode(text).length > 256) return 'x'.repeat(257);
        }
        return text;
      }
      function labelFor(element) {
        const scope = element.getRootNode();
        const labels = (element.getAttribute('aria-labelledby') || '').split(/\s+/).filter(Boolean)
          .map(id => scope.getElementById?.(id)).filter(Boolean);
        let label = labels.map(labelText).join(' ').trim();
        if (!label) label = (element.getAttribute('aria-label') || '').trim();
        if (!label) {
          labels.push(...Array.from(element.labels || []));
          label = labels.map(labelText).join(' ').trim();
        }
        if (!label) label = (element.getAttribute('placeholder') || '').trim();
        return {label, labels};
      }
      const credentialMarkers = ['password', 'passcode', 'verification code', 'verification field',
        'one time code', 'one time password', 'otp', 'otp code', 'two factor code', 'authentication code',
        'two factor authentication code', 'security code', 'security pin', 'recovery code',
        'backup code', '2fa code', 'mfa code', 'password reset code', 'password reset token'];
      function credentialLabel(value) {
        let words = value.replace(/([A-Z]+)([A-Z][a-z])/g, '$1 $2')
          .replace(/([a-z0-9])([A-Z])/g, '$1 $2').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
        for (let i = 0; i < 4; i++) {
          words = words.replace(/^(?:enter|type|provide|input|txt|your|current|new|confirm|repeat|account|[0-9]{1,2} digit) /, '')
            .replace(/ (?:required|optional|field|input|below|here)$/, '');
        }
        // Whole labels avoid turning ordinary fields such as "Password policy"
        // or "Airport code" into authentication merely because of one word.
        return credentialMarkers.includes(words);
      }
      function authenticationStatus() {
        // Inspect metadata across the whole bounded document BEFORE reading
        // any field value. A later password/code field must protect earlier
        // ordinary-looking inputs too. Re-run before every value/edit command.
        const walkers = [doc.createTreeWalker(doc, NodeFilter.SHOW_ELEMENT)];
        let count = 0;
        while (walkers.length) {
          const walker = walkers[walkers.length - 1], element = walker.nextNode();
          if (!element) { walkers.pop(); continue; }
          if (++count > 10000) return 'limit';
          if (element.shadowRoot) walkers.push(doc.createTreeWalker(element.shadowRoot, NodeFilter.SHOW_ELEMENT));
          const control = element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement
            || element.getAttribute('role') === 'textbox' || element.isContentEditable;
          // Disabled/read-only controls are already excluded from all value
          // reads and edits. A saved-password display is not a login challenge.
          if (!control || !rendered(element) || element.matches(':disabled') || element.readOnly) continue;
          const autocomplete = (element.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/);
          if ((element instanceof HTMLInputElement && element.type === 'password')
              || autocomplete.some(t => t === 'one-time-code' || t === 'username' || t.includes('password'))) {
            return 'authentication-required';
          }
          // Revealed passwords and poorly annotated OTP inputs can be plain
          // text/number fields. Labels and identifiers are data, never code.
          const metadata = [labelFor(element).label, element.getAttribute('id') || '', element.getAttribute('name') || ''];
          if (metadata.some(value => value.length > 1024)) return 'limit';
          if (metadata.some(credentialLabel)) return 'authentication-required';
        }
        return null;
      }
      function shape(element) {
        return [element.tagName, element.type || '', element.name || '', element.id || '',
                element.form?.action || '', element.form?.method || '', String(element.multiple === true)].join('\u0000');
      }
      function valueOf(element) { return valueGetters[kind(element)].call(element); }
      // Ask this WebKit engine whether its native setter/getter can preserve
      // the complete result. The probe has no browsing context, is never
      // connected to the page, copies no custom-element attributes, and emits
      // no events. It must never test compatibility by mutating the real field.
      function canRepresent(element, expected) {
        const index = kind(element);
        if (index < 0) return false;
        const probe = probeDocument.createElement(index === 0 ? 'input' : 'textarea');
        if (index === 0) { probe.type = element.type; probe.multiple = element.multiple; }
        valueSetters[index].call(probe, expected);
        return valueGetters[index].call(probe) === expected;
      }
      function snapshot(binding) {
        const element = binding.element;
        if (!binding.valid || !editable(element) || binding.form !== element.form || binding.shape !== shape(element) || binding.label !== labelFor(element).label) return null;
        const value = valueOf(element);
        if (encoder.encode(value).length > 1048576) return null;
        const start = element.selectionStart, end = element.selectionEnd;
        // Email inputs have no browser selection API. Replace/append remain
        // supported; insert is rejected by the host's invalid-range check.
        return {id: binding.id, label: binding.label, value,
                selectionStart: start === null ? -1 : start,
                selectionEnd: end === null ? -1 : end};
      }
      function fields(expectedIDs) {
        let retained = null;
        if (expectedIDs !== undefined) {
          if (!Array.isArray(expectedIDs) || expectedIDs.length < 1 || expectedIDs.length > 16 || new Set(expectedIDs).size !== expectedIDs.length) return reply('unsupported');
          retained = new Map();
          for (const id of expectedIDs) {
            const binding = bindings.get(id);
            if (!binding || !binding.valid || retained.has(binding.element)) return reply('stale');
            retained.set(binding.element, binding);
          }
        } else { bindings.clear(); operations.clear(); }
        const found = [], walkers = [doc.createTreeWalker(doc, NodeFilter.SHOW_ELEMENT)];
        let count = 0, totalBytes = 0;
        while (walkers.length) {
          const walker = walkers[walkers.length - 1], element = walker.nextNode();
          if (!element) { walkers.pop(); continue; }
          if (++count > 10000) { bindings.clear(); return reply('limit'); }
          if (element.shadowRoot) {
            observer.observe(element.shadowRoot, observationOptions);
            walkers.push(doc.createTreeWalker(element.shadowRoot, NodeFilter.SHOW_ELEMENT));
          }
          // Do not read values from hidden/protected/unsupported controls.
          if (!editable(element)) continue;
          const {label, labels} = labelFor(element);
          if (!label || encoder.encode(label).length > 256) { bindings.clear(); return reply('unsupported'); }
          const binding = retained ? retained.get(element) : {id: 'e' + (++nextID), element, form: element.form, label, labels, shape: shape(element), valid: true};
          if (!binding) return reply('stale');
          const field = snapshot(binding);
          if (!field || found.length >= 16) { bindings.clear(); return reply('limit'); }
          totalBytes += encoder.encode(field.value).length;
          if (totalBytes > 1048576) { bindings.clear(); return reply('limit'); }
          bindings.set(binding.id, binding); found.push(field);
        }
        if (retained && found.length !== retained.size) return reply('stale');
        return reply('ok', found);
      }
      function pageContent() {
        // Read rendered text nodes, never form values, innerHTML, scripts or
        // frame documents. Omitted surfaces and bounds remain explicit; this
        // is not a claim to have read every result on a website.
        const excluded = 'script,style,noscript,template,input,textarea,select,option,[contenteditable]:not([contenteditable="false"]),[role="textbox"],[hidden],[inert],[aria-hidden="true"]';
        const texts = [], links = [], anchors = new Map(), containers = new Map();
        const textRange = doc.createRange();
        const pageParent = node => node.assignedSlot || parent(node);
        let count = 0, bytes = 0, truncated = false, omittedEmbeddedContent = false;
        function visibleInPage(element) {
          for (let depth = 0; element && depth < 128; element = pageParent(element), depth++) {
            const style = getComputedStyle(element);
            if (element.matches(excluded) || style.display === 'none' || style.visibility !== 'visible' || Number(style.opacity) === 0) return false;
            if (element === root) return true;
          }
          truncated = true;
          return false;
        }
        const filter = {
          acceptNode(node) {
            if (node.nodeType === Node.ELEMENT_NODE) {
              const style = getComputedStyle(node);
              if (node.matches(excluded) || style.display === 'none' || style.visibility !== 'visible' || Number(style.opacity) === 0) return NodeFilter.FILTER_REJECT;
              if (node.matches('iframe,frame,object,embed,canvas,svg')) {
                omittedEmbeddedContent = true;
                return NodeFilter.FILTER_REJECT;
              }
            }
            return NodeFilter.FILTER_ACCEPT;
          }
        };
        if (filter.acceptNode(root) === NodeFilter.FILTER_REJECT) return {texts, links, truncated, omittedEmbeddedContent};
        // display:contents has no own rectangle but its descendants can render.
        const walkers = [doc.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, filter)];
        while (walkers.length) {
          const walker = walkers[walkers.length - 1], node = walker.nextNode();
          if (!node) { walkers.pop(); continue; }
          if (++count > 10000) { truncated = true; break; }
          if (node.nodeType === Node.ELEMENT_NODE) {
            if (node.shadowRoot) walkers.push(doc.createTreeWalker(node.shadowRoot, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, filter));
            if (node instanceof HTMLAnchorElement && node.hasAttribute('href')) anchors.set(node, []);
            continue;
          }
          if (texts.length >= 256) { truncated = true; break; }
          if (!visibleInPage(pageParent(node))) continue;
          // A text node may live in unassigned light DOM or unused slot
          // fallback. Computed style alone does not prove it participates in
          // layout. Ranges also preserve text under display:contents parents.
          textRange.selectNodeContents(node);
          if (textRange.getClientRects().length === 0) continue;
          const raw = node.nodeValue || '';
          if (raw.length > 8192) { truncated = true; continue; }
          const text = raw.replace(/\s+/g, ' ').trim();
          if (!text) continue;
          const size = encoder.encode(text).length;
          if (size > 2048 || texts.length >= 256 || bytes + size > 65536) { truncated = true; continue; }
          bytes += size;
          let container = pageParent(node);
          for (let element = container, depth = 0; element && depth < 128; element = pageParent(element), depth++) {
            container = element;
            if (element.matches('p,li,tr,article,section,div,h1,h2,h3,h4,h5,h6,[role="listitem"]')) break;
          }
          if (!containers.has(container)) containers.set(container, 'g' + (containers.size + 1));
          const entry = {id: 't' + (texts.length + 1), containerID: containers.get(container), text};
          texts.push(entry);
          for (let element = pageParent(node), depth = 0; element && depth < 128; element = pageParent(element), depth++) {
            if (anchors.has(element)) { anchors.get(element).push(entry); break; }
          }
        }
        for (const [anchor, parts] of anchors) {
          // href is data. Resolve with the document's base URL; never navigate
          // or evaluate it. Unsupported destinations remain plain page text.
          if (links.length >= 128) { truncated = true; break; }
          if (!visibleInPage(anchor) || (!parts.length && anchor.getClientRects().length === 0)) continue;
          const label = parts.map(entry => entry.text).join(' ').trim() || (anchor.getAttribute('aria-label') || '').trim();
          const raw = anchor.getAttribute('href') || '';
          if (!label) continue;
          if (label.length > 8192 || raw.length > 8192) { truncated = true; continue; }
          let url;
          try { url = new URL(raw, doc.baseURI); } catch (_) { continue; }
          if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) continue;
          const labelBytes = encoder.encode(label).length, urlBytes = encoder.encode(url.href).length;
          if (labelBytes > 2048 || urlBytes > 8192 || links.length >= 128 || bytes + labelBytes + urlBytes > 65536) {
            truncated = true; continue;
          }
          bytes += labelBytes + urlBytes;
          links.push({id: 'l' + (links.length + 1), label, destination: url.href, textIDs: parts.map(entry => entry.id)});
        }
        return {texts, links, truncated, omittedEmbeddedContent};
      }
      function run(command, args) {
        // Read only the identity of this loaded Document, before inspecting
        // any form metadata/value or draining target mutation records. Root
        // replacement still retires field bindings through synchronize().
        if (command === 'pageIdentity') {
          return {status: doc === document && doc.documentElement && doc.readyState === 'complete'
            ? 'page-identity' : 'stale', documentID: pageID};
        }
        synchronize();
        if (!root || doc !== document) return reply('stale');
        if (command === 'pageSnapshot' || command === 'validatePageSnapshot') {
          const status = authenticationStatus();
          if (status) { lastPageSnapshot = null; return reply(status); }
          if (doc.readyState !== 'complete') return reply('stale');
          const content = pageContent(), serialized = JSON.stringify(content);
          if (command === 'validatePageSnapshot') {
            // Re-read the projection, including rendering and resolved URLs.
            // Mutation records alone miss CSSOM/value-property changes.
            if (!lastPageSnapshot || args.documentID !== documentID || args.snapshotID !== lastPageSnapshot.id
                || lastPageSnapshot.documentID !== documentID || serialized !== lastPageSnapshot.serialized) return reply('stale');
            return reply('page-current');
          }
          const id = nonce();
          lastPageSnapshot = {id, documentID, serialized};
          return {status: 'page-snapshot', documentID, page: {id, ...content}};
        }
        if (command !== 'fields' && args.documentID !== documentID) return reply('stale');
        // Historical dispatch evidence reads no form values and must survive
        // a login overlay appearing after an earlier input was dispatched.
        if (command === 'receipt') {
          if (typeof args.operationID !== 'string' || args.operationID.length !== 64) return reply('unsupported');
          return reply(operations.get(args.operationID) === 'dispatched' ? 'dispatched' : 'unproven');
        }
        if (['fields', 'read', 'edit', 'reobserve', 'preflight'].includes(command)) {
          const status = authenticationStatus();
          if (status) return reply(status);
        }
        if (command === 'fields') return fields();
        if (command === 'reobserve') {
          if (!Array.isArray(args.ids)) return reply('unsupported');
          return fields(args.ids);
        }
        if (command === 'preflight') {
          if (!Array.isArray(args.steps) || args.steps.length < 1 || args.steps.length > 8) return reply('unsupported');
          // Check every intermediate result, including repeated targets and
          // values resolved from earlier copies, before the task starts input.
          for (const step of args.steps) {
            if (!step || typeof step.id !== 'string' || typeof step.after !== 'string' || encoder.encode(step.after).length > 1048576) return reply('unsupported');
            const binding = bindings.get(step.id);
            if (!binding || !snapshot(binding)) return reply('stale');
            if (!canRepresent(binding.element, step.after)) return reply('unrepresentable');
          }
          return reply('ok');
        }
        const binding = bindings.get(args.id), current = binding && snapshot(binding);
        if (!current) return reply('stale');
        if (command === 'read') return reply('ok', [current]);
        if (command !== 'edit' || typeof args.operationID !== 'string' || args.operationID.length !== 64 || typeof args.payload !== 'string') return reply('unsupported');
        if (operations.has(args.operationID)) return reply('duplicate');
        if (operations.size >= 64 || encoder.encode(args.payload).length > 65536) return reply('limit');
        if (current.value !== args.before || (args.mode === 'insert' &&
            (current.selectionStart !== args.selectionStart || current.selectionEnd !== args.selectionEnd))) return reply('stale');
        // Copy authority includes the retained source object and its exact
        // value. Validate both objects synchronously in this isolated world,
        // before the destination setter or any page event can run.
        if (args.copySourceID !== undefined) {
          const sourceBinding = bindings.get(args.copySourceID), source = sourceBinding && snapshot(sourceBinding);
          if (!source || source.value !== args.copySourceValue || source.value !== args.payload) return reply('stale');
        }
        // These checks and the live setter run in one synchronous invocation.
        // Host reads alone cannot keep an unchanged or previously edited field
        // from drifting while an edit is queued in WebKit.
        if (!Array.isArray(args.requiredValues) || args.requiredValues.length > 16) return reply('unsupported');
        const requiredIDs = new Set();
        for (const required of args.requiredValues) {
          if (!required || typeof required.id !== 'string' || typeof required.value !== 'string' ||
              requiredIDs.has(required.id) || encoder.encode(required.value).length > 1048576) return reply('unsupported');
          requiredIDs.add(required.id);
          const retainedBinding = bindings.get(required.id), retained = retainedBinding && snapshot(retainedBinding);
          if (!retained || retained.value !== required.value) return reply('constraint-changed');
        }
        const start = args.mode === 'replaceAll' ? 0 : args.mode === 'append' ? current.value.length : current.selectionStart;
        const end = args.mode === 'replaceAll' ? current.value.length : args.mode === 'append' ? current.value.length : current.selectionEnd;
        if (!['replaceAll', 'append', 'insert'].includes(args.mode) || start < 0 || end < start || end > current.value.length) return reply('unsupported');
        const expected = current.value.slice(0, start) + args.payload + current.value.slice(end);
        if (encoder.encode(expected).length > 1048576 || expected !== args.after) return reply('unsupported');
        // Repeat at the actual dispatch boundary, before touching the live
        // value, selection, receipt, or any page event handler.
        if (!canRepresent(binding.element, expected)) return reply('unrepresentable');
        // The dispatcher persisted its attempt before this call. This second
        // one-use boundary also prevents a lost callback from repeating input.
        operations.set(args.operationID, 'attempted');
        try {
          valueSetters[kind(binding.element)].call(binding.element, expected);
          if (current.selectionStart >= 0) binding.element.setSelectionRange(start + args.payload.length, start + args.payload.length);
          binding.element.dispatchEvent(new InputEvent('input', {bubbles: true, composed: true, inputType: 'insertText', data: args.payload}));
          operations.set(args.operationID, 'dispatched');
          return reply('attempted');
        } catch (_) { return reply('uncertain'); }
      }
      Object.defineProperty(globalThis, '__remoteDesktopTextV1', {value: Object.freeze({run}), writable: false, configurable: false});
    })();
    """#
}

/// A text adapter sealed to one owned page and one set of retained DOM objects.
/// Only labels go to the existing local planner; exact values remain host-side.
@MainActor
final class ComputerUseBrowserTextTarget {
    private let browser: ComputerUseOwnedBrowser
    private let document: ComputerUseBrowserDocument
    private let requiresFrontmost: Bool
    private var documentID: String?
    private var targets: [String: String] = [:]

    init(browser: ComputerUseOwnedBrowser, document: ComputerUseBrowserDocument, requiresFrontmost: Bool = true) {
        self.browser = browser
        self.document = document
        self.requiresFrontmost = requiresFrontmost
    }

    func fields() async throws -> [ComputerUseTextField] {
        guard let fields = try await fieldsIfSupported() else { throw ComputerUseBrowserError.unsupportedDocument }
        return fields
    }

    /// Only an explicit, complete no-effect discovery decline permits another
    /// capability to consider a fresh task. Transport/decoding failures, stale
    /// documents and invalid snapshots remain errors, even before an edit.
    /// Retained tasks and clarification answers must not use this entrypoint.
    func fieldsIfSupported() async throws -> [ComputerUseTextField]? {
        try validate()
        guard documentID == nil else { throw ComputerUseBrowserError.pageChanged }
        let reply = try await browser.callDOM(.fields, arguments: [:], document: document)
        try validate()
        if reply.status == "unsupported" || reply.status == "limit" {
            guard reply.fields == nil else { throw ComputerUseBrowserError.unsupportedDocument }
            return nil
        }
        if reply.status == "stale" { throw ComputerUseBrowserError.pageChanged }
        guard reply.status == "ok", let fields = reply.fields, fields.count <= 16 else {
            throw ComputerUseBrowserError.unsupportedDocument
        }
        documentID = reply.documentID
        var result: [ComputerUseTextField] = []
        for field in fields {
            let id = ComputerUseTaskContract.digest([document.contextID, document.taskID, String(document.generation), reply.documentID, field.id])
            guard targets[id] == nil else { throw ComputerUseBrowserError.pageChanged }
            targets[id] = field.id
            result.append(.init(label: field.label, snapshot: try snapshot(field, targetID: id)))
        }
        return result
    }

    /// Identity of the retained form, independent of a later answer's task
    /// ID and current field values. Re-observation still has to validate every
    /// retained DOM object; a digest alone does not prove current membership.
    func clarificationScope() throws -> String {
        try validate()
        guard let documentID, !targets.isEmpty else { throw ComputerUseBrowserError.unsupportedDocument }
        // Browser generation also advances when ownership transfers to a new
        // task. validate() checks that lease; the isolated document nonce and
        // retained object IDs bind the form across an authorized transfer.
        return ComputerUseTaskContract.digest(["owned-form-clarification-v1", document.contextID,
            documentID] + targets.values.sorted())
    }

    /// Transfer one unchanged retained form to an explicitly claimed answer
    /// task. This reads fresh values without rediscovering replacement objects
    /// or clearing operation receipts. A failed transfer starts no input.
    func continuingForClarification(taskID: String) async throws
        -> (target: ComputerUseBrowserTextTarget, fields: [ComputerUseTextField]) {
        let next = try transferForClarification(taskID: taskID)
        return (next, try await next.reobserveRetainedFields())
    }

    /// Transfer synchronously so the executor can retain the new owner before
    /// cancellation can interrupt its first asynchronous observation.
    func transferForClarification(taskID: String) throws -> ComputerUseBrowserTextTarget {
        try validate()
        guard !taskID.isEmpty, taskID != document.taskID, let documentID, !targets.isEmpty else {
            throw ComputerUseBrowserError.pageChanged
        }
        let nextDocument = try browser.acquireCurrentDocument(taskID: taskID)
        let next = ComputerUseBrowserTextTarget(browser: browser, document: nextDocument, requiresFrontmost: requiresFrontmost)
        next.documentID = documentID
        next.targets = targets
        return next
    }

    func reobserveRetainedFields() async throws -> [ComputerUseTextField] {
        try validate()
        guard let documentID, !targets.isEmpty else { throw ComputerUseBrowserError.pageChanged }
        try await browser.waitForDOMCompletion(document: document)
        try validate()
        let reply = try await browser.callDOM(.reobserve,
            arguments: ["documentID": documentID, "ids": targets.values.sorted()], document: document)
        try validate()
        guard reply.status == "ok", reply.documentID == documentID, let fields = reply.fields,
              fields.count == targets.count, Set(fields.map(\.id)) == Set(targets.values) else {
            throw ComputerUseBrowserError.pageChanged
        }
        let identities = Dictionary(uniqueKeysWithValues: targets.map { ($0.value, $0.key) })
        let refreshed = try fields.map { field -> ComputerUseTextField in
            guard let id = identities[field.id] else { throw ComputerUseBrowserError.pageChanged }
            return .init(label: field.label, snapshot: try snapshot(field, targetID: id))
        }
        return refreshed
    }

    func read(targetID: String) async throws -> ComputerUseTextSnapshot? {
        try validate()
        guard let documentID, let id = targets[targetID] else { return nil }
        let reply = try await browser.callDOM(.read, arguments: ["documentID": documentID, "id": id], document: document)
        try validate()
        guard reply.status == "ok", reply.documentID == documentID,
              let fields = reply.fields, fields.count == 1, fields[0].id == id else { return nil }
        return try snapshot(fields[0], targetID: targetID)
    }

    func didDispatchInput(operationID: String) async throws -> Bool {
        try validate()
        guard let documentID else { return false }
        let reply = try await browser.callDOM(.receipt, arguments: ["documentID": documentID, "operationID": operationID], document: document)
        try validate()
        guard reply.documentID == documentID else { throw ComputerUseBrowserError.pageChanged }
        return reply.status == "dispatched"
    }

    func validateRepresentability(of contract: ComputerUseTextTaskContract) async throws {
        try validate()
        guard let documentID, (1...8).contains(contract.steps.count) else { throw ComputerUseTextTaskError.staleTarget }
        let steps: [[String: String]] = try contract.steps.map { step in
            guard let id = targets[step.targetID], step.after.utf8.count <= ComputerUseTextEditor.maximumObservedValueBytes else {
                throw ComputerUseTextTaskError.staleTarget
            }
            return ["id": id, "after": step.after]
        }
        let reply = try await browser.callDOM(.preflight, arguments: ["documentID": documentID, "steps": steps], document: document)
        try validate()
        guard reply.documentID == documentID else { throw ComputerUseBrowserError.pageChanged }
        if reply.status == "stale" { throw ComputerUseTextTaskError.staleTarget }
        if reply.status == "unrepresentable" { throw ComputerUseTextEditError.valueNotRepresentable }
        guard reply.status == "ok" else { throw ComputerUseBrowserError.unsupportedDocument }
    }

    func apply(_ dispatch: ComputerUseTextInputDispatch) async throws {
        try await apply(dispatch.edit, expected: dispatch.expected, operationID: dispatch.operationID,
                        copySource: dispatch.copySource, requiredValues: dispatch.requiredValues)
    }

    /// Standalone edits have no constraints on other fields. Compiled tasks
    /// use the dispatch overload to retain every per-step requirement.
    func apply(_ edit: ComputerUseTextPlanEdit, expected: ComputerUseTextSnapshot, operationID: String,
               copySource: ComputerUseTextSnapshot? = nil, requiredValues: [String: String] = [:]) async throws {
        try validate()
        guard edit.targetID == expected.targetID, let documentID, let id = targets[edit.targetID],
              edit.text.utf8.count <= ComputerUseTextEditor.maximumPayloadBytes else { throw ComputerUseTextTaskError.staleTarget }
        let range: NSRange
        switch edit.mode {
        case .replaceAll: range = NSRange(location: 0, length: expected.value.utf16.count)
        case .append: range = NSRange(location: expected.value.utf16.count, length: 0)
        case .insert: range = expected.selection
        }
        guard let textRange = Range(range, in: expected.value) else { throw ComputerUseTextEditError.invalidSelection }
        let after = expected.value.replacingCharacters(in: textRange, with: edit.text)
        guard after.utf8.count <= ComputerUseTextEditor.maximumObservedValueBytes else { throw ComputerUseTextEditError.payloadTooLarge }
        guard requiredValues.count <= 16 else { throw ComputerUseTextTaskError.invalidPlan }
        let requirements: [[String: String]] = try requiredValues.keys.sorted().map { targetID in
            guard let id = targets[targetID], let value = requiredValues[targetID],
                  value.utf8.count <= ComputerUseTextEditor.maximumObservedValueBytes else {
                throw ComputerUseTextTaskError.staleTarget
            }
            return ["id": id, "value": value]
        }
        var arguments: [String: Any] = ["documentID": documentID, "id": id,
            "operationID": operationID, "mode": edit.mode.rawValue, "payload": edit.text, "before": expected.value, "after": after,
            "requiredValues": requirements,
            "selectionStart": expected.selection.location == NSNotFound ? -1 : expected.selection.location,
            "selectionEnd": expected.selection.location == NSNotFound ? -1 : NSMaxRange(expected.selection)]
        if let copySource {
            guard let sourceID = targets[copySource.targetID], copySource.isEditable, !copySource.isSecure,
                  copySource.value.utf8.elementsEqual(edit.text.utf8) else { throw ComputerUseTextTaskError.staleTarget }
            arguments["copySourceID"] = sourceID
            arguments["copySourceValue"] = copySource.value
        }
        let reply = try await browser.callDOM(.edit, arguments: arguments, document: document)
        try validate()
        if reply.status == "stale" { throw ComputerUseTextTaskError.staleTarget }
        guard reply.documentID == documentID else { throw ComputerUseTextEditError.deliveryUncertain }
        if reply.status == "constraint-changed" { throw ComputerUseTextTaskError.incompleteOutcome }
        if reply.status == "unrepresentable" { throw ComputerUseTextEditError.valueNotRepresentable }
        guard reply.status == "attempted" else { throw ComputerUseTextEditError.deliveryUncertain }
        // A separate read by the transaction engine proves the resulting value.
    }

    private func validate() throws {
        try Task.checkCancellation()
        guard browser.validate(document), !requiresFrontmost || browser.isFrontmostWindow else {
            throw ComputerUseBrowserError.pageChanged
        }
    }

    private func snapshot(_ field: ComputerUseBrowserDOMReply.Field, targetID: String) throws -> ComputerUseTextSnapshot {
        guard !field.id.isEmpty, field.id.utf8.count <= 64, !field.label.isEmpty, field.label.utf8.count <= 256,
              field.value.utf8.count <= ComputerUseTextEditor.maximumObservedValueBytes else { throw ComputerUseBrowserError.unsupportedDocument }
        let selection: NSRange
        if field.selectionStart == -1 && field.selectionEnd == -1 { selection = NSRange(location: NSNotFound, length: 0) }
        else {
            guard field.selectionStart >= 0, field.selectionEnd >= field.selectionStart,
                  field.selectionEnd <= field.value.utf16.count else { throw ComputerUseTextEditError.invalidSelection }
            selection = NSRange(location: field.selectionStart, length: field.selectionEnd - field.selectionStart)
        }
        return .init(targetID: targetID, value: field.value, selection: selection, isEditable: true, isSecure: false)
    }
}
