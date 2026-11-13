param([ValidateSet('Build','Run','Publish','Package','Test')][string]$Action='Build',[string]$Dotnet='dotnet',[string]$OutputDirectory='')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$project=Join-Path $root 'src/Perch.App/Perch.App.csproj'
$publishDirectory = if ($OutputDirectory) { [IO.Path]::GetFullPath($OutputDirectory) } else { Join-Path $root '../dist.noindex/windows/Perch' }
if($Action -eq 'Test'){
    & $Dotnet run --project (Join-Path $root 'tests/Perch.Core.Tests/Perch.Core.Tests.csproj')
    if($LASTEXITCODE -ne 0){throw "Windows Core tests failed ($LASTEXITCODE)"}
    & $Dotnet run --project (Join-Path $root 'tests/Perch.App.Tests/Perch.App.Tests.csproj')
}elseif($Action -in @('Publish','Package')){
    & $Dotnet publish $project -c Release -r win-x64 --self-contained true -o $publishDirectory
}elseif($Action -eq 'Run'){
    & $Dotnet run --project $project -- --show
}else{
    & $Dotnet build $project -c Release
}
if($LASTEXITCODE -ne 0){throw "Windows $Action failed ($LASTEXITCODE)"}
if ($Action -eq 'Package') {
    $version = (Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw).Trim()
    $release = Join-Path $root '../dist.noindex/windows/releases'
    New-Item -ItemType Directory -Path $release -Force | Out-Null
    $zip = Join-Path $release "Perch-Windows-$version-x64.zip"
    Compress-Archive -Path (Join-Path $publishDirectory '*') -DestinationPath $zip -Force
    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText((Join-Path $release 'SHA256SUMS'), "$hash  $([IO.Path]::GetFileName($zip))`n", [Text.UTF8Encoding]::new($false))
    Write-Output $zip
}
