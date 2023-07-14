# Convert DV7 to DV8

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
        [switch] $PassThru
    )

    $job = Start-Job -ScriptBlock { & Robocopy.exe "$using:Source" "$using:Destination" "$using:File" /mt /njh /njs }

    $prev_out, $curr_out
    $pc_pattern = "^\s+(\d+)%"
    while (($job | Get-Job).HasMoreData -or ($job | Get-Job).State -eq "Running") {
        $curr_out = Receive-Job $job
        if (($null -eq $curr_out) -or ($prev_out -eq $curr_out)) {
            continue
        }
        if ($curr_out -match $pc_pattern) {
            $pc = ($curr_out | Select-String -Pattern $pc_pattern).Matches.Groups[1].Value
            Write-Progress -Activity "Robocopy" -Status "$pc% complete" -PercentComplete $pc
        }
        else {
            Write-Host $curr_out
        }
        Start-Sleep 1
        $prev_out = $curr_out
    }
    Write-Progress -Activity "Robocopy" -Completed

    if ($PassThru) {
        Join-Path $Destination $File
    }
}

$ErrorActionPreference = "Stop"

$infile = $args[0]
if (!(Test-Path -Path $infile -PathType Leaf)) {
    throw "File does not exist."
}

$original_dir = (Get-Item $infile).Directory.FullName
$filename = (Get-Item $infile).Name
$basename = (Get-Item $infile).BaseName

Write-Host "=== Processing file: '$filename' ==="

$dv_profile = (ffprobe -v quiet -show_streams -select_streams v:0 $infile |
    Select-String -Pattern "dv_profile=(\d)").Matches.Groups[1].Value
if ($dv_profile -eq 8) {
    Write-Host "Already DV profile 8. Fin."
    exit
}
elseif ($dv_profile -ne 7) {
    throw "Unexpected DV profile. Expected: 7. Found: $dv_profile."
}

try {
    $tmp_dir = New-TemporaryDirectory -Path "D:/temp"

    Write-Host "=== Copy DV7 file to working directory ==="
    $infile_tmp = Robocopy $original_dir $tmp_dir $filename -PassThru

    Write-Host "=== Extract DV7 BL+EL+RPU ==="
    mkvextract $infile_tmp tracks 0:"$tmp_dir/DV7.BL_EL_RPU.hevc"

    Write-Host "=== Extract DV7 RPU ==="
    .\dovi_tool.exe extract-rpu "$tmp_dir/DV7.BL_EL_RPU.hevc" -o "$tmp_dir/DV7.RPU.bin"

    # Preserve FEL in case of future support for encoding it into BL or RPU
    $el_type = "MEL"
    if ((.\dovi_tool.exe info "$tmp_dir/DV7.RPU.bin" -s |
            Select-String -Pattern "Profile: 7 \((\w+)\)").Matches.Groups[1].Value -eq "FEL") {
        $el_type = "FEL"

        Write-Host "=== Extract DV7 FEL==="
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
    Remove-Item $tmp_dir -Recurse
}

Write-Host "Fin."
