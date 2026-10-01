#!/usr/bin/env bash
# SubDeck guard: deterministic PreToolUse rules (no model call).
#
# Hook mode (no arguments, hook JSON on stdin; wired as `run-hook.cmd guard`):
#   prints {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"|"ask",
#           "permissionDecisionReason":"..."}} when a rule matches, nothing otherwise. Always exits 0;
#   any internal error means "allow" (no output). SUBDECK_GUARD=0 (or off/false/no) disables it.
# Settings mode:
#   guard.sh [cli] show                              effective rules + source of each mode
#   guard.sh [cli] set rule=mode ... [--project]     mode: deny | ask | off
#   guard.sh [cli] on|off [--project]                guard.enabled true|false
#   guard.sh [cli] reset [--project]                 remove the "guard" member of that config file
#   A trailing existing directory argument is the project dir (default $CLAUDE_PROJECT_DIR, else cwd).
# Config: key "guard" in ~/.subdeck/config.json (user) and <project>/.subdeck/config.json (project wins),
#   e.g. {"guard":{"enabled":true,"rules":{"push":"off","attribution":"deny"}}}.
#   Other top-level members are re-emitted verbatim; a file that is not a JSON object is left untouched.
# Rules (default mode): git-add-all (deny), force-push (deny), push (ask), history-rewrite (ask),
#   rm-rf-danger (deny), secret-files (ask), attribution (off).
# This is a guard rail, not a sandbox: it reads the command text only. Chains (&& || ; | & newline),
#   quoting, $(...) and backticks (also inside double quotes), heredoc bodies (skipped), env assignments,
#   sudo/env/nohup/timeout prefixes, git -C/-c, `bash|sh -c "..."` and `eval` are handled. Known bypasses:
#   git aliases, scripts/Makefiles, variables holding commands or paths ($X push, rm -rf "$DIR"),
#   other interpreters (python -c, node -e), find -delete, writing secret files via the shell.
# bash + awk only; one awk process per hook call.

RULES="git-add-all force-push push history-rewrite rm-rf-danger secret-files attribution"

if [ $# -eq 0 ] || [ "$1" = hook ]; then
  case "$SUBDECK_GUARD" in 0|off|false|no|OFF|FALSE|NO) exit 0 ;; esac
fi

# The awk program is a plain single-quoted string (a heredoc costs a temp file on some bash builds);
# it must not contain a single quote: use "\047".
GUARD_AWK='
# ---------- minimal JSON reader: stores wanted leaves (path ~ WANT) in V[path] ----------
function jws(  c) { while (P <= N) { c = substr(T, P, 1); if (c == " " || c == "\t" || c == "\n" || c == "\r") P++; else break } }
function jstr(  s) {
  if (!match(substr(T, P), /^"([^"\\]|\\.)*"/)) { JERR = 1; return "" }
  s = substr(T, P + 1, RLENGTH - 2); P += RLENGTH; return s
}
function uchr(h,  v, j, x) {
  v = 0
  for (j = 1; j <= 4; j++) { x = index("0123456789abcdef", substr(h, j, 1)); if (!x) return "?"; v = v * 16 + x - 1 }
  if (v == 10) return "\n"; if (v == 9) return "\t"
  if (v >= 32 && v < 127) return sprintf("%c", v)
  return "?"
}
function jdec(s,  out, i, c) {
  if (index(s, "\\") == 0) return s
  out = ""
  while ((i = index(s, "\\")) > 0) {
    out = out substr(s, 1, i - 1); c = substr(s, i + 1, 1)
    if (c == "u") { out = out uchr(tolower(substr(s, i + 2, 4))); s = substr(s, i + 6); continue }
    if (c == "n") out = out "\n"; else if (c == "t") out = out "\t"; else if (c == "r") out = out "\r"
    else if (c == "b" || c == "f") out = out " "; else out = out c
    s = substr(s, i + 2)
  }
  return out s
}
function jval(path,  c, k, i, s, rk, vs, rv) {
  if (JERR || STOP) return
  jws(); if (P > N) { JERR = 1; return }
  c = substr(T, P, 1)
  if (c == "{") {
    P++; jws(); if (substr(T, P, 1) == "}") { P++; return }
    while (1) {
      jws(); if (substr(T, P, 1) != "\"") { JERR = 1; return }
      rk = jstr(); if (JERR) return; k = jdec(rk)
      jws(); if (substr(T, P, 1) != ":") { JERR = 1; return }
      P++; jws(); vs = P; jval(path "/" k); if (JERR || STOP) return
      if (path == "/guard/rules") {
        rv = substr(T, vs, P - vs); gsub(/[\n\r\t]/, " ", rv); sub(/ +$/, "", rv)
        NRK++; RKR[NRK] = "\"" rk "\""; RKD[NRK] = k; RKV[NRK] = rv
      }
      jws(); c = substr(T, P, 1); P++
      if (c == "}") return
      if (c != ",") { JERR = 1; return }
    }
  } else if (c == "[") {
    P++; jws(); if (substr(T, P, 1) == "]") { P++; return }
    i = 0
    while (1) {
      jval(path "/" i); i++; if (JERR || STOP) return
      jws(); c = substr(T, P, 1); P++
      if (c == "]") return
      if (c != ",") { JERR = 1; return }
    }
  } else if (c == "\"") {
    s = jstr(); if (JERR) return
    if (path ~ WANT) { V[path] = jdec(s); if (HOOKPARSE && want_done()) STOP = 1 }
  } else {
    if (!match(substr(T, P), /^[-+0-9a-zA-Z.]+/)) { JERR = 1; return }
    s = substr(T, P, RLENGTH); P += RLENGTH
    if (path ~ WANT) V[path] = s
  }
}
function want_done() {
  return ("/tool_name" in V) && ("/cwd" in V) && (("/tool_input/command" in V) || ("/tool_input/file_path" in V))
}
function jparse(text) {
  T = text; N = length(T); P = 1; JERR = 0; STOP = 0; split("", V); NRK = 0
  jws(); if (substr(T, P, 1) != "{") return 0
  jval("")
  if (STOP) return 1
  if (JERR) return 0
  jws(); return P > N
}
function slurp(f,  t, line, r) {
  t = ""
  while ((r = (getline line < f)) > 0) t = t line "\n"
  close(f)
  return t
}

# ---------- config ----------
function initrules(  i, n, a) {
  n = split("git-add-all force-push push history-rewrite rm-rf-danger secret-files attribution", a, " ")
  NRULE = n
  for (i = 1; i <= n; i++) RID[i] = a[i]
  DEF["git-add-all"] = "deny"; DEF["force-push"] = "deny"; DEF["push"] = "ask"
  DEF["history-rewrite"] = "ask"; DEF["rm-rf-danger"] = "deny"; DEF["secret-files"] = "ask"; DEF["attribution"] = "off"
  for (i = 1; i <= n; i++) { MODE[RID[i]] = DEF[RID[i]]; SRC[RID[i]] = "default" }
  ENABLED = 1; ENSRC = "default"
}
function isknown(id,  i) { for (i = 1; i <= NRULE; i++) if (RID[i] == id) return 1; return 0 }
function cfgfile(f, src,  t, i, v, id) {
  CFGSTATE[src] = "absent"
  t = slurp(f); if (t == "") return
  HOOKPARSE = 0; WANT = "^/guard/"
  if (!jparse(t)) { CFGSTATE[src] = "invalid JSON, ignored"; return }
  CFGSTATE[src] = "ok"
  for (i = 1; i <= NRK; i++) if (!isknown(RKD[i])) UNK = UNK (UNK == "" ? "" : ", ") RKD[i] " (" src ")"
  if ("/guard/enabled" in V) {
    v = tolower(V["/guard/enabled"])
    if (v == "false" || v == "0" || v == "off" || v == "no") { ENABLED = 0; ENSRC = src }
    else if (v == "true" || v == "1" || v == "on" || v == "yes") { ENABLED = 1; ENSRC = src }
  }
  for (i = 1; i <= NRULE; i++) {
    id = RID[i]
    if (("/guard/rules/" id) in V) {
      v = tolower(V["/guard/rules/" id])
      if (v == "deny" || v == "ask" || v == "off") { MODE[id] = v; SRC[id] = src }
    }
  }
}

# ---------- paths ----------
function norm(p,  pre, n, a, i, out, k, st) {
  if (p == "") return ""
  gsub(/\\/, "/", p)
  if (WIN) {
    if (p ~ /^\/[A-Za-z](\/|$)/) p = substr(p, 2, 1) ":/" substr(p, 4)
    if (p ~ /^[A-Za-z]:/) p = tolower(p)
  }
  if (p ~ /^[a-zA-Z]:/) { pre = tolower(substr(p, 1, 2)) "/"; p = substr(p, 3) }
  else if (substr(p, 1, 1) == "/") { pre = "/"; p = substr(p, 2) }
  else return ""
  n = split(p, a, "/"); k = 0
  for (i = 1; i <= n; i++) {
    if (a[i] == "" || a[i] == ".") continue
    if (a[i] == "..") { if (k > 0) k--; continue }
    st[++k] = a[i]
  }
  out = pre
  for (i = 1; i <= k; i++) out = out (i > 1 ? "/" : "") st[i]
  return out
}
function isabs(p) { return p ~ /^\// || p ~ /^[A-Za-z]:/ || p ~ /^\\/ }
# expand ~, $HOME, $PWD, $CLAUDE_PROJECT_DIR; make absolute against CUR; "" when unknown
function resolve(p) {
  if (p == "~" || substr(p, 1, 2) == "~/") p = HOMEN substr(p, 2)
  else if (p ~ /^\$HOME(\/|$)/) p = HOMEN substr(p, 6)
  else if (p ~ /^\$\{HOME\}(\/|$)/) p = HOMEN substr(p, 8)
  else if (p ~ /^\$PWD(\/|$)/) p = CUR substr(p, 5)
  else if (p ~ /^\$\{PWD\}(\/|$)/) p = CUR substr(p, 7)
  else if (p ~ /^\$CLAUDE_PROJECT_DIR(\/|$)/) p = PROJN substr(p, 20)
  else if (p ~ /^\$\{CLAUDE_PROJECT_DIR\}(\/|$)/) p = PROJN substr(p, 22)
  if (p ~ /^[~$]/ || p ~ /[`]/) return ""
  if (!isabs(p)) { if (CUR == "") return ""; p = CUR "/" p }
  return norm(p)
}
function ancestor_or_eq(a, b) {
  if (a == "" || b == "") return 0
  if (a == b) return 1
  if (a ~ /\/$/) return substr(b, 1, length(a)) == a
  return substr(b, 1, length(a) + 1) == a "/"
}
function danger_target(t,  p) {
  p = t
  if (p ~ /(^|\/)\.?\*$/) { sub(/\.?\*$/, "", p); if (p == "") p = "." }
  if (p ~ /[*?[]/) return 0
  p = resolve(p)
  if (p == "") return 0
  if (p == "/" || p ~ /^[a-z]:\/$/) return 1
  return ancestor_or_eq(p, PROJN) || ancestor_or_eq(p, HOMEN)
}

# ---------- shell tokenizer: words per segment, split on ; & | newline ( ) $( ` ----------
function newseg() { NSEG++; CS = NSEG; NW = 0 }
function endseg(d) { if (NW > 0) { WC[d, CS] = NW; NSG[d]++; SEGS[d, NSG[d]] = CS } newseg() }
function flush(d) {
  if (HASW || WD != "") {
    if (HDNEXT) { HDN++; HD[HDN] = WD; HS[HDN] = HDSTRIPNEXT; HDNEXT = 0 }
    else if (SKIPNEXT) SKIPNEXT = 0
    else { NW++; W[d, CS, NW] = WD }
  }
  WD = ""; HASW = 0
}
function push(t, d) {
  SP++; ST[SP] = t
  if (t == "c" || t == "b") { SVC[SP] = CS; SVN[SP] = NW; SVW[SP] = WD; SVP[SP] = PD; PD = 0; WD = ""; HASW = 0; newseg() }
}
function pop(d,  t) {
  t = ST[SP]
  if (t == "c" || t == "b") { flush(d); endseg(d); CS = SVC[SP]; NW = SVN[SP]; WD = SVW[SP] "$()"; HASW = 1; PD = SVP[SP] }
  SP--
}
function skiphd(cmd, i, n,  k, e, line) {
  for (k = 1; k <= HDN; k++) {
    while (i < n) {
      e = index(substr(cmd, i + 1), "\n")
      if (e == 0) { line = substr(cmd, i + 1); i = n } else { line = substr(cmd, i + 1, e - 1); i = i + e }
      if (HS[k]) sub(/^\t+/, "", line)
      sub(/\r$/, "", line)
      if (line == HD[k]) break
    }
  }
  HDN = 0
  return i
}
function tokenize(cmd, d,  n, i, c, nx, m) {
  n = length(cmd); SP = 0; WD = ""; HASW = 0; HDN = 0; HDNEXT = 0; SKIPNEXT = 0; PD = 0; NSG[d] = 0
  newseg()
  for (i = 1; i <= n; i++) {
    c = substr(cmd, i, 1); m = (SP > 0) ? ST[SP] : "u"
    if (m == "s") { if (c == "\047") SP--; else WD = WD c; continue }
    if (m == "d") {
      if (c == "\"") { SP--; continue }
      if (c == "\\") {
        nx = substr(cmd, i + 1, 1)
        if (nx == "\"" || nx == "\\" || nx == "$" || nx == "`") { WD = WD nx; i++; continue }
        if (nx == "\n") { i++; continue }
        WD = WD c; continue
      }
      if (c == "$" && substr(cmd, i + 1, 1) == "(") { i++; push("c", d); continue }
      if (c == "`") { push("b", d); continue }
      WD = WD c; continue
    }
    if (c == "\047") { push("s", d); HASW = 1; continue }
    if (c == "\"") { push("d", d); HASW = 1; continue }
    if (c == "\\") { nx = substr(cmd, i + 1, 1); i++; if (nx != "\n") { WD = WD nx; HASW = 1 } continue }
    if (c == " " || c == "\t" || c == "\r") { flush(d); continue }
    if (c == "#" && !HASW && WD == "") { while (i < n && substr(cmd, i + 1, 1) != "\n") i++; continue }
    if (c == "$" && substr(cmd, i + 1, 1) == "(") { i++; push("c", d); continue }
    if (c == "`") { if (m == "b") pop(d); else push("b", d); continue }
    if (c == "(") { if (m == "c") PD++; flush(d); endseg(d); continue }
    if (c == ")") {
      if (m == "c" && PD == 0) { pop(d); continue }
      if (m == "c") PD--
      flush(d); endseg(d); continue
    }
    if (c == ";" || c == "&" || c == "|" || c == "\n") {
      flush(d); endseg(d)
      if (c == "\n" && HDN > 0) i = skiphd(cmd, i, n)
      continue
    }
    if (c == ">" || c == "<") {
      if (!HASW && WD ~ /^[0-9]+$/) WD = ""
      flush(d)
      if (c == "<" && substr(cmd, i + 1, 1) == "<") {
        if (substr(cmd, i + 2, 1) == "<") { i += 2; SKIPNEXT = 1; continue }
        i++; HDSTRIPNEXT = 0
        if (substr(cmd, i + 1, 1) == "-") { i++; HDSTRIPNEXT = 1 }
        HDNEXT = 1; continue
      }
      nx = substr(cmd, i + 1, 1)
      if (nx == ">" || nx == "|") { i++; nx = substr(cmd, i + 1, 1) }
      if (nx == "&") { i++; while (substr(cmd, i + 1, 1) ~ /[0-9-]/) i++; continue }
      SKIPNEXT = 1; continue
    }
    WD = WD c
  }
  flush(d)
  while (SP > 0) { if (ST[SP] == "c" || ST[SP] == "b") pop(d); else SP-- }
  flush(d); endseg(d)
}

# ---------- rules ----------
function hit(id) {
  if (MODE[id] == "deny") { if (DENYID == "") DENYID = id }
  else if (MODE[id] == "ask") { if (ASKID == "") ASKID = id }
}
function analyze(cmd, d,  s) {
  if (d > 3) return
  tokenize(cmd, d)
  for (s = 1; s <= NSG[d]; s++) seg(d, SEGS[d, s])
}
function seg(d, id,  nw, k, x, cmd, j, str) {
  nw = WC[d, id]; k = 1
  while (k <= nw) {
    x = W[d, id, k]
    if (x ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { k++; continue }
    if (x ~ /^(sudo|command|builtin|nohup|time|exec|then|do|else|elif|if|while|until|!|\{|\}|nice|env|stdbuf|xargs|doas)$/) {
      k++; while (k <= nw && W[d, id, k] ~ /^-/) k++
      continue
    }
    if (x == "timeout") { k++; while (k <= nw && W[d, id, k] ~ /^-/) k++; k++; continue }
    break
  }
  if (k > nw) return
  cmd = x; sub(/.*[\/\\]/, "", cmd); cmd = tolower(cmd); sub(/\.exe$/, "", cmd)
  if (cmd == "git") git_seg(d, id, k + 1, nw)
  else if (cmd == "rm") rm_seg(d, id, k + 1, nw)
  else if (cmd == "cd" || cmd == "pushd") {
    x = (k + 1 <= nw) ? W[d, id, k + 1] : "~"
    if (x == "--" && k + 2 <= nw) x = W[d, id, k + 2]
    CUR = resolve(x)
  }
  else if (cmd ~ /^(bash|sh|zsh|dash|ksh)$/) {
    for (j = k + 1; j < nw; j++) if (W[d, id, j] ~ /^-[a-zA-Z]*c[a-zA-Z]*$/) { analyze(W[d, id, j + 1], d + 1); break }
  }
  else if (cmd == "eval") {
    str = ""; for (j = k + 1; j <= nw; j++) str = str " " W[d, id, j]
    analyze(str, d + 1)
  }
}
function git_seg(d, id, k, nw,  x, sc, i, j, ch, len, force, dd, npos, noop) {
  while (k <= nw) {
    x = W[d, id, k]
    if (x ~ /^(-C|-c|--git-dir|--work-tree|--namespace|--config-env|--super-prefix)$/) { k += 2; continue }
    if (x ~ /^-/) { k++; continue }
    break
  }
  if (k > nw) return
  sc = W[d, id, k]; k++
  if (sc == "add") {
    dd = 0
    for (i = k; i <= nw; i++) {
      x = W[d, id, i]
      if (!dd && x == "--") { dd = 1; continue }
      if (!dd && x ~ /^--(all|no-ignore-removal|update)$/) { hit("git-add-all"); return }
      if (!dd && x ~ /^-[a-zA-Z]+$/ && x ~ /[Au]/) { hit("git-add-all"); return }
      if ((dd || x !~ /^-/) && x ~ /^(\.|\.\/|\*|\.\/\*|:\/|:\/\.|:\/\*|:\(top\)|:\(top\)\.)$/) { hit("git-add-all"); return }
    }
  } else if (sc == "commit") {
    COMMIT = 1
    for (i = k; i <= nw; i++) {
      x = W[d, id, i]
      if (x == "--") break
      if (x == "--all") { hit("git-add-all"); return }
      if (x ~ /^--(message|file|author|date|template|reuse-message|reedit-message|fixup|squash|cleanup|trailer|pathspec-from-file)$/) { i++; continue }
      if (x ~ /^-[^-]/) {
        len = length(x)
        for (j = 2; j <= len; j++) {
          ch = substr(x, j, 1)
          if (ch == "a") { hit("git-add-all"); return }
          if (index("mFCct", ch)) { if (j == len) i++; break }
        }
      }
    }
  } else if (sc == "push") {
    force = 0; dd = 0; npos = 0
    for (i = k; i <= nw; i++) {
      x = W[d, id, i]
      if (!dd && x == "--") { dd = 1; continue }
      if (!dd && x ~ /^--/) {
        if (x ~ /^--force(-with-lease(=.*)?)?$/) force = 1
        else if (x ~ /^--(repo|receive-pack|exec|push-option)$/) i++
        continue
      }
      if (!dd && x ~ /^-./) {
        len = length(x)
        for (j = 2; j <= len; j++) {
          ch = substr(x, j, 1)
          if (ch == "f") force = 1
          if (ch == "o") { if (j == len) i++; break }
        }
        continue
      }
      npos++
      if (npos >= 2 && substr(x, 1, 1) == "+") force = 1
    }
    if (force) hit("force-push"); else hit("push")
  } else if (sc == "reset") {
    for (i = k; i <= nw; i++) if (W[d, id, i] == "--hard") { hit("history-rewrite"); return }
  } else if (sc == "rebase") {
    for (i = k; i <= nw; i++) if (W[d, id, i] ~ /^--(abort|quit|show-current-patch)$/) return
    hit("history-rewrite")
  } else if (sc == "filter-branch" || sc == "filter-repo") {
    hit("history-rewrite")
  } else if (sc == "clean") {
    force = 0; noop = 0
    for (i = k; i <= nw; i++) {
      x = W[d, id, i]
      if (x == "--") break
      if (x == "--force") force = 1
      else if (x == "--dry-run") noop = 1
      else if (x ~ /^-[a-zA-Z]+$/) { if (x ~ /f/) force = 1; if (x ~ /n/) noop = 1 }
    }
    if (force && !noop) hit("history-rewrite")
  }
}
function rm_seg(d, id, k, nw,  i, x, rec, dd, nt, tg) {
  rec = 0; dd = 0; nt = 0
  for (i = k; i <= nw; i++) {
    x = W[d, id, i]
    if (!dd && x == "--") { dd = 1; continue }
    if (!dd && x ~ /^--/) {
      if (x == "--recursive") rec = 1
      if (x == "--no-preserve-root") { NOPRES = 1 }
      continue
    }
    if (!dd && x ~ /^-./) { if (x ~ /[rR]/) rec = 1; continue }
    tg[++nt] = x
  }
  if (!rec) return
  if (NOPRES) { hit("rm-rf-danger"); return }
  for (i = 1; i <= nt; i++) if (danger_target(tg[i])) { hit("rm-rf-danger"); return }
}
function secret_path(p,  b) {
  b = tolower(p); sub(/.*[\/\\]/, "", b)
  if (b ~ /^\.env(\..*)?$/) return b !~ /\.(example|sample|template)$/
  if (b ~ /\.(pem|key)$/) return 1
  if (b ~ /^id_(rsa|ed25519)/) return 1
  if (b ~ /^credentials.*\.json$/) return 1
  return 0
}
function reason(id) {
  if (id == "git-add-all") return "SubDeck guard (git-add-all): do not stage everything; other agents share this working tree. Stage explicit paths (git add <file> ...) and commit with a pathspec (git commit -m \"...\" -- <paths>)."
  if (id == "force-push") return "SubDeck guard (force-push): force pushes rewrite remote history and are blocked. Push without --force/-f/--force-with-lease/+refspec, or ask the user to run it by hand."
  if (id == "push") return "SubDeck guard (push): pushing needs explicit user approval."
  if (id == "history-rewrite") return "SubDeck guard (history-rewrite): git reset --hard / rebase / filter-branch / filter-repo / clean -f discard or rewrite work and need explicit user approval."
  if (id == "rm-rf-danger") return "SubDeck guard (rm-rf-danger): recursive delete of /, a drive root, the home directory, the project root or one of their ancestors is blocked. Delete specific subdirectories instead."
  if (id == "secret-files") return "SubDeck guard (secret-files): this file looks like a secret (.env, key, certificate, credentials); writing it needs explicit user approval."
  if (id == "attribution") return "SubDeck guard (attribution): the commit message contains an attribution line (Co-Authored-By / Generated with); remove it and commit again."
  return "SubDeck guard (" id ")"
}
function jesc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\n/, "\\n", s); gsub(/\t/, " ", s); return s }

# ---------- modes ----------
function do_hook(  t, tool, cmd, fp, cwd, low, dec, id, rs, np, pl, pi, pp) {
  t = ""
  while ((getline line) > 0) t = t line "\n"
  HOOKPARSE = 1; WANT = "^/(tool_name|cwd|tool_input/command|tool_input/file_path|tool_input/path)$"
  if (!jparse(t)) return
  tool = V["/tool_name"]; cmd = V["/tool_input/command"]; fp = V["/tool_input/file_path"]; cwd = V["/cwd"]
  if (tool == "") return
  # other tools: Copilot reports lowercase runtime names and tool_input.path; Codex edits arrive as apply_patch
  if (tool == "bash") tool = "Bash"; else if (tool == "powershell") tool = "PowerShell"
  else if (tool == "edit") tool = "Edit"; else if (tool == "create") tool = "Write"
  if (fp == "") fp = V["/tool_input/path"]
  PROJ = ENVIRON["CLAUDE_PROJECT_DIR"]; if (PROJ == "") PROJ = cwd
  if (uf == "") uf = ENVIRON["HOME"] "/.subdeck/config.json"
  if (pf == "" && PROJ != "") pf = PROJ "/.subdeck/config.json"
  WIN = (ENVIRON["OS"] == "Windows_NT" || cwd ~ /^[A-Za-z]:/ || PROJ ~ /^[A-Za-z]:/)
  initrules(); cfgfile(uf, "user"); if (pf != "") cfgfile(pf, "project")
  if (!ENABLED) return
  HOMEN = norm(ENVIRON["HOME"]); PROJN = norm(PROJ); CUR = norm(cwd); if (CUR == "") CUR = PROJN
  DENYID = ""; ASKID = ""; COMMIT = 0; NOPRES = 0
  if (tool == "Bash" || tool == "PowerShell") {
    if (cmd == "") return
    analyze(cmd, 0)
    if (COMMIT) { low = tolower(cmd); if (index(low, "co-authored-by") || index(low, "generated with")) hit("attribution") }
  } else if (tool == "Write" || tool == "Edit" || tool == "MultiEdit") {
    if (fp != "" && secret_path(fp)) hit("secret-files")
  } else if (tool == "apply_patch") {
    # Codex patch text: file paths are on "*** Add|Update|Delete File: <path>" and "*** Move to: <path>" lines
    np = split(cmd, pl, "\n")
    for (pi = 1; pi <= np; pi++) {
      pp = pl[pi]; sub(/\r$/, "", pp)
      if (match(pp, /^\*\*\* (Add File|Update File|Delete File|Move to): /)) {
        pp = substr(pp, RLENGTH + 1)
        if (secret_path(pp)) { hit("secret-files"); break }
      }
    }
  }
  if (DENYID != "") { dec = "deny"; id = DENYID } else if (ASKID != "") { dec = "ask"; id = ASKID } else return
  rs = reason(id) " (/subdeck:settings: set " id "=off to change)"
  # Codex documents only deny for PreToolUse: an "ask" becomes a deny that tells the model to ask the user first
  if (dec == "ask" && ENVIRON["SUBDECK_TOOL"] == "codex") { dec = "deny"; rs = "Ask the user for approval first; retry only if they approve. " rs }
  if (ENVIRON["SUBDECK_TOOL"] == "copilot")
    # Copilot reads the decision at the top level; keep the Claude-shaped member too
    printf "{\"permissionDecision\":\"%s\",\"permissionDecisionReason\":\"%s\",\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"%s\",\"permissionDecisionReason\":\"%s\"}}\n", dec, jesc(rs), dec, jesc(rs)
  else
    printf "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"%s\",\"permissionDecisionReason\":\"%s\"}}\n", dec, jesc(rs)
}
function do_show(  i, id, e) {
  initrules(); cfgfile(uf, "user"); cfgfile(pf, "project")
  print "SubDeck guard (defaults < user < project)"
  e = ENVIRON["SUBDECK_GUARD"]
  printf "enabled: %s (%s)\n", ENABLED ? "yes" : "no", ENSRC
  if (e == "0" || e == "off" || e == "false" || e == "no") print "note: SUBDECK_GUARD=" e " in this environment disables the guard entirely"
  printf "%-16s %-5s %s\n", "RULE", "MODE", "SOURCE"
  for (i = 1; i <= NRULE; i++) { id = RID[i]; printf "%-16s %-5s %s\n", id, MODE[id], SRC[id] }
  if (UNK != "") print "unknown (ignored): " UNK
  print ""
  printf "user file:    %s (%s)\n", uf, CFGSTATE["user"]
  printf "project file: %s (%s)\n", pf, CFGSTATE["project"]
}
function do_dump(  t, i, id, v) {
  t = slurp(f); if (t == "") return
  HOOKPARSE = 0; WANT = "^/guard/"
  if (!jparse(t)) { print "ERR"; return }
  initrules()
  for (i = 1; i <= NRK; i++) if (!isknown(RKD[i])) print "unknown\t" RKR[i] "\t" RKV[i]
  if ("/guard/enabled" in V) {
    v = tolower(V["/guard/enabled"])
    if (v == "false" || v == "0" || v == "off" || v == "no") print "enabled false"
    else if (v == "true" || v == "1" || v == "on" || v == "yes") print "enabled true"
  }
  for (i = 1; i <= NRULE; i++) {
    id = RID[i]
    if (("/guard/rules/" id) in V) { v = tolower(V["/guard/rules/" id]); if (v == "deny" || v == "ask" || v == "off") print "rule " id " " v }
  }
}
BEGIN {
  if (mode == "hook") do_hook()
  else if (mode == "show") do_show()
  else if (mode == "dump") do_dump()
  exit 0
}
'

# ---------- hook mode ----------
if [ $# -eq 0 ] || [ "$1" = hook ]; then
  awk -v mode=hook "$GUARD_AWK" 2>/dev/null
  exit 0
fi

# ---------- settings mode ----------
[ "$1" = cli ] && shift
CMD=""; SCOPE=user; PROJECT=""; PAIRS=(); BADARGS=()
for a in "$@"; do
  a="${a%$'\r'}"
  case "$a" in
    "") ;;
    --project) SCOPE=project ;;
    --*) BADARGS+=("$a") ;;
    show|set|on|off|reset) if [ -z "$CMD" ]; then CMD="$a"; else BADARGS+=("$a"); fi ;;
    *=*) PAIRS+=("$a") ;;
    *) if [ -d "$a" ]; then PROJECT="$a"; else BADARGS+=("$a"); fi ;;
  esac
done
[ -n "$CMD" ] || CMD=show
[ -n "$PROJECT" ] || PROJECT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
UFILE="${HOME}/.subdeck/config.json"
PFILE="$PROJECT/.subdeck/config.json"
if [ "$SCOPE" = project ]; then TARGET="$PFILE"; else TARGET="$UFILE"; fi

show() {
  awk -v mode=show -v uf="$UFILE" -v pf="$PFILE" "$GUARD_AWK" < /dev/null
  echo "Usage: /subdeck:settings set guard=on|off <rule>=deny|ask|off [--project] (low-level: guard.sh set push=off attribution=deny [--project] | on | off | reset)"
  echo "Modes: deny | ask | off. Env SUBDECK_GUARD=0 disables the guard for a session."
}

# members FILE: each top-level member of a JSON object on its own line (raw text), except "guard".
# Returns 1 when the file is not a well-formed JSON object; an absent or blank file has no members.
members() {
  [ -f "$1" ] || return 0
  tr -d '\r' < "$1" | tr '\n' ' ' | awk '
    { t = t $0 }
    END {
      gsub(/^[ \t]+|[ \t]+$/, "", t)
      if (t == "") exit 0
      n = length(t)
      if (substr(t,1,1) != "{" || substr(t,n,1) != "}") exit 1
      depth = 0; ins = 0; esc = 0; cur = ""
      for (i = 1; i <= n; i++) {
        c = substr(t, i, 1)
        if (ins) { cur = cur c; if (esc) esc = 0; else if (c == "\\") esc = 1; else if (c == "\"") ins = 0; continue }
        if (c == "\"") { ins = 1; cur = cur c; continue }
        if (c == "{" || c == "[") { depth++; if (depth == 1) continue }
        else if (c == "}" || c == "]") {
          depth--
          if (depth < 0) exit 1
          if (depth == 0) { if (i != n) exit 1; emit(); continue }
        }
        else if (c == "," && depth == 1) { emit(); continue }
        cur = cur c
      }
      if (ins || depth != 0) exit 1
    }
    function emit() {
      gsub(/^[ \t]+|[ \t]+$/, "", cur)
      if (cur != "" && cur !~ /^"guard"[ \t]*:/) print cur
      cur = ""
    }'
}

# write_file FILE OTHERS GUARDJSON: OTHERS = newline-separated raw members kept verbatim; GUARDJSON may be empty.
write_file() {
  local f="$1" others="$2" g="$3" line body=""
  mkdir -p "$(dirname "$f")" 2>/dev/null
  while IFS= read -r line; do if [ -n "$line" ]; then body="$body$line,"; fi; done <<< "$others"
  if [ -n "$g" ]; then body="$body\"guard\":$g,"; fi
  if printf '{%s}\n' "${body%,}" > "$f" 2>/dev/null; then return 0; fi
  echo "error: could not write $f"; return 1
}

valid_rule() { case " $RULES " in *" $1 "*) return 0 ;; esac; return 1; }

# update ENABLED(true|false|keep) [rule=mode ...]: merge into TARGET's guard member.
update() {
  local TAB=$'\t' unk="" en="$1" cur others dump line en_cur="" rules="" id m kv g="" rj=""
  shift
  if ! others="$(members "$TARGET")"; then
    echo "error: $TARGET is not a valid JSON object; left untouched (fix or delete it by hand)."; return 1
  fi
  dump=""
  [ -f "$TARGET" ] && dump="$(awk -v mode=dump -v f="$TARGET" "$GUARD_AWK" < /dev/null)"
  case "$dump" in ERR*) echo "error: $TARGET is not a valid JSON object; left untouched (fix or delete it by hand)."; return 1 ;; esac
  # rules kept as " id=mode" words (bash 3.2 has no associative arrays); later entries win
  while IFS= read -r line; do
    case "$line" in
      unknown$TAB*) line="${line#unknown$TAB}"; unk="$unk,${line%%$TAB*}:${line#*$TAB}" ;;
      *) IFS=' ' read -r a b c <<< "$line"; case "$a" in enabled) en_cur="$b" ;; rule) rules="$rules $b=$c" ;; esac ;;
    esac
  done <<< "$dump"
  [ "$en" = keep ] || en_cur="$en"
  for kv in "$@"; do rules="$rules $kv"; done
  for id in $RULES; do
    m=""
    for kv in $rules; do [ "${kv%%=*}" = "$id" ] && m="${kv#*=}"; done
    [ -n "$m" ] && rj="$rj,\"$id\":\"$m\""
  done
  [ -n "$en_cur" ] && g="\"enabled\":$en_cur"
  rj="$rj$unk"
  [ -n "$rj" ] && g="$g${g:+,}\"rules\":{${rj#,}}"
  write_file "$TARGET" "$others" "{$g}" && echo "wrote $TARGET"
}

for b in "${BADARGS[@]}"; do echo "warning: ignored argument '$b'"; done

case "$CMD" in
  show) show ;;
  on|off)
    if [ "$CMD" = on ]; then update true; else update false; fi
    echo; show ;;
  set)
    if [ ${#PAIRS[@]} -eq 0 ]; then echo "error: set needs rule=mode pairs, e.g. set push=off"; echo "rules: $RULES"; exit 0; fi
    ERR=0; NEW=()
    for kv in "${PAIRS[@]}"; do
      k="${kv%%=*}"; v="$(printf '%s' "${kv#*=}" | tr 'A-Z' 'a-z')"
      if ! valid_rule "$k"; then echo "error: unknown rule '$k' (rules: $RULES)"; ERR=1
      else case "$v" in deny|ask|off) NEW+=("$k=$v") ;; *) echo "error: invalid mode '$v' for $k (valid: deny, ask, off)"; ERR=1 ;; esac; fi
    done
    if [ $ERR -ne 0 ]; then echo "nothing written."; exit 0; fi
    update keep "${NEW[@]}"
    echo; show ;;
  reset)
    if [ ! -f "$TARGET" ]; then echo "reset: nothing to remove ($TARGET absent)"
    elif ! OTHERS="$(members "$TARGET")"; then echo "error: $TARGET is not a valid JSON object; left untouched (fix or delete it by hand)."
    elif [ -z "$OTHERS" ]; then
      if rm -f "$TARGET" 2>/dev/null; then echo "reset: removed $TARGET"; else echo "error: could not remove $TARGET"; fi
    else
      if write_file "$TARGET" "$OTHERS" ""; then echo "reset: removed guard from $TARGET (other settings kept)"; fi
    fi
    echo; show ;;
esac
exit 0
