param([string]$FilePath)
$lines = [System.IO.File]::ReadAllLines($FilePath)
$inPrint = $false
$printStart = 0
$buf = ""

for ($i = 0; $i -lt $lines.Count; $i++) {
    $l = $lines[$i]
    if (-not $inPrint) {
        if ($l -match '^\s*print\(') {
            # check if print closes on same line
            # count parens: if balanced after open, it's single-line
            $trimmed = $l.TrimStart()
            $open = ($l.ToCharArray() | Where-Object { $_ -eq '(' } | Measure-Object).Count
            $close = ($l.ToCharArray() | Where-Object { $_ -eq ')' } | Measure-Object).Count
            if ($open -le $close) {
                # single-line print, OK
            } else {
                $inPrint = $true
                $printStart = $i + 1
                $buf = $l
            }
        }
    } else {
        $buf = $buf + " " + $l.TrimStart()
        $open = ($buf.ToCharArray() | Where-Object { $_ -eq '(' } | Measure-Object).Count
        $close = ($buf.ToCharArray() | Where-Object { $_ -eq ')' } | Measure-Object).Count
        if ($open -le $close) {
            Write-Host "MULTILINE_PRINT lines $printStart-$($i+1):"
            Write-Host $buf
            Write-Host "---"
            $inPrint = $false
            $buf = ""
        }
    }
}
