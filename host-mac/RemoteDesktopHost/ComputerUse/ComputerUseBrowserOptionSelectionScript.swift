import Foundation

/// Fixed code beside the popup dispatcher. No page/model-authored script is
/// accepted. Choice graphs come only from an existing scoped page snapshot.
enum ComputerUseBrowserOptionSelectionScript {
    static let source = #"""
      const selectionPlans = new Map(), selectionOperations = new Map(), selectionRetirements = new Map();
      let selectionPins = new WeakMap();
      function retireSelectionRecords(records) {
        if (!selectionPlans.size) return;
        if (records.length > 512) { for (const plan of selectionPlans.values()) plan.invalid = true; return; }
        for (const record of records) if (record.type === 'childList') for (const removed of record.removedNodes) {
          for (const plan of selectionPins.get(removed) || []) plan.invalid = true;
        }
      }
      function selectionMetadata(binding) {
        const metadata = {...binding.metadata}; delete metadata.containerID;
        return JSON.stringify(metadata);
      }
      function selectionIdentity(graph) {
        const fixed = JSON.parse(JSON.stringify(graph));
        for (const key of ['input_value','display_text','active_option','list_active_option','list_hidden']) delete fixed[key];
        for (const key of ['aria-expanded','aria-busy']) { delete fixed.attributes[key]; delete fixed.list_attributes[key]; }
        for (const option of fixed.options) {
          for (const key of ['selected','checked','hidden']) delete option[key];
          for (const group of option.groups) delete group.hidden;
        }
        return JSON.stringify(fixed);
      }
      function selectionGraph(binding) {
        if (!binding?.composite || binding.state?.kind !== 'composite') return null;
        const graph = JSON.parse(binding.state.value), options = graph.options;
        if (!options.length || graph.attributes['aria-multiselectable'] === 'true' || graph.list_attributes['aria-multiselectable'] === 'true') return null;
        let mode;
        if (options.every(option => ['true','false'].includes(option.selected) && option.checked === null)) mode = 'selected';
        else if (options.every(option => ['true','false'].includes(option.checked) && option.selected === null)) mode = 'checked';
        else return null;
        const selected = options.filter(option => option[mode] === 'true');
        if (selected.length > 1) return null;
        return {graph,mode,selectedID:selected[0]?.id || null,identity:selectionIdentity(graph)};
      }
      function selectionReady(state) {
        return !state.graph.list_disabled && [state.graph.attributes,state.graph.list_attributes].every(attributes =>
          ['aria-readonly','aria-disabled','aria-busy'].every(key => attributes[key] !== 'true'));
      }
      function selectionClickable(element) {
        if (!(element instanceof HTMLElement) || !popupRendered(element) || element.isContentEditable) return false;
        for (let node = element, depth = 0; node && depth < 128; node = node.assignedSlot || parent(node), depth++) {
          if (node.matches('a[href],area[href],label,input,textarea,select')
              || node instanceof HTMLButtonElement && node.type !== 'button'
              || node.matches(':disabled') || node.hasAttribute('aria-disabled') && node.getAttribute('aria-disabled') !== 'false'
              || ['popovertarget','commandfor','command'].some(key => node.hasAttribute(key))) return false;
          if (node === root) return true;
        }
        return false;
      }
      function selectionReferences(binding) {
        const references = new Set();
        const starts = [binding.element,...binding.references,...labelFor(binding.element).labels];
        if (binding.element.form) starts.push(binding.element.form);
        for (const start of starts) {
          let reached = false;
          for (let node = start, depth = 0; node && depth < 128; node = node.assignedSlot || parent(node), depth++) {
            references.add(node);
            if (references.size > 4096) return null;
            if (node === root) { reached = true; break; }
          }
          if (!reached) return null;
        }
        return Array.from(references);
      }
      function selectionCandidate(args, controls) {
        const binding = controls.get(args.controlID), state = selectionGraph(binding);
        if (!state || binding.metadata.disabled || binding.metadata.readOnly || !selectionReady(state)
            || state.graph.list_hidden || !lastPageSnapshot.scopedControlIDs.includes(args.controlID)
            || state.graph.role === 'combobox' && state.graph.attributes['aria-expanded'] !== 'true') return null;
        const index = state.graph.options.findIndex(option => option.id === args.optionID), composite = binding.composite;
        if (index < 0 || state.graph.options[index].disabled || state.graph.options[index].hidden) return null;
        const option = composite.optionElements[index];
        if (!option || !selectionClickable(option)) return null;
        const preserved = [], references = selectionReferences(binding);
        if (!references) return null;
        const required = new Set(references);
        for (const [id, other] of controls) {
          if (id === args.controlID) continue;
          // Shared or unobserved combobox ownership cannot be guessed from
          // the selected list alone. Choose its one observed owning control.
          if (other.metadata.compositeRole === 'combobox') {
            const key = other.element.hasAttribute('aria-controls') ? 'aria-controls' : 'aria-owns';
            if (popupList(other.element,other.element.getAttribute(key)) === composite.list) return null;
          }
          if (other.composite?.list === composite.list) {
            if (other.metadata.compositeRole !== 'listbox' || state.graph.role !== 'combobox') return null;
            continue;
          }
          if (!other.state || ['unavailable','stateless'].includes(other.state.kind)) continue;
          const refs = selectionReferences(other);
          if (!refs) return null;
          for (const node of refs) { required.add(node); if (required.size > 4096) return null; }
          preserved.push({id,binding:other,metadata:selectionMetadata(other),state:JSON.stringify(other.state),references:refs,form:other.element.form || null});
        }
        return {binding,state,option,list:composite.list,preserved,references,required,
          owner:popupOwnerIdentity(binding.element),form:binding.element.form || null};
      }
      function selectionPlanMatches(args, plan) {
        return plan && plan.controlID === args.controlID && plan.optionID === args.optionID && plan.snapshotID === args.snapshotID && plan.url === doc.URL;
      }
      function selectionPreflight(args, controls) {
        const plan = selectionPlans.get(args.bindingID);
        if (!selectionPlanMatches(args,plan) || plan.invalid || plan.retired || plan.attemptID) return null;
        const candidate = selectionCandidate(args,controls);
        if (!candidate || candidate.binding.element !== plan.element || candidate.option !== plan.option || candidate.list !== plan.list
            || candidate.form !== plan.form || !samePopupOwner(candidate.owner,plan.owner)
            || selectionMetadata(candidate.binding) !== plan.metadata || candidate.references.length !== plan.references.length
            || candidate.references.some((node,index) => node !== plan.references[index])
            || candidate.state.mode !== plan.mode || candidate.state.identity !== plan.identity
            || candidate.state.selectedID !== plan.selectedID || candidate.preserved.length !== plan.preserved.length
            || candidate.preserved.some((current,index) => {
              const expected = plan.preserved[index];
              return current.id !== expected.id || current.binding.element !== expected.binding.element || current.form !== expected.form
                || current.metadata !== expected.metadata || current.state !== expected.state || current.references.length !== expected.references.length
                || current.references.some((node,index) => node !== expected.references[index]);
            })) return null;
        return plan;
      }
      function selectionHistorical(args) {
        if (args.documentID !== documentID || typeof args.operationID !== 'string' || !/^[a-f0-9]{64}$/.test(args.operationID)) return reply('stale');
        const plan = selectionPlans.get(args.bindingID), operation = selectionOperations.get(args.operationID);
        if (!selectionPlanMatches(args,plan) || !operation || operation.plan !== plan || plan.attemptID !== args.operationID) return reply('selection-uncertain');
        if (operation.receipt) return {...reply('selection-confirmed'),optionSelectionReceipt:operation.receipt};
        const authentication = authenticationStatus();
        if (authentication) return reply(authentication);
        if (operation.failed || plan.invalid || performance.now() > operation.deadline || popupUserInputSerial !== operation.userInputSerial) return reply('selection-uncertain');
        const controls = new Map();
        pageContent(new Map(),controls,new Map(),true,plan.scopedControlIDs);
        const binding = controls.get(plan.controlID), state = selectionGraph(binding);
        const references = binding && selectionReferences(binding);
        const invalid = () => { operation.failed = true; return reply('selection-uncertain'); };
        if (!state || binding.element !== plan.element || (binding.element.form || null) !== plan.form
            || selectionMetadata(binding) !== plan.metadata || !samePopupOwner(plan.owner,popupOwnerIdentity(binding.element))
            || binding.composite.list !== plan.list || state.mode !== plan.mode || state.identity !== plan.identity
            || !references || references.length !== plan.references.length || references.some((node,index) => node !== plan.references[index])
            || binding.composite.optionElements.length !== plan.optionElements.length
            || binding.composite.optionElements.some((node,index) => node !== plan.optionElements[index])) return invalid();
        for (const expected of plan.preserved) {
          const current = controls.get(expected.id), refs = current && selectionReferences(current);
          if (!current || current.element !== expected.binding.element || (current.element.form || null) !== expected.form
              || selectionMetadata(current) !== expected.metadata || JSON.stringify(current.state) !== expected.state
              || !refs || refs.length !== expected.references.length || refs.some((node,index) => node !== expected.references[index])) return invalid();
        }
        if (!selectionReady(state) || state.selectedID !== plan.optionID) return reply('selection-pending');
        operation.receipt = {operationID:args.operationID,bindingID:plan.id,controlID:plan.controlID,optionID:plan.optionID,documentID,
          didDispatch:operation.didDispatch,afterValue:binding.state.value,preservedControlIDs:plan.preserved.map(item => item.id)};
        return {...reply('selection-confirmed'),optionSelectionReceipt:operation.receipt};
      }
      function selectionHistoricalCommand(command,args) {
        if (command === 'optionSelectionReceipt') return selectionHistorical(args);
        if (!['selectOption','retireUnsentOptionSelection'].includes(command)) return null;
        if (args.documentID !== documentID || typeof args.operationID !== 'string' || !/^[a-f0-9]{64}$/.test(args.operationID)) return reply('stale');
        const plan = selectionPlans.get(args.bindingID), previous = selectionOperations.get(args.operationID);
        if (command === 'retireUnsentOptionSelection') {
          if (!selectionPlanMatches(args,plan)) return reply('stale');
          if (plan.attemptID || previous) return reply('selection-attempted');
          if (plan.retired && plan.retired !== args.operationID || selectionRetirements.has(args.operationID) && selectionRetirements.get(args.operationID) !== plan) return reply('stale');
          plan.retired = args.operationID; selectionRetirements.set(args.operationID,plan);
          return reply('selection-retired-unsent');
        }
        if (selectionRetirements.has(args.operationID) || plan?.retired) return reply('selection-retired');
        if (previous) return reply(previous.plan === plan && selectionPlanMatches(args,plan) ? 'selection-already-attempted' : 'selection-uncertain');
        return null;
      }
      function selectionCurrentCommand(command,args,controls) {
        if (!['prepareOptionSelection','validateOptionSelection','selectOption'].includes(command)) return null;
        if (command === 'prepareOptionSelection') {
          const candidate = selectionCandidate(args,controls);
          if (!candidate || !candidate.owner) return reply('selection-unavailable');
          let plan = Array.from(selectionPlans.values()).find(plan => selectionPlanMatches(args,plan) && !plan.invalid && !plan.retired && !plan.attemptID
            && plan.element === candidate.binding.element && plan.option === candidate.option && plan.list === candidate.list);
          if (!plan) {
            if (selectionPlans.size >= 32) return reply('limit');
            plan = {id:nonce(),controlID:args.controlID,optionID:args.optionID,snapshotID:args.snapshotID,url:doc.URL,
              element:candidate.binding.element,option:candidate.option,list:candidate.list,form:candidate.form,owner:candidate.owner,
              metadata:selectionMetadata(candidate.binding),mode:candidate.state.mode,identity:candidate.state.identity,selectedID:candidate.state.selectedID,
              optionElements:candidate.binding.composite.optionElements,preserved:candidate.preserved,
              references:candidate.references,
              scopedControlIDs:[...lastPageSnapshot.scopedControlIDs],needsDispatch:candidate.state.selectedID !== args.optionID};
            selectionPlans.set(plan.id,plan);
            for (const node of candidate.required) {
              if (!selectionPins.has(node)) selectionPins.set(node,new Set());
              selectionPins.get(node).add(plan);
            }
          }
          return {...reply('selection-prepared'),optionSelectionBinding:{id:plan.id,controlID:plan.controlID,optionID:plan.optionID,needsDispatch:plan.needsDispatch},
            selectionPreservedControls:plan.preserved.map(item => item.id)};
        }
        const plan = selectionPreflight(args,controls);
        if (!plan) return reply('selection-unavailable');
        if (command === 'validateOptionSelection') return reply('selection-current');
        if (selectionOperations.size >= 32) return reply('limit');
        const operation = {plan,didDispatch:plan.needsDispatch,userInputSerial:popupUserInputSerial,deadline:performance.now() + 2000};
        plan.attemptID = args.operationID; selectionOperations.set(args.operationID,operation);
        lastPageSnapshot = null; formQueries.clear();
        try {
          if (operation.didDispatch) popupClick.call(plan.option);
          synchronize(); // Drain removals even if the same nodes were reinserted.
          selectionHistorical(args);
          return reply('selection-dispatched');
        } catch (_) { operation.failed = true; return reply('selection-uncertain'); }
      }
    """#
}
