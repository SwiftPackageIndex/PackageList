![Valid JSON](https://github.com/SwiftPackageIndex/PackageList/workflows/Valid%20JSON/badge.svg)

# The Swift Package Index

Anyone can add a package to the Swift Package Index. Please feel free to submit any package repository to the index, whether it's a package written by you or someone else. There's also no quality threshold. As long as the packages are valid and meet the requirements below, we will accept them. If you're unsure about any of the requirements, please submit the package(s), and we'll happily provide help.

There are a few requirements for inclusion in the index, but they aren't onerous:

- The package repositories must all be publicly accessible.
- The packages must all contain a valid `Package.swift` file in the root folder.
- The packages must be written in Swift 5.0 or later.
- The packages should have at least one release tagged as a [semantic version](https://semver.org/).
- The packages must all output valid JSON when running `swift package dump-package` with the latest Swift toolchain.
- The package URLs must include the protocol (usually `https`) and the `.git` extension.
- The packages must all compile without errors.
- All package content must comply with our [code of conduct](https://github.com/SwiftPackageIndex/SwiftPackageIndex-Server/blob/main/CODE_OF_CONDUCT.md).

<a href="https://github.com/SwiftPackageIndex/PackageList/issues/new/choose"><img src="https://user-images.githubusercontent.com/5180/156020907-8bebd0ca-c1ca-4a6f-9771-11a4037002a3.png" width="170" alt="Add Packages Button"></a>

> **Note:** Our build system can now generate and host DocC documentation and make it available from your package’s page in the index. All we need is a little configuration data so that we know how best to build your docs.
>
> [More information here](https://blog.swiftpackageindex.com/posts/auto-generating-auto-hosting-and-auto-updating-docc-documentation/).

> **Note:** If submitting your own packages, don't forget to add shields.io badges to your package's README to always have up to date swift version and platform compatibility information readily available. Once your package appears in the index, use the "Do you maintain this package?" link in the right-hand sidebar of your package page and use the provided markdown.
>
> For example: [![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fdaveverwer%2FLeftPad%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/daveverwer/LeftPad) [![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fdaveverwer%2FLeftPad%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/daveverwer/LeftPad)

### Removing a Package

You can request to have a package removed from the index with [this GitHub workflow](https://github.com/SwiftPackageIndex/PackageList/issues/new/choose).
