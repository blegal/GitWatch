# GitWatch

Application macOS de la barre des menus qui surveille vos dépôts Git : retard sur le serveur, commits non poussés, modifications locales, tirage automatique sûr. Native (SwiftUI, AppKit, UserNotifications, ServiceManagement), sans dépendance externe.

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
- **Tirage automatique** (par dépôt) : uniquement en avance rapide (`git merge --ff-only @{upstream}`), et seulement sans commit local ni modification en cours. Sinon le dépôt est juste signalé « À tirer ». Le tirage manuel (survol d'une ligne › Tirer, ou « Tout tirer ») est lui aussi en avance rapide uniquement.

## Menu de la barre des menus

L'icône montre le nombre de dépôts à tirer ou en erreur (désactivable). Deux présentations au choix dans les réglages :

- **Liste** : une pastille de couleur par dépôt et un résumé par état ; les dépôts à jour sont repliés.
- **Par action** : sections Erreurs, À tirer, À pousser, Modifications locales, Tirés aujourd'hui, À jour (repliée).

Clic sur une ligne : ouvre le dossier dans le Finder. Clic droit : tirer, ouvrir dans le Finder ou le Terminal, copier le chemin.

## Réglages

- **Dépôts** : tableau filtrable avec, pour chaque dépôt, les bascules *Suivre* et *Auto-pull* ; menu *Sélection* pour changer plusieurs dépôts à la fois.
- **Dossiers** : dossiers explorés et profondeur de recherche.
- **Général** : intervalle de vérification, présentation du menu, badge, notifications (nouveaux commits à tirer ; tirage automatique effectué ou échoué), ouverture à l'ouverture de session.
