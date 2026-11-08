#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    /bin/echo "Usage: $0 HOST_TASK_ID 32-character-fixture-token" >&2
    exit 2
fi
task_id="$1"
token="$2"
if [[ ! "$task_id" =~ ^[A-Za-z0-9-]{1,80}$ || ! "$token" =~ ^[a-f0-9]{32}$ ]]; then
    /bin/echo "Invalid task ID or fixture token." >&2
    exit 2
fi
support="${REMOTE_DESKTOP_APPROVAL_VERIFY_SUPPORT_ROOT:-${HOME:?}/Library/Application Support}"
ledger="$support/Remote Desktop Host/Computer Use Tasks/processed-prompts.json"
episode="$support/RemoteDesktopHost/episodes/$task_id/episode.jsonl"
if [[ ! -f "$ledger" || ! -f "$episode" ]]; then
    /bin/echo "The task ledger or host episode is missing." >&2
    exit 1
fi
if ! /usr/bin/jq -e --arg taskID "$task_id" \
    '.[$taskID].promptClaimed == true and .[$taskID].executionStarted == true' \
    "$ledger" >/dev/null; then
    /bin/echo "The host task ID was not claimed and execution-started in the task ledger." >&2
    exit 1
fi
if ! /usr/bin/jq -e -n --arg taskID "$task_id" --arg token "$token" '
    [inputs
      | select(.episode_id == $taskID)
      | select(
          .type == "footer"
          or (
              .type == "step"
              and (
                  ((.observation.task // "") | contains($token))
                  or ((.observation.surface.url // "") | contains("__eval_run=" + $token))
              )
          )
      )
      | if .type == "step" then {type, episode_id, step, action, gate, execution}
        else {type, episode_id, outcome}
        end] as $records
    | [$records[] | select(.type == "step")] as $steps
    | any($records[]; .type == "footer") as $closed
    | any($steps[]; .gate.decision == "needs_approval" and .gate.fingerprint != null and .action != null) as $has_pending
    | any($steps[];
        . as $denied
        | select(.gate.decision == "rejected"
            and .gate.reason == "rejected: user declined"
            and .execution.status == "not_executed"
            and .gate.fingerprint != null
            and .action != null)
        | any($steps[];
            .step < $denied.step
            and .gate.decision == "needs_approval"
            and .gate.fingerprint == $denied.gate.fingerprint
        )
    ) as $has_matching_denial
    | all($steps[];
        . as $deniedCandidate
        | if $deniedCandidate.gate.decision != "rejected"
             or $deniedCandidate.gate.reason != "rejected: user declined"
             or $deniedCandidate.gate.fingerprint == null then true
          else all($steps[];
              .gate.fingerprint != $deniedCandidate.gate.fingerprint
              or .execution.status != "ok")
          end
    ) as $no_execution_of_denied_fingerprint
    | $closed and $has_pending and $has_matching_denial and $no_execution_of_denied_fingerprint
' "$episode" >/dev/null; then
    /bin/echo "Host episode did not prove that the token-bound pending action was denied, not executed, and closed." >&2
    exit 1
fi
/bin/echo "Verified task-ledger identity, same-episode approval fingerprint denial, no execution of that fingerprint, and a closed host episode."
