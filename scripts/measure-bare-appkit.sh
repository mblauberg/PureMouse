#!/bin/zsh
# The comparison column of docs/companion.md, "Footprint": what a bare AppKit status item with a
# five-item NSMenu costs on this Mac, after the same opens as scripts/measure-menu.sh, in MB of
# physical footprint. It runs a UI process, so use it only where measure-menu.sh may run (a spare
# Mac with a desktop session, never the one whose PureMouse you use).
#
#   scripts/measure-bare-appkit.sh [RUNS]     (default 5)
#
# Prints one line per run: fresh, open-1, open-3 and open-10, then the medians.
set -euo pipefail
TRAPZERR() { exit 2 }
cd "${0:A:h}/.."
runs=${1:-5}
dir=$PWD/.build/rig; mkdir -p $dir
cat > $dir/bare.swift <<'SWIFT'
import AppKit
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.title = "M"
    let menu = NSMenu()
    for title in ["One", "Two", "Three", "Four", "Five"] { menu.addItem(withTitle: title, action: nil, keyEquivalent: "") }
    item.menu = menu
    signal(SIGUSR1, SIG_IGN)  // SIGUSR1 opens the menu for 0.6 s
    let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    source.setEventHandler {
        MainActor.assumeIsolated {
            RunLoop.main.add(Timer(timeInterval: 0.6, repeats: false) { _ in MainActor.assumeIsolated { menu.cancelTracking() } }, forMode: .common)
            item.button?.performClick(nil)
        }
    }
    source.resume()
    app.run()
}
SWIFT
swiftc -O $dir/bare.swift -o $dir/bare
mb() { footprint -f bytes --noCategories $1 | awk '$1 == "phys_footprint:" { printf "%.2f", $2 / 1048576 }'; }
rows=()
for run in {1..$runs}; do
    $dir/bare & pid=$!
    sleep 3; fresh=$(mb $pid)
    kill -USR1 $pid; sleep 2; one=$(mb $pid)
    for i in 2 3; do kill -USR1 $pid; sleep 1.5; done; sleep 1.5; three=$(mb $pid)
    for i in {4..10}; do kill -USR1 $pid; sleep 1.5; done; sleep 1.5; ten=$(mb $pid)
    kill $pid; wait $pid 2>/dev/null || true
    print "run $run: fresh $fresh open-1 $one open-3 $three open-10 $ten"
    rows+=("$fresh $one $three $ten")
done
print -l $rows | awk '{ for (i = 1; i <= NF; i++) v[i, NR] = $i; n = NR }
    END { split("fresh open-1 open-3 open-10", name)
          for (i = 1; i <= 4; i++) {
              for (a = 1; a <= n; a++) x[a] = v[i, a] + 0
              for (a = 2; a <= n; a++) { t = x[a]; b = a - 1; while (b >= 1 && x[b] > t) { x[b + 1] = x[b]; b-- } x[b + 1] = t }
              printf "median %s %.2f\n", name[i], (n % 2) ? x[(n + 1) / 2] : (x[n / 2] + x[n / 2 + 1]) / 2 } }'
