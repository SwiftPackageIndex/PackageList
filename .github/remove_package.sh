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

    # 1a. Rewrite SPI URLs
    if [[ $url == https://swiftpackageindex.com/* ]]; then
        url=$(echo "$url" | sed 's/swiftpackageindex.com/github.com/g')
    fi

    # 1b. Skip non URLs
    if [[ $url != https://github.com/* ]]; then
        continue
    fi

    # 1c. Normalise URL
    if [[ $url != *.git ]]; then
        # Add `.git` at end
        url="$url.git"
    fi

    # 1d. Delete Item
    jq 'del(.[] | select((.|ascii_downcase) == ("'$url'"|ascii_downcase)))' packages.json > temp.json
    mv temp.json packages.json
    echo "- '$url'."
done