#!/usr/bin/env bash
# Usage: bash plugins/subdeck/tests/test-agent-variants.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
A="$HERE/../agents"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL $1"; }
body() { awk 'c>=2{print} /^---\r?$/{c++}' "$1"; }
fm()   { awk '/^---\r?$/{c++; next} c==1{print}' "$1" | tr -d '\r'; }

for pair in worker-sonnet:worker-current researcher:researcher-current verifier:verifier-current; do
  named="${pair%%:*}"; cur="${pair##*:}"
  if [ "$(body "$A/$named.md" | cksum)" = "$(body "$A/$cur.md" | cksum)" ]; then ok "$cur body identical to $named"; else bad "$cur body differs from $named"; fi
  if fm "$A/$cur.md" | grep -qx 'model: inherit'; then ok "$cur has model: inherit"; else bad "$cur lacks model: inherit"; fi
  if fm "$A/$cur.md" | grep -qx "name: $cur"; then ok "$cur name matches"; else bad "$cur name wrong"; fi
  if grep -q $'\r' "$A/$cur.md"; then bad "$cur has CRLF"; else ok "$cur LF endings"; fi
done
for pair in worker-sonnet:sonnet worker-opus:opus researcher:sonnet verifier:sonnet; do
  n="${pair%%:*}"; m="${pair##*:}"
  if fm "$A/$n.md" | grep -qx "model: $m"; then ok "$n keeps model: $m"; else bad "$n model changed"; fi
done
if grep -q $'\r' "${BASH_SOURCE[0]}"; then bad "test file has CRLF"; else ok "test file LF endings"; fi
for n in worker-sonnet worker-opus worker-current; do
  if grep -q '^Stop: <done|waiting|quota|timeout|no-progress|blocked>' "$A/$n.md"; then ok "$n report has Stop line"; else bad "$n lacks Stop line"; fi
done
for n in verifier verifier-current; do
  if grep -q 'negative control' "$A/$n.md"; then ok "$n has negative control rule"; else bad "$n lacks negative control"; fi
  if grep -q 'node --check' "$A/$n.md"; then ok "$n has static syntax checks"; else bad "$n lacks static checks"; fi
  if grep -q '^`Fingerprint: HEAD=' "$A/$n.md"; then ok "$n reports a fingerprint"; else bad "$n lacks fingerprint"; fi
done
O="$HERE/../skills/orchestrator/SKILL.md"
for pat in 'Contract first' 'Produces: ' 'Consumes: ' 'Integration verification' 'CLAUDE_AUTOCOMPACT_PCT_OVERRIDE' 'approval of X is not approval of Y' 'Report freshness' 'Stop reason' 'negative control'; do
  if grep -q "$pat" "$O"; then ok "orchestrator mentions: $pat"; else bad "orchestrator lacks: $pat"; fi
done
echo "pass=$PASS fail=$FAIL"; [ "$FAIL" -eq 0 ]
