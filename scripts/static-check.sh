#!/bin/sh
# Fails if any forbidden API or string appears in the app, collector or shared sources.
# Lines carrying the marker "static-check:allow" are the documented exceptions.
set -u
cd "$(dirname "$0")/.."

status=0
for pattern in 'SecItem' 'import Security' '.credentials.json' 'URLSession' 'import Network' \
               'anthropic.com' 'transcript' 'setup-token' 'CLAUDE_CODE_OAUTH_TOKEN'; do
    hits=$(grep -RIn -F -- "$pattern" Sources/ Collector/ Shared/ | grep -v 'static-check:allow')
    # The session handoff copies a conversation file between profile directories byte-for-byte
    # (it never parses it); it is the one file allowed to name it.
    if [ "$pattern" = "transcript" ]; then
        hits=$(printf '%s\n' "$hits" | grep -v '^Sources/Services/SessionHandoffService.swift:' | grep -v '^$')
    fi
    if [ -n "$hits" ]; then
        echo "FORBIDDEN: '$pattern'"
        echo "$hits"
        status=1
    fi
done

# Narrow decoders: files Claude Pool reads from Claude Code are decoded through structs that
# declare only the fields it needs. None of them may ever declare content or secret fields.
decoders="Sources/Services/UsageIndex.swift Sources/Models/AccountDetails.swift Sources/Services/SessionRegistryService.swift Sources/Services/UsageProbe.swift Collector/StatuslinePayload.swift Collector/RateLimitInput.swift"
hits=$(grep -nE '^\s*(let|var) (content|text|prompt|message_content|accessToken|access_token|refreshToken|refresh_token|primaryApiKey|apiKey|messagingSocketPath|transcript_path|thinking|tool_use|input_json)\b' $decoders)
if [ -n "$hits" ]; then
    echo "FORBIDDEN: content or secret field declared in a narrow decoder"
    echo "$hits"
    status=1
fi

allowed=$(grep -RIn 'static-check:allow' Sources/ Collector/ Shared/ | wc -l | tr -d ' ')
if [ "$status" -eq 0 ]; then
    echo "static-check: OK (0 forbidden hits; $allowed marked exception line(s); narrow decoders declare no content or secret fields)"
fi
exit "$status"
