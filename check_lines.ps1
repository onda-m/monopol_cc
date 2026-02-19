$path = 'C:/work/monopol_cc/monopol_cc/monopol-p2p/swift/cast/WaitViewController+CommonSkyway.swift'
$lines = [System.IO.File]::ReadAllLines($path)
for ($i = 0; $i -lt $lines.Count; $i++) {
    $l = $lines[$i]
    if ($l -match 'startConnection: (called|invalidating)') {
        Write-Host "[$($i+1)] len=$($l.Length)"
        Write-Host "[$($l)]"
        Write-Host "---"
    }
}
