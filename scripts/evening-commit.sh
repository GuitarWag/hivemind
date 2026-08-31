#!/bin/sh
# Commit with a timestamp at or after 19:00 today, whatever the current hour.
# Every argument is passed straight to git commit.
#
#   scripts/evening-commit.sh -m "feat: something"
set -e

hour=${EVENING_HOUR:-19}
now=$(date +%H)

if [ "$((10#$now))" -ge "$hour" ]; then
    stamp=$(date +"%Y-%m-%dT%H:%M:%S%z")
else
    # Keep the real minutes and seconds, move only the hour.
    stamp=$(date -v"${hour}"H +"%Y-%m-%dT%H:%M:%S%z")
fi

GIT_AUTHOR_DATE="$stamp" GIT_COMMITTER_DATE="$stamp" git commit "$@"
echo "recorded at $stamp"
