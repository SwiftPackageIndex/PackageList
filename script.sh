#!/bin/bash

# To run in local Swift package directory execute:
# `curl -s https://raw.githubusercontent.com/SwiftPackageIndex/PackageList/main/script.sh | bash -s -- mine`

temp_file=$(mktemp)
curl -L https://raw.githubusercontent.com/SwiftPackageIndex/PackageList/main/validate > $temp_file
chmod 755 $temp_file
$temp_file $* $PWD/packages.json
rm $temp_file
