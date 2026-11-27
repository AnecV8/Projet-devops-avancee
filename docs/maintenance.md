# Maintenance : opérations d'infrastructure qui peuvent couper le service

Ce document liste les opérations sur l'infrastructure de production (k3s sur vm1 + vm2) qui peuvent
provoquer une interruption, explique pourquoi, et donne la procédure sûre pour chacune.

Rappel de l'architecture : vm1 = serveur k3s (control plane) + charge, vm2 = agent.
Backend et frontend ont 2 pods minimum, répartis sur les deux VM. **PostgreSQL n'a qu'une seule réplique.**

## Résumé

| # | Opération | Coupure ? | Pourquoi |
|---|---|---|---|
| 1 | Drainer ou redémarrer la VM qui héberge PostgreSQL | **Oui, totale** | 1 seule réplique, volume `local-path` attaché à cette VM : le pod ne peut pas partir ailleurs |
| 2 | Redémarrer ou mettre à jour vm1 (serveur k3s) | Partielle | Plus de control plane : pas de déploiement, pas d'auto-scaling, pas de mode pull, `kubectl` indisponible |
| 3 | Mettre à jour k3s | Possible | Redémarrage des nœuds ; écart de version client/serveur |
| 4 | Changer la version majeure de PostgreSQL (16 → 17) | **Oui, totale** | Le format des données change : la nouvelle version refuse de démarrer sur l'ancien volume |
| 5 | Changer `db_password` dans le vault | **Oui, totale** | Le mot de passe n'est appliqué par PostgreSQL qu'à la création de la base : le back-end ne peut plus se connecter |
| 6 | Changer `jwt_secret` | Pas de coupure, mais impact | Tous les utilisateurs sont déconnectés (leurs jetons deviennent invalides) |
| 7 | Supprimer le namespace `jat` ou le PVC de PostgreSQL | **Oui + perte de données** | Le volume est supprimé avec les données |
| 8 | Migration de base destructive (Liquibase) | Possible | Pendant le rolling update, les anciens pods tournent encore avec le nouveau schéma |
| 9 | Arrêt ou redémarrage du PC hôte Windows | **Oui, totale** | Les deux VM Multipass s'arrêtent |
| 10 | Docker Hub indisponible ou limite de requêtes atteinte | Pas tout de suite | Les pods en place continuent ; un pod recréé sur un nœud sans l'image en cache reste en `ImagePullBackOff` |
| 11 | Mettre à jour la supervision (Helm) | Non pour l'appli | Trou de quelques minutes dans les métriques |
| 12 | Désinstaller ou réinstaller k3s | **Oui, totale** | Le cluster est recréé : certificats et kubeconfig changent, données perdues si le volume n'est pas sauvegardé |

## Avant toute opération risquée

```bash
# 1. Mettre le déploiement automatique en pause (sinon il peut déclencher un rollout pendant la maintenance)
ssh ubuntu@<IP vm1> sudo touch /etc/jat-pull.pause

# 2. Sauvegarder la base
kubectl -n jat exec postgres-0 -- pg_dump -U jobtracker jobtracker > backup-$(date +%F-%H%M).sql

# 3. Voir où tourne chaque pod
kubectl -n jat get pods -o wide
```

Après l'opération : vérifier `kubectl get nodes` et `kubectl -n jat get pods`, puis
`ssh ubuntu@<IP vm1> sudo rm /etc/jat-pull.pause`.

## Procédures

### 1. Maintenance de la VM qui héberge PostgreSQL

Interruption inévitable avec une seule réplique : annoncer une fenêtre de maintenance.

```bash
kubectl -n jat get pod postgres-0 -o wide            # quelle VM ?
kubectl cordon <vm>                                  # plus de nouveaux pods dessus
kubectl drain <vm> --ignore-daemonsets --delete-emptydir-data
# ... maintenance, redémarrage ...
kubectl uncordon <vm>
kubectl -n jat get pods -w                           # postgres-0 repart, les back-ends redeviennent Ready
```

Pendant la coupure, les pods back-end deviennent « non prêts » (leur readiness vérifie aussi la base) : ils ne sont
pas tués, et reprennent seuls quand la base revient.

Pour supprimer ce risque : base managée, ou PostgreSQL répliqué (opérateur CloudNativePG) avec stockage répliqué (Longhorn).

### 2. Maintenance de vm1 (serveur k3s)

L'appli continue de répondre via vm2 tant que PostgreSQL n'est pas sur vm1. Mais il n'y a plus de control plane :
pas de déploiement, pas de HPA, pas de mode pull, et `kubectl` ne répond plus.
Faire l'opération en dehors des heures d'usage, puis vérifier `kubectl get nodes`.
Pour supprimer ce risque : 3 serveurs k3s (etcd embarqué en haute disponibilité).

### 3. Mise à jour de k3s

Une version mineure à la fois (1.33 → 1.34), **le serveur d'abord**, puis l'agent :
modifier `k3s_version` dans `ansible/group_vars/all/main.yml`, relancer `ansible-playbook site.yml --ask-vault-pass`,
puis drainer et redémarrer les nœuds un par un. Mettre ensuite `kubectl` à la même version.

### 4. Changement de version majeure de PostgreSQL

Ne jamais changer seulement l'image. Procédure : sauvegarde (`pg_dump`), nouvelle base avec la nouvelle version,
restauration (`psql < backup.sql`), puis bascule du back-end.

### 5. Changement du mot de passe de la base

Dans cet ordre, sinon le back-end ne peut plus se connecter :

```bash
kubectl -n jat exec -it postgres-0 -- psql -U jobtracker -c "ALTER USER jobtracker PASSWORD 'nouveau';"
ansible-vault edit ansible/group_vars/all/vault.yml          # mettre le même mot de passe
ansible-playbook deploy.yml --ask-vault-pass                 # met à jour le Secret
kubectl -n jat rollout restart deployment/backend            # les pods relisent le Secret (sans coupure)
```

### 6. Rotation du secret JWT

Changer `jwt_secret` dans le vault, `deploy.yml`, puis `kubectl -n jat rollout restart deployment/backend`.
Prévenir les utilisateurs qu'ils devront se reconnecter.

### 7. Suppressions

Ne jamais lancer `kubectl delete namespace jat` ni supprimer le PVC `data-postgres-0` sans sauvegarde récente.

### 8. Migrations de schéma

Appliquer le principe *expand / contract* : d'abord ajouter (colonne, table) dans une version compatible avec
l'ancien code, puis supprimer l'ancien dans une version suivante. Jamais de renommage ou suppression de colonne
en une seule étape.

### 9. Redémarrage du PC hôte

Après un redémarrage de Windows : `multipass list` (VM en Running, IP inchangées), relancer la commande de
forwarding WSL ↔ Multipass (voir README), puis `kubectl get nodes`.

### 10. Docker Hub indisponible

Rien à faire pour les pods en place. Éviter de drainer un nœud tant que Docker Hub ne répond pas.
Le mode pull réessaie seul chaque minute.

### 11. Mise à jour de la supervision

`ansible-playbook monitoring.yml --ask-vault-pass` : sans effet sur l'application.

### 12. Réinstallation de k3s

Sauvegarder la base, relancer `ansible-playbook site.yml --ask-vault-pass`, restaurer la base,
réexporter le nouveau `KUBECONFIG`. Utilisé une fois pendant le projet après la fuite d'un kubeconfig :
réinstaller invalide les anciens certificats.

## Éléments de maintenance déjà en place

| Élément | Rôle |
|---|---|
| `/etc/jat-pull.pause` | met le déploiement automatique en pause |
| `/var/log/jat-pull.log` | historique des déploiements automatiques |
| `revisionHistoryLimit: 5` | permet `kubectl rollout undo` |
| PodDisruptionBudget backend (`minAvailable: 1`) | un `kubectl drain` ne peut pas arrêter tous les back-ends en même temps |
| Rolling update `maxUnavailable: 0` + readiness | mise à jour sans coupure |
| Playbooks idempotents | relancer Ansible pour remettre l'état voulu sans risque |