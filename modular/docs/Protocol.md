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
Œuf : uid, category, name, rarity (Divine/Eternal/Secret), weightKg et incomePerSecond
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
