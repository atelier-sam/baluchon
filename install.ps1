# ============================================================
#  Baluchon - installeur Windows
#  Usage :  irm https://raw.githubusercontent.com/atelier-sam/baluchon/main/install.ps1 | iex
#  Installe Baluchon dans %USERPROFILE%\.baluchon et les commandes courtes "baluchon" / "baluchon1"
#  (alias historiques : "ccp" / "ccp1").
#
#  UNE seule chaine d'installation pour les deux systemes. Ce script ne fait que ce que Windows exige
#  en plus :
#   1. Git portable (bash + outils) dans .baluchon\git-win, verifie contre le digest publie par
#      l'API GitHub ; le menu de Baluchon est le meme script bash que sur Mac, lance par ce bash.
#   2. SHA256SUMS de la derniere release, SIGNE (ssh-keygen -Y verify, cle ci-dessous), puis
#      install.sh de cette release, verifie contre SHA256SUMS.
#   3. install.sh, lance par le bash de Git portable : il pose et verifie TOUT le reste exactement
#      comme sur Mac (wizard, bibliotheque, desinstalleur, noyau, claude.exe contre le manifest
#      d'Anthropic, gum contre son empreinte epinglee, releve signe qui rend la relance immediate et
#      autorise "Partir"), puis appelle le crochet de la couche s'il y en a une.
#   4. Les commandes .cmd et le PATH de l'utilisateur.
#  Toute verification qui echoue ARRETE l'installation.
#
#  Variables (facultatives) : BALUCHON_DIR, CCP_DL (source de la release ; la signature reste exigee),
#  BALUCHON_OUVRIR_MENU=1 (ouvre le menu a la fin), BALUCHON_ETAT_SORTIE (voir install.sh).
#  Fichier volontairement en ASCII (pas d'accents) : PowerShell 5.1 lit les scripts sans BOM en ANSI.
# ============================================================
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = "SilentlyContinue"   # Invoke-WebRequest est 10x plus lent avec la barre

$CcpDl  = if ($env:CCP_DL) { $env:CCP_DL } else { "https://github.com/atelier-sam/baluchon/releases/latest/download" }
$Signer = "baluchon-release ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIRcs8TrzgdQa1DTZ/Tdt2qUYCBeNuJ1p/DP27yyDttp"
$SignerId = ($Signer -split ' ')[0]
$Dir    = if ($env:BALUCHON_DIR) { $env:BALUCHON_DIR } else { "$env:USERPROFILE\.baluchon" }
$W      = Join-Path $env:TEMP ("baluchon-install-" + [guid]::NewGuid().ToString("N"))

function Fail($msg) { Write-Host "X $msg" -ForegroundColor Red; Remove-Item -Recurse -Force $W -ErrorAction SilentlyContinue; exit 1 }
function Ok($msg)   { Write-Host "OK $msg" -ForegroundColor Green }
function Say($msg)  { Write-Host ". $msg" -ForegroundColor Cyan }
function Sha($path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLower() }
function Get($url, $out) { Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing }

New-Item -ItemType Directory -Force -Path $W, "$Dir\git-win" | Out-Null
Say "Installation de Baluchon dans $Dir"

# --- 1) Git portable (bash du menu, ssh-keygen, curl) ----------------------------------------
function Install-PortableGit {
  Say "Telechargement de Git portable (interface + outils, une seule fois) ..."
  $rel = Invoke-RestMethod "https://api.github.com/repos/git-for-windows/git/releases/latest" -Headers @{ "User-Agent" = "baluchon-install" }
  $asset = $rel.assets | Where-Object { $_.name -match '^PortableGit-.*-64-bit\.7z\.exe$' } | Select-Object -First 1
  if (-not $asset) { Fail "Git portable introuvable dans la release officielle." }
  if (-not $asset.digest -or $asset.digest -notmatch '^sha256:') { Fail "Empreinte de Git portable non publiee : refus." }
  $exe = Join-Path $W "git.7z.exe"
  Get $asset.browser_download_url $exe
  if ((Sha $exe) -ne $asset.digest.Substring(7).ToLower()) { Fail "Empreinte invalide pour Git portable." }
  & $exe -o"$Dir\git-win" -y | Out-Null
  if (-not (Test-Path "$Dir\git-win\bin\bash.exe")) { Fail "Git portable mal extrait (bash.exe absent)." }
  Ok "Git portable verifie et installe"
}
if (-not (Test-Path "$Dir\git-win\bin\bash.exe")) { Install-PortableGit }
$Bash = "$Dir\git-win\bin\bash.exe"

$SshKeygen = (Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue).Source
if (-not $SshKeygen -and (Test-Path "$Dir\git-win\usr\bin\ssh-keygen.exe")) { $SshKeygen = "$Dir\git-win\usr\bin\ssh-keygen.exe" }
if (-not $SshKeygen) { Fail "ssh-keygen introuvable : impossible d'authentifier la release." }

# --- 2) Sommes signees de la release, puis install.sh verifie -------------------------------
Get "$CcpDl/SHA256SUMS" "$W\SHA256SUMS"
Get "$CcpDl/SHA256SUMS.sig" "$W\SHA256SUMS.sig"
[IO.File]::WriteAllText("$W\allowed_signers", "$Signer`n")
# Les OCTETS exacts de SHA256SUMS doivent arriver sur stdin : un pipe PowerShell re-encode le texte
# (et cmd /c casse les guillemets imbriques), d'ou Process avec ecriture binaire directe dans stdin.
$psi = New-Object Diagnostics.ProcessStartInfo $SshKeygen
$psi.Arguments = "-Y verify -f `"$W\allowed_signers`" -I $SignerId -n file -s `"$W\SHA256SUMS.sig`""
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
$proc = [Diagnostics.Process]::Start($psi)
$bytes = [IO.File]::ReadAllBytes("$W\SHA256SUMS")
$proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length); $proc.StandardInput.Close()
$null = $proc.StandardOutput.ReadToEnd(); $null = $proc.StandardError.ReadToEnd()
$proc.WaitForExit()
if ($proc.ExitCode -ne 0) { Fail "Signature de la release INVALIDE : installation annulee." }
Ok "Release authentifiee (signature $SignerId)"

$want = $null
foreach ($line in Get-Content "$W\SHA256SUMS") {
  if ($line -match '^([0-9a-f]{64})\s+\*?install\.sh$') { $want = $Matches[1] }
}
if (-not $want) { Fail "install.sh absent de la release." }
Get "$CcpDl/install.sh" "$W\install.sh"
if ((Sha "$W\install.sh") -ne $want) { Fail "Empreinte invalide pour install.sh : installation annulee." }

# --- 3) Le reste : install.sh, par le bash de Git portable ----------------------------------
# Chemins en barres obliques (C:/Users/...) : compris par bash comme par Windows. Le script est lu par
# son CHEMIN dans le dossier prive $W, qui n'est connu que de nous (GUID).
$env:BALUCHON_DIR = $Dir -replace '\\', '/'
& $Bash --noprofile --norc ("$W\install.sh" -replace '\\', '/')
$rc = $LASTEXITCODE
Remove-Item -Recurse -Force $W -ErrorAction SilentlyContinue
# "Partir" a pu tout effacer pendant le menu : rien d'autre a poser, le code dit ce qui reste.
if (-not (Test-Path "$Dir\.baluchon-install")) { exit $rc }
if ($rc -ne 0) { Fail "Installation interrompue (code $rc) : relance la meme commande." }

# --- 4) Commandes courtes et PATH -------------------------------------------------------------
$binDir = "$env:USERPROFILE\.local\bin"
New-Item -ItemType Directory -Force -Path $binDir | Out-Null
foreach ($n in @("baluchon", "ccp")) {
  Set-Content "$binDir\$n.cmd"  "@echo off`r`ncall `"$Dir\claude.cmd`" %*"
}
foreach ($n in @("baluchon1", "ccp1")) {
  Set-Content "$binDir\$n.cmd" "@echo off`r`nset `"CC_PROFILE=2`"`r`ncall `"$Dir\claude.cmd`" %*"
}
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$binDir*") {
  [Environment]::SetEnvironmentVariable("Path", "$userPath;$binDir", "User")
  Write-Host "$binDir ajoute au PATH (rouvre le terminal)." -ForegroundColor Yellow
}
Write-Host ""
Write-Host "OK. Rouvre un terminal et tape :  baluchon" -ForegroundColor Green
Write-Host "Tout est range dans $Dir (sessions comprises). Tout enlever : baluchon, puis Partir."
