# Create parent dirs for standalone MKV files
#
# Usage:
#   gci -Path "Z:\Movies" -Filter "*.mkv" | % { .\preprocess.ps1 $_ }

param (
    [string]$infile
)

$ErrorActionPreference = "Stop"

if (!(Test-Path -Path $infile)) {
    throw "Path does not exist."
}

$parent = (Get-Item $infile).Directory.FullName
$base = (Get-Item $infile).BaseName

if (Test-Path -Path $infile -PathType Leaf) {
    $parent = New-Item -Path (Join-Path $parent $base) -ItemType Directory
    $infile = Move-Item $infile $parent -PassThru
}
