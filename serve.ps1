param(
  [int]$Port = 5173
)

$root = (Get-Location).Path
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
Write-Host "Serving $root at http://localhost:$Port/"

function Get-MimeType([string]$Path) {
  switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
    ".html" { "text/html" }
    ".js" { "text/javascript" }
    ".css" { "text/css" }
    ".json" { "application/json" }
    ".png" { "image/png" }
    ".jpg" { "image/jpeg" }
    ".jpeg" { "image/jpeg" }
    ".svg" { "image/svg+xml" }
    ".glb" { "model/gltf-binary" }
    ".gltf" { "model/gltf+json" }
    default { "application/octet-stream" }
  }
}

function Send-Response($Stream, [int]$StatusCode, [string]$StatusText, [byte[]]$Body, [string]$ContentType) {
  $header = "HTTP/1.1 $StatusCode $StatusText`r`nContent-Type: $ContentType`r`nContent-Length: $($Body.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
  $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
  $Stream.Write($headerBytes, 0, $headerBytes.Length)
  if ($Body.Length -gt 0) {
    $Stream.Write($Body, 0, $Body.Length)
  }
}

function Send-Redirect($Stream, [string]$Location) {
  $body = [System.Text.Encoding]::UTF8.GetBytes("Redirecting to $Location")
  $header = "HTTP/1.1 302 Found`r`nLocation: $Location`r`nContent-Type: text/plain`r`nContent-Length: $($body.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
  $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
  $Stream.Write($headerBytes, 0, $headerBytes.Length)
  $Stream.Write($body, 0, $body.Length)
}

try {
  while ($true) {
    $client = $listener.AcceptTcpClient()
    try {
      $stream = $client.GetStream()
      $buffer = New-Object byte[] 4096
      $read = $stream.Read($buffer, 0, $buffer.Length)
      if ($read -le 0) {
        $client.Close()
        continue
      }

      $request = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read)
      $lines = $request -split "`r?`n"
      $firstLine = $lines[0]
      $parts = $firstLine -split " "
      $relative = "index.html"
      if ($parts.Length -ge 2) {
        $path = $parts[1].Split("?")[0].TrimStart("/")
        if (-not [string]::IsNullOrWhiteSpace($path)) {
          $relative = [Uri]::UnescapeDataString($path)
        }
      }

      $accept = ""
      $fetchDest = ""
      foreach ($line in $lines) {
        if ($line.StartsWith("Accept:", [System.StringComparison]::OrdinalIgnoreCase)) {
          $accept = $line.Substring(7).Trim()
        }
        elseif ($line.StartsWith("Sec-Fetch-Dest:", [System.StringComparison]::OrdinalIgnoreCase)) {
          $fetchDest = $line.Substring(15).Trim()
        }
      }

      # If a source file is opened directly in the address bar, send the player
      # back to the game. Module/script requests still receive the real files.
      $isDocumentNavigation = $fetchDest -eq "document" -or $accept.Contains("text/html")
      if ($isDocumentNavigation -and $relative.StartsWith("src/", [System.StringComparison]::OrdinalIgnoreCase)) {
        Send-Redirect $stream "/"
        continue
      }

      $candidate = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($root, $relative))
      if (-not $candidate.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        Send-Response $stream 403 "Forbidden" ([System.Text.Encoding]::UTF8.GetBytes("Forbidden")) "text/plain"
      }
      elseif (-not [System.IO.File]::Exists($candidate)) {
        Send-Response $stream 404 "Not Found" ([System.Text.Encoding]::UTF8.GetBytes("Not Found")) "text/plain"
      }
      else {
        Send-Response $stream 200 "OK" ([System.IO.File]::ReadAllBytes($candidate)) (Get-MimeType $candidate)
      }
    }
    finally {
      $client.Close()
    }
  }
}
finally {
  $listener.Stop()
}
