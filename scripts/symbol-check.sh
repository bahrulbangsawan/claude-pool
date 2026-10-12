#!/bin/sh
# Asserts the built binaries import no networking or Keychain symbols.
set -u
APP="${1:-build/ClaudePool.app}"
status=0
for bin in "$APP/Contents/MacOS/ClaudePool" "$APP/Contents/Helpers/claude-pool-collector"; do
    if [ ! -f "$bin" ]; then echo "symbol-check: missing $bin"; exit 1; fi
    hits=$(nm -u "$bin" 2>/dev/null | grep -E 'URLSession|NSURLConnection|_nw_|CFSocket|CFStream.*Socket|_SecItem|_SecKeychain|_socket$|_connect$|_getaddrinfo' || true)
    libs=$(otool -L "$bin" | grep -E 'Network.framework|Security.framework' || true)
    if [ -n "$hits$libs" ]; then
        echo "symbol-check: FORBIDDEN in $bin"; echo "$hits"; echo "$libs"; status=1
    fi
done
[ "$status" -eq 0 ] && echo "symbol-check: OK (no networking or Keychain symbols imported)"
exit "$status"
