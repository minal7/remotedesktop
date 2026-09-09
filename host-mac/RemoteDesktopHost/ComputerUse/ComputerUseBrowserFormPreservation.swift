import Foundation

/// A private native predicate, not an editable field or a model-facing reading.
/// Parent integration must bind this fingerprint into its durable contract.
struct ComputerUseBrowserFormPreservation: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    struct Reply: Decodable {
        let id: String
        let scopeDigest: String
        let controlIDs: [String]
        let states: [ComputerUseBrowserControlState]
    }
    let id: String
    let scopeDigest: String
    let controlIDs: [String]
    let document: ComputerUseBrowserDocument
    let documentID: String
    let inputLedgerID: String
    let digest: String

    init(reply: Reply, evidence: ComputerUseBrowserPageEvidence, inputLedgerID: String,
         scopeDigest: String, controlIDs: [String]) throws {
        guard reply.id.utf8.count == 32, reply.id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              scopeDigest.utf8.count == 64, scopeDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              inputLedgerID.utf8.count == 32, inputLedgerID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              reply.scopeDigest == scopeDigest, reply.controlIDs == controlIDs,
              (1...16).contains(controlIDs.count), Set(controlIDs).count == controlIDs.count,
              reply.states.map(\.controlID) == controlIDs else { throw ComputerUseBrowserError.pageChanged }
        for state in reply.states {
            guard let control = evidence.page.controls.first(where: { $0.id == state.controlID }), Self.allows(control),
                  state.isValid(for: control), ![.unavailable, .stateless, .composite].contains(state.kind) else {
                throw ComputerUseBrowserError.pageChanged
            }
        }
        let baseline = try ComputerUseBrowserObservedCriteria.digest(controlIDs: controlIDs,
            controls: evidence.page.controls, states: reply.states)
        id = reply.id; self.scopeDigest = scopeDigest; self.controlIDs = controlIDs
        document = evidence.document; documentID = evidence.documentID; self.inputLedgerID = inputLedgerID
        digest = ComputerUseTaskContract.digest(["browser-form-preservation-v1",document.contextID,documentID,
            inputLedgerID,scopeDigest,id,baseline])
    }

    static func allows(_ control: ComputerUseBrowserPageSnapshot.Control) -> Bool {
        guard control.compositeRole == nil, ComputerUseBrowserControlRead.allows(control) else { return false }
        return control.disabled || control.readOnly || control.multiple || ["checkbox","radio"].contains(control.kind)
            || ComputerUseBrowserDeclaredState.kinds.contains(control.kind)
    }
    var description: String { "BrowserFormPreservation(controls: \(controlIDs.count))" }
    var debugDescription: String { description }

    static let script = #"""
      const formPreservationPlans = new Map();
      let formPreservationPins = new WeakMap();
      const preservationAttributes = new Set([...identityAttributes,...scalarConstraintAttributes,
        'role','required','checked','selected','label','for','slot','aria-disabled','aria-readonly','aria-required',
        'aria-describedby','aria-controls','aria-owns','aria-details','aria-haspopup','aria-expanded',
        'aria-orientation','aria-roledescription','aria-invalid','aria-busy',
        'aria-checked','aria-pressed','aria-valuenow','aria-valuemin','aria-valuemax','aria-valuetext']);
      const formPreservationObserver = new MutationObserver(retireFormPreservationRecords);
      function retireFormPreservationRecords(records) {
        if (!formPreservationPlans.size) return;
        if (records.length > 512) { for (const plan of formPreservationPlans.values()) plan.invalid = true; return; }
        for (const record of records) {
          if (record.type === 'childList') for (const removed of record.removedNodes) {
            for (const plan of formPreservationPins.get(removed) || []) plan.invalid = true;
          }
          for (const plan of formPreservationPlans.values()) {
            if (record.type === 'attributes' && preservationAttributes.has(record.attributeName)
                && plan.records.some(item => record.target === item.binding.element || record.target === item.form
                  || item.binding.references.includes(record.target) || labelFor(item.binding.element).labels.includes(record.target))) plan.invalid = true;
            if (['characterData','childList'].includes(record.type) && plan.records.some(item =>
                [item.binding.element,...item.binding.references,...labelFor(item.binding.element).labels]
                  .some(node => contains(node,record.target)))) plan.invalid = true;
          }
        }
      }
      function preservationBinding(binding) {
        if (!binding) return null;
        const references = [...binding.references];
        if (binding.element instanceof HTMLSelectElement) for (const option of binding.element.options) {
          references.push(option); if (option.parentElement instanceof HTMLOptGroupElement) references.push(option.parentElement);
        }
        return {...binding,references:Array.from(new Set(references))};
      }
      function fieldPreservationCurrent(expectedID, allowEarlierScope = false) {
        const id = fieldScope?.preservationID;
        if (!id) return expectedID === undefined || expectedID === null;
        const plan = formPreservationPlans.get(id);
        retireFormPreservationRecords(formPreservationObserver.takeRecords());
        // Earlier form requirements remain meaningful after additive
        // preservation. All original records survive in the stronger plan;
        // preflight and input still require its exact active identity.
        if (!plan || plan.invalid || (expectedID !== undefined && expectedID !== id
              && !(allowEarlierScope && (expectedID === null || plan.earlierIDs.includes(expectedID))))
            || plan.inputLedgerID !== inputLedgerID || plan.form !== fieldScope.form
            || !plan.form.isConnected || plan.form.ownerDocument !== doc) return false;
        if (authenticationStatus()) return false;
        const metadata = new Map(); pageContent(new Map(),metadata,new Map());
        if (plan.records.some(item => {
          const current = preservationBinding(metadata.get(item.id));
          return !current || current.element !== item.binding.element || current.signature !== item.binding.signature
            || observedControlMetadata(current) !== item.metadata;
        })) { plan.invalid = true; return false; }
        const current = new Map(); pageContent(new Map(),current,new Map(),true,plan.controlIDs);
        if (plan.records.some(item => !preservationControlMatches(item,preservationBinding(current.get(item.id))))) {
          plan.invalid = true; return false;
        }
        return true;
      }
      function preservationControlMatches(record,binding) {
        return !!binding && binding.signature === record.binding.signature && observedControlMatches(record,binding);
      }
      function prepareFieldPreservation(args, controls) {
        if (!fieldScope || args.inputLedgerID !== inputLedgerID || pendingChanges.size
            || Array.from(operations.values()).some(status => status !== 'dispatched')) return reply('stale');
        if (typeof args.scopeDigest !== 'string' || !/^[a-f0-9]{64}$/.test(args.scopeDigest)
            || !Array.isArray(args.controlIDs) || args.controlIDs.length < 1 || args.controlIDs.length > 16
            || new Set(args.controlIDs).size !== args.controlIDs.length) return reply('unsupported');
        const previous = fieldScope.preservationID ? formPreservationPlans.get(fieldScope.preservationID) : null;
        if (!fieldPreservationCurrent() || previous?.controlIDs.some(id => !args.controlIDs.includes(id))) return reply('constraint-changed');
        const repeated = Array.from(formPreservationPlans.values()).find(plan => plan.scopeDigest === args.scopeDigest);
        if (repeated) {
          if (repeated !== previous || JSON.stringify(repeated.controlIDs) !== JSON.stringify(args.controlIDs)) return reply('stale');
          return preservationReply(repeated);
        }
        if (formPreservationPlans.size >= 32) return reply('limit');
        for (const id of args.controlIDs) {
          const binding = controls.get(id);
          if (typeof id !== 'string' || !binding || editable(binding.element) || binding.metadata.compositeRole
              || !researchScopeAllowed(binding.element,binding.metadata)) return reply('unsupported');
        }
        const current = new Map(); pageContent(new Map(),current,new Map(),true,args.controlIDs);
        const records = [];
        for (const id of args.controlIDs) {
          const binding = preservationBinding(current.get(id));
          if (!binding || !binding.state || !['text','scalar','selection','checked','declared'].includes(binding.state.kind)
              || observedControlMetadata(binding) !== observedControlMetadata(controls.get(id))) return reply('unsupported');
          const prior = previous?.records.find(item => item.id === id);
          if (prior && !preservationControlMatches(prior,binding)) { previous.invalid = true; return reply('constraint-changed'); }
          const record = prior || observedControlRecord(id,binding);
          if (!record) return reply('limit');
          records.push(record);
        }
        const plan = {id:nonce(),scopeDigest:args.scopeDigest,controlIDs:[...args.controlIDs],records,
          form:fieldScope.form,inputLedgerID,invalid:false,earlierIDs:previous ? [...previous.earlierIDs,previous.id] : []};
        const references = new Set(records.flatMap(item => item.references));
        if (references.size > 4096) return reply('limit');
        for (const node of references) {
          const plans = formPreservationPins.get(node) || new Set(); plans.add(plan); formPreservationPins.set(node,plans);
          const tree = node.getRootNode();
          if (tree instanceof ShadowRoot) formPreservationObserver.observe(tree,{subtree:true,childList:true,attributes:true,characterData:true});
        }
        formPreservationObserver.observe(doc,{subtree:true,childList:true,attributes:true,characterData:true});
        formPreservationPlans.set(plan.id,plan); fieldScope.preservationID = plan.id; formQueries.clear();
        return preservationReply(plan);
      }
      function preservationReply(plan) {
        return {...reply('form-preservation-prepared'),formPreservation:{id:plan.id,scopeDigest:plan.scopeDigest,
          controlIDs:plan.controlIDs,states:plan.records.map(item => JSON.parse(item.state))}};
      }
    """#
}
