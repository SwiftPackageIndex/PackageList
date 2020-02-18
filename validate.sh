#!/bin/bash

# Check jq is installed
jq -e . packages.json > /dev/null

# Make sure there are no dupes (no dupe variants w/ .git and w/o, no case differences)
echo "Checking for duplicate packages."
(for repo in $(jq '.[]' packages.json); do basename $repo; done) \
  | tr '[:upper:]' '[:lower:]' \
  | sed 's|"||g' | sed s/.git//g \
  | uniq -d

# Sort the JSON into a temporary file
echo "$(jq 'sort_by(ascii_downcase)' packages.json)" > packages.sorted.json

# Verify that there are no differences between the committed JSON and the sorted JSON
echo "Checking package JSON is sorted."
diff packages.json packages.sorted.json > /dev/null
if [ $? -ne 0 ]; then
  echo "Error: packages.json is not sorted. Sort it by running:"
  echo
  echo '  echo "$(jq '\''sort_by(ascii_downcase)'\'' packages.json)" > packages.json'
  echo
fi

# Clean up the temporary JSON file
rm packages.sorted.json
