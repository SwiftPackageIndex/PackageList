#!/bin/bash

if [[ -z "${GH_BODY}" ]]; then
    echo "::error::Missing GH_BODY environment variable."
    exit 1
fi

# 0. Take Backup for Comparison

cp packages.json packages-backup.json

# 1. Cycle over Lines

echo "${GH_BODY}" | while read url ; do
    url=$(echo "$url" | sed 's/\r//g')

    # 1a. Skip non URLs
    if [[ $url != https://github.com/* ]]; then
        continue
    fi

    # 1b. Append Item
    jq '. |= . + ["'$url'"]' -S packages.json > temp.json
    mv temp.json packages.json
    echo "+ '$url'."
done
