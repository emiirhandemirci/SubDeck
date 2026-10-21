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
for f in agents/worker-sonnet.md agents/worker-opus.md agents/worker-current.md scripts/roles/worker.md skills/orchestrator/SKILL.md; do
  F="$HERE/../$f"
  # the report block (first fenced block holding a "Stop:" template line) has the Not verified line right after Tested and stays within 9 lines
  blk2="$(awk '/^```/ { n++; next } n % 2 == 1 && /^<short-name>/ { f = 1 } f && n % 2 == 1 { print } f && /^Stop:/ { exit }' "$F")"
  if printf '%s\n' "$blk2" | grep -A1 '^Tested:' | grep -q '^Not verified: '; then ok "$f: Not verified line follows Tested"; else bad "$f: Not verified line missing after Tested"; fi
  if [ "$(printf '%s\n' "$blk2" | grep -c .)" -le 9 ]; then ok "$f: worker report block within 9 lines"; else bad "$f: worker report block over 9 lines"; fi
done
for n in verifier verifier-current; do
  if grep -q 'Not verified:' "$A/$n.md"; then ok "$n has the Not verified line"; else bad "$n lacks Not verified"; fi
  if grep -q 'negative control' "$A/$n.md"; then ok "$n has negative control rule"; else bad "$n lacks negative control"; fi
  if grep -q 'node --check' "$A/$n.md"; then ok "$n has static syntax checks"; else bad "$n lacks static checks"; fi
  if grep -q '^`Fingerprint: HEAD=' "$A/$n.md"; then ok "$n reports a fingerprint"; else bad "$n lacks fingerprint"; fi
done
# worker rule integrity: rule 11 keeps its closing sentence, rule 13 exists, no line ends inside an unclosed backtick span
for f in agents/worker-sonnet.md agents/worker-opus.md agents/worker-current.md scripts/roles/worker.md; do
  F="$HERE/../$f"
  if grep -qF 'Never run `tasks.sh done`; only the manager does.' "$F"; then ok "$f keeps 'Never run tasks.sh done'"; else bad "$f lost 'Never run tasks.sh done; only the manager does.'"; fi
  if grep -qF 'stop every background process or job you started' "$F"; then ok "$f has the background-work rule"; else bad "$f lacks the background-work rule"; fi
  odd="$(awk '/^```/ { next } { n = gsub(/`/, "`"); if (n % 2 == 1) c++ } END { print c + 0 }' "$F")"
  if [ "$odd" = 0 ]; then ok "$f: no line with an unclosed backtick"; else bad "$f: $odd line(s) with an odd number of backticks"; fi
done
O="$HERE/../skills/orchestrator/SKILL.md"
for pat in 'Contract first' 'Produces: ' 'Consumes: ' 'Integration verification' 'CLAUDE_AUTOCOMPACT_PCT_OVERRIDE' 'approval of X is not approval of Y' 'Report freshness' 'Stop reason' 'negative control'; do
  if grep -q "$pat" "$O"; then ok "orchestrator mentions: $pat"; else bad "orchestrator lacks: $pat"; fi
done
echo "pass=$PASS fail=$FAIL"; [ "$FAIL" -eq 0 ]
