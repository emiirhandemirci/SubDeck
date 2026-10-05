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
#   guard.sh [cli] push <ask|branches|off> [--project]   push mode (default branches); branches <glob>[,<glob>] [--project]
#       sets guard.protectBranches (default main,master,release/*)
#   guard.sh [cli] protect <glob>[,<glob>] [--project]   add to guard.protectedPaths (unprotect <glob>[,..] removes)
#   A trailing existing directory argument is the project dir (default $CLAUDE_PROJECT_DIR, else cwd).
# Config: key "guard" in ~/.subdeck/config.json (user) and the project config (project wins), which is
#   ~/.subdeck/projects/<key>/config.json (lib-paths.sh); a legacy <project>/.subdeck/config.json is still read
#   below it and never written. E.g. {"guard":{"enabled":true,"rules":{"push":"off","attribution":"deny"}}}.
#   Other top-level members are re-emitted verbatim; a file that is not a JSON object is left untouched.
# Rules (default mode): git-add-all (deny), force-push (deny), push (branches: ask only for protected branches and tags; or ask | off), history-rewrite (ask),
#   rm-rf-danger (deny), secret-files (ask), attribution (off), protected-paths (ask; active only when
#   guard.protectedPaths, an array of globs in user/project config, is non-empty; a project list replaces the user list).
#   Globs match the path relative to the project root (case-insensitive on Windows, / or \ separators):
#   a glob without "/" matches that name at any depth (CLAUDE.md, *.lock); with "/" it is anchored at the root;
#   * stays inside one segment, ** crosses segments; a match also covers everything below it.
#   Checked: Write/Edit/MultiEdit/apply_patch targets, redirections (> >>), rm/mv/cp (destination)/tee/truncate/
#   dd of=, sed -i, git rm/mv/restore/checkout -- <path>, PowerShell Remove-Item/Move-Item/Copy-Item.
# This is a guard rail, not a sandbox: it reads the command text only. Chains (&& || ; | & newline),
#   quoting, $(...) and backticks (also inside double quotes), heredoc bodies (skipped), env assignments,
#   sudo/doas/env/nice/time/timeout/stdbuf/xargs/nohup prefixes (with option arguments: sudo -u root), git -C/-c,
#   `bash|sh -c "..."` and `eval` are handled. PowerShell tool: backtick is the escape character, backslash a path
#   separator; Remove-Item/ri/rm/del/rd/rmdir -Recurse (or /s, also via cmd /c) of a protected root is rm-rf-danger.
#   Known bypasses:
#   git aliases, scripts/Makefiles, variables holding commands or paths ($X push, rm -rf "$DIR"),
#   other interpreters (python -c, node -e), find -delete, writing secret/protected files via the shell.
#   Protected paths also escape through shell globs or variables in targets (rm CLA*), perl -pi, patch,
#   editors, git checkout <branch> / stash / reset, and cp into a protected directory.
# bash + awk only; one awk process per hook call.

RULES="git-add-all force-push push history-rewrite rm-rf-danger secret-files attribution protected-paths"

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
    if (path == "/guard/protectedPaths") HASPP = 1
    if (path == "/guard/protectBranches") HASBR = 1
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
    if (path ~ /^\/guard\/protectedPaths\/[0-9]+$/) { NPP++; PPRAW[NPP] = s; PPDEC[NPP] = jdec(s) }
    if (path ~ /^\/guard\/protectBranches\/[0-9]+$/) { NBR++; BRRAW[NBR] = s; BRDEC[NBR] = jdec(s) }
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
  T = text; N = length(T); P = 1; JERR = 0; STOP = 0; split("", V); NRK = 0; NPP = 0; HASPP = 0; NBR = 0; HASBR = 0
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
  n = split("git-add-all force-push push history-rewrite rm-rf-danger secret-files attribution protected-paths", a, " ")
  NRULE = n
  for (i = 1; i <= n; i++) RID[i] = a[i]
  DEF["git-add-all"] = "deny"; DEF["force-push"] = "deny"; DEF["push"] = "branches"
  DEF["history-rewrite"] = "ask"; DEF["rm-rf-danger"] = "deny"; DEF["secret-files"] = "ask"; DEF["attribution"] = "off"; DEF["protected-paths"] = "ask"
  for (i = 1; i <= n; i++) { MODE[RID[i]] = DEF[RID[i]]; SRC[RID[i]] = "default" }
  ENABLED = 1; ENSRC = "default"; NPL = 0; PLSRC = "default"
  NPB = 3; PB[1] = "main"; PB[2] = "master"; PB[3] = "release/*"; PBSRC = "default"
}
function isknown(id,  i) { for (i = 1; i <= NRULE; i++) if (RID[i] == id) return 1; return 0 }
function cfgfile(f, src,  t, i, v, id) {
  CFGSTATE[src] = "absent"
  t = slurp(f); if (t == "") return
  HOOKPARSE = 0; WANT = "^/guard/"
  if (!jparse(t)) { CFGSTATE[src] = "invalid JSON, ignored"; return }
  CFGSTATE[src] = "ok"
  if (HASPP) { NPL = 0; for (i = 1; i <= NPP; i++) if (PPDEC[i] != "") PL[++NPL] = PPDEC[i]; PLSRC = src }
  if (HASBR) { NPB = 0; for (i = 1; i <= NBR; i++) if (BRDEC[i] != "") PB[++NPB] = BRDEC[i]; PBSRC = src }
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
      if (v == "deny" || v == "ask" || v == "off" || (id == "push" && v == "branches")) { MODE[id] = v; SRC[id] = src }
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
function endseg(d) { if (NW > 0 || RN[d, CS] > 0) { WC[d, CS] = NW; NSG[d]++; SEGS[d, NSG[d]] = CS } newseg() }
function flush(d) {
  if (HASW || WD != "") {
    if (HDNEXT) { HDN++; HD[HDN] = WD; HS[HDN] = HDSTRIPNEXT; HDNEXT = 0 }
    else if (SKIPNEXT) { if (SKIPOUT) { RN[d, CS]++; RD[d, CS, RN[d, CS]] = WD }; SKIPNEXT = 0 }
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
  n = length(cmd); SP = 0; WD = ""; HASW = 0; HDN = 0; HDNEXT = 0; SKIPNEXT = 0; SKIPOUT = 0; PD = 0; NSG[d] = 0
  newseg()
  for (i = 1; i <= n; i++) {
    c = substr(cmd, i, 1); m = (SP > 0) ? ST[SP] : "u"
    if (m == "s") { if (c == "\047") SP--; else WD = WD c; continue }
    if (m == "d") {
      if (c == "\"") { SP--; continue }
      if (PSM && c == "`") { nx = substr(cmd, i + 1, 1); i++; if (nx != "\n") WD = WD nx; continue }
      if (!PSM && c == "\\") {
        nx = substr(cmd, i + 1, 1)
        if (nx == "\"" || nx == "\\" || nx == "$" || nx == "`") { WD = WD nx; i++; continue }
        if (nx == "\n") { i++; continue }
        WD = WD c; continue
      }
      if (c == "$" && substr(cmd, i + 1, 1) == "(") { i++; push("c", d); continue }
      if (c == "`" && !PSM) { push("b", d); continue }
      WD = WD c; continue
    }
    if (c == "\047") { push("s", d); HASW = 1; continue }
    if (c == "\"") { push("d", d); HASW = 1; continue }
    if (PSM && c == "`") {
      nx = substr(cmd, i + 1, 1); i++
      if (nx == "\r" && substr(cmd, i + 1, 1) == "\n") i++
      else if (nx != "\n") { WD = WD nx; HASW = 1 }
      continue
    }
    if (c == "\\" && !PSM) { nx = substr(cmd, i + 1, 1); i++; if (nx != "\n") { WD = WD nx; HASW = 1 } continue }
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
        if (substr(cmd, i + 2, 1) == "<") { i += 2; SKIPNEXT = 1; SKIPOUT = 0; continue }
        i++; HDSTRIPNEXT = 0
        if (substr(cmd, i + 1, 1) == "-") { i++; HDSTRIPNEXT = 1 }
        HDNEXT = 1; continue
      }
      nx = substr(cmd, i + 1, 1)
      if (nx == ">" || nx == "|") { i++; nx = substr(cmd, i + 1, 1) }
      if (nx == "&") { i++; while (substr(cmd, i + 1, 1) ~ /[0-9-]/) i++; continue }
      SKIPNEXT = 1; SKIPOUT = (c == ">"); continue
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
  else if (MODE[id] == "ask" || MODE[id] == "branches") { if (ASKID == "") ASKID = id }
}
# ---------- branch-aware push rule (push mode "branches") ----------
function sq(s) { return "\047" s "\047" }
function safename(s) { return s != "" && s !~ /[^A-Za-z0-9._\/@+-]/ }
# current branch of the repository at dir (read-only git call, cached); "" when unknown or detached
function curbranch(dir,  cmd, b) {
  if (dir in CB) return CB[dir]
  b = ""
  if (dir != "" && index(dir, "\047") == 0) {
    cmd = "git -C " sq(dir) " symbolic-ref -q --short HEAD 2>/dev/null"
    if ((cmd | getline b) <= 0) b = ""
    close(cmd); sub(/\r$/, "", b)
  }
  CB[dir] = b
  return b
}
function tagexists(dir, name,  cmd) {
  if (dir == "" || index(dir, "\047") || !safename(name)) return 0
  cmd = "git -C " sq(dir) " show-ref -q --verify refs/tags/" name " 2>/dev/null"
  return system(cmd) == 0
}
function globre(g,  i, c, o) {
  o = ""
  for (i = 1; i <= length(g); i++) {
    c = substr(g, i, 1)
    if (c == "*") o = o ".*"
    else if (c == "?") o = o "."
    else if (index("\\.+^$|(){}[]", c)) o = o "\\" c
    else o = o c
  }
  return "^" o "$"
}
function isprot(b,  i) {
  for (i = 1; i <= NPB; i++) if (b ~ globre(PB[i])) return 1
  return 0
}
function pushnote(s) { if (PUSHINFO == "") PUSHINFO = s; hit("push") }
# one refspec (or branch name) of a push: ask when it targets a protected branch or a tag
function push_ref(r, dir,  dst, cb) {
  sub(/^\+/, "", r)
  dst = r
  if (index(r, ":")) { dst = r; sub(/^[^:]*:/, "", dst) }
  if (dst == "") return
  if (dst ~ /[*?]/) { pushnote("the refspec " r " may touch a protected branch"); return }
  if (dst ~ /^refs\/tags\//) { pushnote("pushing a tag (" r ")"); return }
  sub(/^refs\/heads\//, "", dst)
  if (dst == "HEAD") {
    cb = curbranch(dir)
    if (cb == "") { pushnote("the current branch could not be determined"); return }
    dst = cb
  }
  if (isprot(dst)) { pushnote("pushing to the protected branch " dst); return }
  if (index(r, ":") == 0 && tagexists(dir, dst)) pushnote("pushing the tag " dst)
}
# git push in "branches" mode: ask only for protected branches, tags, --all/--mirror, or when the target is unknown
function push_branches(d, id, k, nw, dir,  i, x, dd, npos, tags, bulk, cb, refs, nref, tagword) {
  dd = 0; npos = 0; nref = 0; tags = 0; bulk = 0; tagword = 0
  for (i = k; i <= nw; i++) {
    x = W[d, id, i]
    if (!dd && x == "--") { dd = 1; continue }
    if (!dd && x ~ /^--/) {
      if (x ~ /^--(tags|follow-tags)$/) tags = 1
      else if (x ~ /^--(all|mirror|branches)$/) bulk = 1
      else if (x ~ /^--(repo|receive-pack|exec|push-option)$/) i++
      continue
    }
    if (!dd && x ~ /^-./) {
      if (x ~ /^-[a-zA-Z]*o$/) i++
      continue
    }
    npos++
    if (npos == 2 && x == "tag") { tagword = 1; continue }
    if (npos >= 2) refs[++nref] = x
  }
  if (tags || tagword) { pushnote("pushing tags"); return }
  if (bulk) { pushnote("pushing all branches (--all/--mirror) includes the protected ones"); return }
  if (nref == 0) {
    cb = curbranch(dir)
    if (cb == "") pushnote("the current branch could not be determined")
    else if (isprot(cb)) pushnote("pushing the protected branch " cb)
    return
  }
  for (i = 1; i <= nref; i++) push_ref(refs[i], dir)
}
# merge / rebase / reset on a protected current branch (mode "branches" only)
function move_check(what, dir,  cb) {
  if (MODE["push"] != "branches") return
  cb = curbranch(dir)
  if (cb != "" && isprot(cb)) pushnote(what " moves the protected branch " cb)
}
function analyze(cmd, d,  s) {
  if (d > 3) return
  tokenize(cmd, d)
  for (s = 1; s <= NSG[d]; s++) seg(d, SEGS[d, s])
}
# ---------- protected paths ----------
function g2re(g,  out, i, c, n) {
  out = ""; n = length(g)
  for (i = 1; i <= n; i++) {
    c = substr(g, i, 1)
    if (c == "*") {
      if (substr(g, i + 1, 1) == "*") {
        i++
        if (substr(g, i + 1, 1) == "/") { i++; out = out "(.*/)?" } else out = out ".*"
      } else out = out "[^/]*"
    } else if (c == "?") out = out "[^/]"
    else if (index("\\.+(){}|^$[]", c)) out = out "\\" c
    else out = out c
  }
  return out
}
function pp_prepare(  i, g, anc, a, n, j, an) {
  PPON = 0
  if (MODE["protected-paths"] == "off" || NPL == 0) return
  for (i = 1; i <= NPL; i++) {
    g = PL[i]; gsub(/\\/, "/", g)
    if (WIN) g = tolower(g)
    sub(/^(\.\/)+/, "", g); an = (g ~ /^\//); sub(/^\/+/, "", g); sub(/\/+$/, "", g)
    if (g == "") { PRE[i] = "^$"; PANC[i] = ""; continue }
    if (index(g, "/")) an = 1
    PRE[i] = (an ? "^" : "^(.*/)?") g2re(g) "(/.*)?$"
    PANC[i] = ""
    if (an) {
      n = split(g, a, "/"); anc = ""
      for (j = 1; j <= n; j++) { if (a[j] ~ /[*?[]/) break; anc = anc (j > 1 ? "/" : "") a[j] }
      PANC[i] = anc
    }
  }
  PPON = 1
}
# target path relative to the project root; OUTSIDE (a control character, never part of a path) when outside it or unknown
function pp_rel(p,  r, bl, rl) {
  r = resolve(p); if (r == "" || PROJN == "") return OUTSIDE
  rl = r; bl = PROJN
  if (WIN) { rl = tolower(rl); bl = tolower(bl) }
  if (rl == bl) return ""
  if (bl !~ /\/$/) bl = bl "/"
  if (substr(rl, 1, length(bl)) == bl) return substr(rl, length(bl) + 1)
  return OUTSIDE
}
function pp_check(p, destr,  r, i) {
  if (!PPON || p == "") return
  r = pp_rel(p); if (r == OUTSIDE) return
  for (i = 1; i <= NPL; i++) {
    if (r != "" && r ~ PRE[i]) { pp_hit(p, i); return }
    if (destr && PANC[i] != "" && (r == "" || PANC[i] == r || substr(PANC[i], 1, length(r) + 1) == r "/")) { pp_hit(p, i); return }
  }
}
function pp_hit(p, i) { if (PPINFO == "") PPINFO = p " matches \"" PL[i] "\""; hit("protected-paths") }
# non-option arguments of one command into TG[1..TN] (after "--" everything is an argument)
function pp_args(d, id, k, nw,  i, x, dd) {
  TN = 0; dd = 0
  for (i = k; i <= nw; i++) {
    x = W[d, id, i]
    if (!dd && x == "--") { dd = 1; continue }
    if (!dd && x ~ /^-./) continue
    TG[++TN] = x
  }
}
function pp_all(destr,  i) { for (i = 1; i <= TN; i++) pp_check(TG[i], destr) }
function prot_cmd(cmd, d, id, k, nw,  i, x, sc, inplace, svcur, dd) {
  if (cmd ~ /^(rm|unlink|rmdir|rd|del|erase|ri|remove-item)$/) { pp_args(d, id, k, nw); pp_all(1) }
  else if (cmd ~ /^(mv|move|mi|move-item)$/) { pp_args(d, id, k, nw); pp_all(1) }
  else if (cmd ~ /^(cp|copy|cpi|copy-item)$/) { pp_args(d, id, k, nw); if (TN > 1) pp_check(TG[TN], 0) }
  else if (cmd ~ /^(tee|truncate)$/) { pp_args(d, id, k, nw); pp_all(0) }
  else if (cmd == "dd") { for (i = k; i <= nw; i++) if (W[d, id, i] ~ /^of=/) pp_check(substr(W[d, id, i], 4), 0) }
  else if (cmd == "sed") {
    inplace = 0
    for (i = k; i <= nw; i++) { x = W[d, id, i]; if (x == "--") break; if (x ~ /^--in-place/ || x ~ /^-i/ || (x ~ /^-[a-zA-Z]+$/ && x ~ /i/)) inplace = 1 }
    if (inplace) { pp_args(d, id, k, nw); pp_all(0) }
  }
  else if (cmd == "git") {
    svcur = CUR
    while (k <= nw) {
      x = W[d, id, k]
      if (x == "-C" && k < nw) { CUR = resolve(W[d, id, k + 1]); if (CUR == "") CUR = svcur; k += 2; continue }
      if (x ~ /^(-c|--git-dir|--work-tree|--namespace|--config-env|--super-prefix)$/) { k += 2; continue }
      if (x ~ /^-/) { k++; continue }
      break
    }
    if (k <= nw) {
      sc = W[d, id, k]; k++
      if (sc == "rm" || sc == "mv") { pp_args(d, id, k, nw); pp_all(1) }
      else if (sc == "restore") { pp_args(d, id, k, nw); pp_all(0) }
      else if (sc == "checkout") {
        dd = 0
        for (i = k; i <= nw; i++) { x = W[d, id, i]; if (!dd) { if (x == "--") dd = 1; continue }; pp_check(x, 0) }
      }
    }
    CUR = svcur
  }
}
function seg(d, id,  nw, k, x, cmd, j, str) {
  nw = WC[d, id]; k = 1
  if (PPON) for (j = 1; j <= RN[d, id]; j++) pp_check(RD[d, id, j], 0)
  while (k <= nw) {
    x = W[d, id, k]
    if (x ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { k++; continue }
    # wrappers: skip their options, including the argument of options that take one (sudo -u root)
    if (x == "sudo") { k = wopts(d, id, k + 1, nw, "ugCDhpURrtT", "^--(user|group|close-from|chdir|host|prompt|chroot|role|type|command-timeout|other-user)$"); continue }
    if (x == "doas") { k = wopts(d, id, k + 1, nw, "uC", ""); continue }
    if (x == "env") { k = wopts(d, id, k + 1, nw, "uCS", "^--(unset|chdir|split-string)$"); continue }
    if (x == "nice") { k = wopts(d, id, k + 1, nw, "n", "^--adjustment$"); continue }
    if (x == "time") { k = wopts(d, id, k + 1, nw, "fo", "^--(format|output)$"); continue }
    if (x == "exec") { k = wopts(d, id, k + 1, nw, "a", ""); continue }
    if (x == "stdbuf") { k = wopts(d, id, k + 1, nw, "ioe", "^--(input|output|error)$"); continue }
    if (x == "xargs") { k = wopts(d, id, k + 1, nw, "adEILnPs", "^--(arg-file|delimiter|max-args|max-procs|max-chars|process-slot-var)$"); continue }
    if (x == "timeout") { k = wopts(d, id, k + 1, nw, "sk", "^--(signal|kill-after)$") + 1; continue }
    if (x ~ /^(command|builtin|nohup|then|do|else|elif|if|while|until|!|\{|\})$/) { k = wopts(d, id, k + 1, nw, "", ""); continue }
    break
  }
  if (k > nw) return
  cmd = x; sub(/.*[\/\\]/, "", cmd); cmd = tolower(cmd); sub(/\.exe$/, "", cmd)
  if (PPON) prot_cmd(cmd, d, id, k + 1, nw)
  if (cmd == "git") git_seg(d, id, k + 1, nw)
  else if (PSM && cmd ~ /^(rm|remove-item|ri|del|erase|rd|rmdir)$/) ps_rm_seg(d, id, k + 1, nw)
  else if (PSM && cmd == "cmd") {
    # cmd /c "rd /s /q dir": check the command string (cmd.exe also keeps backslashes literal)
    for (j = k + 1; j <= nw; j++) if (tolower(W[d, id, j]) ~ /^\/[ck]$/) break
    str = ""; for (j++; j <= nw; j++) str = str " " W[d, id, j]
    if (str != "") analyze(str, d + 1)
  }
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
# skip a wrapper\047s options from word k; sa: short options that take an argument, la: regex of long ones
function wopts(d, id, k, nw, sa, la,  x, j, len) {
  while (k <= nw) {
    x = W[d, id, k]
    if (x == "--") return k + 1
    if (x !~ /^-/) return k
    k++
    if (x ~ /^--/) { if (la != "" && x ~ la) k++; continue }
    len = length(x)
    for (j = 2; j <= len; j++) if (index(sa, substr(x, j, 1))) { if (j == len) k++; break }
  }
  return k
}
function git_seg(d, id, k, nw,  x, sc, i, j, ch, len, force, dd, npos, noop, cdir, hard) {
  cdir = CUR
  while (k <= nw) {
    x = W[d, id, k]
    if (x == "-C" && k < nw) { cdir = resolve(W[d, id, k + 1]); k += 2; continue }
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
    if (force) hit("force-push")
    else if (MODE["push"] == "branches") push_branches(d, id, k, nw, cdir)
    else hit("push")
  } else if (sc == "reset") {
    npos = 0; hard = 0
    for (i = k; i <= nw; i++) {
      x = W[d, id, i]
      if (x == "--hard") { hit("history-rewrite"); hard = 1 }
      else if (x ~ /^--(soft|mixed|keep|merge)$/) hard = 1
      else if (x == "--") { npos = 99; break }
      else if (x !~ /^-/) npos++
    }
    if (hard || npos == 1) move_check("git reset", cdir)
  } else if (sc == "rebase") {
    for (i = k; i <= nw; i++) if (W[d, id, i] ~ /^--(abort|quit|show-current-patch)$/) return
    hit("history-rewrite"); move_check("git rebase", cdir)
  } else if (sc == "merge") {
    for (i = k; i <= nw; i++) if (W[d, id, i] ~ /^--(abort|quit)$/) return
    move_check("git merge", cdir)
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
# PowerShell / cmd.exe deletes: Remove-Item (ri, rm, del, erase, rd, rmdir) with -Recurse (any prefix: -r, -rec)
#   or /s; same policy as rm -rf: only protected roots are denied. Paths may be comma-separated.
#   -WhatIf, or a -Filter/-Include narrower than *, is not a wholesale delete.
function ps_rm_seg(d, id, k, nw,  i, x, n, rec, nt, tg, a, j, na, v) {
  rec = 0; nt = 0
  for (i = k; i <= nw; i++) {
    x = W[d, id, i]
    if (x ~ /^\/[A-Za-z]$/) { if (tolower(x) == "/s") rec = 1; continue }
    if (x ~ /^-[A-Za-z]/) {
      n = tolower(substr(x, 2)); sub(/:.*/, "", n)
      if (n == "whatif" || n == "wi") return
      if (index("recurse", n) == 1 || n ~ /^(rf|fr)$/) rec = 1
      else if (length(n) > 1 && (index("filter", n) == 1 || index("include", n) == 1 || index("exclude", n) == 1 || index("credential", n) == 1 || index("stream", n) == 1)) {
        v = (x ~ /:./) ? substr(x, index(x, ":") + 1) : W[d, id, ++i]
        if ((index("filter", n) == 1 || index("include", n) == 1) && v !~ /^\*(\.\*)?$/) return
      }
      else if (n ~ /^(path|literalpath|lp|pspath)$/ && x ~ /:./) { x = substr(x, index(x, ":") + 1); na = split(x, a, ","); for (j = 1; j <= na; j++) tg[++nt] = a[j] }
      continue
    }
    na = split(x, a, ","); for (j = 1; j <= na; j++) if (a[j] != "") tg[++nt] = a[j]
  }
  if (!rec) return
  for (i = 1; i <= nt; i++) if (danger_target(ps_path(tg[i]))) { hit("rm-rf-danger"); return }
}
# PowerShell path spelling to the form danger_target/resolve understand
function ps_path(p,  l) {
  gsub(/\\/, "/", p); l = tolower(p)
  if (l ~ /^\$(home|env:userprofile|env:home|\{env:userprofile\}|\{env:home\})(\/|$)/) { sub(/^[^\/]*/, "", p); p = "$HOME" p }
  else if (l ~ /^\$pwd(\/|$)/) p = "$PWD" substr(p, 5)
  return p
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
  if (id == "git-add-all") return "SubDeck guard (git-add-all): staging everything at once (git add -A/--all/-u/., git commit -a) can pick up unrelated, generated or secret files. Stage explicit paths (git add <file> ...) and commit with a pathspec (git commit -m \"...\" -- <paths>)."
  if (id == "force-push") return "SubDeck guard (force-push): a force push rewrites remote history. Push without --force/-f/--force-with-lease/+refspec, or ask the user to run it by hand."
  if (id == "push" && PUSHINFO != "") return "SubDeck guard (push): " PUSHINFO "; get the user\047s approval first (push mode branches: protected branches, tags and branch-moving merges/rebases/resets ask; other pushes are allowed)."
  if (id == "push") return "SubDeck guard (push): pushing publishes commits to the remote; get the user\047s approval first."
  if (id == "history-rewrite") return "SubDeck guard (history-rewrite): git reset --hard / rebase / filter-branch / filter-repo / clean -f discard or rewrite work; get the user\047s approval first."
  if (id == "rm-rf-danger") return "SubDeck guard (rm-rf-danger): this recursive delete targets /, a drive root, the home directory, the project root or one of their ancestors. Delete specific subdirectories instead."
  if (id == "secret-files") return "SubDeck guard (secret-files): this file looks like a secret (.env, key, certificate, credentials); get the user\047s approval before writing it."
  if (id == "attribution") return "SubDeck guard (attribution): the commit message contains an attribution line (Co-Authored-By / Generated with); remove it and commit again."
  if (id == "protected-paths") return "SubDeck guard (protected-paths): " PPINFO "; this path is listed in guard.protectedPaths; get the user\047s approval before editing, moving or deleting it."
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
  if (pf == "") pf = ENVIRON["SD_GUARD_PF"]; if (lf == "") lf = ENVIRON["SD_GUARD_LF"]
  if (pf == "" && PROJ != "") pf = PROJ "/.subdeck/config.json"
  WIN = (ENVIRON["OS"] == "Windows_NT" || cwd ~ /^[A-Za-z]:/ || PROJ ~ /^[A-Za-z]:/)
  initrules(); cfgfile(uf, "user"); if (lf != "" && lf != pf) cfgfile(lf, "project"); if (pf != "") cfgfile(pf, "project")
  if (!ENABLED) return
  HOMEN = norm(ENVIRON["HOME"]); PROJN = norm(PROJ); CUR = norm(cwd); if (CUR == "") CUR = PROJN
  DENYID = ""; ASKID = ""; PUSHINFO = ""; split("", CB); COMMIT = 0; NOPRES = 0; PPINFO = ""; pp_prepare()
  if (tool == "Bash" || tool == "PowerShell") {
    if (cmd == "") return
    # PowerShell: backtick is the escape character (no command substitution), backslash is a plain path separator
    PSM = (tool == "PowerShell")
    analyze(cmd, 0)
    if (COMMIT) { low = tolower(cmd); if (index(low, "co-authored-by") || index(low, "generated with")) hit("attribution") }
  } else if (tool == "Write" || tool == "Edit" || tool == "MultiEdit") {
    if (fp != "" && secret_path(fp)) hit("secret-files")
    pp_check(fp, 0)
  } else if (tool == "apply_patch") {
    # Codex patch text: file paths are on "*** Add|Update|Delete File: <path>" and "*** Move to: <path>" lines
    np = split(cmd, pl, "\n")
    for (pi = 1; pi <= np; pi++) {
      pp = pl[pi]; sub(/\r$/, "", pp)
      if (match(pp, /^\*\*\* (Add File|Update File|Delete File|Move to): /)) {
        pp = substr(pp, RLENGTH + 1)
        if (secret_path(pp)) hit("secret-files")
        pp_check(pp, 0)
      }
    }
  }
  if (DENYID != "") { dec = "deny"; id = DENYID } else if (ASKID != "") { dec = "ask"; id = ASKID } else return
  rs = reason(id) " To change this rule: /subdeck:settings set " id "=" othermodes(id)
  if (id == "push" && MODE["push"] == "branches") rs = rs " (or protect-branches=<glob>[,<glob>])"
  if (id == "protected-paths") rs = rs " (or unprotect=<glob>)"
  # Codex documents only deny for PreToolUse: an "ask" becomes a deny that tells the model to ask the user first
  if (dec == "ask" && ENVIRON["SUBDECK_TOOL"] == "codex") { dec = "deny"; rs = "Ask the user for approval first; retry only if they approve. " rs }
  if (ENVIRON["SUBDECK_TOOL"] == "copilot")
    # Copilot reads the decision at the top level; keep the Claude-shaped member too
    printf "{\"permissionDecision\":\"%s\",\"permissionDecisionReason\":\"%s\",\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"%s\",\"permissionDecisionReason\":\"%s\"}}\n", dec, jesc(rs), dec, jesc(rs)
  else
    printf "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"%s\",\"permissionDecisionReason\":\"%s\"}}\n", dec, jesc(rs)
}
# the modes a rule can be switched to from its current one, for the "To change this rule" hint
function othermodes(id,  all, n, a, i, r) {
  all = (id == "push") ? "ask branches off" : "deny ask off"
  n = split(all, a, " "); r = ""
  for (i = 1; i <= n; i++) if (a[i] != MODE[id]) r = r (r == "" ? "" : "|") a[i]
  return r
}
function do_show(  i, id, e) {
  if (pf == "") pf = ENVIRON["SD_GUARD_PF"]; if (lf == "") lf = ENVIRON["SD_GUARD_LF"]
  initrules(); cfgfile(uf, "user"); LST = "absent"
  if (lf != "" && lf != pf) { cfgfile(lf, "project"); LST = CFGSTATE["project"] }
  cfgfile(pf, "project")
  print "SubDeck guard (defaults < user < project)"
  e = ENVIRON["SUBDECK_GUARD"]
  printf "enabled: %s (%s)\n", ENABLED ? "yes" : "no", ENSRC
  if (e == "0" || e == "off" || e == "false" || e == "no") print "note: SUBDECK_GUARD=" e " in this environment disables the guard entirely"
  printf "%-16s %-8s %s\n", "RULE", "MODE", "SOURCE"
  for (i = 1; i <= NRULE; i++) { id = RID[i]; printf "%-16s %-8s %s\n", id, MODE[id], SRC[id] }
  if (UNK != "") print "unknown (ignored): " UNK
  e = ""; for (i = 1; i <= NPL; i++) e = e (i > 1 ? "," : "") PL[i]
  if (NPL == 0) print "protectedPaths: (none)"
  else printf "protectedPaths (%s): %s\n", PLSRC, e
  e = ""; for (i = 1; i <= NPB; i++) e = e (i > 1 ? "," : "") PB[i]
  if (NPB == 0) print "protectBranches: (none)"
  else printf "protectBranches (%s): %s\n", PBSRC, e
  print ""
  printf "user file:    %s (%s)\n", uf, CFGSTATE["user"]
  printf "project file: %s (%s)\n", pf, CFGSTATE["project"]
  if (LST != "absent") printf "legacy file:  %s (%s; still read, the project file wins; remove it by hand when no longer needed)\n", lf, LST
}
function do_dump(  t, i, id, v) {
  t = slurp(f); if (t == "") return
  HOOKPARSE = 0; WANT = "^/guard/"
  if (!jparse(t)) { print "ERR"; return }
  initrules()
  for (i = 1; i <= NRK; i++) if (!isknown(RKD[i])) print "unknown\t" RKR[i] "\t" RKV[i]
  for (i = 1; i <= NPP; i++) if (PPDEC[i] != "") print "protect\t" PPRAW[i]
  if (HASBR) { print "branches-set"; for (i = 1; i <= NBR; i++) if (BRDEC[i] != "") print "branch\t" BRRAW[i] }
  if ("/guard/enabled" in V) {
    v = tolower(V["/guard/enabled"])
    if (v == "false" || v == "0" || v == "off" || v == "no") print "enabled false"
    else if (v == "true" || v == "1" || v == "on" || v == "yes") print "enabled true"
  }
  for (i = 1; i <= NRULE; i++) {
    id = RID[i]
    if (("/guard/rules/" id) in V) { v = tolower(V["/guard/rules/" id]); if (v == "deny" || v == "ask" || v == "off" || (id == "push" && v == "branches")) print "rule " id " " v }
  }
}
BEGIN {
  OUTSIDE = sprintf("%c", 1)
  if (mode == "hook") do_hook()
  else if (mode == "show") do_show()
  else if (mode == "dump") do_dump()
  exit 0
}
'

# ---------- hook mode ----------
if [ $# -eq 0 ] || [ "$1" = hook ]; then
  # project config paths (new state dir + legacy <project>/.subdeck) are computed here and passed via ENVIRON
  # (awk -v would mangle backslashes). Without CLAUDE_PROJECT_DIR the payload's cwd is needed first, so stdin
  # is read by the bash builtin and handed to awk as a here-string; otherwise awk reads stdin directly.
  GP="${CLAUDE_PROJECT_DIR:-}"; GIN=""; GREAD=0
  if [ -z "$GP" ]; then
    IFS= read -r -d '' GIN 2>/dev/null; GREAD=1
    BS=$'\134'; re="\"cwd\"[[:space:]]*:[[:space:]]*\"(([^\"$BS$BS]|$BS$BS.)*)\""
    if [[ $GIN =~ $re ]]; then GP="${BASH_REMATCH[1]}"; GP="${GP//"$BS$BS"//}"; GP="${GP//"$BS"//}"; fi
  fi
  SD_GUARD_PF=""; SD_GUARD_LF=""
  GH="${BASH_SOURCE[0]%[/\\]*}"; [ "$GH" = "${BASH_SOURCE[0]}" ] && GH="."
  if [ -n "$GP" ] && . "$GH/lib-paths.sh" 2>/dev/null; then
    sd_state_dir "$GP"; SD_GUARD_PF="$SD_STATE/config.json"; SD_GUARD_LF="$SD_LEGACY/config.json"
  fi
  export SD_GUARD_PF SD_GUARD_LF
  if [ "$GREAD" = 1 ]; then awk -v mode=hook "$GUARD_AWK" <<< "$GIN" 2>/dev/null
  else awk -v mode=hook "$GUARD_AWK" 2>/dev/null; fi
  exit 0
fi

# ---------- settings mode ----------
[ "$1" = cli ] && shift
CMD=""; SCOPE=user; PROJECT=""; PAIRS=(); BADARGS=(); PLIST=""; PADD=(); PDEL=()
for a in "$@"; do
  a="${a%$'\r'}"
  # protect/unprotect take one positional glob list (a glob may look like a directory name)
  if { [ "$CMD" = protect ] || [ "$CMD" = unprotect ] || [ "$CMD" = push ] || [ "$CMD" = branches ]; } && [ -z "$PLIST" ] && [ -n "$a" ] && [[ "$a" != --* ]] && { { [ "$CMD" != push ] && [ "$CMD" != branches ]; } || { [[ "$a" != /* ]] && [[ "$a" != [A-Za-z]:* ]]; }; }; then PLIST="$a"; continue; fi
  case "$a" in
    "") ;;
    --project) SCOPE=project ;;
    --*) BADARGS+=("$a") ;;
    show|set|on|off|reset|protect|unprotect|push|branches) if [ -z "$CMD" ]; then CMD="$a"; else BADARGS+=("$a"); fi ;;
    *=*) PAIRS+=("$a") ;;
    *) if [ -d "$a" ]; then PROJECT="$a"; else BADARGS+=("$a"); fi ;;
  esac
done
[ -n "$CMD" ] || CMD=show
[ -n "$PROJECT" ] || PROJECT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
UFILE="${HOME}/.subdeck/config.json"
HERE="${BASH_SOURCE[0]%[/\\]*}"; [ "$HERE" = "${BASH_SOURCE[0]}" ] && HERE="."
LFILE="$PROJECT/.subdeck/config.json"   # legacy project config: still read (new file wins), never written
PFILE="$LFILE"; . "$HERE/lib-paths.sh" 2>/dev/null && { sd_state_dir "$PROJECT"; PFILE="$SD_STATE/config.json"; }
[ "$LFILE" = "$PFILE" ] && LFILE=""
if [ "$SCOPE" = project ]; then TARGET="$PFILE"; else TARGET="$UFILE"; fi

show() {
  SD_GUARD_PF="$PFILE" SD_GUARD_LF="$LFILE" awk -v mode=show -v uf="$UFILE" "$GUARD_AWK" < /dev/null
  echo "Usage: /subdeck:settings set guard=on|off <rule>=deny|ask|off protect=<glob>[,<glob>] unprotect=<glob> [--project] (low-level: guard.sh set push=off attribution=deny [--project] | on | off | reset | protect GLOBS | unprotect GLOBS)"
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

BRREPLACE=0; BRNEW=()
valid_rule() { case " $RULES " in *" $1 "*) return 0 ;; esac; return 1; }

# update ENABLED(true|false|keep) [rule=mode ...]: merge into TARGET's guard member.
update() {
  local TAB=$'\t' BRS=0 bl="" unk="" en="$1" cur others dump line en_cur="" rules="" id m kv g="" rj="" pl="" pitem pdup; local -a PPL=() BRL=()
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
      protect$TAB*) PPL+=("${line#protect$TAB}") ;;
      branches-set) BRS=1 ;;
      branch$TAB*) BRL+=("${line#branch$TAB}") ;;
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
  # protectedPaths: existing raw entries minus PDEL, plus PADD (exact, no duplicates)
  for pitem in "${PPL[@]}"; do
    pdup=0; for kv in "${PDEL[@]}"; do [ "$kv" = "$pitem" ] && pdup=1; done
    [ $pdup -eq 0 ] && pl="$pl,\"$pitem\""
  done
  for kv in "${PADD[@]}"; do
    case ",$pl," in *",\"$kv\","*) ;; *) pl="$pl,\"$kv\"" ;; esac
  done
  [ -n "$pl" ] && g="$g${g:+,}\"protectedPaths\":[${pl#,}]"
  if [ $BRREPLACE -eq 1 ]; then for kv in "${BRNEW[@]}"; do bl="$bl,\"$kv\""; done; BRS=1
  else for kv in "${BRL[@]}"; do bl="$bl,\"$kv\""; done; fi
  [ $BRS -eq 1 ] && g="$g${g:+,}\"protectBranches\":[${bl#,}]"
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
      else case "$v" in deny|ask|off) NEW+=("$k=$v") ;; branches) if [ "$k" = push ]; then NEW+=("$k=$v"); else echo "error: invalid mode '$v' for $k (valid: deny, ask, off)"; ERR=1; fi ;; *) echo "error: invalid mode '$v' for $k (valid: deny, ask, off; push also: branches)"; ERR=1 ;; esac; fi
    done
    if [ $ERR -ne 0 ]; then echo "nothing written."; exit 0; fi
    update keep "${NEW[@]}"
    echo; show ;;
  push)
    V="$(printf '%s' "$PLIST" | tr 'A-Z' 'a-z')"
    case "$V" in
      ask|branches|off) update keep "push=$V"; echo; show ;;
      *) echo "error: usage: push <ask|branches|off> [--project] (got '$PLIST'); nothing written." ;;
    esac ;;
  branches)
    ERR=0; IFS=',' read -ra ITEMS <<< "$PLIST"
    for it in "${ITEMS[@]}"; do
      it="${it#"${it%%[![:space:]]*}"}"; it="${it%"${it##*[![:space:]]}"}"
      [ -n "$it" ] || continue
      case "$it" in *\"*|*\\*|*[[:cntrl:]]*) echo "error: invalid branch pattern '$it' (no quotes, backslashes or control characters)"; ERR=1; continue ;; esac
      BRNEW+=("$it")
    done
    if [ $ERR -ne 0 ] || [ ${#BRNEW[@]} -eq 0 ]; then echo "error: usage: branches <glob>[,<glob>] [--project] (e.g. main,release/*); nothing written."; exit 0; fi
    BRREPLACE=1; update keep; echo; show ;;
  protect|unprotect)
    if [ -z "$PLIST" ]; then echo "error: $CMD needs a glob list, e.g. $CMD 'CLAUDE.md,migrations/**'"; exit 0; fi
    ERR=0; IFS=',' read -ra ITEMS <<< "$PLIST"
    for it in "${ITEMS[@]}"; do
      it="${it//\\//}"; it="${it#"${it%%[![:space:]]*}"}"; it="${it%"${it##*[![:space:]]}"}"
      [ -n "$it" ] || continue
      case "$it" in *\"*|*[[:cntrl:]]*) echo "error: invalid glob '$it' (no quotes or control characters)"; ERR=1; continue ;; esac
      if [ "$CMD" = protect ]; then PADD+=("$it"); else PDEL+=("$it"); fi
    done
    if [ $ERR -ne 0 ] || [ $((${#PADD[@]} + ${#PDEL[@]})) -eq 0 ]; then echo "nothing written."; exit 0; fi
    if [ "$CMD" = unprotect ] && [ -f "$TARGET" ] && ! tr -d '\r' < "$TARGET" | grep -qF -- "\"${PDEL[0]}\""; then
      echo "note: '${PDEL[0]}' is not in $TARGET (check with: show); other scope files are not changed"
    fi
    update keep
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
