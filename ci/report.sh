#!/bin/bash
# usage: ci/report.sh "message" [file-to-append]
set +e
W=$(pwd)
D=$(mktemp -d); cd "$D"; git init -q; git checkout -q -b ci-status
{ echo "run $RUN · commit $SHA · $1 · $(date -u +%H:%M:%S)"; [ -n "$2" ] && tail -40 "$W/$2"; } > status.txt
git add . && git -c user.name=ci -c user.email=ci@local commit -qm status
git push -qf "https://x-access-token:$TOKEN@github.com/$REPO" ci-status
