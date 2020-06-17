#!/bin/bash

# To run in local Swift package directory execute:
# `curl -s https://raw.githubusercontent.com/daveverwer/SwiftPMLibrary/master/script.sh | bash -s -- mine`

temp_file=$(mktemp)
#curl -s https://raw.githubusercontent.com/daveverwer/SwiftPMLibrary/master/validate.swift > $temp_file
cp swiftpmls $temp_file
chmod 755 $temp_file
$temp_file $* $PWD/packages.json 
rm $temp_file
