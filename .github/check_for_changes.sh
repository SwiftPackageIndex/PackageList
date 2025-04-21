#!/bin/bash

if [[ $(git status --porcelain) ]]; then
    echo "changes=true" >> $GITHUB_OUTPUT
else
    echo "changes=false" >> $GITHUB_OUTPUT
fi