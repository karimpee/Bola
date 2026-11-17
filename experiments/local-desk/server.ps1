$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$prefix = "http://127.0.0.1:8080/"

function Read-JsonFile($path) {
  $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
  return $raw | ConvertFrom-Json
}

function Get-RequestBody($request) {
  $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
  try {
    $text = $reader.ReadToEnd()
  } finally {
    $reader.Dispose()
  }
  if ([string]::IsNullOrWhiteSpace($text)) {
    return $null
  }
  return $text | ConvertFrom-Json
}

function Send-Bytes($context, $status, $contentType, $bytes) {
  $context.Response.StatusCode = $status
  $context.Response.ContentType = $contentType
  $context.Response.ContentLength64 = $bytes.Length
  $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $context.Response.Close()
}

function Send-Text($context, $status, $contentType, $text) {
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
  Send-Bytes $context $status $contentType $bytes
}

function Send-Json($context, $status, $payload) {
  $json = $payload | ConvertTo-Json -Compress -Depth 6
  Send-Text $context $status "application/json; charset=utf-8" $json
}

function Normalize([string]$value) {
  if ($null -eq $value) { return "" }
  return $value.Trim().ToLowerInvariant()
}

$config = Read-JsonFile (Join-Path $root "config.json")
$verifications = @{}

function New-Verification($username, $topic) {
  $id = [guid]::NewGuid().ToString("N")
  $script:verifications[$id] = @{
    Username = $username
    Topic = $topic
    Expires = (Get-Date).AddMinutes(10)
    Used = $false
  }
  return $id
}

function Get-Verification([string]$id) {
  if ([string]::IsNullOrWhiteSpace($id) -or -not $script:verifications.ContainsKey($id)) {
    return $null
  }
  $record = $script:verifications[$id]
  if ($record.Used -or $record.Expires -lt (Get-Date)) {
    return $null
  }
  return $record
}

function Invoke-ExternalJson($url, $payload) {
  $body = $payload | ConvertTo-Json -Compress -Depth 6
  return Invoke-RestMethod -Method Post -Uri $url -Body $body -ContentType "application/json; charset=utf-8"
}

function Get-LocalVerify($username, $answer, $topic) {
  $accounts = Read-JsonFile (Join-Path $root "data\accounts.json")
  $account = $accounts.accounts | Where-Object { (Normalize $_.username) -eq (Normalize $username) } | Select-Object -First 1
  if ($null -eq $account -or (Normalize $account.verifyAnswer) -ne (Normalize $answer)) {
    return @{
      ok = $false
      message = "Verifikasi belum sesuai. Data tidak sama dengan yang terdaftar. Password tidak diubah."
    }
  }

  if ($topic -eq "withdrawal_issue") {
    if ($account.withdrawBlocked) {
      $message = "Verifikasi benar. Withdrawal belum bisa: $($account.withdrawReason)"
    } else {
      $message = "Verifikasi benar. Akun ini tidak sedang diblokir. Customer bisa mengajukan withdrawal."
    }
    return @{ ok = $true; message = $message }
  }

  $id = New-Verification $account.username $topic
  return @{
    ok = $true
    verificationId = $id
    message = "Verifikasi benar. Masukkan password baru untuk akun ini."
  }
}

function Invoke-Verify($payload) {
  $topic = [string]$payload.topic
  $allowed = @("login_password", "withdrawal_password", "withdrawal_issue")
  if ($allowed -notcontains $topic) {
    return @{ ok = $false; status = 400; message = "Jenis pertanyaan tidak dikenali. Password tidak diubah." }
  }
  if ([string]::IsNullOrWhiteSpace([string]$payload.username) -or [string]::IsNullOrWhiteSpace([string]$payload.answer)) {
    return @{ ok = $false; status = 400; message = "Username dan jawaban verifikasi wajib diisi. Password tidak diubah." }
  }

  if (-not [string]::IsNullOrWhiteSpace([string]$config.verifyApiUrl)) {
    try {
      $remote = Invoke-ExternalJson $config.verifyApiUrl $payload
    } catch {
      return @{ ok = $false; status = 502; message = "API verifikasi tidak bisa dihubungi. Password tidak diubah." }
    }
    if (-not $remote.ok) {
      $message = [string]$remote.message
      if ([string]::IsNullOrWhiteSpace($message)) {
        $message = "Verifikasi belum sesuai. Password tidak diubah."
      }
      return @{ ok = $false; message = $message }
    }
    if ($topic -eq "withdrawal_issue") {
      $message = [string]$remote.message
      if ([string]::IsNullOrWhiteSpace($message)) {
        $message = "Verifikasi benar."
      }
      return @{ ok = $true; message = $message }
    }
    $id = New-Verification ([string]$payload.username) $topic
    $message = [string]$remote.message
    if ([string]::IsNullOrWhiteSpace($message)) {
      $message = "Verifikasi benar. Masukkan password baru untuk akun ini."
    }
    return @{ ok = $true; verificationId = $id; message = $message }
  }

  return Get-LocalVerify ([string]$payload.username) ([string]$payload.answer) $topic
}

function Invoke-ChangePassword($payload) {
  $record = Get-Verification ([string]$payload.verificationId)
  if ($null -eq $record -or $record.Topic -eq "withdrawal_issue") {
    return @{ ok = $false; status = 403; message = "Verifikasi belum berhasil. Password tidak diubah." }
  }
  $newPassword = [string]$payload.newPassword
  if ($newPassword.Length -lt 8) {
    return @{ ok = $false; status = 400; message = "Password baru minimal 8 karakter. Password belum diubah." }
  }

  $passwordType = "login"
  $label = "login"
  if ($record.Topic -eq "withdrawal_password") {
    $passwordType = "withdrawal"
    $label = "withdrawal"
  }

  if (-not [string]::IsNullOrWhiteSpace([string]$config.changePasswordApiUrl)) {
    try {
      Invoke-ExternalJson $config.changePasswordApiUrl @{
        username = $record.Username
        passwordType = $passwordType
        newPassword = $newPassword
        verificationId = [string]$payload.verificationId
      } | Out-Null
    } catch {
      return @{ ok = $false; status = 502; message = "API ubah password tidak bisa dihubungi. Password tidak diubah." }
    }
  }

  $record.Used = $true
  return @{ ok = $true; message = "Password $label untuk $($record.Username) sudah diubah." }
}

function Invoke-Understand($payload) {
  $text = Normalize ([string]$payload.text)
  if ([string]::IsNullOrWhiteSpace($text)) {
    return @{ ok = $false; status = 400; topic = ""; message = "Kata-kata customer masih kosong." }
  }

  $aboutWithdraw = $text -match "withdraw|penarikan|\bwd\b|tarik"
  $aboutPassword = $text -match "password|sandi|\bpin\b|kata sandi"
  $aboutBlock = $text -match "tidak bisa|ga bisa|gak bisa|nggak bisa|kenapa|mengapa|gagal|ditahan|tertahan|pending|lupa"
  $aboutLogin = $text -match "login|masuk"

  if ($aboutWithdraw -and $aboutBlock -and -not $aboutPassword) {
    return @{
      ok = $true
      topic = "withdrawal_issue"
      message = "Baik. Customer tidak bisa melakukan withdrawal. Masukkan username dan jawaban verifikasi yang terdaftar."
    }
  }
  if ($aboutWithdraw -and $aboutPassword) {
    return @{
      ok = $true
      topic = "withdrawal_password"
      message = "Baik. Customer mau mengubah password withdrawal. Masukkan username dan jawaban verifikasi yang terdaftar."
    }
  }
  if ($aboutPassword -or ($aboutLogin -and $aboutBlock)) {
    return @{
      ok = $true
      topic = "login_password"
      message = "Baik. Customer mau mengubah password login. Masukkan username dan jawaban verifikasi yang terdaftar."
    }
  }
  if ($text -match "pagi|siang|sore|malam|halo|hai|hei|terima kasih|makasih") {
    return @{
      ok = $true
      topic = ""
      message = "Halo. Sampaikan saja masalah customer dalam satu kalimat."
    }
  }
  if ($text -match "paham|mengerti|ngerti|bingung|gimana|bagaimana|maksud") {
    return @{
      ok = $true
      topic = ""
      message = "Tidak apa-apa. Minta customer menceritakan masalahnya dengan kalimat biasa, misalnya tidak bisa masuk atau tidak bisa menarik dana."
    }
  }

  return @{
    ok = $true
    topic = ""
    message = "Kalimat itu sudah saya baca. Belum ada permintaan yang bisa dikerjakan. Minta customer menyebutkan masalahnya dalam satu kalimat."
  }
}

function Handle-Request($context) {
  $path = $context.Request.Url.AbsolutePath
  if ($context.Request.HttpMethod -eq "GET") {
    $file = switch ($path) {
      "/" { "static\index.html" }
      "/index.html" { "static\index.html" }
      "/app.js" { "static\app.js" }
      "/style.css" { "static\style.css" }
      default { $null }
    }
    if ($null -eq $file) {
      Send-Text $context 404 "text/plain; charset=utf-8" "Tidak ditemukan."
      return
    }
    $type = "text/html; charset=utf-8"
    if ($file.EndsWith(".js")) { $type = "text/javascript; charset=utf-8" }
    if ($file.EndsWith(".css")) { $type = "text/css; charset=utf-8" }
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $root $file))
    Send-Bytes $context 200 $type $bytes
    return
  }

  if ($context.Request.HttpMethod -ne "POST") {
    Send-Json $context 405 @{ ok = $false; message = "Metode tidak didukung." }
    return
  }

  $payload = Get-RequestBody $context.Request
  if ($null -eq $payload) {
    Send-Json $context 400 @{ ok = $false; message = "Body permintaan kosong. Password tidak diubah." }
    return
  }

  $result = switch ($path) {
    "/api/understand" { Invoke-Understand $payload }
    "/api/verify" { Invoke-Verify $payload }
    "/api/change-password" { Invoke-ChangePassword $payload }
    default { @{ ok = $false; status = 404; message = "API tidak ditemukan." } }
  }
  $status = 200
  if ($result.ContainsKey("status")) {
    $status = [int]$result.status
    $result.Remove("status")
  } elseif (-not $result.ok) {
    $status = 422
  }
  Send-Json $context $status $result
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)
$listener.Start()
Write-Output "Meja CS siap di $prefix"

try {
  while ($listener.IsListening) {
    $context = $listener.GetContext()
    try {
      Handle-Request $context
    } catch {
      try {
        Send-Json $context 500 @{ ok = $false; message = "Terjadi gangguan di meja CS. Password tidak diubah." }
      } catch {
        $context.Response.Abort()
      }
    }
  }
} finally {
  $listener.Stop()
}
