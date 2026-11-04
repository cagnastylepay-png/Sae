# AutoSAE modulaire — structure préparatoire

Statut : squelette uniquement. Test.lua et SaeLauncher.lua restent la version active.
Aucune fonction de Test.lua n'est encore migrée ; les fichiers ci-dessous ne remplacent pas le script actuel.

## Dépendances

Loader.lua -> modules/* -> lib/NotreLib.lua -> API du jeu et capacités de l'exécuteur.
Chaque module recevra context.LoadLibrary(), qui téléchargera NotreLib par loadstring et
réutilisera la même instance. Une seule connexion WebSocket par session client sera partagée
entre modules, identifiés par moduleId dans les messages. La bibliothèque ne dépendra d'aucun module.

Le futur loader utilisera une révision GitHub immuable pour tous ses téléchargements,
vérifiera les erreurs HTTP/compilation/exécution et démarrera les modules dans un ordre explicite.
Il ne faut pas mélanger des modules de plusieurs versions de main pendant une migration.

## Arborescence

- Loader.lua : futur point d'entrée, chargement, arrêt et redémarrage coordonnés.
- config/Defaults.lua : valeurs initiales, fonctionnalités réseau désactivées.
- lib/NotreLib.lua : catalogue des API à extraire de Test.lua.
- modules/EggObserver.lua : observation locale, reset, fin du chargement du nouveau cycle.
- modules/EggCollector.lua : file et collecte avec les règles existantes.
- modules/EggVisualizer.lua : interface locale Map/Queue/Backpack/Plot/Params.
- modules/InventoryManager.lua : ouverture, vente, placement, Equip Best, fusion.
- modules/ButterflyCollector.lua : attente papillons quand aucune cible.
- modules/ServerHopper.lua : recherche de serveurs, historique par cycle.
- modules/WebSocketClient.lua : transport partagé, reconnexion et abonnement des modules.
- modules/EggReporter.lua : publication Divine/Eternal/Secret pour chaque cycle.
- docs/Protocol.md : contrat réseau proposé.

## Règles conservées lors de la future migration

Divine toujours collecté. Eternal et autres raretés : revenu >= minimum OU
Manquants ON et espèce absente de l'index, du Backpack et du plot.
Eternal sous le seuil non éligible via Manquants : recherche sans collecte.
Les cibles passent avant toute maintenance. Serveurs les moins peuplés et non visités.
Pas de téléportation de personnage par CFrame/PivotTo.
La collecte, le reporting et le futur bouton GO restent trois responsabilités distinctes.

## Serveur

Dépôt : cagnastylepay-png/Render, dossier sae/.
Hôte fourni : https://m4gix-ws.onrender.com ; futur chemin /sae/ws (pas encore enregistré).
Le dashboard Eggs sera intégré après validation du protocole ; GO reste désactivé.
Aucun déploiement ni branchement au serveur actuel dans cette étape.
