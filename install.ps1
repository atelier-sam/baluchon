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

# Sortie avec code. Lance par -File (amorce de la couche, essais) : `exit`, dont l'appelant lit le code. Lance par
# `irm ... | iex` (README) : `exit` FERMERAIT la fenetre PowerShell de l'utilisateur avant qu'il ait lu le message
# (mesure le 16/11/2026) ; on pose alors $LASTEXITCODE et `break`, qui arrete le script sans tuer PowerShell (meme
# geste que l'installeur de Scoop). Jamais appele depuis une boucle : `break` en sortirait seulement.
function Stop-Install([int]$code) {
  if ($PSCommandPath) { exit $code }
  $global:LASTEXITCODE = $code
  break
}
function Fail($msg) { Write-Host "X $msg" -ForegroundColor Red; Remove-Item -Recurse -Force $W -ErrorAction SilentlyContinue; Stop-Install 1 }
function Ok($msg)   { Write-Host "OK $msg" -ForegroundColor Green }
function Say($msg)  { Write-Host ". $msg" -ForegroundColor Cyan }
function Sha($path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLower() }
function Get($url, $out) { Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing }

# "Partir" (menu) efface tout SAUF git-win, dont le bash tourne encore, et pose .baluchon-a-finir (voir
# uninstall.sh). Cette fonction finit le travail une fois bash termine : git-win avec reessais (un guetteur
# bash peut survivre ~2 s au menu), le temoin, puis le dossier SEULEMENT s'il est vide (Directory.Delete non
# recursif) : rien d'autre n'est jamais efface ici. Rend $true si plus rien ne reste du dossier.
function Finish-Depart {
  if (-not (Test-Path -LiteralPath "$Dir\.baluchon-a-finir") -or (Test-Path -LiteralPath "$Dir\.baluchon-install")) { return $false }
  # Local a la fonction : sous "Stop", PowerShell 5.1 fait d'une ligne d'erreur d'un programme natif (rmdir sur
  # un fichier encore ouvert) une erreur fatale ; ici un echec se constate en relisant le disque.
  $ErrorActionPreference = "Continue"
  Set-Location $env:TEMP
  # rmdir /s de cmd, pas Remove-Item -Recurse : celui de PowerShell 5.1 peut suivre une jonction et vider sa
  # cible ; rmdir retire la jonction elle-meme sans y entrer (on ne suit jamais un lien pour effacer).
  for ($i = 0; $i -lt 30 -and (Test-Path -LiteralPath "$Dir\git-win"); $i++) {
    & cmd.exe /d /c rmdir /s /q "$Dir\git-win" 2>$null
    if (Test-Path -LiteralPath "$Dir\git-win") { Start-Sleep -Seconds 1 }
  }
  if (-not (Test-Path -LiteralPath "$Dir\git-win")) { Remove-Item -LiteralPath "$Dir\.baluchon-a-finir" -Force -ErrorAction SilentlyContinue }
  try { [IO.Directory]::Delete($Dir, $false) } catch {}
  return -not (Test-Path -LiteralPath $Dir)
}

# Un depart precedent inacheve (fenetre fermee avant la derniere etape) : on le termine avant de reinstaller,
# pour repartir d'un Git portable verifie plutot que de reprendre un git-win que plus rien n'authentifie.
if ((Test-Path -LiteralPath "$Dir\.baluchon-a-finir") -and -not (Test-Path -LiteralPath "$Dir\.baluchon-install")) {
  if (-not (Finish-Depart) -and (Test-Path -LiteralPath "$Dir\git-win")) { Fail "Un depart precedent n'a pas pu finir ($Dir\git-win) : ferme les fenetres Baluchon et relance." }
}

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

# TOUJOURS le ssh-keygen de Git portable (verifie a l'etape 1), jamais celui de Windows : le
# ssh-keygen de C:\Windows\System32\OpenSSH ne voit pas la fin d'un stdin redirige et attend
# indefiniment (mesure le 15/11/2026 sur Windows 11 : -Y verify bloque, celui de Git rend 0).
$SshKeygen = "$Dir\git-win\usr\bin\ssh-keygen.exe"
if (-not (Test-Path $SshKeygen)) { Fail "ssh-keygen de Git portable introuvable : impossible d'authentifier la release." }

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
# Sorties lues en asynchrone AVANT d'ecrire stdin : aucun interblocage possible sur un tampon plein.
$outTask = $proc.StandardOutput.ReadToEndAsync(); $errTask = $proc.StandardError.ReadToEndAsync()
$bytes = [IO.File]::ReadAllBytes("$W\SHA256SUMS")
$proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length); $proc.StandardInput.BaseStream.Flush(); $proc.StandardInput.Close()
# Une verification qui ne rend pas la main en 60 s est un ECHEC, jamais une attente sans fin.
if (-not $proc.WaitForExit(60000)) { try { $proc.Kill() } catch {}; Fail "Verification de signature bloquee (ssh-keygen) : installation annulee." }
$null = $outTask.Result; $null = $errTask.Result
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
# Le menu demande (BALUCHON_OUVRIR_MENU=1) n'est PAS ouvert par install.sh : il le serait avant que les commandes
# .cmd et le PATH (etape 4) existent, et une fenetre fermee pendant le menu laissait une installation sans commande
# (mesure le 16/11/2026). Il est ouvert a la fin de ce script, par claude.cmd, qui sait finir un "Partir".
$ouvrirMenu = ($env:BALUCHON_OUVRIR_MENU -eq "1")
$env:BALUCHON_OUVRIR_MENU = "0"
& $Bash --noprofile --norc ("$W\install.sh" -replace '\\', '/')
$rc = $LASTEXITCODE
if ($ouvrirMenu) { $env:BALUCHON_OUVRIR_MENU = "1" } else { Remove-Item Env:BALUCHON_OUVRIR_MENU -ErrorAction SilentlyContinue }
Remove-Item -Recurse -Force $W -ErrorAction SilentlyContinue
# "Partir" a pu tout effacer pendant le menu : rien d'autre a poser. Derniere etape (git-win), relue.
if (-not (Test-Path "$Dir\.baluchon-install")) {
  if (Test-Path -LiteralPath "$Dir\.baluchon-a-finir") {
    if (Finish-Depart) { Write-Host "  OK Rien ne reste sur cet ordinateur." -ForegroundColor Green; Stop-Install $rc }
    Write-Host "  ! Il reste le dossier $Dir : ferme les fenetres Baluchon puis supprime-le a la main." -ForegroundColor Yellow
    Stop-Install 12
  }
  Stop-Install $rc
}
if ($rc -ne 0) { Fail "Installation interrompue (code $rc) : relance la meme commande." }

# --- 4) Commandes courtes et PATH -------------------------------------------------------------
$binDir = "$env:USERPROFILE\.local\bin"
New-Item -ItemType Directory -Force -Path $binDir | Out-Null
# Une seule ligne qui ENCHAINE sur claude.cmd (pas de `call`) : cmd ne revient jamais lire cette commande,
# que "Partir" efface pendant le menu (sinon : "Le fichier de commandes est introuvable").
foreach ($n in @("baluchon", "ccp")) {
  Set-Content "$binDir\$n.cmd"  "@`"$Dir\claude.cmd`" %*"
}
foreach ($n in @("baluchon1", "ccp1")) {
  Set-Content "$binDir\$n.cmd" "@set `"CC_PROFILE=2`" & `"$Dir\claude.cmd`" %*"
}
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$binDir*") {
  [Environment]::SetEnvironmentVariable("Path", "$userPath;$binDir", "User")
  Write-Host "$binDir ajoute au PATH (rouvre le terminal)." -ForegroundColor Yellow
}
if ($ouvrirMenu) {
  # Le meme chemin que la commande `baluchon` : claude.cmd lance le menu, puis termine lui-meme un "Partir"
  # (git-win, dossier) et dit "Rien ne reste" ; son code de sortie est le notre. BALUCHON_DEPUIS_LIEN : le
  # menu sait qu'il vient du lien (question "cet ordinateur est-il a toi ?", Partir en tete sur un poste invite).
  $env:BALUCHON_DEPUIS_LIEN = "1"
  & "$Dir\claude.cmd"
  $rc = $LASTEXITCODE
  Remove-Item Env:BALUCHON_DEPUIS_LIEN -ErrorAction SilentlyContinue
  if (-not (Test-Path "$Dir\.baluchon-install")) { Stop-Install $rc }
}
Write-Host ""
Write-Host "OK. Rouvre un terminal et tape :  baluchon" -ForegroundColor Green
Write-Host "Tout est range dans $Dir (sessions comprises). Tout enlever : baluchon, puis Partir."
