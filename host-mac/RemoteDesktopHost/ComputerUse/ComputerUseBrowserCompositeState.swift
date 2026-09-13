import Foundation

/// One bounded, scoped option graph. Focus, selection, input text and option
/// labels remain distinct observations; none is a provider result fact.
enum ComputerUseBrowserCompositeState {
    static let kinds: Set<String> = ["aria-combobox", "aria-listbox"]
    static let maximumBytes = 8_192

    static func object(_ value: String, control: ComputerUseBrowserPageSnapshot.Control) -> [String: Any]? {
        guard value.utf8.count <= maximumBytes, let role = control.compositeRole else { return nil }
        var parser = StrictSemanticJSONParser(value, maximumValueCount: 2_048)
        guard let parsed = try? parser.parse(), case .object(let root) = parsed,
              Set(root.keys) == ["role", "attributes", "list_attributes", "list_label", "list_disabled", "list_hidden", "input_value", "display_text", "active_option", "list_active_option", "options"],
              string(root["role"]) == role, attributes(root["attributes"]), attributes(root["list_attributes"]),
              bounded(root["list_label"], limit: 256), boolean(root["list_disabled"]), boolean(root["list_hidden"]),
              case .object(let owner)? = root["attributes"], case .object(let list)? = root["list_attributes"],
              case .array(let options)? = root["options"], options.count <= 64 else { return nil }
        if role == "combobox" {
            guard ["true", "false"].contains(string(owner["aria-expanded"]) ?? ""),
                  owner["aria-haspopup"] == nil || string(owner["aria-haspopup"]) == "listbox" else { return nil }
            if ["text", "search", "textarea"].contains(control.kind) {
                guard bounded(root["input_value"], limit: 2_048), isNull(root["display_text"]) else { return nil }
            } else {
                guard isNull(root["input_value"]), bounded(root["display_text"], limit: 2_048) else { return nil }
            }
        } else if role != "listbox" || !isNull(root["input_value"]) || !isNull(root["display_text"]) { return nil }
        var ids: Set<String> = [], positions: Set<Int> = [], selected = 0
        for option in options {
            guard case .object(let row) = option,
                  Set(row.keys) == ["id", "label", "groups", "selected", "checked", "disabled", "hidden", "position", "size"],
                  let id = string(row["id"]), identifier(id), ids.insert(id).inserted,
                  bounded(row["label"], limit: 256, nonempty: true),
                  nullable(row["selected"], choices: ["true", "false"]), nullable(row["checked"], choices: ["true", "false", "mixed"]),
                  boolean(row["disabled"]), boolean(row["hidden"]),
                  case .array(let groups)? = row["groups"], groups.count <= 8 else { return nil }
            for group in groups {
                guard case .object(let row) = group, Set(row.keys) == ["label", "disabled", "hidden"],
                      bounded(row["label"], limit: 256, nonempty: true), boolean(row["disabled"]), boolean(row["hidden"]) else { return nil }
            }
            if !isNull(row["position"]) {
                guard let raw = string(row["position"]), let position = positive(raw), position <= options.count,
                      positions.insert(position).inserted else { return nil }
            }
            if !isNull(row["size"]) {
                guard let raw = string(row["size"]), positive(raw) == options.count else { return nil }
            }
            if string(row["selected"]) == "true" { selected += 1 }
        }
        guard selected <= 1 || (role == "listbox" && string(list["aria-multiselectable"]) == "true") else { return nil }
        for key in ["active_option", "list_active_option"] {
            guard isNull(root[key]) || string(root[key]).map(ids.contains) == true else { return nil }
        }
        return (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [String: Any]
    }

    private static func string(_ value: MCPJSONValue?) -> String? { if case .string(let text)? = value { return text }; return nil }
    private static func isNull(_ value: MCPJSONValue?) -> Bool { if case .null? = value { return true }; return false }
    private static func boolean(_ value: MCPJSONValue?) -> Bool { if case .bool? = value { return true }; return false }
    private static func bounded(_ value: MCPJSONValue?, limit: Int, nonempty: Bool = false) -> Bool {
        string(value).map { $0.utf8.count <= limit && (!nonempty || !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } ?? false
    }
    private static func nullable(_ value: MCPJSONValue?, choices: Set<String>) -> Bool { isNull(value) || string(value).map(choices.contains) == true }
    private static func positive(_ value: String) -> Int? {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(value), number > 0 else { return nil }
        return number
    }
    private static func identifier(_ value: String) -> Bool {
        value.hasPrefix("o") && value.utf8.count <= 32 && positive(String(value.dropFirst())) != nil
    }
    private static func attributes(_ value: MCPJSONValue?) -> Bool {
        guard case .object(let object)? = value else { return false }
        let flags: Set<String> = ["aria-expanded", "aria-disabled", "aria-readonly", "aria-required", "aria-multiselectable", "aria-busy"]
        guard Set(object.keys).isSubset(of: flags.union(["aria-haspopup", "aria-orientation", "aria-autocomplete", "aria-invalid"])) else { return false }
        return object.allSatisfy { key, value in bounded(value, limit: 256, nonempty: true)
            && (!flags.contains(key) || ["true", "false"].contains(string(value) ?? "")) }
    }

    // Inserted inside pageContent, sharing its document, budgets and helpers.
    // This observes DOM data only; it never opens a popup or changes focus.
    static let script = #"""
        const compositeIDMaps = new Map(), compositeOwnerMaps = new Map();
        function compositeState(element, control) {
          const references = [], referenceSet = new Set(), seen = new Set(), options = [], optionElements = [], positions = new Set();
          let nodes = 0;
          const retain = node => { if (!referenceSet.has(node)) { referenceSet.add(node); references.push(node); } return node; };
          function resolve(node, raw, many = false) {
            if (!small(raw, 2048)) throw 0;
            const ids = raw.trim().split(/\s+/).filter(Boolean);
            if (!ids.length || ids.length > 64 || (!many && ids.length !== 1) || new Set(ids).size !== ids.length) throw 0;
            const tree = node.getRootNode();
            if (!compositeIDMaps.has(tree)) {
              const map = new Map(), owners = new Map(), walker = doc.createTreeWalker(tree, NodeFilter.SHOW_ELEMENT);
              let current, count = 0, ownershipCount = 0;
              while ((current = walker.nextNode())) {
                if (++count > 10000) throw 0;
                if (current.id) map.set(current.id, map.has(current.id) ? null : current);
                if (current.hasAttribute('aria-owns')) {
                  const raw = current.getAttribute('aria-owns');
                  if (!small(raw,2048)) throw 0;
                  for (const id of raw.trim().split(/\s+/).filter(Boolean)) {
                    if (++ownershipCount > 4096) throw 0;
                    if (!owners.has(id)) owners.set(id,new Set());
                    owners.get(id).add(current);
                  }
                }
              }
              compositeIDMaps.set(tree, map); compositeOwnerMaps.set(tree, owners);
            }
            return ids.map(id => {
              const target = compositeIDMaps.get(tree).get(id);
              if (!target || !target.isConnected || target.ownerDocument !== doc) throw 0;
              return retain(target);
            });
          }
          function label(node, contents) {
            let value = '';
            if (node.hasAttribute('aria-labelledby')) value = resolve(node, node.getAttribute('aria-labelledby'), true).map(labelText).join(' ').trim();
            else value = (node.getAttribute('aria-label') || '').trim();
            if (!value && contents) value = labelText(node).trim();
            if (!small(value, 256)) throw 0;
            return value;
          }
          function attrs(node) {
            const result = {}, flags = ['aria-expanded','aria-disabled','aria-readonly','aria-required','aria-multiselectable','aria-busy'];
            for (const key of [...flags,'aria-haspopup','aria-orientation','aria-autocomplete','aria-invalid']) if (node.hasAttribute(key)) {
              const value = node.getAttribute(key);
              if (!small(value, 256) || !value || (flags.includes(key) && !['true','false'].includes(value))) throw 0;
              result[key] = value;
            }
            return result;
          }
          function disabled(node) {
            let result = false;
            for (let depth = 0; node && depth < 128; node = pageParent(node), depth++) {
              retain(node);
              if (node.hasAttribute('aria-disabled') && !['true','false'].includes(node.getAttribute('aria-disabled'))) throw 0;
              if (node.matches(':disabled') || node.getAttribute('aria-disabled') === 'true') result = true;
              if (node === root) return result;
            }
            throw 0;
          }
          function hidden(node) { return !renderedControl(node); }
          function nullable(node, key, allowed) {
            if (!node.hasAttribute(key)) return null;
            const value = node.getAttribute(key);
            if (!allowed.includes(value)) throw 0;
            return value;
          }
          function positive(node, key) {
            if (!node.hasAttribute(key)) return null;
            const value = node.getAttribute(key);
            if (!small(value, 32) || !/^[0-9]+$/.test(value) || !Number.isSafeInteger(Number(value)) || Number(value) < 1) throw 0;
            return value;
          }
          function displayValue(node) {
            const walker = doc.createTreeWalker(node,NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT,{acceptNode(current) {
              if (current.nodeType !== Node.ELEMENT_NODE) return NodeFilter.FILTER_ACCEPT;
              const style = getComputedStyle(current);
              return current === list || current.matches('script,style,noscript,template,[hidden],[inert],[aria-hidden="true"]')
                || style.display === 'none' || style.visibility !== 'visible' || Number(style.opacity) === 0
                ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
            }});
            let current, count = 0, value = '';
            while ((current = walker.nextNode())) {
              if (++count > 512) throw 0;
              if (current.nodeType !== Node.TEXT_NODE) continue;
              textRange.selectNodeContents(current);
              if (!textRange.getClientRects().length) continue;
              value += current.nodeValue || '';
              if (!small(value,2048)) throw 0;
            }
            return value.replace(/\s+/g,' ').trim();
          }
          function visit(node, groups, depth) {
            if (++nodes > 512 || depth > 32 || seen.has(node) || node.shadowRoot || node.isContentEditable) throw 0;
            seen.add(node); retain(node);
            const role = node.getAttribute('role') || '';
            if (role === 'option') {
              if (options.length >= 64 || node.hasAttribute('aria-owns') || node.querySelector('input,textarea,select,button,[role],a[href]')) throw 0;
              const name = label(node, true);
              if (!name) throw 0;
              if (!pageOptionIDs.has(node)) pageOptionIDs.set(node, 'o' + (++nextPageOptionID));
              const position = positive(node, 'aria-posinset'), size = positive(node, 'aria-setsize');
              if (position !== null && positions.has(Number(position))) throw 0;
              if (position !== null) positions.add(Number(position));
              options.push({id:pageOptionIDs.get(node), label:name, groups, selected:nullable(node,'aria-selected',['true','false']),
                checked:nullable(node,'aria-checked',['true','false','mixed']), disabled:disabled(node) || groups.some(group => group.disabled) || disabled(list),
                hidden:hidden(node) || groups.some(group => group.hidden), position, size});
              optionElements.push(node);
              return;
            }
            if (node !== list && !['','group','none','presentation'].includes(role)) throw 0;
            if (node !== list && node.matches('input,textarea,select,button,a[href],iframe,object,embed,canvas,svg')) throw 0;
            if (role === 'group') {
              const name = label(node, false);
              if (!name || groups.length >= 8) throw 0;
              if (researchValueProtected(node, {label:name, name:node.getAttribute('name') || ''})) throw 0;
              groups = [...groups,{label:name, disabled:disabled(node), hidden:hidden(node)}];
            }
            for (const child of node.children) visit(child, groups, depth + 1);
            if (node.hasAttribute('aria-owns')) for (const owned of resolve(node,node.getAttribute('aria-owns'),true)) {
              const owners = compositeOwnerMaps.get(node.getRootNode()).get(owned.id);
              if (!owners || owners.size !== 1 || !owners.has(node)) throw 0;
              // A second physical list/group is not silently overwritten by
              // a remote ownership claim. Duplicate/reordered visits also fail.
              for (let ancestor = owned.parentElement; ancestor; ancestor = ancestor.parentElement) {
                if (['listbox','group'].includes(ancestor.getAttribute('role')) && !seen.has(ancestor)) throw 0;
              }
              visit(owned,groups,depth + 1);
            }
          }
          let list;
          try {
            retain(element); label(element, false);
            const attributes = attrs(element);
            if (control.compositeRole === 'combobox') {
              if (!['true','false'].includes(attributes['aria-expanded']) || (attributes['aria-haspopup'] !== undefined && attributes['aria-haspopup'] !== 'listbox')) throw 0;
              const key = element.hasAttribute('aria-controls') ? 'aria-controls' : 'aria-owns';
              list = resolve(element,element.getAttribute(key))[0];
              if (element.hasAttribute('aria-controls') && element.hasAttribute('aria-owns') && resolve(element,element.getAttribute('aria-owns'))[0] !== list) throw 0;
            } else list = element;
            if (list === element && control.compositeRole !== 'listbox' || list.getAttribute('role') !== 'listbox') throw 0;
            const listLabel = label(list, false), listAttributes = attrs(list);
            if (researchValueProtected(list, {label:listLabel, name:list.getAttribute('name') || ''})) throw 0;
            visit(list, [], 0);
            if (options.some(option => option.position !== null && Number(option.position) > options.length
                || option.size !== null && Number(option.size) !== options.length)) throw 0;
            if (options.filter(option => option.selected === 'true').length > 1
                && (control.compositeRole !== 'listbox' || listAttributes['aria-multiselectable'] !== 'true')) throw 0;
            function active(node) {
              if (!node.hasAttribute('aria-activedescendant')) return null;
              const target = resolve(node,node.getAttribute('aria-activedescendant'))[0], index = optionElements.indexOf(target);
              if (index < 0) throw 0;
              return options[index].id;
            }
            let inputValue = null, displayText = null;
            if (control.compositeRole === 'combobox') {
              if (element instanceof HTMLInputElement) inputValue = valueGetters[0].call(element);
              else if (element instanceof HTMLTextAreaElement) inputValue = valueGetters[1].call(element);
              else {
                if (element.querySelector('input,textarea,select,[contenteditable]:not([contenteditable="false"])')) throw 0;
                displayText = displayValue(element);
              }
              if (inputValue !== null && !small(inputValue,2048) || displayText !== null && !small(displayText,2048)) throw 0;
            }
            const value = JSON.stringify({role:control.compositeRole, attributes, list_attributes:listAttributes, list_label:listLabel,
              list_disabled:disabled(list), list_hidden:hidden(list), input_value:inputValue,
              display_text:displayText, active_option:active(element), list_active_option:active(list), options});
            if (!small(value,8192)) throw 0;
            return {state:{controlID:control.id, kind:'composite', value}, references, members:seen, list, optionElements};
          } catch (_) { return {state:{controlID:control.id, kind:'unavailable'}, references:[], members:[]}; }
        }
    """#
}
