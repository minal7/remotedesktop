import Foundation
import WebKit

enum ComputerUseBrowserDOMCommand: String { case fields, read, edit, receipt, reobserve }

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
      let documentID = nonce(), root = null, nextID = 0;
      const bindings = new Map(), operations = new Map();
      const protectedTypes = new Set(['password', 'hidden', 'file']);
      const textTypes = new Set(['text', 'search', 'url', 'tel', 'email']);
      const identityAttributes = new Set(['id', 'name', 'type', 'form', 'action', 'method', 'enctype', 'target', 'disabled', 'readonly', 'hidden', 'inert', 'aria-hidden', 'aria-label', 'aria-labelledby', 'placeholder', 'autocomplete']);
      const valueGetters = [HTMLInputElement, HTMLTextAreaElement].map(c => Object.getOwnPropertyDescriptor(c.prototype, 'value').get);
      const valueSetters = [HTMLInputElement, HTMLTextAreaElement].map(c => Object.getOwnPropertyDescriptor(c.prototype, 'value').set);
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
          if (root) { documentID = nonce(); bindings.clear(); operations.clear(); }
          root = doc.documentElement;
        }
      }
      function kind(element) {
        if (element instanceof HTMLTextAreaElement) return 1;
        if (!(element instanceof HTMLInputElement) || protectedTypes.has(element.type) || !textTypes.has(element.type)) return -1;
        return 0;
      }
      function editable(element) {
        if (!element.isConnected || element.ownerDocument !== doc || kind(element) < 0 || element.matches(':disabled') || element.readOnly) return false;
        const autocomplete = (element.autocomplete || '').toLowerCase().split(/\s+/);
        if (autocomplete.some(t => t === 'one-time-code' || t.includes('password') || t.startsWith('cc-'))) return false;
        if (element.getClientRects().length === 0) return false;
        let node = element;
        for (let i = 0; node && i < 128; i++, node = parent(node)) {
          if (node.hidden || node.inert || node.getAttribute('aria-hidden') === 'true') return false;
          const style = getComputedStyle(node);
          if (style.display === 'none' || style.visibility !== 'visible' || Number(style.opacity) === 0) return false;
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
      function shape(element) {
        return [element.tagName, element.type || '', element.name || '', element.id || '',
                element.form?.action || '', element.form?.method || ''].join('\u0000');
      }
      function valueOf(element) { return valueGetters[kind(element)].call(element); }
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
      function run(command, args) {
        synchronize();
        if (!root || doc !== document) return reply('stale');
        if (command === 'fields') return fields();
        if (args.documentID !== documentID) return reply('stale');
        if (command === 'reobserve') {
          if (!Array.isArray(args.ids)) return reply('unsupported');
          return fields(args.ids);
        }
        if (command === 'receipt') {
          if (typeof args.operationID !== 'string' || args.operationID.length !== 64) return reply('unsupported');
          return reply(operations.get(args.operationID) === 'dispatched' ? 'dispatched' : 'unproven');
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
        const start = args.mode === 'replaceAll' ? 0 : args.mode === 'append' ? current.value.length : current.selectionStart;
        const end = args.mode === 'replaceAll' ? current.value.length : args.mode === 'append' ? current.value.length : current.selectionEnd;
        if (!['replaceAll', 'append', 'insert'].includes(args.mode) || start < 0 || end < start || end > current.value.length) return reply('unsupported');
        const expected = current.value.slice(0, start) + args.payload + current.value.slice(end);
        if (encoder.encode(expected).length > 1048576 || expected !== args.after) return reply('unsupported');
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
        try validate()
        guard documentID == nil else { throw ComputerUseBrowserError.pageChanged }
        let reply = try await browser.callDOM(.fields, arguments: [:], document: document)
        try validate()
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

    func apply(_ edit: ComputerUseTextPlanEdit, expected: ComputerUseTextSnapshot, operationID: String,
               copySource: ComputerUseTextSnapshot? = nil) async throws {
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
        var arguments: [String: Any] = ["documentID": documentID, "id": id,
            "operationID": operationID, "mode": edit.mode.rawValue, "payload": edit.text, "before": expected.value, "after": after,
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
