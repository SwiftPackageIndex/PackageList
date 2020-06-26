#!/bin/bash

# To run in local Swift package directory execute:
# `curl -s https://raw.githubusercontent.com/SwiftPackageIndex/PackageList/main/script.sh | bash -s -- mine`

temp_file=$(mktemp)
curl -s https://raw.githubusercontent.com/SwiftPackageIndex/PackageList/main/validate.swift > $temp_file
swift $temp_file $PWD $*
rm $temp_file
