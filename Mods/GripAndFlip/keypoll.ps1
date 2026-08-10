# GripAndFlip key poller - writes arrow-key held state for the Lua mod to read.
# Runs only while Grain Rot is running; exits (and cleans up) when the game closes.
# Singleton via named mutex so mod hot-reloads don't stack pollers.

$mtx = New-Object System.Threading.Mutex($false, "GripAndFlip_KeyPoll")
if (-not $mtx.WaitOne(0)) { exit }

Add-Type -Namespace GR3D -Name Keys -MemberDefinition @'
[DllImport("user32.dll")]
public static extern short GetAsyncKeyState(int vKey);
'@

$out = Join-Path $env:TEMP "GripAndFlip_keys.txt"
$prev = -1
$tick = 0

while ($true) {
    $tick++
    if ($tick % 250 -eq 0) {
        if (-not (Get-Process "Helden-Win64-Shipping" -ErrorAction SilentlyContinue)) { break }
    }
    $m = 0
    if ([GR3D.Keys]::GetAsyncKeyState(0x26) -band 0x8000) { $m = $m -bor 1 } # Up
    if ([GR3D.Keys]::GetAsyncKeyState(0x28) -band 0x8000) { $m = $m -bor 2 } # Down
    if ([GR3D.Keys]::GetAsyncKeyState(0x25) -band 0x8000) { $m = $m -bor 4 } # Left
    if ([GR3D.Keys]::GetAsyncKeyState(0x27) -band 0x8000) { $m = $m -bor 8 }  # Right
    if ([GR3D.Keys]::GetAsyncKeyState(0xA4) -band 0x8000) { $m = $m -bor 16 } # Left Alt (rotate mode)
    if ($m -ne $prev) {
        try { [System.IO.File]::WriteAllText($out, [string]$m) } catch {}
        $prev = $m
    }
    Start-Sleep -Milliseconds 8
}
try { Remove-Item $out -Force } catch {}
