# Convert DV7 to DV8
#
#
# Usage:
#   gci -Path "Z:\Movies" -Filter "*.mkv" -Recurse | % { .\dv7todv8.ps1 $_ }

param (
    [string]$infile
)

$ErrorActionPreference = "Stop"

function New-TemporaryDirectory {
    param (
        $Path
    )
    $parent = if ($Path) { $Path } else { [System.IO.Path]::GetTempPath() }
    [string] $name = [System.Guid]::NewGuid()
    New-Item -ItemType Directory -Path (Join-Path $parent $name)
}

function Robocopy {
    param (
        $Source,
        $Destination,
        $File,
        [switch]$PassThru
    )

    $job = Start-ThreadJob -ScriptBlock { & Robocopy.exe "$using:Source" "$using:Destination" "$using:File" /mt /njh /njs }

    $pc_pattern = "^\s+(\d+)%"
    while (($job | Get-Job).State -in 'NotStarted', 'Running') {
        $results = Receive-Job $job
        if ($results -match $pc_pattern) {
            $pc = ($results | Select-String -Pattern $pc_pattern).Matches.Groups[1].Value
            Write-Progress -Activity "Robocopy" -Status "$pc% complete" -PercentComplete $pc
        }
        Start-Sleep 1
    }
    Write-Progress -Activity "Robocopy" -Completed

    if ($PassThru) {
        Join-Path $Destination $File
    }
}

if (!(Test-Path -Path $infile -PathType Leaf)) {
    throw "File does not exist."
}

$original_dir = (Get-Item $infile).Directory.FullName
$filename = (Get-Item $infile).Name
$basename = (Get-Item $infile).BaseName

Write-Host "=== Processing file: '$filename' ==="

$info = & MediaInfo.exe "\\?\$infile" --Output=JSON | ConvertFrom-Json
$hdr_format_profile = $info.media.track[1].HDR_Format_Profile
if (!$hdr_format_profile) {
    Write-Host "Not a DV file."
    exit
}
elseif ($hdr_format_profile -like "dvhe.08*") {
    Write-Host "Already a DV8 file."
    exit
}
elseif (!$hdr_format_profile -like "dvhe.07*") {
    Write-Error "Unexpected DV profile. Expected: 'dvhe.07'. Found: '$hdr_format_profile'."
}

try {
    $tmp_dir = New-TemporaryDirectory -Path "D:/temp"

    Write-Host "=== Copy DV7 file to working directory ==="
    $infile_tmp = Robocopy $original_dir $tmp_dir $filename -PassThru

    Write-Host "=== Extract DV7 BL+EL+RPU ==="
    mkvextract $infile_tmp tracks 0:"$tmp_dir/DV7.BL_EL_RPU.hevc"

    Write-Host "=== Extract DV7 RPU ==="
    .\dovi_tool.exe extract-rpu "$tmp_dir/DV7.BL_EL_RPU.hevc" -o "$tmp_dir/DV7.RPU.bin"

    # Preserve FEL in case of future support for encoding it into BL
    $el_type = "MEL"
    if ((.\dovi_tool.exe info "$tmp_dir/DV7.RPU.bin" -s |
            Select-String -Pattern "Profile: 7 \((\w+)\)").Matches.Groups[1].Value -eq "FEL") {
        $el_type = "FEL"

        Write-Host "=== Extract DV7 FEL ==="
        $outfile_el = (Join-Path $original_dir $basename) + ".FEL.hevc"
        .\dovi_tool.exe demux --el-only "$tmp_dir/DV7.BL_EL_RPU.hevc" --el-out $outfile_el
    }

    Write-Host "=== Convert DV7 BL+EL+RPU to DV8 BL+RPU ==="
    .\dovi_tool.exe -m 2 convert --discard "$tmp_dir/DV7.BL_EL_RPU.hevc" -o "$tmp_dir/DV8.BL_RPU.hevc"

    Write-Host "=== Merge DV8 BL+RPU ==="
    $outfile = (Join-Path $original_dir $basename) + ".DV8.mkv"
    mkvmerge -o $outfile -D $infile_tmp "$tmp_dir/DV8.BL_RPU.hevc" --track-order 1:0

    Remove-Item $infile
    Rename-Item $outfile $infile

    if ($el_type -eq "FEL") {
        Set-Content "$original_dir/notes.txt" "converted DV7 BL+FEL+RPU to DV8 BL+RPU using dovi_tool 2.0.3"
    }
    else {
        Set-Content "$original_dir/notes.txt" "converted DV7 BL+MEL+RPU to DV8 BL+RPU using dovi_tool 2.0.3"
    }
}
finally {
    Get-Job | Stop-Job
    if ($tmp_dir) { Remove-Item $tmp_dir -Recurse }
}

Write-Host "=== Fin. ==="
