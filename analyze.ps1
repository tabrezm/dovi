# Extract mastering metadata and generate plots
#
# Usage:
#   $ .\analyze.ps1 "Z:\Movies"
#   $ gci -Path "Z:\Movies" -Filter "*.mkv" -Recurse | .\analyze.ps1

param (
    [String[]]$rootdir
)

$ErrorActionPreference = "Stop"

# Support pipeline input
if (!$rootdir) {
    $Dirs = @($input)
}
else {
    $Dirs = Get-ChildItem -Path "Z:\Movies" -Filter "*.mkv" -Recurse
}

$origin = @{}
$Dirs | Foreach-Object { $origin.($_.GetHashCode()) = @{} }
$sync = [System.Collections.Hashtable]::Synchronized($origin)

try {
    $job = $Dirs | Foreach-Object -AsJob -Parallel {
        function New-TemporaryDirectory {
            param (
                $Path
            )
            $parent = if ($Path) { $Path } else { [System.IO.Path]::GetTempPath() }
            [string] $name = [System.Guid]::NewGuid()
            New-Item -ItemType Directory -Path (Join-Path $parent $name)
        }

        function Get-WslPath {
            param(
                $Path
            )

            wsl wslpath ($Path.Replace('\', '\\'))
        }

        function Get-PropertySafe {
            param(
                $Object, $Name
            )

            if ($Name -in $Object.PSObject.Properties.Name) {
                $Object.$Name
            }
            else {
                $null
            }
        }

        try {
            # workaround to allow expressions with $using:sync
            $syncCopy = $using:sync
            $id = $_.GetHashCode()

            Write-Host "[$id] Processing '$($_.Name)'"

            $process = $syncCopy.$($id)
            $process.Id = $id
            $process.Activity = $_.BaseName

            $tmp_dir = New-TemporaryDirectory -Path "D:/temp"

            $process.Status = "(1/6) Load metadata from BL"
            $process.PercentComplete = -1
            $info = & MediaInfo.exe $_ --Output=JSON | ConvertFrom-Json
            $video_track = $info.media.track[1]

            if ("HEVC" -ne $video_track.Format) {
                Write-Host "[$id] Not a HEVC file. Found: $($video_track.Format)."
                return
            }
            elseif (!$video_track.HDR_Format) {
                Write-Host "[$id] Not a HDR file."
                return
            }

            $MasteringDisplay_Luminance = $video_track.MasteringDisplay_Luminance
            $MasteringDisplay_Luminance_matches = ($MasteringDisplay_Luminance | Select-String -Pattern "^min: (.+), max: (.+)$").Matches

            $BL_data = [ordered]@{
                HDR_Format                     = Get-PropertySafe $video_track "HDR_Format"
                HDR_Format_Version             = Get-PropertySafe $video_track "HDR_Format_Version"
                HDR_Format_Profile             = Get-PropertySafe $video_track "HDR_Format_Profile"
                HDR_Format_Level               = Get-PropertySafe $video_track "HDR_Format_Level"
                HDR_Format_Settings            = Get-PropertySafe $video_track "HDR_Format_Settings"
                HDR_Format_Compatibility       = Get-PropertySafe $video_track "HDR_Format_Compatibility"
                MasteringDisplay_Luminance_Min = $MasteringDisplay_Luminance_matches.Groups[1].Value
                MasteringDisplay_Luminance_Max = $MasteringDisplay_Luminance_matches.Groups[2].Value
                MaxCLL                         = $video_track.MaxCLL
                MaxFALL                        = $video_track.MaxFALL
            }

            # drop null values
            ($BL_data.GetEnumerator() | Where-Object { -not $_.Value }) | ForEach-Object { $BL_data.Remove($_.Name) }

            if ($BL_data.HDR_Format -like "Dolby Vision*") {
                $process.Status = "(2/6) Extract DV8 BL+RPU"
                $job = Start-ThreadJob -ScriptBlock {
                    param ($source, $out) & mkvextract.exe $source tracks 0:$out
                } -ArgumentList $_, "$tmp_dir/DV8.BL_RPU.hevc"
                $pc_pattern = "^Progress: (\d+)%"
                while (($job | Get-Job).State -in 'NotStarted', 'Running') {
                    $results = Receive-Job $job
                    if ($results -match $pc_pattern) {
                        $pc = ($results | Select-String -Pattern $pc_pattern).Matches.Groups[1].Value
                        $process.Status = "(2/6) Extract DV8 BL+RPU ($pc%)"
                        $process.PercentComplete = $pc
                    }
                    Start-Sleep -Seconds 1
                }

                # TODO: use pseudoconsole instead of wsl + unbuffer
                $process.Status = "(3/6) Extract DV8 RPU"
                $dovi_tool_linux = "$(Get-WslPath $PWD.Path)/dovi_tool"
                $job = Start-ThreadJob -ScriptBlock {
                    param ($dovi_tool, $in, $out) & bash -c "unbuffer $dovi_tool extract-rpu $in -o $out"
                } -ArgumentList $dovi_tool_linux, (Get-WslPath "$tmp_dir/DV8.BL_RPU.hevc"), (Get-WslPath "$tmp_dir/DV8.RPU.bin")
                $pc_pattern = "(\d+)%"
                while (($job | Get-Job).State -in 'NotStarted', 'Running') {
                    $results = Receive-Job $job
                    if ($results -match $pc_pattern) {
                        $pc = ($results | Select-String -Pattern $pc_pattern).Matches.Groups[1].Value
                        $process.Status = "(3/6) Extract DV8 RPU ($pc%)"
                        $process.PercentComplete = $pc
                    }
                    Start-Sleep -Seconds 1
                }

                $process.Status = "(4/6) Generate plot from DV8 RPU"
                $process.PercentComplete = -1
                & .\dovi_tool plot "$tmp_dir/DV8.RPU.bin" -o ((Join-Path $_.Directory $_.BaseName) + ".plot.png") | Out-Null

                $process.Status = "(5/6) Load mastering data from RPU"
                $process.PercentComplete = -1
                $info = [ordered]@{}
                # ignore "Parsing RPU file...", newline, and "Summary:"
                & .\dovi_tool info "$tmp_dir/DV8.RPU.bin" -s | Select-Object -Skip 3 | ForEach-Object {
                    $key, $value = $_ -split ":", 2 | ForEach-Object { $_.Trim() }
                    $info[$key] = $value
                }

                $MasteringDisplay_Luminance = $info."RPU mastering display"
                $MasteringDisplay_Luminance_matches = ($MasteringDisplay_Luminance | Select-String -Pattern "^(.+)\/(.+) nits$").Matches

                $L1_MaxCLL_MaxFALL = $info."RPU content light level (L1)"
                $L1_MaxCLL_MaxFALL_matches = ($L1_MaxCLL_MaxFALL | Select-String -Pattern "^MaxCLL: (.+) nits, MaxFALL: (.+) nits$").Matches

                $L6_MaxCLL_MaxFALL = $info."L6 metadata"
                $L6_MaxCLL_MaxFALL_matches = ($L6_MaxCLL_MaxFALL | Select-String -Pattern "^.+ MaxCLL: (.+) nits, MaxFALL: (.+) nits$").Matches

                $RPU_data = [ordered]@{
                    Profile                        = $info.Profile
                    Content_Mapping_Version        = ($info."DM version" | Select-String -pattern "^.+ \(CM (.+)\)$").Matches.Groups[1].Value
                    MasteringDisplay_Luminance_Min = "$($MasteringDisplay_Luminance_matches.Groups[1].Value) nits"
                    MasteringDisplay_Luminance_Max = "$($MasteringDisplay_Luminance_matches.Groups[2].Value) nits"
                    L1_MaxCLL                      = "$($L1_MaxCLL_MaxFALL_matches.Groups[1].Value) nits"
                    L1_MaxFALL                     = "$($L1_MaxCLL_MaxFALL_matches.Groups[2].Value) nits"
                    L6_MaxCLL                      = "$($L6_MaxCLL_MaxFALL_matches.Groups[1].Value) nits"
                    L6_MaxFALL                     = "$($L6_MaxCLL_MaxFALL_matches.Groups[2].Value) nits"
                }
            }

            $process.Status = "(6/6) Write BL+RPU mastering data"
            $process.PercentComplete = -1
            $BL_RPU_data = [ordered]@{
                Name = $_.Name
                BL   = $BL_data
                RPU  = $RPU_data
            } | ConvertTo-Json
            $BL_RPU_data | Set-Content ((Join-Path $_.Directory $_.BaseName) + ".master.json")

            $process.Completed = $true

            Write-Host "[$id] Fin."
        }
        catch {
            throw "[$id] $_"
        }
        finally {
            Get-Job | Stop-Job
            Remove-Item $tmp_dir -Recurse
        }
    }

    while ($job.State -eq 'Running') {
        $sync.Keys | Foreach-Object {
            if ($sync.$_.keys -and $sync.$_.keys -ne "") {
                $param = $sync.$_
                Write-Progress @param
            }
        }

        Start-Sleep 1
    }
}
finally {
    Receive-Job $job
    Get-Job | Stop-Job
}
