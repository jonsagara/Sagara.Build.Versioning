#Requires -Version 7.0
<#
.SYNOPSIS
    Verifies Sagara.Build.Versioning end to end.

.DESCRIPTION
    1. Packs the package (as 0.0.1-alpha.1) into tests/artifacts/feed and checks its layout.
    2. Restores tests/Package, which consumes the .nupkg through GlobalPackageReference.
    3. For both fixtures (by-path imports and the real package), evaluates Version, PackageVersion,
       AssemblyVersion, and FileVersion in the outer build and in every per-framework build, for each case.
    4. Checks that invalid input fails validation with the expected error code.
    5. Packs the package fixture as a CI prerelease and checks the .nupkg name and the built DLL versions.

    Exits with a non-zero code if anything fails.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path $PSScriptRoot -Parent
$artifacts = Join-Path $PSScriptRoot 'artifacts'
$feed = Join-Path $artifacts 'feed'
$packages = Join-Path $artifacts 'packages'
$packageProject = Join-Path $repoRoot 'src/Sagara.Build.Versioning/Sagara.Build.Versioning.csproj'
$byPathFixture = Join-Path $PSScriptRoot 'ByPath/ByPathFixture.csproj'
$packageFixture = Join-Path $PSScriptRoot 'Package/PackageFixture.csproj'
$testPackageVersion = '0.0.1-alpha.1'   # must match tests/Package/Directory.Packages.props
$targetFrameworks = @('net8.0', 'net9.0', 'net10.0')

# Every run repacks the same package version to the same path. Reused MSBuild nodes can keep the previous
# run's imported .targets files cached, so disable node reuse and shut down any nodes left over.
$env:MSBUILDDISABLENODEREUSE = '1'
& dotnet build-server shutdown --msbuild *> $null

$script:failures = 0
$script:passes = 0

function Write-Pass([string] $message) {
    $script:passes++
    Write-Host "  PASS  $message" -ForegroundColor Green
}

function Write-Fail([string] $message) {
    $script:failures++
    Write-Host "  FAIL  $message" -ForegroundColor Red
}

function Invoke-Dotnet([string[]] $arguments) {
    $output = & dotnet @arguments 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

function ConvertTo-MSBuildArgs([hashtable] $properties) {
    # Pass every input explicitly (empty overrides the fixture default), so cases don't leak into each other.
    $all = [ordered]@{ VersionPrefix = ''; PrereleaseLabel = ''; PreviewNumber = ''; OfficialBuildId = '' }
    foreach ($key in $properties.Keys) { $all[$key] = $properties[$key] }
    return $all.Keys | ForEach-Object { "-p:$_=$($all[$_])" }
}

function Get-VersionProperties([string] $project, [hashtable] $properties, [string] $targetFramework) {
    $arguments = @('msbuild', $project, '-nologo',
        '-getProperty:Version', '-getProperty:PackageVersion', '-getProperty:AssemblyVersion', '-getProperty:FileVersion')
    $arguments += ConvertTo-MSBuildArgs $properties
    if ($targetFramework) { $arguments += "-p:TargetFramework=$targetFramework" }

    $result = Invoke-Dotnet $arguments
    if ($result.ExitCode -ne 0) { throw "Evaluation failed for $project`n$($result.Output)" }
    return ($result.Output | ConvertFrom-Json).Properties
}

#
# Cases: inputs and the values every evaluation (outer + each TFM) must produce.
#
$cases = @(
    @{ Name = 'local stable';                  In = @{ VersionPrefix = '1.0.3' };                                                       Version = '1.0.3';             AssemblyVersion = '1.0.0.0';  FileVersion = '1.0.300.0' }
    @{ Name = 'local preview';                 In = @{ VersionPrefix = '1.0.3'; PreviewNumber = '2' };                                  Version = '1.0.3-preview.2';   AssemblyVersion = '1.0.0.0';  FileVersion = '1.0.300.0' }
    @{ Name = 'rc';                            In = @{ VersionPrefix = '1.0.3'; PrereleaseLabel = 'rc'; PreviewNumber = '1' };          Version = '1.0.3-rc.1';        AssemblyVersion = '1.0.0.0';  FileVersion = '1.0.300.0' }
    @{ Name = 'label without number = stable'; In = @{ VersionPrefix = '1.0.3'; PrereleaseLabel = 'rc' };                               Version = '1.0.3';             AssemblyVersion = '1.0.0.0';  FileVersion = '1.0.300.0' }
    @{ Name = 'alpha, two-digit number';       In = @{ VersionPrefix = '2.0.0'; PrereleaseLabel = 'alpha'; PreviewNumber = '10' };      Version = '2.0.0-alpha.10';    AssemblyVersion = '2.0.0.0';  FileVersion = '2.0.0.0' }
    @{ Name = 'non-zero minor';                In = @{ VersionPrefix = '5.10.3' };                                                      Version = '5.10.3';            AssemblyVersion = '5.10.0.0'; FileVersion = '5.10.300.0' }
    @{ Name = 'CI stable';                     In = @{ VersionPrefix = '1.0.3'; OfficialBuildId = '20261016.3' };                       Version = '1.0.3';             AssemblyVersion = '1.0.0.0';  FileVersion = '1.0.326.51603' }
    @{ Name = 'CI preview';                    In = @{ VersionPrefix = '1.0.3'; PreviewNumber = '2'; OfficialBuildId = '20261016.3' };  Version = '1.0.3-preview.2';   AssemblyVersion = '1.0.0.0';  FileVersion = '1.0.326.51603' }
    @{ Name = 'CI Jan 1, build 1';             In = @{ VersionPrefix = '1.2.0'; OfficialBuildId = '20270101.1' };                       Version = '1.2.0';             AssemblyVersion = '1.2.0.0';  FileVersion = '1.2.27.5101' }
    @{ Name = 'CI maximum values';             In = @{ VersionPrefix = '2.3.654'; OfficialBuildId = '20991231.99' };                    Version = '2.3.654';           AssemblyVersion = '2.3.0.0';  FileVersion = '2.3.65499.63199' }
)

#
# Error cases: inputs and the code validation must report.
#
$errorCases = @(
    @{ Name = 'missing VersionPrefix';        In = @{};                                                                      Code = 'SBV0002' }
    @{ Name = 'VersionPrefix 1.0';            In = @{ VersionPrefix = '1.0' };                                               Code = 'SBV0003' }
    @{ Name = 'VersionPrefix leading zero';   In = @{ VersionPrefix = '1.0.03' };                                            Code = 'SBV0003' }
    @{ Name = 'VersionPrefix with label';     In = @{ VersionPrefix = '1.0.3-beta' };                                        Code = 'SBV0003' }
    @{ Name = 'Patch 655';                    In = @{ VersionPrefix = '1.0.655' };                                           Code = 'SBV0004' }
    @{ Name = 'Major 65535';                  In = @{ VersionPrefix = '65535.0.0' };                                         Code = 'SBV0004' }
    @{ Name = 'PreviewNumber 0';              In = @{ VersionPrefix = '1.0.3'; PreviewNumber = '0' };                        Code = 'SBV0005' }
    @{ Name = 'PreviewNumber abc';            In = @{ VersionPrefix = '1.0.3'; PreviewNumber = 'abc' };                      Code = 'SBV0005' }
    @{ Name = 'label rc1';                    In = @{ VersionPrefix = '1.0.3'; PrereleaseLabel = 'rc1'; PreviewNumber = '1' }; Code = 'SBV0006' }
    @{ Name = 'label uppercase';              In = @{ VersionPrefix = '1.0.3'; PrereleaseLabel = 'Preview'; PreviewNumber = '1' }; Code = 'SBV0006' }
    @{ Name = 'OfficialBuildId no N';         In = @{ VersionPrefix = '1.0.3'; OfficialBuildId = '20261016' };               Code = 'SBV0007' }
    @{ Name = 'OfficialBuildId 7-digit date'; In = @{ VersionPrefix = '1.0.3'; OfficialBuildId = '2026101.3' };              Code = 'SBV0007' }
    @{ Name = 'OfficialBuildId N=0';          In = @{ VersionPrefix = '1.0.3'; OfficialBuildId = '20261016.0' };             Code = 'SBV0007' }
    @{ Name = 'OfficialBuildId N=100';        In = @{ VersionPrefix = '1.0.3'; OfficialBuildId = '20261016.100' };           Code = 'SBV0007' }
    @{ Name = 'OfficialBuildId month 13';     In = @{ VersionPrefix = '1.0.3'; OfficialBuildId = '20261316.1' };             Code = 'SBV0008' }
    @{ Name = 'OfficialBuildId day 00';       In = @{ VersionPrefix = '1.0.3'; OfficialBuildId = '20261000.1' };             Code = 'SBV0008' }
)

Push-Location $repoRoot
try {
    #
    # 1. Pack the package and check its layout.
    #
    Write-Host "`n== Pack Sagara.Build.Versioning $testPackageVersion" -ForegroundColor Cyan
    if (Test-Path $feed) { Remove-Item $feed -Recurse -Force }
    # Drop only our package from the isolated packages folder; keep downloaded reference packs.
    $cached = Join-Path $packages 'sagara.build.versioning'
    if (Test-Path $cached) { Remove-Item $cached -Recurse -Force }

    $result = Invoke-Dotnet @('pack', $packageProject, '-c', 'Release', '-o', $feed, '-nologo',
        '-p:VersionPrefix=0.0.1', '-p:PrereleaseLabel=alpha', '-p:PreviewNumber=1')
    if ($result.ExitCode -ne 0) { throw "Packing Sagara.Build.Versioning failed.`n$($result.Output)" }

    $nupkg = Join-Path $feed "Sagara.Build.Versioning.$testPackageVersion.nupkg"
    if (Test-Path $nupkg) { Write-Pass "package file name: $(Split-Path $nupkg -Leaf)" }
    else { throw "Expected $nupkg; found: $((Get-ChildItem $feed).Name -join ', ')" }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($nupkg)
    try { $entries = @($zip.Entries | ForEach-Object FullName) } finally { $zip.Dispose() }

    $expectedEntries = @(
        'build/Sagara.Build.Versioning.props'
        'build/Sagara.Build.Versioning.targets'
        'buildMultiTargeting/Sagara.Build.Versioning.props'
        'buildMultiTargeting/Sagara.Build.Versioning.targets'
        'core/Sagara.Build.Versioning.Versioning.targets'
        'README.md'
        'LICENSE.md'
    )
    foreach ($entry in $expectedEntries) {
        if ($entries -contains $entry) { Write-Pass "package contains $entry" } else { Write-Fail "package is missing $entry" }
    }
    $assemblyEntries = @($entries | Where-Object { $_ -like 'lib/*' -or $_ -like 'ref/*' -or $_ -like '*.dll' })
    if ($assemblyEntries.Count -eq 0) { Write-Pass 'package contains no assemblies' }
    else { Write-Fail "package contains assemblies: $($assemblyEntries -join ', ')" }

    #
    # 2. Restore the package fixture from the local feed.
    #
    Write-Host "`n== Restore package fixture" -ForegroundColor Cyan
    # nuget.org comes from the repo's nuget.config. (Passing it with a second --source gets mangled into a local path.)
    $result = Invoke-Dotnet @('restore', $packageFixture, '-nologo',
        "-p:RestoreAdditionalProjectSources=$feed", "-p:RestorePackagesPath=$packages")
    if ($result.ExitCode -ne 0) { throw "Restoring the package fixture failed.`n$($result.Output)" }
    Write-Pass 'restored PackageFixture'

    #
    # 3. Property matrix.
    #
    foreach ($fixture in @($byPathFixture, $packageFixture)) {
        $fixtureName = [System.IO.Path]::GetFileNameWithoutExtension($fixture)
        Write-Host "`n== Property matrix: $fixtureName" -ForegroundColor Cyan

        foreach ($case in $cases) {
            foreach ($tfm in @('') + $targetFrameworks) {
                $scope = $tfm ? $tfm : 'outer'
                $actual = Get-VersionProperties $fixture $case.In $tfm
                $expected = [ordered]@{
                    Version = $case.Version
                    PackageVersion = $case.Version
                    AssemblyVersion = $case.AssemblyVersion
                    FileVersion = $case.FileVersion
                }
                $mismatches = @($expected.Keys | Where-Object { $actual.$_ -ne $expected[$_] } |
                    ForEach-Object { "$_ expected '$($expected[$_])' but was '$($actual.$_)'" })

                if ($mismatches.Count -eq 0) { Write-Pass "$($case.Name) [$scope]" }
                else { Write-Fail "$($case.Name) [$scope]: $($mismatches -join '; ')" }
            }
        }
    }

    #
    # 4. Validation errors and the override warning.
    #
    foreach ($fixture in @($byPathFixture, $packageFixture)) {
        $fixtureName = [System.IO.Path]::GetFileNameWithoutExtension($fixture)
        Write-Host "`n== Validation: $fixtureName" -ForegroundColor Cyan

        foreach ($case in $errorCases) {
            foreach ($tfm in @('', 'net10.0')) {
                $scope = $tfm ? $tfm : 'outer'
                $arguments = @('msbuild', $fixture, '-nologo', '-t:_SagaraValidateVersioning') + (ConvertTo-MSBuildArgs $case.In)
                if ($tfm) { $arguments += "-p:TargetFramework=$tfm" }
                $result = Invoke-Dotnet $arguments

                if ($result.ExitCode -ne 0 -and $result.Output -match "error $($case.Code)") { Write-Pass "$($case.Name) -> $($case.Code) [$scope]" }
                else { Write-Fail "$($case.Name) [$scope]: expected error $($case.Code), exit code $($result.ExitCode)`n$($result.Output)" }
            }
        }

        $result = Invoke-Dotnet (@('msbuild', $fixture, '-nologo', '-t:_SagaraValidateVersioning', '-p:Version=9.9.9') + (ConvertTo-MSBuildArgs @{ VersionPrefix = '1.0.3' }))
        if ($result.ExitCode -eq 0 -and $result.Output -match 'warning SBV1001') { Write-Pass 'explicit Version -> warning SBV1001' }
        else { Write-Fail "explicit Version: expected warning SBV1001 and success, exit code $($result.ExitCode)`n$($result.Output)" }
    }

    # Validation is wired into real builds and packs, not just callable directly.
    Write-Host "`n== Validation runs during build and pack" -ForegroundColor Cyan
    $result = Invoke-Dotnet (@('build', $byPathFixture, '-nologo', '-p:TargetFramework=net10.0') + (ConvertTo-MSBuildArgs @{ VersionPrefix = '1.0' }))
    if ($result.ExitCode -ne 0 -and $result.Output -match 'error SBV0003') { Write-Pass 'dotnet build fails with SBV0003' }
    else { Write-Fail "dotnet build: expected error SBV0003, exit code $($result.ExitCode)`n$($result.Output)" }

    $result = Invoke-Dotnet (@('pack', $packageFixture, '-nologo', '--no-restore', '-o', (Join-Path $artifacts 'bad')) + (ConvertTo-MSBuildArgs @{ VersionPrefix = '1.0.3'; PreviewNumber = 'x' }))
    if ($result.ExitCode -ne 0 -and $result.Output -match 'error SBV0005') { Write-Pass 'dotnet pack fails with SBV0005' }
    else { Write-Fail "dotnet pack: expected error SBV0005, exit code $($result.ExitCode)`n$($result.Output)" }

    #
    # 5. Real pack of the package fixture as a CI prerelease.
    #
    Write-Host "`n== Pack package fixture (CI prerelease)" -ForegroundColor Cyan
    $fixtureOut = Join-Path $artifacts 'fixture'
    if (Test-Path $fixtureOut) { Remove-Item $fixtureOut -Recurse -Force }
    $result = Invoke-Dotnet (@('pack', $packageFixture, '-c', 'Release', '-nologo', '--no-restore', '-o', $fixtureOut) +
        (ConvertTo-MSBuildArgs @{ VersionPrefix = '1.0.3'; PreviewNumber = '2'; OfficialBuildId = '20261016.3' }))
    if ($result.ExitCode -ne 0) { throw "Packing the package fixture failed.`n$($result.Output)" }

    $fixtureNupkg = Join-Path $fixtureOut 'PackageFixture.1.0.3-preview.2.nupkg'
    if (Test-Path $fixtureNupkg) { Write-Pass "fixture package file name: $(Split-Path $fixtureNupkg -Leaf)" }
    else { Write-Fail "expected $(Split-Path $fixtureNupkg -Leaf); found: $((Get-ChildItem $fixtureOut).Name -join ', ')" }

    foreach ($tfm in $targetFrameworks) {
        $dll = Join-Path $PSScriptRoot "Package/bin/Release/$tfm/PackageFixture.dll"
        $assemblyVersion = [System.Reflection.AssemblyName]::GetAssemblyName($dll).Version.ToString()
        $fileVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($dll).FileVersion
        $productVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($dll).ProductVersion

        if ($assemblyVersion -eq '1.0.0.0') { Write-Pass "$tfm DLL AssemblyVersion $assemblyVersion" } else { Write-Fail "$tfm DLL AssemblyVersion expected 1.0.0.0 but was $assemblyVersion" }
        if ($fileVersion -eq '1.0.326.51603') { Write-Pass "$tfm DLL FileVersion $fileVersion" } else { Write-Fail "$tfm DLL FileVersion expected 1.0.326.51603 but was $fileVersion" }
        if ($productVersion -like '1.0.3-preview.2*') { Write-Pass "$tfm DLL InformationalVersion $productVersion" } else { Write-Fail "$tfm DLL InformationalVersion expected 1.0.3-preview.2[+sha] but was $productVersion" }
    }
}
finally {
    Pop-Location
}

Write-Host "`n$($script:passes) passed, $($script:failures) failed" -ForegroundColor ($script:failures -eq 0 ? 'Green' : 'Red')
exit ($script:failures -eq 0 ? 0 : 1)
