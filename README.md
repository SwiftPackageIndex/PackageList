![Valid JSON](https://github.com/SwiftPackageIndex/PackageList/workflows/Valid%20JSON/badge.svg)

# The Swift Package Index

Adding a new package to the Swift Package Index is straightforward. Every package indexed by this site comes from a list of package repository URLs, stored in a [publicly available JSON file](https://github.com/SwiftPackageIndex/PackageList/blob/main/packages.json). To add a package to the index, add a URL to a package repository to that file.

Please feel free to submit your own, or other people's repositories to this list. There are a few requirements, but they are simple.

The easiest way to validate that packages meet the requirements is to run the validation tool included in this repository. Fork [this repository](https://github.com/SwiftPackageIndex/PackageList/) and clone your fork locally. Then edit `packages.json` and add the package URL(s) to the JSON. Finally, in the directory where you have the clone of your fork of this repository, run the following command:

```shell
swift ./validate.swift
```

When validation is successful, commit your changes and submit your pull request! Your package(s) will appear in the index within a few minutes.

---

If you would prefer to validate the requirements manually, please verify that:

* The package repositories are all publicly accessible.
* The packages all contain a `Package.swift` file in the root folder.
* The packages are written in Swift 4.0 or later.
* The packages all contain at least one product (either library or executable).
* The packages all have at least one release tagged as a [semantic version](https://semver.org/).
* The packages all output valid JSON from `swift package dump-package` with the latest Swift toolchain.
* The package URLs are all fully specified including `https` and the `.git` extension.
* The packages all compile without errors.

**Note:** There's no gatekeeping or quality threshold to be included in this list. As long as the package is valid, and meets the above requirements, we will accept it.
