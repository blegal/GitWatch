# GitWatch

Application macOS de la barre des menus qui surveille vos dépôts Git : pull et push à faire, modifications locales, auto-pull sûr. Native (SwiftUI, AppKit, UserNotifications, ServiceManagement) ; seule dépendance : UpdateKit (dépôt [iBaobab](https://github.com/blegal/iBaobab)) pour la mise à jour automatique.

## Compiler et lancer

```bash
./build.sh            # produit build/GitWatch.app
open build/GitWatch.app
```

Nécessite macOS 26+ et Xcode (Swift 6). `UNIVERSAL=1`, `VERSION`, `BUILD_NUMBER` et `SIGN_IDENTITY` fonctionnent comme pour Enhanced File Manager. L'application n'a pas d'icône dans le Dock (`LSUIElement`).

## Fonctionnement

- **Découverte** : les dossiers choisis dans les réglages (par défaut `~/GitHub`, profondeur 2) sont explorés à la recherche de dépôts. On ne descend pas dans un dépôt (sous-modules ignorés), ni dans `node_modules`, `Library`, `build`, `DerivedData`.
- **Vérification** : à l'intervalle choisi (5 min à 4 h), `git fetch --prune` sur chaque dépôt suivi (6 en parallèle), puis `git status --porcelain=v2 --branch` : commits en retard (↓) et en avance (↑) sur la branche suivie, fichiers modifiés et lignes non commitées (+/−, `git diff HEAD --shortstat`).
- **Identifiants** : ceux du système (clés SSH, agent, trousseau). Git ne demande jamais rien de façon interactive (`GIT_TERMINAL_PROMPT=0`, SSH en `BatchMode`) : un dépôt inaccessible apparaît simplement en erreur.
- **Auto-pull** (par dépôt) : uniquement en avance rapide (`git merge --ff-only @{upstream}`), et seulement sans commit local ni modification en cours. Sinon le dépôt est juste signalé « Pull à faire ». Le pull manuel (survol d'une ligne › ↓ Pull, ou ↓ Pull all) est lui aussi en avance rapide uniquement ; Pull all ignore les dépôts modifiés.
- **Push** : ↑ Push au survol d'un dépôt en avance, ou ↑ Push all pour tous les dépôts en avance et à jour avec le serveur (`git push`, refusé par le serveur s'il a des commits plus récents).
- **Fusions manuelles** : pour un dépôt divergé ou dont le pull a été refusé, le survol propose d'ouvrir GitHub Desktop (s'il est installé).
- **Détails** : fichiers non suivis, stashes en attente, commits non poussés sur d'autres branches (y compris les branches jamais poussées), branche courante différente de la branche par défaut (en orange, avec le retard de `main`). Au survol, la bulle d'aide liste les commits à récupérer (`git log HEAD..@{upstream}`).
- **Réveil et réseau** : une vérification est lancée au réveil du Mac et au retour du réseau (si la dernière date de plus de deux minutes).
- **Dépôt modifié** : le survol propose ↓ Pull ou ↑ Push (s'ils sont possibles), puis VS Code, GitHub Desktop et Claude (Claude Code lancé dans le Terminal, dans le dossier du dépôt). Seules les applications installées apparaissent.

## Menu de la barre des menus

L'icône montre le nombre de pull à faire et de dépôts en erreur (désactivable). Deux présentations au choix dans les réglages :

- **Liste** : une pastille de couleur par dépôt et un résumé par état ; les dépôts à jour sont repliés.
- **Par action** : sections Erreurs, Pull à faire, Push à faire, Modifications locales, Pull du jour, À jour (repliée).

Clic sur une ligne : ouvre le dossier dans le Finder. Clic droit : Pull, Push, commits à récupérer, ouvrir dans VS Code, GitHub Desktop, Claude Code, le Finder, le Terminal ou sur GitHub/GitLab, copier le chemin, ne plus suivre.

## Fenêtre

Bouton fenêtre de l'en-tête du menu (ou *Réglages…*), deux onglets :

- **Tableau de bord** : catégories dans la barre latérale (avec leur nombre), liste des dépôts avec les boutons Pull / Push / Fusionner toujours visibles, et panneau de détail : état, commits à récupérer, branches non poussées, outils. Sélection multiple : Pull et Push groupés.
- **Réglages** : les panneaux ci-dessous.

## Réglages

- **Dépôts** : tableau filtrable avec, pour chaque dépôt, les bascules *Suivre* et *Auto-pull* ; menu *Sélection* pour changer plusieurs dépôts à la fois.
- **Dossiers** : dossiers explorés et profondeur de recherche.
- **À cloner** : dépôts de vos comptes absents de ce Mac, avec *Cloner* (dans le dossier choisi) et *Ignorer*. GitHub via GitHub CLI (`gh auth login`) ; GitLab via un jeton personnel (portée `read_api`) par serveur, saisi dans *Général* et gardé dans le trousseau. Archivés, partagés, forks et ignorés : menu *Afficher*.
- **Général** : intervalle de vérification, présentation du menu, badge, notifications (pull à faire ; auto-pull effectué ou échoué), comptes distants, ouverture à l'ouverture de session, recherche de mises à jour.

## Releases et mise à jour

Le workflow `.github/workflows/release.yml` compile un binaire universel et produit `GitWatch-<version>.dmg` à chaque push ; sur un tag `v*`, il publie une release GitHub. L'image disque est signée en Ed25519 avec le secret `UPDATE_SIGNING_KEY` (clé : `swift Tools/make-update-key.swift`), et l'application vérifie cette signature avant d'installer (clé publique `UpdatePublicKey` dans `Info.plist`). La vérification est silencieuse au lancement tant que le dépôt est privé.

- `Tools/bump-version.sh` : incrémente la version avant un commit.
- `Tools/make-icon.sh` : régénère `Resources/AppIcon.icns`.
