# AutoSAE : protocole WebSocket v1

Transport JSON texte : wss://m4gix-ws.onrender.com/sae/ws.
Test.lua implémente temporairement le client. Les modules modular/ restent des squelettes.
Une connexion par session ; aucune commande distante et GO désactivé.

## Connexion

Premier message : {version:1,type:"hello",role:"reporter"|"viewer",token?:string}.
Réponse : {version:1,type:"hello.ack",role}.
Les clés sont optionnelles en test anonyme. SAE_REPORT_TOKEN et SAE_VIEW_TOKEN
activent la restriction correspondante sur Render. Les clés restent hors Git et logs.
Le navigateur renseigne la clé de lecture en mémoire. Le reporter la lit dans
shared.__AutoSAEReportingOptions.Token avant lancement ; aucune sauvegarde du token.
Un viewer ne peut pas publier. Aucun message reçu ne peut exécuter du Lua.

## eggs.snapshot (reporter -> serveur)

Champs : version=1, type="eggs.snapshot", moduleId="EggReporter", sessionId,
placeId (chaîne), jobId, cycleId (chaîne numérique), revision (entier >=1),
observedAt (ISO UTC), eggs (liste).
Œuf : uid, category, name, rarity (Divine/Eternal/Secret/Cosmic), weightKg et incomePerSecond
(nombre fini >=0 ou null). Les métriques inconnues ne deviennent jamais zéro.

Tous les œufs de ces trois raretés sont signalés, sans appliquer le seuil de collecte
ni le filtre Manquants. Après reset, attendre RarityRevealed.PeriodIndex et le batch
officiel ; relire le snapshot du jeu et regrouper les modifications.
Publier à la connexion, à chaque reset, aux changements de données utiles et toutes les
60 secondes pour renouveler les observations. Réémission forcée après reconnexion.

## Accusé et affichage

Réponse : {version:1,type:"eggs.ack",sessionId,cycleId,revision,accepted}.
Les révisions sont comparées par session/serveur/cycle. Les cycles plus anciens sont rejetés.
Le dernier snapshot complet reçu remplace celui du serveur, même si eggs est vide.
Les viewers reçoivent {version:1,type:"eggs.state",serverCount,eggs}.
Chaque ligne inclut placeId/jobId/cycleId et les heures d'observation/réception.
Le stockage mémoire expire après 10 minutes, borne à 100 serveurs et 200 œufs par snapshot.
Le serveur ignore un snapshot ancien/dupliqué ; les autres erreurs donnent type="error".
Le mode anonyme et les données clientes ne constituent aucune preuve d'autorité.

## Disponibilité

Connexion initiale et reconnexion en tâche séparée, temporisation 2..60 s,
attente de connexion jusqu'à 65 s pour le réveil de Render ; hello.ack sous 15 s
et eggs.ack sous 20 s. Le transport ne bloque pas l'Auto.
Logs [REPORT] persistés avec le reste des logs.
API de test : shared.__AutoSAEController.Reporting.MarkDirty(0).
Une instance fermée/remplacée déconnecte son socket et ses abonnements.

## Extension reporting-v2

eggs.snapshot ajoute cycleEndsAt (secondes Unix suivant le calendrier du jeu) et
les détails sérialisés : position {x,y,z}, cframe[12], sellValue, assetScale, mutations,
baseMutation, state, areaId, nestId/nestScale, couleur, genre/personnalité/skin disponibles,
version, droppedAt et carrierUserId. Le serveur construit globalUid=jobId/uid et
key=placeId/jobId/uid, puis fournit imageUrl locale à partir de son propre catalogue.
Les images de public/eggs sont incluses dans le dépôt Render.

players.snapshot : moduleId="PlayerReporter", sessionId/placeId/jobId,
reporterUserId, revision et players[].
Joueur : userId/name/displayName, walkSpeed, speedPower, incomePerSecond et incomeSource.
Les valeurs absentes sont inconnues. Le total est issu du roster répliqué (MoneyPerSecond).
Le serveur calcule reporterConnected à partir des sockets actifs ; le client ne choisit pas ce badge.
Accusé players.ack ; diffusion players.state aux viewers. Retrait immédiat à la fermeture
du socket, expiration au bout de 45 s sans rafraîchissement. Mise à jour groupée à 1 s,
heartbeat de présence 15 s, sans attendre la fin du reset des œufs.

eggs.events annonce appeared/disappeared/updated. Les listes restent des snapshots complets :
une disparition enlève la carte ; une réapparition la restaure avec le même UID composé.
Le serveur expire les œufs à cycleEndsAt, sinon prochain créneau de cinq minutes.
Le navigateur corrige son horloge à l'aide de serverTime et affiche les timers.

history.state transmet les 2 000 derniers événements avec date ISO UTC de réception ;
history.append diffuse les suivants. L'affichage convertit date/heure vers le fuseau du navigateur.
MongoDB Atlas via MONGODB_URI/MONGODB_DB=autosae assure la persistance ; sans URI,
repli sur disque local (éphémère sur Render sans volume). Stockage borné à 10 000 événements.
GO reste désactivé. Payload borné à 1 MiB, 500 œufs et 200 joueurs par snapshot.
