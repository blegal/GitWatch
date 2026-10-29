# Consommation CPU et mémoire — rapport (version 1.0.1, 29 octobre 2026)

## Résumé

| Mesure (57 dépôts) | 1.0.0 | 1.0.1 | Gain |
|---|---:|---:|---:|
| Processus git lancés par vérification | 432 | 217 | −50 % |
| CPU de GitWatch par vérification locale | 0,92 s | 0,17 s | −82 % |
| CPU de GitWatch par vérification avec fetch | 1,60 s | 0,25 s | −84 % |
| CPU de git par vérification locale | 3,4 s | 2,5 s | −26 % |
| CPU de git par vérification avec fetch | 6,9 s | 5,9 s | −15 % |
| Durée d'une vérification locale | 0,83 s | 0,50 s | −40 % |
| Empreinte mémoire après 20 vérifications | 116 Mo | 21 Mo | −82 % |
| App réelle : empreinte après lancement et 1ʳᵉ vérification | 63 Mo | 23 Mo | −63 % |
| App réelle : CPU du lancement et de la 1ʳᵉ vérification | 3,0 s | 0,75 s | −75 % |
| Au repos (entre deux vérifications) | 0 % CPU, 0 réveil | 0 % CPU, 0 réveil | = |

La 1.0.0 ne gaspillait rien au repos. Le coût venait de chaque vérification, et la mémoire grimpait d'environ 1,1 Mo par vérification, sans jamais redescendre tant que les vérifications s'enchaînaient.

## Méthode

- Un banc d'essai temporaire, retiré avant le commit, lance l'application sans interface. Il fait d'abord une vérification d'échauffement, puis *n* vérifications de suite (20 locales, ou 3 avec fetch).
- Il relève pour chaque vérification :
  - la durée ;
  - le CPU du processus (`getrusage(RUSAGE_SELF)`) ;
  - le CPU des processus git (`RUSAGE_CHILDREN`) ;
  - le nombre de processus lancés ;
  - l'empreinte physique (`phys_footprint`).
- On retient les médianes. Les deux versions ont tourné coup sur coup, sur deux séries, avec des résultats concordants à ±3 %.
- Le contenu de la mémoire vient de `heap` ; `leaks` ne signale aucune fuite.
- L'application installée a été mesurée avec `footprint`, `ps` et `top` (réveils au repos).
- Contrôle de non-régression : l'état lu par la 1.0.1 est **identique** à celui de la 1.0.0.
  - Vérifié sur les 57 dépôts réels : branches, avance et retard, fichiers modifiés, stashes, branche par défaut et son retard, URL web.
  - Vérifié aussi sur un dépôt de test qui couvre une branche en avance sur son amont, une branche purement locale, une branche dont l'amont a disparu, un stash et un `origin/HEAD`.

## Problèmes trouvés et corrections

### 1. Mémoire retenue par chaque processus git (le plus gros poste)

- **Cause.** Chaque appel à git armait une minuterie de garde (`DispatchWorkItem` + `asyncAfter`, 30 à 90 s). Annulé, un `DispatchWorkItem` reste en file jusqu'à son échéance, avec tout ce que sa fermeture capture : le `Process`, ses deux `Pipe`, ses descripteurs de fichier et une copie de l'environnement (1,3 Ko).
- **Constat.** Après 20 vérifications, `heap` comptait 4 537 `NSConcreteTask` encore vivants, plus 18 000 `NSConcreteFileHandle` et 11,6 Mo de dictionnaires d'environnement.
- **Correction.**
  - La garde est désormais une `DispatchSourceTimer`, libérée dès son annulation, qui ne garde qu'une référence faible au processus.
  - Chaque appel s'exécute dans un pool d'autorelease : les fils de Swift Concurrency n'en vident pas.
- **Résultat.** L'empreinte reste plate à 21 Mo, au lieu de 115 Mo après 20 vérifications.

### 2. Trop de processus git par dépôt

Avant : 7 à 8 processus par dépôt :

- `status`
- `rev-list` (stash)
- `remote`
- `remote get-url`
- `symbolic-ref`
- `for-each-ref`, deux fois
- `diff` si le dépôt est modifié

Après : 3 processus de base :

- `status --porcelain=v2 --branch` : branche, amont, avance, retard, fichiers.
- Un seul `for-each-ref` sur `refs/heads`, `refs/remotes` et `refs/stash`. Il donne l'avance et le retard de chaque branche, l'existence de `origin/main` ou `master`, la cible de `origin/HEAD` et la présence d'un stash.
- `config --get-regexp remote.*.url` : noms et URL des remotes en un appel.

Les appels restants ne sont faits que si nécessaire :

- `diff --shortstat`, si le dépôt est modifié ;
- `rev-list` du stash, seulement si un stash existe ;
- `log` des commits à récupérer, si le dépôt est en retard.

Le retard de la branche par défaut se lit dans le suivi de `for-each-ref` quand elle suit son amont.

Le lancement d'un processus (`posix_spawn`) représentait l'essentiel du CPU propre à GitWatch. Moitié moins de processus, c'est moitié moins de ce coût.

### 3. Verrou et réécriture de l'index

`GIT_OPTIONAL_LOCKS=0` : `git status` ne réécrit plus l'index des dépôts surveillés. Cela fait moins d'écritures disque et plus de conflit de verrou avec l'éditeur ou un `git commit` lancé au même moment.

### 4. Environnement recopié à chaque appel

L'environnement des processus git (sans invite interactive, SSH en mode batch, `LC_ALL=C`) est construit une fois au lieu d'être recopié pour chaque appel.

### 5. Un rafraîchissement de l'interface par dépôt

- **Avant.** Chaque résultat modifiait `Monitor.repos`, ce qui faisait recalculer l'icône de la barre des menus et le menu ouvert : 57 fois par vérification.
- **Après.** Les résultats sont appliqués par lots, au plus deux fois par seconde. En pratique, c'est 2 à 12 mises à jour selon la durée du fetch, et l'affichage reste progressif.
- C'est ce qui fait passer le CPU de GitWatch de 0,53 s à 0,17 s par vérification, une fois les corrections 1 à 4 faites.

### 6. LaunchServices interrogé à chaque affichage

- **Avant.** Chaque ligne du menu cherchait VS Code, Zed, GitHub Desktop et Claude (`urlForApplication`) et rechargeait leur icône (`icon(forFile:)`), à chaque affichage et à chaque survol.
- **Après.** Application et icône sont gardées en cache. Le cache est vidé à chaque vérification, si bien qu'une application installée ou supprimée est prise en compte.

## Ce qui n'a pas été changé

- **Le fetch reste le poste principal.** Il représente environ 3,3 s de CPU git par vérification, et sa durée dépend du réseau. Tous les remotes de cette machine sont en HTTPS (48 GitHub, 8 gitlab.inria.fr), et chaque fetch paie sa poignée de main TLS et son appel au trousseau. Le multiplexage SSH (`ControlMaster`) n'aurait rien apporté ici.
- **Le levier qui reste est l'intervalle de vérification** (Réglages → Général, 15 min par défaut) :
  - toutes les 30 min, la consommation liée au fetch est divisée par deux ;
  - avec le réveil du Mac et le retour du réseau, qui déclenchent déjà une vérification, l'information reste fraîche.
- **Maintenance automatique de git.** Un fetch peut parfois déclencher `git maintenance` (gc) dans un dépôt. C'est le comportement normal de git, conservé : ce travail serait de toute façon fait au prochain fetch manuel.
- **La mémoire de l'interface n'a pas été mesurée.** Le menu ouvert et la fenêtre (SwiftUI) n'entrent pas dans les mesures ci-dessus, faites menu fermé.
