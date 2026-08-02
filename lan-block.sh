#!/usr/bin/env bash
# lan-block.sh [install|uninstall|status|test] — fence every Apple Container off
# the home LAN while leaving the internet reachable.
#
# Apple Container has no egress policy of its own (`container run` exposes only
# --network / --dns), so this is enforced on the host with pf. Needs root for
# install/uninstall; status and test don't.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

ANCHOR_NAME="claude-agent"
ANCHOR_SRC="${SCRIPT_DIR}/pf/claude-agent.pf"
ANCHOR_DST="/etc/pf.anchors/${ANCHOR_NAME}"
PF_CONF="/etc/pf.conf"
DAEMON_LABEL="com.brianlow.claude-agent.lan-block"
DAEMON_PLIST="/Library/LaunchDaemons/${DAEMON_LABEL}.plist"
MARKER="# ${ANCHOR_NAME}: container LAN fence"

need_root() {
  [ "$(id -u)" -eq 0 ] || { echo "run with sudo: sudo $0 $1" >&2; exit 1; }
}

install_anchor() {
  need_root install
  install -m 0644 "${ANCHOR_SRC}" "${ANCHOR_DST}"

  # pf.conf is Apple's file and gets replaced by OS updates, so append (never
  # rewrite) and keep it idempotent — re-running install must not stack lines.
  if ! grep -q "${MARKER}" "${PF_CONF}"; then
    cp -p "${PF_CONF}" "${PF_CONF}.bak-$(date +%Y%m%dT%H%M%SZ)"
    cat >> "${PF_CONF}" <<EOF

${MARKER} — see ~/dev/claude-agent/pf/claude-agent.pf
anchor "${ANCHOR_NAME}"
load anchor "${ANCHOR_NAME}" from "${ANCHOR_DST}"
EOF
  fi

  # pf is off by default on macOS and doesn't survive a reboot on its own.
  cat > "${DAEMON_PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${DAEMON_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/sbin/pfctl</string>
        <string>-E</string>
        <string>-f</string>
        <string>${PF_CONF}</string>
    </array>
    <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
  chown root:wheel "${DAEMON_PLIST}"
  chmod 0644 "${DAEMON_PLIST}"
  launchctl bootout "system/${DAEMON_LABEL}" &>/dev/null || true
  launchctl bootstrap system "${DAEMON_PLIST}"

  # `pfctl -f /etc/pf.conf` reloads the *main* ruleset, which silently discards
  # the NAT rules Apple Container's vmnet service installed at `container system
  # start` — containers keep DNS (that's the bridge) but lose all egress. So
  # only do the full load when the anchor isn't in the running ruleset yet;
  # after that, load into the anchor alone, which leaves NAT untouched.
  if pfctl -s Anchors 2>/dev/null | grep -q "${ANCHOR_NAME}"; then
    pfctl -a "${ANCHOR_NAME}" -f "${ANCHOR_DST}" 2>&1 | sed 's/^/  pf: /'
    echo "rules reloaded into the existing anchor; container NAT untouched."
  else
    pfctl -E -f "${PF_CONF}" 2>&1 | sed 's/^/  pf: /'
    cat <<'WARN'

  NOTE: that was a full pf reload, which drops Apple Container's NAT rules.
  Any running container has just lost its internet (DNS still resolves, which
  makes it look like something else). Put it back with:

      container system stop && container system start
      ./hermes/hermes-run.sh     # launchd restarts agent-1..5 on its own

WARN
  fi
  echo "verify with: ${SCRIPT_DIR}/lan-block.sh test"
}

uninstall_anchor() {
  need_root uninstall
  launchctl bootout "system/${DAEMON_LABEL}" &>/dev/null || true
  rm -f "${DAEMON_PLIST}" "${ANCHOR_DST}"
  if grep -q "${MARKER}" "${PF_CONF}"; then
    # Drop the marker line and the two lines that follow it.
    sed -i '' "/${MARKER}/,+2d" "${PF_CONF}"
  fi
  # Flushing our anchor is enough to lift the block and, unlike reloading
  # pf.conf, doesn't take Apple Container's NAT with it. The stale anchor
  # reference left in the running ruleset is inert once empty.
  pfctl -a "${ANCHOR_NAME}" -F rules 2>&1 | sed 's/^/  pf: /'
  echo "uninstalled (pf left enabled; disable entirely with: sudo pfctl -d)"
}

show_status() {
  printf 'pf:      '
  pfctl -s info 2>/dev/null | head -1 || echo "unreadable (try sudo)"
  printf 'daemon:  '
  launchctl print "system/${DAEMON_LABEL}" &>/dev/null && echo "loaded" || echo "not loaded"
  printf 'anchor:  '
  [ -f "${ANCHOR_DST}" ] && echo "${ANCHOR_DST}" || echo "absent"
  echo 'rules:'
  pfctl -a "${ANCHOR_NAME}" -s rules 2>/dev/null | sed 's/^/  /' || echo "  (try sudo)"
}

# End-to-end check from inside a real container: the LAN must fail, the
# internet must not. Uses whichever container is running.
run_test() {
  local name
  name="$(container list --format json 2>/dev/null \
    | jq -r '[.[] | select(.status=="running") | .configuration.id][0] // empty')"
  [ -n "${name}" ] || { echo "no running container to test from" >&2; exit 1; }
  echo "testing from ${name}:"
  # curl still prints the -w line on timeout (000) and then exits non-zero, so
  # swallow the status and read 000 as "no answer".
  container exec "${name}" sh -c '
    probe() { curl -s -m 5 -o /dev/null -w "$2=%{http_code}\n" "$1" 2>/dev/null || true; }
    probe http://192.168.1.1/          "  lan-router"
    probe http://192.168.1.90:2128/    "  lan-apex"
    probe https://example.com          "  internet"
    getent hosts example.com >/dev/null 2>&1 && echo "  dns=ok" || echo "  dns=FAIL"
  '
  echo "  want: lan-* = 000, internet = 200, dns = ok"
  echo "  (internet=000 with dns=ok means the NAT rules were flushed — see install)"
}

case "${1:-status}" in
  install)   install_anchor ;;
  uninstall) uninstall_anchor ;;
  status)    show_status ;;
  test)      run_test ;;
  *) echo "usage: $0 [install|uninstall|status|test]" >&2; exit 1 ;;
esac
