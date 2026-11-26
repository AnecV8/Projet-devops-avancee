# Projet DevOps avancé — Déploiement continu d'une application multi-composants

Projet ESGI (DevOps avancé) : mise en production de l'application **Job Application Tracker**
(API Spring Boot + frontend React + PostgreSQL) avec conteneurs, Infrastructure-as-Code,
CI/CD, Kubernetes, zéro-downtime, auto-scaling et observabilité.

**Équipe :** <Basma MORABIT> · <Mariam FATHALLAH> · <Siham AIDROUS>

## Structure du dépôt

```
app/backend      API Spring Boot (Dockerfile, tests, tests d'intégration)
app/frontend     Frontend React / Vite
infra/ansible    Installation des VM (Docker, k3s) et déploiement — à venir
infra/k8s        Manifests Kubernetes / Helm — à venir
monitoring       Prometheus, Grafana (et Loki)
.github/workflows Pipeline CI/CD (GitHub Actions) — à venir
docs             Dossier de projet ; archive du projet CI/CD précédent
```

## Point de départ

Le code reprend le projet CI/CD Jenkins précédent (tag `base-cicd-jenkins`).
Jenkins, Nexus et le déploiement Docker/OpenTofu ont été retirés au profit de GitHub Actions et Kubernetes.
Documentation de l'application : [app/README.md](app/README.md).