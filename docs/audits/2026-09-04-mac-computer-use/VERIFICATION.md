**Audit verification record**

Baseline: [minal7/remotedesktop](https://github.com/minal7/remotedesktop) main at **603e79e9f877a4a1c9a0b462d8db4da06dc46cf2**, pulled September 4, 2026.

Environment observed: Apple Silicon Mac; Xcode 26.6, build 17F113; Swift 6.3.3. All commands ran from the repository root. Application source was left unchanged.

**Existing Python suite**

~~~sh
python3 -m unittest discover -s host-mac/scripts/tests -p 'test_*.py'
~~~

Result: **102 tests ran; OK**. This suite tests harness/configuration contracts; it does not establish local-model or live GUI task success.

**Attempted Mac XCTest**

~~~sh
xcodebuild test \
  -project host-mac/RemoteDesktopHost.xcodeproj \
  -scheme RemoteDesktopHost \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/remotedesktop-audit-derived-data \
  -resultBundlePath /tmp/remotedesktop-audit-mac-tests.xcresult \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  -only-testing:RemoteDesktopHostTests/ComputerUseTests \
  -only-testing:RemoteDesktopHostTests/AppleFoundationMCPPlannerTests \
  -only-testing:RemoteDesktopHostTests/MCPFirstComputerUseExecutorTests \
  -only-testing:RemoteDesktopHostTests/OSAtlasComputerUseExecutorTests \
  -only-testing:RemoteDesktopHostTests/LocalComputerUseTransportTests \
  -only-testing:RemoteDesktopHostTests/SemanticCandidateSelectionV5Tests \
  -only-testing:RemoteDesktopHostTests/LlamaSemanticActionRouterTests \
  -quiet
~~~

Result: **exit 65; tests did not execute**. The build reported that no Mac App Development provisioning profile was found for com.threadmark.remotedesktop.host. It could not create one under the invoked signing configuration. No provisioning update, entitlement change, or signing bypass was attempted. This is a prerequisite/build-signing failure, not a model accuracy result or evidence of a source compiler failure.

**Isolated policy/input probe**

~~~sh
bash docs/audits/2026-09-04-mac-computer-use/run-policy-probe.sh
~~~

The script compiles actual ComputerUseRuntimeTypes, ComputerUseActionSafetyPolicy, InputInjector, HIDUsage, WireFormat, and HostConfig source. One unrelated video-negotiation constant is supplied locally to avoid importing WebRTC. Every CGEvent is intercepted and discarded; no input is posted to macOS and no desktop is captured.

Observed output:

~~~text
click [AXButton • Send] -> approval=true
click [AXButton • Enviar] -> approval=false
click [AXButton • Continue] -> approval=false
Return [AXTextField • Search and submit payment] -> approval=false
Discarded event sink: text apply returned=true, discardedEvents=10, deliveredEvents=0
These are component observations, not end-to-end authorization bypass claims.
~~~

Result: compiled and exited successfully. The effect-policy labels are synthetic examples. The probe demonstrates a policy classification boundary and that injection success is not delivery verification; it does not bypass the full task/target/approval pipeline.

**Acceptance inventory check**

~~~sh
python3 - <<'PY'
from pathlib import Path
import re
source = Path('host-mac/RemoteDesktopHostTests/OSAtlasComputerUseExecutorTests.swift').read_text()
suite = source.split('final class OSAtlasComputerUseExecutorTests: XCTestCase {', 1)[1]
suite = suite.split('final class OSAtlasLlamaRuntimeTests: XCTestCase {', 1)[0]
names = re.findall(r'^    func (test\w+)\s*\(', suite, re.M)
runner = Path('host-mac/scripts/run_osatlas_acceptance.sh').read_text()
selection = runner.split('xcodebuild test', 1)[1].split('/bin/bash "$VERIFY_XCRESULT"', 1)[0]
selectors = re.findall(r'-only-testing:([^\s\\]+)', selection)
expected = int(re.search(r'DETERMINISTIC_EXPECTED_TESTS=(\d+)', runner).group(1))
print('Executor methods:', len(names))
print('Additional method selectors:', len(selectors) - 1)
print('Selected source total:', len(names) + len(selectors) - 1)
print('Configured expected total:', expected)
PY
~~~

Observed: **154 executor methods + 13 extra selections = 167; configured expected total = 138**. There were no duplicate executor method names. This is static inventory evidence. Once a signed test target is available, compare actual XCTest discovery identifiers as part of the fix.

**Primary references checked**

Apple's Foundation Models availability and session context guidance support F18/F19. Apple's CGDisplayCreateImage documentation and the local SDK declaration support F11; the local declaration uses SCREEN_CAPTURE_OBSOLETE(10.6,14.4,15.0). Apple's NSEvent global-monitor documentation establishes asynchronous event delivery for F08. The OS-Atlas model card distinguishes Base grounding and Pro action-generation roles and shows dynamic preprocessing for F12/F21.

Links and exact source locations appear alongside their claims in [AUDIT.md](</Users/michael/Documents/ChatGPT/remote desktop/docs/audits/2026-09-04-mac-computer-use/AUDIT.md>). Model performance, end-to-end task accuracy, stop latency, and physical 8 GiB behavior were not measured.

Temporary full build logs and DerivedData are under /tmp and are not included as permanent evidence; they are not needed to understand the signing failure. The audit artifacts retain only the commands, minimal result summaries, and privacy-safe probe output.
