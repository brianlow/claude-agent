#!/usr/bin/env bash
# verify-browser.sh [profile.sb] — assert the security property of the SECOND
# sandbox, the one CloakBrowser runs in.
#
#   ./verify-browser.sh                      # generated/sbx-browser.sb
#   ./verify-browser.sh path/to/profile.sb
#
# The browser profile is the permissive one: it holds WindowServer and
# LaunchServices, which the agent profile deliberately withholds. Its value is
# therefore entirely in what it does NOT hold, and that needs asserting rather
# than assuming — this file is the assertion.
#
# Two things it checks that verify.sh does not:
#
#   1. METADATA, not just content. (deny file-read*) does NOT cover
#      file-read-metadata in Seatbelt — verified — so a profile can deny every
#      byte of the vault and still let this sandbox enumerate it. Both are
#      tested per path, separately, because they fail separately.
#   2. That granting LaunchServices did not re-open the rev-04 escape.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/fleet-common.sh"

PROFILE="${1:-${BROWSER_PROFILE}}"
[ -f "$PROFILE" ] || PROFILE="${HERE}/profiles/$PROFILE"
[ -f "$PROFILE" ] || { echo "no such profile: $PROFILE" >&2; exit 1; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }

sbx() { sandbox-exec -f "$PROFILE" "$@" >/dev/null 2>&1; }

# A secret must be unreadable AND unenumerable.
deny_all() {
  local path="$1" label="$2"
  if sbx /bin/cat "$path"; then bad "$label — CONTENT readable"; else ok "$label — content denied"; fi
  if sbx /bin/ls -ld "$path"; then bad "$label — METADATA readable"; else ok "$label — metadata denied"; fi
}

echo "=== browser profile: $(basename "$PROFILE")"
echo
echo "--- secrets must be entirely out of reach"
deny_all "${VAULT}"                        "vault"
deny_all "${BEAR_DIR}"                     "Bear"
deny_all "${HOME}/Library/Keychains"       "login keychain"
deny_all "${HOME}/.gcalcli"                "gcalcli creds"
deny_all "${HOME}/.ssh"                    "~/.ssh"
deny_all "${HOME}/.claude"                 "~/.claude"
deny_all "${HOME}/dev"                     "~/dev"
deny_all "${HOME}/Documents"               "~/Documents"

echo
echo "--- LaunchServices is granted here; the escape must still be shut"
# This is the rev-04 confused-deputy hole. This profile DOES hold
# launchservicesd (the browser abort()s without it), so `open` and `osascript`
# being exec-denied is the only thing standing between a compromised browser
# process and an unconfined GUI app.
if sbx /usr/bin/open -a Calculator;                                  then bad "open -a launched an unconfined app"; else ok "open -a denied"; fi
if sbx /usr/bin/osascript -e 'tell application "Finder" to get name'; then bad "osascript drove Finder";             else ok "osascript denied"; fi
if sbx /usr/bin/sudo -n true;                                        then bad "sudo exec allowed";                   else ok "sudo denied"; fi

echo
echo "--- the browser itself must still work"
CB="$(cloak_bin)"
if [ -z "$CB" ]; then
  printf '  \033[33mn/a\033[0m   CloakBrowser not installed — run: cloakbrowser install\n'
else
  if sbx "$CB" --version; then ok "CloakBrowser binary runs under the profile"
  else bad "CloakBrowser cannot start — profile is too tight"; fi
fi

echo
echo "=== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
