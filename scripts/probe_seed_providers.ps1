# Probe upstream keys — uses curl.exe; never prints full secrets.
$seedPath = Join-Path $PSScriptRoot '..\data\seed.providers.json'
$seed = Get-Content $seedPath -Raw | ConvertFrom-Json
$tmp = Join-Path $env:TEMP 'janus-probe-body.json'

foreach ($p in $seed.providers) {
  $ki = 0
  foreach ($key in $p.keys) {
    $ki++
    $model = [string]$p.models[0]
    $url = ($p.base_url.TrimEnd('/') + '/chat/completions')
    $prefix = if ($key.Length -ge 8) { $key.Substring(0, 8) } else { $key }
    @{
      model = $model
      messages = @(@{ role = 'user'; content = 'ping' })
      max_tokens = 8
      stream = $false
    } | ConvertTo-Json -Depth 5 -Compress | Set-Content -Path $tmp -Encoding utf8NoBOM
    $outFile = Join-Path $env:TEMP ("janus-probe-{0}-{1}.out" -f $p.name, $ki)
    $errFile = Join-Path $env:TEMP ("janus-probe-{0}-{1}.err" -f $p.name, $ki)
    $args = @(
      '-sS', '-o', $outFile, '-w', '%{http_code}',
      '-X', 'POST', $url,
      '-H', "Authorization: Bearer $key",
      '-H', 'Content-Type: application/json',
      '--data-binary', "@$tmp",
      '--connect-timeout', '15',
      '--max-time', '45'
    )
    $code = & curl.exe @args 2>$errFile
    $snippet = ''
    if (Test-Path $outFile) {
      $raw = Get-Content $outFile -Raw -ErrorAction SilentlyContinue
      if ($raw) {
        $snippet = ($raw -replace '\s+', ' ').Trim()
        if ($snippet.Length -gt 120) { $snippet = $snippet.Substring(0, 120) }
      }
    }
    Write-Output ("{0}`tkey#{1}({2}…)`t{3}`tHTTP {4}`t{5}" -f $p.name, $ki, $prefix, $model, $code, $snippet)
  }
}
