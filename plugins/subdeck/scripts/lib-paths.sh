# SubDeck shared path helpers (sourced by the other scripts; not run on its own). Bash 3.2+, no forks
# except one `pwd -W` on Windows for a non-drive MSYS path such as /tmp.
#
# Per-project state (events, notify log, status-line cache, project config) lives outside the project:
#   ${SUBDECK_STATE_DIR:-${SUBDECK_HOME:-$HOME}/.subdeck/projects}/<key>/
# <key> = <sanitised basename>-<fnv1a32 hex of the normalised path>. The same algorithm is implemented in
# desk/lib/paths.mjs (stateKey); desk/test/fixtures/state-keys.txt pins both to the same results.
# Normalisation: \ -> /; on Windows /c/x and /cygdrive/c/x -> c:/x; drive letter lower case; empty and "."
# segments dropped, ".." resolved (never above the root); no trailing slash; on Windows the whole path is
# lower-cased (ASCII only). Hash and basename work on the UTF-8 bytes.
# Legacy location <project>/.subdeck/ is still read (events merged; project config: new location wins).

# sd_platform -> SD_PLAT (win|posix)
sd_platform() {
  case "$OSTYPE" in msys*|cygwin*|win32*) SD_PLAT=win ;; *) SD_PLAT=posix ;; esac
}

# sd_lower STR -> SD_LOWER (ASCII lower case, bash 3.2 compatible)
sd_lower() {
  local s="$1" out="" c i LC_ALL=C
  if [ "${BASH_VERSINFO[0]:-3}" -ge 4 ]; then eval 'SD_LOWER="${s,,}"'; return 0; fi
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      A) c=a ;; B) c=b ;; C) c=c ;; D) c=d ;; E) c=e ;; F) c=f ;; G) c=g ;; H) c=h ;; I) c=i ;; J) c=j ;;
      K) c=k ;; L) c=l ;; M) c=m ;; N) c=n ;; O) c=o ;; P) c=p ;; Q) c=q ;; R) c=r ;; S) c=s ;; T) c=t ;;
      U) c=u ;; V) c=v ;; W) c=w ;; X) c=x ;; Y) c=y ;; Z) c=z ;;
    esac
    out="$out$c"
  done
  SD_LOWER="$out"
}

# sd_norm_path PATH [win|posix] -> SD_NORM (empty for an empty PATH)
sd_norm_path() {
  local p="$1" plat="$2" pre="" seg n out="" i LC_ALL=C
  local -a st
  st=()
  [ -n "$plat" ] || { sd_platform; plat="$SD_PLAT"; }
  SD_NORM=""
  [ -n "$p" ] || return 0
  p="${p//\\//}"
  if [ "$plat" = win ]; then
    if [[ $p =~ ^/cygdrive/([A-Za-z])(/.*)?$ ]]; then p="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
    elif [[ $p =~ ^/([A-Za-z])(/.*)?$ ]]; then p="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"; fi
  fi
  if [[ $p =~ ^([A-Za-z]): ]]; then sd_lower "${BASH_REMATCH[1]}"; pre="$SD_LOWER:/"; p="${p:2}"
  elif [ "$plat" = win ] && [ "${p:0:2}" = // ]; then pre="//"; p="${p:2}"
  elif [ "${p:0:1}" = / ]; then pre="/"; p="${p:1}"
  fi
  while [ -n "$p" ]; do
    seg="${p%%/*}"
    if [ "$seg" = "$p" ]; then p=""; else p="${p#*/}"; fi
    n=${#st[@]}
    case "$seg" in
      ""|.) ;;
      ..)
        if [ "$n" -gt 0 ] && [ "${st[n-1]}" != .. ]; then unset "st[$((n - 1))]"
        elif [ -z "$pre" ]; then st[n]=..; fi ;;
      *) st[n]="$seg" ;;
    esac
  done
  for ((i = 0; i < ${#st[@]}; i++)); do out="$out${out:+/}${st[i]}"; done
  out="$pre$out"
  [ -n "$out" ] || out="."
  if [ "$plat" = win ]; then sd_lower "$out"; out="$SD_LOWER"; fi
  SD_NORM="$out"
}

# sd_project_key PATH [win|posix] -> SD_KEY (empty for an empty PATH)
sd_project_key() {
  local s name h=2166136261 b i LC_ALL=C
  SD_KEY=""
  sd_norm_path "$1" "$2"
  s="$SD_NORM"
  [ -n "$s" ] || return 0
  name="${s%/}"; name="${name##*/}"
  case "$name" in ""|.|*:) name=root ;; esac
  name="${name//[^A-Za-z0-9._-]/_}"; name="${name:0:32}"
  for ((i = 0; i < ${#s}; i++)); do
    printf -v b '%d' "'${s:i:1}"
    h=$(( ((h ^ (b & 255)) * 16777619) & 0xFFFFFFFF ))
  done
  printf -v SD_KEY '%s-%08x' "$name" "$h"
}

# sd_state_root -> SD_ROOT
sd_state_root() {
  if [ -n "${SUBDECK_STATE_DIR:-}" ]; then SD_ROOT="${SUBDECK_STATE_DIR%/}"
  else SD_ROOT="${SUBDECK_HOME:-$HOME}/.subdeck/projects"; fi
}

# sd_state_dir PROJECT -> SD_STATE (new per-project state dir, not created) and SD_LEGACY (<project>/.subdeck)
sd_state_dir() {
  local p="$1" w
  SD_LEGACY="${p%/}/.subdeck"
  sd_platform
  # MSYS/Cygwin paths without a drive (/tmp, /home/x) are resolved to their Windows form first
  if [ "$SD_PLAT" = win ] && [ "${p:0:1}" = / ] && [ "${p:1:1}" != / ] && ! [[ $p =~ ^/[A-Za-z](/|$) ]] \
     && ! [[ $p =~ ^/cygdrive/[A-Za-z](/|$) ]] && [ -d "$p" ]; then
    w="$(cd "$p" 2>/dev/null && pwd -W 2>/dev/null)" && [ -n "$w" ] && p="$w"
  fi
  sd_project_key "$p" "$SD_PLAT"
  sd_state_root
  SD_STATE="$SD_ROOT/$SD_KEY"
}
