#!/usr/bin/env bash
# This script was written by claude
# Tests a running server built from dist/docker-compose.yml.
# Usage: ./test.sh [base-url]        e.g. ./test.sh http://1.2.3.4:8080
#   Key and model are read from dist/docker-compose.yml; override with LLAMA_API_KEY / MODEL_ALIAS.
set -Euo pipefail
cd "$(dirname "$0")"

BASE="${1:-http://localhost:8080}"
BASE="${BASE%/}"
[[ $BASE == http*://* ]] || BASE="http://$BASE"
compose=dist/docker-compose.yml
# Value of a flag in the compose command list (the item after "- --<flag>").
from_compose() { [[ -f $compose ]] && grep -A1 -- "^ *- --$1\b" "$compose" | sed -n '2s/^ *- "\{0,1\}\([^" ]*\)"\{0,1\}.*/\1/p'; }
KEY="${LLAMA_API_KEY:-$(from_compose api-key)}"
MODEL="${MODEL_ALIAS:-$(from_compose alias)}"
[[ -n "$KEY" && -n "$MODEL" ]] || { echo "No key/model: run ./setup.sh or set LLAMA_API_KEY and MODEL_ALIAS" >&2; exit 1; }

failed=0
pass() { printf '\033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[31mFAIL\033[0m %s\n' "$*"; failed=$((failed + 1)); }

# POST to /v1/chat/completions, print the response body.
chat() {
    curl -sS --max-time 300 "$BASE/v1/chat/completions" \
        -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -d "$1"
}
# Read a value from JSON on stdin with a Python expression over `d` (non-strings come back as JSON).
jget() { python3 -c "import sys,json; d=json.load(sys.stdin); v=$1; print(v if isinstance(v,str) else json.dumps(v))" 2>/dev/null; }

echo "Testing $BASE (model: $MODEL)"

# 1. Health
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE/health")
case $code in
    200) pass "health" ;;
    503) fail "health: model is still loading, try again in a minute"; exit 1 ;;
    000) fail "health: nothing is listening on the server port. The model may still be downloading,"
         echo "     or the container crashed. On the instance run: docker logs --tail 50 llama-server"; exit 1 ;;
    *)   fail "health: HTTP $code"; exit 1 ;;
esac

# 2. Auth: a wrong key must be rejected, the right one accepted
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/v1/models" -H 'Authorization: Bearer wrong')
[[ $code == 401 ]] && pass "rejects bad API key" || fail "bad API key returned HTTP $code, expected 401"
models=$(curl -sS "$BASE/v1/models" -H "Authorization: Bearer $KEY")
ids=$(jget '",".join(m["id"] for m in d["data"])' <<< "$models")
[[ ",$ids," == *",$MODEL,"* ]] && pass "model '$MODEL' listed" || fail "model '$MODEL' not in /v1/models: $ids"

# 3. Plain chat
resp=$(chat '{"model":"'"$MODEL"'","messages":[{"role":"user","content":"Reply with just the word: pong"}],"max_tokens":512}')
content=$(jget 'd["choices"][0]["message"]["content"]' <<< "$resp")
[[ ${content,,} == *pong* ]] && pass "chat: $content" || fail "chat: ${content:-$resp}"
tps=$(jget 'round(d["timings"]["predicted_per_second"],1)' <<< "$resp")
[[ -n $tps ]] && echo "     speed: $tps tokens/s"

# 4. Tool call (what MCP clients rely on)
TOOLS='[{"type":"function","function":{"name":"get_weather","description":"Get current weather for a city",
  "parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}]'
resp=$(chat '{"model":"'"$MODEL"'","tools":'"$TOOLS"',"max_tokens":2048,
  "messages":[{"role":"user","content":"What is the weather in Paris?"}]}')
call=$(jget 'd["choices"][0]["message"]["tool_calls"][0]' <<< "$resp")
name=$(jget 'd["choices"][0]["message"]["tool_calls"][0]["function"]["name"]' <<< "$resp")
args=$(jget 'json.loads(d["choices"][0]["message"]["tool_calls"][0]["function"]["arguments"])["city"]' <<< "$resp")
if [[ $name == get_weather && $args == *Paris* ]]; then pass "tool call: get_weather(city=$args)"
else fail "tool call: expected get_weather(Paris), got: ${call:-$resp}"; fi

# 5. Tool result round trip: model must use the tool output in its answer
if [[ -n $call ]]; then
    id=$(jget 'd["choices"][0]["message"]["tool_calls"][0]["id"]' <<< "$resp")
    resp=$(chat '{"model":"'"$MODEL"'","tools":'"$TOOLS"',"max_tokens":2048,"messages":[
      {"role":"user","content":"What is the weather in Paris?"},
      {"role":"assistant","content":null,"tool_calls":['"$call"']},
      {"role":"tool","tool_call_id":"'"$id"'","content":"{\"temp_c\":17,\"sky\":\"sunny\"}"}]}')
    content=$(jget 'd["choices"][0]["message"]["content"]' <<< "$resp")
    [[ $content == *17* ]] && pass "tool result used: ${content:0:80}" || fail "tool result not used: ${content:-$resp}"
fi

echo
(( failed == 0 )) && echo "All tests passed" || { echo "$failed test(s) failed"; exit 1; }
