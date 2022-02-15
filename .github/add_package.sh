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
    echo "Processing '$url'."

    # 1a. Skip non URLs
    if [[ $url != https://github.com/* ]]; then
        continue
    fi

    # 1b. Normalise URL
    if [[ $url != *.git ]]; then
        # Add `.git` at end
        url="$url.git"
    fi

    # 1c. Append Item
    jq '. |= . + ["'$url'"]' -S packages.json > temp.json

    # 1d. Remove Duplicates and Sort
    jq '.|unique' temp.json > packages.json
    rm temp.json 
done

# 2. Compare

diff --brief packages.json packages-backup.json >/dev/null
CONTAINS_CHANGES=$?

if [ $CONTAINS_CHANGES -eq 1 ]; then
    echo '::set-output name=changes::true'
else
    echo '::set-output name=changes::false'
fi