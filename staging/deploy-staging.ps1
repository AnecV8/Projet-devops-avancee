# Déploiement SEMI-AUTOMATIQUE du staging : une commande, avec vérification et rollback.
#
#   .\deploy-staging.ps1            -> déploie le dernier SHA publié par la CI sur Docker Hub
#   .\deploy-staging.ps1 ccbdf81    -> déploie une version précise
#   (si Windows bloque le script : powershell -ExecutionPolicy Bypass -File .\deploy-staging.ps1)
#
# Étapes : 1. version actuelle notée  2. pull des images  3. up -d
#          4. attente de /actuator/health = UP  5. smoke test du front et de /api
#          6. si échec : retour automatique à la version précédente
#
# Variables optionnelles : $env:DH (compte Docker Hub, défaut mariamfathallah),
#                          $env:HEALTH_TIMEOUT (secondes d'attente, défaut 120)
param([string]$Tag = "")

# Les commandes docker écrivent leur progression sur stderr : ce n'est pas une erreur
$ErrorActionPreference = "Continue"
Set-Location $PSScriptRoot                    # le compose est dans le même dossier que le script

$Dh = if ($env:DH) { $env:DH } else { "mariamfathallah" }
$HealthTimeout = if ($env:HEALTH_TIMEOUT) { [int]$env:HEALTH_TIMEOUT } else { 120 }

# Le script modifie DH/TAG pour docker compose : on les restaure à la fin (sinon ils restent dans la session)
$savedDh = $env:DH
$savedTag = $env:TAG

function Write-Log($msg) { Write-Host "[$(Get-Date -Format HH:mm:ss)] $msg" }

# Dernier tag SHA sur Docker Hub (on ignore "latest" : on veut une version précise et traçable)
function Get-LatestTag {
    $url = "https://hub.docker.com/v2/repositories/$Dh/jat-backend/tags?page_size=10&ordering=last_updated"
    $res = Invoke-RestMethod -Uri $url -TimeoutSec 20
    return ($res.results | Where-Object { $_.name -ne "latest" } | Select-Object -First 1).name
}

# Tag de l'image du back qui tourne actuellement (vide si rien ne tourne ou image locale)
function Get-CurrentTag {
    $id = docker compose ps -q backend 2>$null
    if (-not $id) { return "" }
    $image = docker inspect --format '{{.Config.Image}}' $id 2>$null
    if ($image -like "$Dh/jat-backend:*") { return $image.Split(":")[-1] }
    return ""
}

# Code HTTP d'une adresse (0 si injoignable), sans lever d'erreur sur 4xx/5xx
function Get-HttpCode($url) {
    try {
        return [int](Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5).StatusCode
    } catch {
        if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }
        return 0
    }
}

# Déploie le tag : pull puis up (seuls back et front changent, la base et la supervision restent)
function Invoke-Deploy($t) {
    $env:DH = $Dh
    $env:TAG = $t
    Write-Log "Téléchargement des images $Dh/jat-backend:$t et jat-frontend:$t"
    docker compose pull --quiet backend frontend | Out-Host    # Out-Host : affiché, pas renvoyé par la fonction
    if ($LASTEXITCODE -ne 0) { return $false }
    Write-Log "Mise à jour des conteneurs"
    docker compose up -d --no-build | Out-Host
    return ($LASTEXITCODE -eq 0)
}

# Attend que l'API réponde UP, puis vérifie le front et le passage de /api par nginx
function Test-Staging {
    $backPort = (docker compose port backend 8080).Split(":")[-1]
    $frontPort = (docker compose port frontend 8080).Split(":")[-1]

    Write-Log "Attente de l'API (http://localhost:$backPort/actuator/health, max ${HealthTimeout}s)"
    $waited = 0
    while ($true) {
        try {
            $h = Invoke-RestMethod -Uri "http://localhost:$backPort/actuator/health" -TimeoutSec 3
            if ($h.status -eq "UP") { break }
        } catch { }
        if ($waited -ge $HealthTimeout) {
            Write-Log "ÉCHEC : l'API n'est pas UP après ${HealthTimeout}s"
            return $false
        }
        Start-Sleep -Seconds 5
        $waited += 5
    }
    Write-Log "API UP"

    $code = Get-HttpCode "http://localhost:$frontPort/"
    if ($code -ne 200) { Write-Log "ÉCHEC : le front répond $code"; return $false }

    # Sans connexion, l'API répond 401/403 : cela prouve que nginx joint bien le back (502 sinon)
    $code = Get-HttpCode "http://localhost:$frontPort/api/applications"
    if ($code -eq 0 -or $code -ge 500) { Write-Log "ÉCHEC : /api via le front répond $code"; return $false }
    Write-Log "Smoke test OK (front 200, /api joignable : $code)"
    return $true
}

# ---------------------------------------------------------------------------
$exitCode = 1
try {
    if (-not $Tag) {
        try { $Tag = Get-LatestTag } catch { $Tag = "" }
        if (-not $Tag) { throw "Impossible de lire le dernier tag sur Docker Hub" }
        Write-Log "Dernière version publiée par la CI : $Tag"
    }

    $prevTag = Get-CurrentTag
    $prevLabel = if ($prevTag) { $prevTag } else { "aucune (ou image locale)" }
    Write-Log "Version actuelle : $prevLabel -> version demandée : $Tag"

    if (-not (Invoke-Deploy $Tag)) {
        Write-Log "ÉCHEC du pull ou du démarrage : rien n'a été remplacé si l'image n'existe pas"
    }
    elseif (Test-Staging) {
        Write-Log "Staging déployé en $Tag"
        $exitCode = 0
    }
    elseif ($prevTag -and $prevTag -ne $Tag) {
        # ---- Rollback ----
        Write-Log "ROLLBACK vers $prevTag"
        $HealthTimeout = 120                  # version déjà connue comme saine : délai normal
        if ((Invoke-Deploy $prevTag) -and (Test-Staging)) {
            Write-Log "Rollback réussi : le staging tourne à nouveau en $prevTag"
        } else {
            Write-Log "Rollback en échec : intervention manuelle nécessaire (docker compose logs backend)"
        }
    }
    else {
        Write-Log "Pas de version précédente connue : pas de rollback (docker compose logs backend)"
    }
}
catch {
    Write-Log "ÉCHEC : $($_.Exception.Message)"
}
finally {
    $env:DH = $savedDh
    $env:TAG = $savedTag
}
exit $exitCode
