#!/bin/bash

# Check jq is installed
jq -e . packages.json > /dev/null

# Make sure there are no dupes (no dupe variants w/ .git and w/o, no case differences)
(for repo in $(jq '.[]' packages.json); do basename $repo; done) \
  | tr '[:upper:]' '[:lower:]' \
  | sed 's|"||g' | sed s/.git//g \
  | uniq -d

# Sort
echo "$(jq 'sort_by(ascii_downcase)' packages.json)" > packages.sorted.json

# Verify
diff packages.json packages.sorted.json

# Clean up
rm packages.sorted.json
