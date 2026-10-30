# Dedicated-simulator helpers, sourced by scripts/smoke-test.sh and ./ui-test.sh.
#
# Each run targets a device dedicated to one app and one purpose, named after
# the app's bundle id (`Smoke — <bundle id>`, `UI — <bundle id>`). Selecting
# whichever simulator happened to be booted let two apps scaffolded from this
# template share a device, so app B installed onto app A's simulator and every
# assertion read app A's UI (#2971). The bundle id is the identity two apps on
# one machine can never share, and it reads clearly in the Simulator's list.
#
# The caller defines `log` and `fail` (both write to stderr) before sourcing.
# Nothing here writes to stdout except the values the functions return.

# Echo "<udid> <state>" for the device named $1, or nothing when this machine
# has no such device. A Booted match wins, so a name that exists on more than
# one runtime resolves to the one already running. The name is passed through
# the environment rather than interpolated into the Python source: it carries
# a bundle id and whatever the caller's override was set to.
sim_by_name() {
    xcrun simctl list devices available -j \
        | SIM_LOOKUP_NAME="$1" python3 -c "
import json, os, sys
name = os.environ['SIM_LOOKUP_NAME']
devices = json.load(sys.stdin)['devices'].values()
matches = [d for dl in devices for d in dl if d.get('name') == name]
for d in sorted(matches, key=lambda d: d.get('state') != 'Booted'):
    print(d['udid'], d.get('state', ''))
    break
" 2>/dev/null
}

# boot_simulator <name> <base device type> <override variable for the base>
#
# Echo the UDID of the device named <name>, creating it from <base device type>
# on first use and booting it when it isn't already running. Selection is by
# name alone, so another app's booted device is never adopted and re-runs stay
# on the same device (#2971). The third argument names the environment
# variable that overrides the base, for the hint when creation fails.
boot_simulator() {
    local name="$1" base="$2" base_var="$3"
    local udid state
    read -r udid state <<<"$(sim_by_name "$name")"
    if [ -z "${udid:-}" ]; then
        log "Creating simulator '$name' ($base)..."
        # Checked explicitly for the same reason the boot below is: a failed
        # create in a command substitution does not stop the run, and an empty
        # UDID reaches `simctl install`/`launch` as "the booted device" — the
        # wrong-device failure this whole function exists to prevent (#2971).
        local create_err create_status=0
        create_err="$(mktemp)"
        udid=$(xcrun simctl create "$name" "$base" 2>"$create_err") \
            || create_status=$?
        if [ "$create_status" != "0" ] || [ -z "${udid:-}" ]; then
            fail "Could not create simulator '$name' from device type '$base'."
            while IFS= read -r line; do log "  $line"; done <"$create_err"
            log "  Set $base_var to a device type this Xcode has"
            log "  (see: xcrun simctl list devicetypes)."
            rm -f "$create_err"
            return 1
        fi
        rm -f "$create_err"
        state="Shutdown"
    fi
    if [ "$state" != "Booted" ]; then
        log "Booting '$name' ($udid)..."
        # Checked explicitly: this function runs inside a command substitution,
        # which does not inherit `set -e`, so a failed boot would otherwise fall
        # through and echo a UDID nothing is running on.
        if ! xcrun simctl boot "$udid"; then
            fail "Could not boot simulator '$name' ($udid)."
            return 1
        fi
        open -ga Simulator
    fi
    echo "$udid"
}
