import Foundation

enum ComputerUseBrowserPopupError: Error, Equatable {
    case invalidIntent, unavailable, uncertain, retired, retirementPending, busy
}

/// Proposed purpose under the whole original task; never a URL or click point.
struct ComputerUseBrowserPopupIntent: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let interpretation: ComputerUseBrowserGoalProposal
    let evidence: ComputerUseBrowserPageEvidence
    let controlID: String
    let requirementIndex: Int
    let observedPreservedControlIDs: [String]
    let baselineDigest: String
    let scopeReview: ComputerUseBrowserEffectScopeReview?
    init(interpretation: ComputerUseBrowserGoalProposal, evidence: ComputerUseBrowserPageEvidence,
         controlID: String, requirementIndex: Int, scopeReview: ComputerUseBrowserEffectScopeReview? = nil) throws {
        guard interpretation.input.taskID == evidence.document.taskID, interpretation.disposition == .research,
              interpretation.requirements.indices.contains(requirementIndex),
              ComputerUseBrowserControlRead.accepts(interpretation.requirements[requirementIndex]),
              evidence.page.isWellFormed, evidence.page.controlStateObserved, evidence.page.scopedControlIDs.contains(controlID),
              let control = evidence.page.controls.first(where: { $0.id == controlID }),
              control.compositeRole == "combobox", ComputerUseBrowserControlRead.allows(control),
              ComputerUseBrowserObservedCriteria.hasAvailableScopedCriteria(in: evidence.page, excluding: controlID) else {
            throw ComputerUseBrowserPopupError.invalidIntent
        }
        let preserved = evidence.page.controlStates.filter {
            $0.controlID != controlID && $0.kind != .unavailable && $0.kind != .stateless
        }.map(\.controlID)
        observedPreservedControlIDs = preserved
        baselineDigest = try ComputerUseBrowserObservedCriteria.digest(controlIDs: [controlID] + preserved, page: evidence.page)
        guard scopeReview == nil || (scopeReview?.formScope == nil && scopeReview?.matches(interpretation: interpretation, evidence: evidence) == true) else { throw ComputerUseBrowserPopupError.invalidIntent }
        self.scopeReview = scopeReview
        self.interpretation = interpretation; self.evidence = evidence
        self.controlID = controlID; self.requirementIndex = requirementIndex
    }
    var description: String { "BrowserPopupIntent" }
    var debugDescription: String { description }
}

struct ComputerUseBrowserPopupBinding: Decodable, Equatable, Sendable {
    let id: String
    let controlID: String
    var isWellFormed: Bool {
        id.count == 32 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            && controlID.hasPrefix("c") && (2...32).contains(controlID.utf8.count)
            && controlID.dropFirst().utf8.allSatisfy { (48...57).contains($0) }
    }
}

/// One immutable historical opening observation, not a selected option or result.
struct ComputerUseBrowserPopupReceipt: Decodable, Equatable, Sendable {
    let operationID: String
    let bindingID: String
    let controlID: String
    let documentID: String
    let preservedControlIDs: [String]
    func validates(_ target: ComputerUseBrowserPopupTarget, operationID: String) -> Bool {
        self.operationID == operationID && bindingID == target.binding.id && controlID == target.binding.controlID
            && documentID == target.intent.evidence.documentID && preservedControlIDs == target.intent.observedPreservedControlIDs
    }
}

struct ComputerUseBrowserPopupTarget: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let intent: ComputerUseBrowserPopupIntent
    let binding: ComputerUseBrowserPopupBinding
    var payloadDigest: String {
        ComputerUseTaskContract.digest([intent.scopeReview == nil ? "browser-popup-opening-v2" : "browser-popup-opening-v3", intent.interpretation.input.digest,
            intent.evidence.document.contextID, intent.evidence.documentID, intent.evidence.page.id,
            binding.id, binding.controlID, String(intent.requirementIndex), intent.baselineDigest] + (intent.scopeReview.map { [$0.digest] } ?? []))
    }
    var description: String { "BrowserPopupTarget" }
    var debugDescription: String { description }
}

extension ComputerUseOwnedBrowser {
    /// Eligibility metadata only; this allocates no plan and reads no values.
    func popupControlIDs(in evidence: ComputerUseBrowserPageEvidence) async throws -> [String] {
        try requirePopupContext(evidence.document)
        let result = try await callDOM(.popupCandidates, arguments: ["documentID":evidence.documentID,
            "snapshotID":evidence.page.id], document: evidence.document)
        try requirePopupContext(evidence.document)
        guard result.status == "popup-candidates", result.documentID == evidence.documentID,
              let controls = result.popupControls, controls.count <= 64, Set(controls).count == controls.count,
              controls.allSatisfy({ id in evidence.page.controls.contains { $0.id == id && $0.compositeRole == "combobox"
                && !$0.disabled && ComputerUseBrowserControlRead.allows($0) } }) else { throw ComputerUseBrowserPopupError.unavailable }
        return controls
    }

    func preparePopup(_ intent: ComputerUseBrowserPopupIntent) async throws -> ComputerUseBrowserPopupTarget {
        try requirePopupContext(intent.evidence.document)
        let result = try await callDOM(.preparePopup, arguments: ["documentID":intent.evidence.documentID,
            "snapshotID":intent.evidence.page.id, "controlID":intent.controlID], document: intent.evidence.document)
        try requirePopupContext(intent.evidence.document)
        guard result.status == "popup-prepared", result.documentID == intent.evidence.documentID,
              let binding = result.popupBinding, binding.isWellFormed, binding.controlID == intent.controlID,
              result.popupReceipt == nil, result.popupPreservedControls == intent.observedPreservedControlIDs else { throw ComputerUseBrowserPopupError.unavailable }
        return .init(intent: intent, binding: binding)
    }

    func validatePopup(_ target: ComputerUseBrowserPopupTarget) async throws {
        try requirePopupContext(target.intent.evidence.document)
        let result = try await callDOM(.validatePopup, arguments: popupArguments(target), document: target.intent.evidence.document)
        try requirePopupContext(target.intent.evidence.document)
        guard result.status == "popup-current", result.documentID == target.intent.evidence.documentID else {
            throw ComputerUseBrowserPopupError.unavailable
        }
    }

    /// The journaled stage is the caller. A timeout/cancelled callback never
    /// authorizes another click; confirmation can only query the same ledger.
    func dispatchPopup(_ target: ComputerUseBrowserPopupTarget, operationID: String,
                       willBeginEffect: () throws -> Void) async throws {
        try requirePopupContext(target.intent.evidence.document)
        guard popupOperationID(operationID) else { throw ComputerUseBrowserPopupError.invalidIntent }
        var arguments = popupArguments(target); arguments["operationID"] = operationID
        try willBeginEffect()
        try requirePopupContext(target.intent.evidence.document)
        let result = try await callDOM(.openPopup, arguments: arguments, document: target.intent.evidence.document)
        try requirePopupContext(target.intent.evidence.document)
        guard result.documentID == target.intent.evidence.documentID, ["popup-dispatched", "popup-already-attempted"].contains(result.status) else {
            throw ComputerUseBrowserPopupError.uncertain
        }
    }

    func popupReceipt(_ target: ComputerUseBrowserPopupTarget, operationID: String) async throws -> ComputerUseBrowserPopupReceipt? {
        try requirePopupContext(target.intent.evidence.document)
        guard popupOperationID(operationID) else { throw ComputerUseBrowserPopupError.invalidIntent }
        var arguments = popupArguments(target); arguments["operationID"] = operationID
        let result = try await callDOM(.popupReceipt, arguments: arguments, document: target.intent.evidence.document)
        try requirePopupContext(target.intent.evidence.document)
        guard result.documentID == target.intent.evidence.documentID else { throw ComputerUseBrowserPopupError.uncertain }
        if result.status == "popup-pending", result.popupReceipt == nil { return nil }
        guard result.status == "popup-confirmed", let receipt = result.popupReceipt, receipt.validates(target, operationID: operationID) else {
            throw ComputerUseBrowserPopupError.uncertain
        }
        return receipt
    }

    func retireUnsentPopup(_ target: ComputerUseBrowserPopupTarget, operationID: String) async throws -> Bool {
        try requirePopupContext(target.intent.evidence.document)
        guard popupOperationID(operationID) else { throw ComputerUseBrowserPopupError.invalidIntent }
        var arguments = popupArguments(target); arguments["operationID"] = operationID
        let result = try await callDOM(.retireUnsentPopup, arguments: arguments, document: target.intent.evidence.document)
        try requirePopupContext(target.intent.evidence.document)
        guard result.documentID == target.intent.evidence.documentID else { throw ComputerUseBrowserPopupError.uncertain }
        if result.status == "popup-attempted" { return false }
        guard result.status == "popup-retired-unsent" else { throw ComputerUseBrowserPopupError.uncertain }
        return true
    }

    private func requirePopupContext(_ document: ComputerUseBrowserDocument) throws {
        try Task.checkCancellation()
        guard hasRequiredPresentation else { throw ComputerUseBrowserError.windowNotActive }
        try validateSourceDocument(document)
    }
    private func popupArguments(_ target: ComputerUseBrowserPopupTarget) -> [String: Any] {
        ["documentID":target.intent.evidence.documentID, "snapshotID":target.intent.evidence.page.id,
         "bindingID":target.binding.id, "controlID":target.binding.controlID]
    }
    private func popupOperationID(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

enum ComputerUseBrowserPopupScript {
    static let source = #"""
      const popupPlans = new Map(), popupOperations = new Map(), popupRetirements = new Map();
      const popupClick = HTMLElement.prototype.click;
      let popupPins = new WeakMap();
      function retirePopupRecords(records) {
        if (!popupPlans.size) return;
        if (records.length > 512) { for (const plan of popupPlans.values()) plan.invalid = true; return; }
        for (const record of records) if (record.type === 'childList') for (const removed of record.removedNodes) {
          for (const plan of popupPins.get(removed) || []) plan.invalid = true;
        }
      }
      let popupUserInputSerial = 0;
      for (const name of ['pointerdown','mousedown','keydown','input','wheel','touchstart','click']) {
        doc.addEventListener(name,event => { if (event.isTrusted) popupUserInputSerial++; },true);
      }
      function popupRendered(element) {
        if (!rendered(element)) return false;
        for (let node = element, depth = 0; node && depth < 128; node = node.assignedSlot || parent(node), depth++) {
          if (node.inert || node.getAttribute('aria-hidden') === 'true') return false;
          if (node === root) return true;
        }
        return false;
      }
      function popupList(element, targetID) {
        const tree = element.getRootNode(), walker = doc.createTreeWalker(tree,NodeFilter.SHOW_ELEMENT);
        let node, found = null, count = 0;
        while ((node = walker.nextNode())) {
          if (++count > 10000) return undefined;
          if (node.id === targetID) { if (found) return undefined; found = node; }
        }
        return found;
      }
      function popupOwnerIdentity(element) {
        const label = labelFor(element), keys = ['role','type','form','name','autocomplete','readonly','disabled',
          'aria-label','aria-labelledby','aria-describedby','aria-controls','aria-owns','aria-haspopup','aria-disabled','aria-readonly'];
        const values = keys.map(key => element.getAttribute(key));
        if (encoder.encode(label.label).length > 256 || values.some(value => value && encoder.encode(value).length > 512)) return null;
        const references = [...label.labels];
        for (let node = element, depth = 0; node && depth < 128; node = node.assignedSlot || parent(node), depth++) {
          references.push(node);
          if (node === root) return {signature:JSON.stringify([label.label,values]),references};
        }
        return null;
      }
      function samePopupOwner(first, second) {
        return !!first && !!second && first.signature === second.signature && first.references.length === second.references.length
          && first.references.every((node,index) => node === second.references[index]);
      }
      function popupOpening(element, control) {
        if (!(element instanceof HTMLElement) || control.compositeRole !== 'combobox' || !researchScopeAllowed(element,control)
            || !popupRendered(element) || element.isContentEditable || element.getAttribute('role') !== 'combobox'
            || element.getAttribute('aria-expanded') !== 'false' || element.matches(':disabled')
            || element.getAttribute('aria-disabled') === 'true') return null;
        if (element instanceof HTMLInputElement && !['text','search'].includes(element.type)) return null;
        if (element instanceof HTMLButtonElement && element.type !== 'button') return null;
        if (element.hasAttribute('aria-haspopup') && element.getAttribute('aria-haspopup') !== 'listbox') return null;
        for (let node = element, depth = 0; node && depth < 128; node = node.assignedSlot || parent(node), depth++) {
          if (node.matches('a[href],area[href]') || node instanceof HTMLButtonElement && node.type !== 'button'
              || node instanceof HTMLInputElement && ['submit','image','reset'].includes(node.type)
              || node.hasAttribute('aria-disabled') && node.getAttribute('aria-disabled') !== 'false'
              || ['popovertarget','commandfor','command'].some(key => node.hasAttribute(key))) return null;
          if (node === root) break;
        }
        if (!(element instanceof HTMLInputElement) && element.querySelector('input,textarea,select,[contenteditable]:not([contenteditable="false"])')) return null;
        const key = element.hasAttribute('aria-controls') ? 'aria-controls' : 'aria-owns', targetID = element.getAttribute(key);
        if (!targetID || !/^[^\s]+$/.test(targetID) || encoder.encode(targetID).length > 256) return null;
        if (element.hasAttribute('aria-controls') && element.hasAttribute('aria-owns') && element.getAttribute('aria-owns') !== targetID) return null;
        const list = popupList(element,targetID);
        if (list === undefined || list === element || list && (list.getAttribute('role') !== 'listbox' || popupRendered(list))) return null;
        if (list && researchValueProtected(list,{label:labelFor(list).label,name:list.getAttribute('name') || ''})) return null;
        const owner = popupOwnerIdentity(element);
        return owner ? {key,targetID,list,owner} : null;
      }
      function popupOwnerCriteria(binding) {
        if (binding.state?.kind !== 'composite') return binding.element instanceof HTMLInputElement ? undefined : null;
        const graph = JSON.parse(binding.state.value);
        // Opening may change visibility and focus, never an existing selection
        // or native input value. Custom button display text is presentation.
        for (const key of ['active_option','list_active_option','list_hidden','display_text']) delete graph[key];
        for (const key of ['aria-expanded','aria-busy']) { delete graph.attributes[key]; delete graph.list_attributes[key]; }
        for (const option of graph.options) {
          delete option.hidden;
          for (const group of option.groups) delete group.hidden;
        }
        return JSON.stringify(graph);
      }
      function popupCandidate(controlID,controls) {
        const binding = controls.get(controlID), opening = binding && popupOpening(binding.element,binding.metadata);
        if (!opening || !lastPageSnapshot.includeControlState || !lastPageSnapshot.scopedControlIDs.includes(controlID)) return null;
        const references = observedControlReferences(binding), ownerCriteria = popupOwnerCriteria(binding);
        if (!references || ownerCriteria === undefined || opening.list && ownerCriteria === null) return null;
        const required = new Set(references), preserved = [];
        for (const [id,other] of controls) {
          if (id === controlID) continue;
          if (lastPageSnapshot.scopedControlIDs.includes(id) && (!other.state || ['unavailable','stateless'].includes(other.state.kind))) return null;
          if (!other.state || ['unavailable','stateless'].includes(other.state.kind)) continue;
          const record = observedControlRecord(id,other);
          if (!record) return null;
          preserved.push(record);
          for (const node of record.references) { required.add(node); if (required.size > 4096) return null; }
        }
        return {binding,...opening,references,required,preserved,ownerCriteria,metadata:observedControlMetadata(binding)};
      }
      function preparedPopup(args, controls) {
        const plan = popupPlans.get(args.bindingID), current = popupCandidate(args.controlID,controls);
        if (!plan || plan.invalid || plan.retired || plan.attemptID || !current || plan.element !== current.binding.element
            || plan.form !== (current.binding.element.form || null) || plan.metadata !== current.metadata || plan.ownerCriteria !== current.ownerCriteria
            || plan.controlID !== args.controlID || plan.snapshotID !== args.snapshotID || plan.url !== doc.URL
            || plan.references.length !== current.references.length || plan.references.some((node,index) => node !== current.references[index])
            || plan.preserved.length !== current.preserved.length
            || plan.preserved.some((expected,index) => expected.id !== current.preserved[index].id || !observedControlMatches(expected,current.preserved[index].binding))) return null;
        return current.key === plan.key && current.targetID === plan.targetID && current.list === plan.list
          && samePopupOwner(current.owner,plan.owner) ? plan : null;
      }
      function popupHistorical(args) {
        if (args.documentID !== documentID || typeof args.operationID !== 'string' || !/^[a-f0-9]{64}$/.test(args.operationID)) return reply('stale');
        const plan = popupPlans.get(args.bindingID), operation = popupOperations.get(args.operationID);
        if (!plan || plan.controlID !== args.controlID || plan.snapshotID !== args.snapshotID || plan.url !== doc.URL
            || !operation || operation.plan !== plan || plan.attemptID !== args.operationID) return reply('popup-uncertain');
        if (operation.receipt) return {...reply('popup-confirmed'),popupReceipt:operation.receipt};
        if (!operation.dispatched || operation.failed || plan.invalid || popupUserInputSerial !== operation.userInputSerial
            || performance.now() > operation.deadline || !plan.element.isConnected || plan.element.ownerDocument !== doc || plan.form !== (plan.element.form || null)
            || !samePopupOwner(plan.owner,popupOwnerIdentity(plan.element))) { operation.failed = true; return reply('popup-uncertain'); }
        const status = authenticationStatus();
        if (status) return reply(status);
        const controls = new Map();
        pageContent(new Map(),controls,new Map(),true,plan.scopedControlIDs);
        const current = controls.get(plan.controlID);
        const invalid = () => { operation.failed = true; return reply('popup-uncertain'); };
        if (!current || current.element !== plan.element || observedControlMetadata(current) !== plan.metadata
            || plan.ownerCriteria !== null && popupOwnerCriteria(current) !== plan.ownerCriteria
            || plan.preserved.some(expected => !observedControlMatches(expected,controls.get(expected.id)))) return invalid();
        const list = popupList(plan.element,plan.targetID);
        if (list === undefined || list && list.getAttribute('role') !== 'listbox') return invalid();
        if (list && researchValueProtected(list,{label:labelFor(list).label,name:list.getAttribute('name') || ''})) return invalid();
        if (plan.element.getAttribute('aria-expanded') !== 'true' || !popupRendered(plan.element) || !list || !popupRendered(list)) return reply('popup-pending');
        // A prepared existing popup cannot be swapped by the opening handler.
        // A lazy popup is captured only after it exists and is visibly linked.
        if (plan.list && plan.list !== list) return invalid();
        operation.receipt = {operationID:args.operationID,bindingID:plan.id,controlID:plan.controlID,documentID,
          preservedControlIDs:plan.preserved.map(item => item.id)};
        operation.list = list;
        return {...reply('popup-confirmed'),popupReceipt:operation.receipt};
      }
    """#
}
