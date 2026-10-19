# Sagara.Build.Versioning

An MSBuild-only NuGet package that versions .NET projects the way the .NET SDK does: NuGet `Version` from `VersionPrefix`, `PrereleaseLabel`, and `PreviewNumber`; `AssemblyVersion` `Major.Minor.0.0`; and a date-stamped `FileVersion` in CI.

See the [package README](src/Sagara.Build.Versioning/README.md) for usage.

## Repo layout

| Path | Purpose |
|---|---|
| [src/Sagara.Build.Versioning/](src/Sagara.Build.Versioning/) | The package: `build/`, `buildMultiTargeting/`, and `core/` MSBuild files |
| [tests/ByPath/](tests/ByPath/) | Fixture that imports the build files by path |
| [tests/Package/](tests/Package/) | Fixture that consumes the packed `.nupkg` through `GlobalPackageReference` |
| [tests/Verify-Versioning.ps1](tests/Verify-Versioning.ps1) | End-to-end verification; run by CI |

This repo versions itself with its own build files, imported by path from [Directory.Build.props](Directory.Build.props). Set the next version there.

## Build and test

```sh
dotnet build
pwsh ./tests/Verify-Versioning.ps1
dotnet pack src/Sagara.Build.Versioning -c Release -o nuget
```

`Verify-Versioning.ps1` packs the package as `0.0.1-alpha.1` into `tests/artifacts/feed`, restores the package fixture from there, and checks every version property in the outer build and each per-framework build, plus the validation errors and the built DLLs.

## Releasing

Create a GitHub Release. The [publish workflow](.github/workflows/build-and-publish.yml) verifies, packs, and pushes to nuget.org with trusted publishing (OIDC).
