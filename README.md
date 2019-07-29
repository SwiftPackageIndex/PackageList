# Swift Package Manager Library

Let's build a list of packages that support the Swift Package Manager!

Please fork this repository, add any libraries that support **Swift 4.0 or later** and submit a pull request. The libraries *do not* need to have been written by you, the only requirement is that they support the Swift Package Manager.

If you plan to submit a set of packages, there is no need to submit each package in a separate PR. Please feel free to bundle multiple in a single.

**Note:** There's no gatekeeping or quality threshold to be included in this list. As long as your package has a Package.swift file, supports Swift 4 (or greater) and is open source, it'll be included.

To validate the JSON in your submission you can use
[jq](https://stedolan.github.io/jq/),
e.g. like so:
```shell
jq -e . packages.json  > /dev/null
```

Make sure the list is in alphabetical order before merging with the master:
```shell
echo "$(jq 'sort_by(ascii_downcase)' packages.json)" > packages.json
```
