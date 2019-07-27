# Swift Package Manager Library

Let's build a list of packages that support the Swift Package Manager!

Please fork this repository, add **any** libraries and submit a pull request. The libraries do not need to have been written by you, the only requirement is that they support the Swift Package Manager.

If you plan to submit a set of packages, there is no need to submit each package
in a separate PR. Please feel free to bundle multiple in a single.

To validate the JSON in your submission you can use
[jq](https://stedolan.github.io/jq/),
e.g. like so:
```shell
jq -e . packages.json  > /dev/null
```
