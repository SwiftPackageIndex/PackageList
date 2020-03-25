#!/bin/bash

temp_file=$(mktemp)
curl -s https://raw.githubusercontent.com/brightdigit/SwiftPMLibrary/master/validate.swift > $temp_file
swift $temp_file $PWD $*
rm $temp_file
