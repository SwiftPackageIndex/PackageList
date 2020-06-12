![Valid JSON](https://github.com/daveverwer/SwiftPMLibrary/workflows/Valid%20JSON/badge.svg)

# The Swift Package Index

Adding a new package to the Swift Package Index is straightforward. Every package indexed by this site comes from a master list of repositories, stored in a [publicly available JSON file](https://github.com/SwiftPackageIndex/MasterPackageList/blob/master/packages.json). To add a package to the index, add the URL of the repository to that file.

### Package requirements

Please feel free to submit your own, or other people's repositories to this list. There are a few requirements, but they are simple:

* The package repository must be publicly accessible.
* Packages must have a `Package.swift` file located in the root of the repository.
* Packages must be written in **Swift 4.0 or later**.
* Packages must declare at least one product in the `Package.swift` file. It can be either a library or an executable product, and of course, you may declare more than one.
* Packages should have at least one release. A release is a git tag that conforms to the [semantic version](https://semver.org) spec. It can be a [beta or a pre-release](https://semver.org/#spec-item-9) semantic version.
* Packages should compile without errors. This isn't a strict requirement, but it's probably a good idea since you're about to add the package to a public index!
* Packages must output valid JSON when executing `swift package dump-package` using the latest version of the Swift toolchain.
* Package URLs should be a full HTTPS clone URL and include the .git extension.

**Note:** There's no gatekeeping or quality threshold to be included in this list. As long as the package is valid, and meets the above requirements, we will accept it.

### How do you add a package?

It's simple. Fork [this repository](https://github.com/SwiftPackageIndex/MasterPackageList/), edit `packages.json`, and submit a pull request. If you plan to add a set of packages there is no need to submit each package in a separate pull request. Feel free to bundle multiple updates at once as long as all packages match the criteria above.

Before submitting your pull request, please run the validation script locally:

```shell
swift ./validate.swift diff
```

Once validation is successful, please submit your pull request! Your package(s) will appear in the index within a few minutes.
