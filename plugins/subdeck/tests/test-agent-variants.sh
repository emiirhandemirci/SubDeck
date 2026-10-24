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
# the rulebook is a lean core plus references/*.md; every rule stays reachable from the core or one of its references
OALL="$(mktemp)"; cat "$O" "$HERE"/../skills/orchestrator/references/*.md > "$OALL"
if [ "$(wc -c < "$O")" -le 10240 ]; then ok "orchestrator core is at most 10 KB"; else bad "orchestrator core is over 10 KB"; fi
for rf in mapped-roles autopilot pre-push verification task-files parallelism rulebook-items; do
  if grep -q "references/$rf.md" "$O" && [ -s "$HERE/../skills/orchestrator/references/$rf.md" ]; then ok "orchestrator core names references/$rf.md"; else bad "orchestrator core lacks references/$rf.md"; fi
done
for pat in 'Contract first' 'Produces: ' 'Consumes: ' 'Integration verification' 'CLAUDE_AUTOCOMPACT_PCT_OVERRIDE' 'approval of X is not approval of Y' 'Report freshness' 'Stop reason' 'negative control'; do
  if grep -q "$pat" "$OALL"; then ok "orchestrator mentions: $pat"; else bad "orchestrator lacks: $pat"; fi
done
# 149: read scope rules (workers rule 14, researchers, verifiers), Read first in the template, verification tiers
for f in agents/worker-sonnet.md agents/worker-opus.md agents/worker-current.md scripts/roles/worker.md; do
  if grep -qF '14. **Read scope:**' "$HERE/../$f" && grep -qF 'Never read a whole repo or tree' "$HERE/../$f" && grep -qF 'more than about 10 files' "$HERE/../$f"; then ok "$f has the read-scope rule"; else bad "$f lacks the read-scope rule"; fi
done
for f in agents/researcher.md agents/researcher-current.md scripts/roles/researcher.md agents/verifier.md agents/verifier-current.md scripts/roles/verifier.md; do
  if grep -qF 'Never read a whole repo or tree' "$HERE/../$f" || grep -qF 'never read a whole repo or tree' "$HERE/../$f"; then ok "$f has the read-scope rule"; else bad "$f lacks the read-scope rule"; fi
done
# negative control: the check must fail on a copy without the rule
NC="$(mktemp)"; grep -vF 'Read scope' "$HERE/../agents/worker-sonnet.md" > "$NC"
if grep -qF '14. **Read scope:**' "$NC"; then bad "read-scope negative control did not fail"; else ok "read-scope check fails without the rule (negative control)"; fi
rm -f "$NC"
if grep -qF 'Read first: <3-5 concrete paths' "$O" && grep -qF 'verification tiers' "$O" && grep -qF 'Small** (one file' "$O"; then ok "orchestrator has Read first and the verification tiers"; else bad "orchestrator lacks Read first or tiers"; fi
# 149 items 4-8: verification levels, delta, compact verifier reply, artifact reuse, small-edit and resume rules
for f in agents/verifier.md agents/verifier-current.md scripts/roles/verifier.md; do
  F="$HERE/../$f"
  if grep -qF '^Verified paths:' "$F" || grep -qF '`Verified paths: ' "$F"; then ok "$f asks for the Verified paths line"; else bad "$f lacks the Verified paths line"; fi
  if grep -qF 'goes ONLY into the Detail file' "$F" && grep -qF 'at most 8 lines' "$F"; then ok "$f has the compact reply rule"; else bad "$f lacks the compact reply rule"; fi
  if grep -qF 'previously verified' "$F" && grep -qF 'sha256sum' "$F"; then ok "$f has delta and artifact reuse"; else bad "$f lacks delta or artifact reuse"; fi
done
for f in agents/worker-sonnet.md agents/worker-opus.md agents/worker-current.md scripts/roles/worker.md; do
  if grep -qF 'Artifact: <path> sha256:<hex>' "$HERE/../$f"; then ok "$f has the artifact rule"; else bad "$f lacks the artifact rule"; fi
done
NC="$(mktemp)"; grep -vF 'Artifact:' "$HERE/../agents/worker-sonnet.md" > "$NC"
if grep -qF 'Artifact: <path> sha256:<hex>' "$NC"; then bad "artifact negative control did not fail"; else ok "artifact check fails without the rule (negative control)"; fi
rm -f "$NC"
for pat in 'small-edit rule' 'at most 10 lines' 'Verification levels' '\*\*L0\*\*' 'verify-reason' 'never higher than the previous level' 'verify-delta' 'Artifact reuse' 'tasks.sh warm' 'age >= 5 min' 'one verifier per wave'; do
  if grep -q -i -- "$pat" "$OALL"; then ok "orchestrator mentions: $pat"; else bad "orchestrator lacks: $pat"; fi
done
rm -f "$OALL"
echo "pass=$PASS fail=$FAIL"; [ "$FAIL" -eq 0 ]
