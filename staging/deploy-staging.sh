#!/usr/bin/env bash
# Déploiement SEMI-AUTOMATIQUE du staging : une commande, avec vérification et rollback.
#
#   ./deploy-staging.sh            -> déploie le dernier SHA publié par la CI sur Docker Hub
#   ./deploy-staging.sh ccbdf81    -> déploie une version précise
#
# Étapes : 1. version actuelle notée  2. pull des images  3. up -d
#          4. attente de /actuator/health = UP  5. smoke test du front et de /api
#          6. si échec : retour automatique à la version précédente
#
# Variables optionnelles : DH (compte Docker Hub, défaut mariamfathallah),
#                          HEALTH_TIMEOUT (secondes d'attente, défaut 120)
set -uo pipefail

cd "$(dirname "$0")"                       # le compose est dans le même dossier que le script

DH="${DH:-mariamfathallah}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-120}"
export DH

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# Dernier tag SHA sur Docker Hub (on ignore "latest" : on veut une version précise et traçable)
latest_tag() {
  curl -fsS --max-time 20 \
    "https://hub.docker.com/v2/repositories/${DH}/jat-backend/tags?page_size=10&ordering=last_updated" \
  | grep -o '"name": *"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/' | grep -v '^latest$' | head -n 1
}

# Tag de l'image du back qui tourne actuellement (vide si rien ne tourne ou image locale)
current_tag() {
  local id image
  id=$(docker compose ps -q backend 2>/dev/null)
  [ -n "$id" ] || return 0
  image=$(docker inspect --format '{{.Config.Image}}' "$id" 2>/dev/null)
  case "$image" in
    "${DH}/jat-backend:"*) echo "${image##*:}" ;;
  esac
}

# Déploie le tag $1 : pull puis up (seuls back et front changent, la base et la supervision restent)
deploy() {
  export TAG="$1"
  log "Téléchargement des images ${DH}/jat-backend:${TAG} et jat-frontend:${TAG}"
  docker compose pull --quiet backend frontend || return 1
  log "Mise à jour des conteneurs"
  docker compose up -d --no-build || return 1
}

# Attend que l'API réponde UP, puis vérifie le front et le passage de /api par nginx
check() {
  local back_port front_port waited=0 code
  back_port=$(docker compose port backend 8080 | sed 's/.*://')
  front_port=$(docker compose port frontend 8080 | sed 's/.*://')

  log "Attente de l'API (http://localhost:${back_port}/actuator/health, max ${HEALTH_TIMEOUT}s)"
  until curl -fsS --max-time 3 "http://localhost:${back_port}/actuator/health" 2>/dev/null | grep -q '"UP"'; do
    if [ "$waited" -ge "$HEALTH_TIMEOUT" ]; then
      log "ÉCHEC : l'API n'est pas UP après ${HEALTH_TIMEOUT}s"
      return 1
    fi
    sleep 5; waited=$((waited + 5))
  done
  log "API UP"

  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:${front_port}/")
  [ "$code" = "200" ] || { log "ÉCHEC : le front répond ${code}"; return 1; }

  # Sans connexion, l'API répond 401/403 : cela prouve que nginx joint bien le back (502 sinon)
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:${front_port}/api/applications")
  [ "$code" -lt 500 ] || { log "ÉCHEC : /api via le front répond ${code}"; return 1; }
  log "Smoke test OK (front 200, /api joignable : ${code})"
}

# ---------------------------------------------------------------------------
NEW_TAG="${1:-}"
if [ -z "$NEW_TAG" ]; then
  NEW_TAG=$(latest_tag) || true
  [ -n "$NEW_TAG" ] || { log "Impossible de lire le dernier tag sur Docker Hub"; exit 1; }
  log "Dernière version publiée par la CI : ${NEW_TAG}"
fi

PREV_TAG=$(current_tag)
log "Version actuelle : ${PREV_TAG:-aucune (ou image locale)} -> version demandée : ${NEW_TAG}"

if ! deploy "$NEW_TAG"; then
  log "ÉCHEC du pull ou du démarrage : rien n'a été remplacé si l'image n'existe pas"
  exit 1
fi

if check; then
  log "Staging déployé en ${NEW_TAG}"
  exit 0
fi

# ---- Rollback ----
if [ -n "$PREV_TAG" ] && [ "$PREV_TAG" != "$NEW_TAG" ]; then
  log "ROLLBACK vers ${PREV_TAG}"
  HEALTH_TIMEOUT=120                       # version déjà connue comme saine : délai normal
  if deploy "$PREV_TAG" && check; then
    log "Rollback réussi : le staging tourne à nouveau en ${PREV_TAG}"
  else
    log "Rollback en échec : intervention manuelle nécessaire (docker compose logs backend)"
  fi
else
  log "Pas de version précédente connue : pas de rollback (docker compose logs backend)"
fi
exit 1
