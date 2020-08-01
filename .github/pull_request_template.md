⚠⚠⚠⚠⚠⚠⚠⚠⚠⚠⚠⚠⚠⚠⚠⚠⚠⚠⚠⚠⚠⚠⚠⚠
There's a bug in Xcode 12 beta 3 that is affecting this repository's validation script. Unfortunately, validation for your pull request *will* fail due to this bug.

If possible, please run validation locally with Xcode 12 beta 1 or 2. If that's not possible, don't worry. Just submit your pull request, and one of the repository administrators will run validation for you.
⚠⚠⚠⚠⚠⚠⚠⚠⚠⚠⚠⚠⚠⚠⚠⚠⚠⚠⚠⚠⚠⚠⚠⚠️

The package(s) being submitted are:

* [Package Name](https://example.com/repository/)

## Checklist

I have either:

* [ ] Run `swift ./validate.swift`.

Or, checked that:

* [ ] The package repositories are publicly accessible.
* [ ] The packages all contain a `Package.swift` file in the root folder.
* [ ] The packages are written in Swift 4.0 or later.
* [ ] The packages all contain at least one product (either library or executable).
* [ ] The packages all have at least one release tagged as a [semantic version](https://semver.org/).
* [ ] The packages all output valid JSON from `swift package dump-package` with the latest Swift toolchain.
* [ ] The package URLs are all fully specified including `https` and the `.git` extension.
* [ ] The packages all compile without errors.
