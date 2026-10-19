# Sagara.Build.Versioning

An MSBuild-only NuGet package (it contains no assemblies) that versions your projects the way the .NET SDK and runtime do it.

| Property | Example | Rule |
|---|---|---|
| NuGet `Version` / `PackageVersion` | `1.0.3`, `1.0.3-preview.2` | `VersionPrefix`, plus `-PrereleaseLabel.PreviewNumber` for prereleases |
| `AssemblyVersion` | `1.0.0.0` | `Major.Minor.0.0`, so patch releases never change assembly identity |
| `FileVersion` (CI) | `1.0.326.51603` | `Major.Minor.(Patch*100 + yy).((MM*50 + dd)*100 + N)` |
| `FileVersion` (local) | `1.0.300.0` | `Major.Minor.(Patch*100).0` |
| `InformationalVersion` | `1.0.3-preview.2+<commit sha>` | SDK default, unchanged |

In CI, `FileVersion` encodes the build date and build-of-the-day number. `1.0.326.51603` is version 1.0.3, built on 2026-10-16 (`26`, `10*50 + 16`), build 3 of that day.

## Usage

Reference the package for every project in the repo with [Central Package Management](https://learn.microsoft.com/nuget/consume-packages/central-package-management)'s `GlobalPackageReference`, in `Directory.Packages.props`:

```xml
<ItemGroup>
  <GlobalPackageReference Include="Sagara.Build.Versioning" Version="1.0.0" />
</ItemGroup>
```

Then set the version in `Directory.Build.props`, and remove any explicit `Version`, `AssemblyVersion`, or `FileVersion`:

```xml
<PropertyGroup>
  <VersionPrefix>1.0.3</VersionPrefix>
  <!-- For a prerelease: -->
  <!-- <PrereleaseLabel>preview</PrereleaseLabel> -->
  <!-- <PreviewNumber>2</PreviewNumber> -->
</PropertyGroup>
```

A plain `PackageReference` with `PrivateAssets="all"` also works.

## Inputs

| Property | Required | Default | Description |
|---|---|---|---|
| `VersionPrefix` | yes | | `Major.Minor.Patch`, e.g. `1.0.3`. No leading zeros, no prerelease label. |
| `PrereleaseLabel` | no | `preview` | `alpha`, `beta`, `preview`, or `rc`. Ignored when `PreviewNumber` is empty. |
| `PreviewNumber` | no | | A positive integer. **Empty means a stable release.** |
| `OfficialBuildId` | CI only | | `yyyyMMdd.N`, where `N` is the build of the day (1-99). Empty means a local build. |

Examples:

| Inputs | Version | FileVersion (local) |
|---|---|---|
| `VersionPrefix=1.0.3` | `1.0.3` | `1.0.300.0` |
| `VersionPrefix=1.0.3`, `PreviewNumber=2` | `1.0.3-preview.2` | `1.0.300.0` |
| `VersionPrefix=1.0.3`, `PrereleaseLabel=rc`, `PreviewNumber=1` | `1.0.3-rc.1` | `1.0.300.0` |
| `VersionPrefix=1.0.3`, `PrereleaseLabel=rc` | `1.0.3` | `1.0.300.0` |

The properties can be set anywhere MSBuild properties can: `Directory.Build.props`, the project file, or the command line (`-p:PreviewNumber=2`).

## Setting OfficialBuildId in CI

Pass `OfficialBuildId` to `dotnet build`, `dotnet pack`, and `dotnet test`, or set it as an environment variable for the job. This GitHub Actions step computes it from the run's creation date and the run's position among the workflow's runs that day, which stays the same across re-runs. Replace `build-and-publish.yml` with your workflow's file name, and give the job `permissions: actions: read`.

```yaml
- name: Compute OfficialBuildId
  shell: pwsh
  env:
    GH_TOKEN: ${{ github.token }}
    REPO: ${{ github.repository }}
    RUN_ID: ${{ github.run_id }}
  run: |
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $createdAt = gh api "repos/$env:REPO/actions/runs/$env:RUN_ID" --jq '.created_at'
    if ($LASTEXITCODE -ne 0) { throw "Could not read run $env:RUN_ID." }
    $created = [System.DateTimeOffset]::Parse($createdAt, $inv).UtcDateTime
    $day = $created.ToString('yyyy-MM-dd', $inv)
    $ids = gh api --paginate "repos/$env:REPO/actions/workflows/build-and-publish.yml/runs?created=${day}T00:00:00Z..${day}T23:59:59Z&per_page=100" --jq ".workflow_runs[] | select(.id <= $env:RUN_ID) | .id"
    if ($LASTEXITCODE -ne 0) { throw 'Could not list workflow runs.' }
    $n = @($ids | Where-Object { $_ }).Count
    if ($n -lt 1 -or $n -gt 99) { throw "Build of the day must be 1-99, but was $n." }
    $officialBuildId = '{0}.{1}' -f $created.ToString('yyyyMMdd', $inv), $n
    "OfficialBuildId=$officialBuildId" >> $env:GITHUB_ENV
```

Steps after this one see `OfficialBuildId` as an environment variable, which MSBuild reads as a property.

## Errors and warnings

Invalid input fails the build or pack with one of these codes:

| Code | Meaning |
|---|---|
| `SBV0001` | The versioning file was not imported. Something reassigned `BeforeMicrosoftNETSdkTargets` instead of appending to it. |
| `SBV0002` | `VersionPrefix` is missing. |
| `SBV0003` | `VersionPrefix` is not `Major.Minor.Patch` (e.g. `1.0`, `1.0.03`, or `1.0.3-beta`). |
| `SBV0004` | `VersionPrefix` is out of range: Major and Minor must be at most 65534, and Patch at most 654. |
| `SBV0005` | `PreviewNumber` is not a positive integer. |
| `SBV0006` | `PrereleaseLabel` is not `alpha`, `beta`, `preview`, or `rc`. Use `PrereleaseLabel=rc` + `PreviewNumber=1` rather than `rc1`. |
| `SBV0007` | `OfficialBuildId` is not `yyyyMMdd.N` with `N` from 1 to 99. |
| `SBV0008` | `OfficialBuildId` has an invalid month or day. |
| `SBV1001` (warning) | An explicit `Version`, `PackageVersion`, `VersionSuffix`, `AssemblyVersion`, or `FileVersion` overrides the computed value. |

## How it works

Package `.props` files are imported before the project body, and the SDK computes `Version` before package `.targets` files are imported, so neither is the right place to compute versions. Instead, the package's `.props` file appends a file to `BeforeMicrosoftNETSdkTargets`, which the SDK imports after `Directory.Build.props` and the project body, but before it computes `Version` from `VersionPrefix` and `VersionSuffix`. All values are computed during evaluation, so `dotnet msbuild -getProperty:Version` returns the real value.

The package ships both `build/` and `buildMultiTargeting/` assets, so the outer build of a multi-targeted project, where `dotnet pack` runs, gets the same version as each per-framework build.

If your own build also uses `BeforeMicrosoftNETSdkTargets`, append to it rather than replacing it:

```xml
<BeforeMicrosoftNETSdkTargets>$(BeforeMicrosoftNETSdkTargets);my.targets</BeforeMicrosoftNETSdkTargets>
```
