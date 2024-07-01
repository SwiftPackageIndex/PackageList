#!/bin/bash

if [[ $(git status --porcelain) ]]; then
    echo '::set-output name=changes::true'
else
    echo '::set-output name=changes::false'
fi