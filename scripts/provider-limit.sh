#!/bin/bash
# Record the reset time of a provider rate limit, so agent-guard.sh refuses a delegate_task to that
# provider until the reset.
# Usage: scripts/provider-limit.sh <provider or model> <reset UTC, YYYY-MM-DDTHH:MM>
# It appends the line <name><TAB><reset> to dirigible-provider-limits in the git common dir, which
# agent-guard.sh reads: a line matches a call when its name equals the providerInstanceId or the
# model of the target. The reset is the start of that UTC minute. Exit 2, with the file unchanged,
# for a name that is empty or holds white space, and for a reset that is not a real date and time
# in that form.
set -uo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: scripts/provider-limit.sh <provider or model> <reset UTC, YYYY-MM-DDTHH:MM>" >&2
    exit 2
fi
name="$1" reset="$2"
if [[ -z "$name" || "$name" == *[[:space:]]* ]]; then
    echo "provider-limit: the name must not be empty or hold white space: '$name'" >&2
    exit 2
fi
# The round trip rejects a day that the month does not have: date -j rolls such a date over. The
# seconds are set to 00, because date -j takes an unset field from the clock.
if ! [[ "$reset" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}$ ]] \
    || ! epoch="$(date -j -u -f %Y-%m-%dT%H:%M:%S "$reset:00" +%s 2> /dev/null)" \
    || [[ "$(date -u -r "$epoch" +%Y-%m-%dT%H:%M)" != "$reset" ]]; then
    echo "provider-limit: the reset must be a UTC date and time as YYYY-MM-DDTHH:MM: '$reset'" >&2
    exit 2
fi
common="$(git -C "$(dirname "$0")" rev-parse --path-format=absolute --git-common-dir)" || exit 1
printf '%s\t%s\n' "$name" "$reset" >> "$common/dirigible-provider-limits"
