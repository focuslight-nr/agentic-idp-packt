#!/usr/bin/env bash
# Smoke-tests one attendee's LiteLLM virtual key end to end, without the cluster:
# key -> gateway -> model alias -> provider, and proves the model can do a tool call.
#
# Run it as the last step of labs/00-setup/local/bootstrap.sh, while the
# in-cluster LiteLLM port-forward (localhost:4000) is still up. It proves the
# environment is usable, not assumed: if this passes, Hermes can authenticate
# and the model honors tool calls.
#
# Usage: smoke-hermes.sh <attendee-key> [litellm-url]
set -euo pipefail

KEY="${1:?usage: smoke-hermes.sh <attendee-key> [litellm-url]}"
LITELLM_URL="${2:-${LITELLM_ADMIN_URL:-http://localhost:4000}}"
MODEL="${LITELLM_SMOKE_MODEL:-triage}"

response="$(
  curl -fsS -m 60 "$LITELLM_URL/v1/chat/completions" \
    -H "Authorization: Bearer $KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg model "$MODEL" \
      '{
        model: $model,
        tool_choice: {type: "function", function: {name: "report_status"}},
        tools: [{
          type: "function",
          function: {
            name: "report_status",
            description: "Record the smoke-test result.",
            parameters: {
              type: "object",
              properties: {ok: {type: "boolean"}},
              required: ["ok"]
            }
          }
        }],
        messages: [{role: "user", content: "Run the report_status tool with ok set to true."}]
      }')"
)"

if ! tool_name="$(echo "$response" | jq -r '.choices[0].message.tool_calls[0].function.name // empty' 2>/dev/null)"; then
  echo "smoke-hermes: FAIL - could not parse the LiteLLM response:" >&2
  echo "$response" >&2
  exit 1
fi

if [[ "$tool_name" != "report_status" ]]; then
  echo "smoke-hermes: FAIL - model did not invoke the tool (expected report_status)." >&2
  echo "response: $response" >&2
  exit 1
fi

echo "smoke-hermes: PASS - $MODEL authenticated through the gateway and invoked the tool."
