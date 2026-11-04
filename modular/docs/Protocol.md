# Protocole proposé : AutoSAE v1

Transport JSON WebSocket, futur chemin /sae/ws. Non branché dans cette étape.
Les modules accèdent au transport commun via NotreLib ; pas de socket supplémentaire par module.

## eggs.snapshot

Envoi à chaque réinitialisation une fois les données du nouveau cycle reçues.
Aussi à la première connexion et à la reconnexion, pour rattraper un reset manqué.
Un snapshot vide remplace les anciens œufs de ce serveur/cycle.
Observer le reset ET FieldRefreshed ; ne pas envoyer le snapshot du cycle précédent au signal de fermeture.
Après reset, un premier snapshot complet puis des révisions peuvent corriger les arrivées tardives.

Champs : version=1, type="eggs.snapshot", moduleId="EggReporter", sessionId,
placeId (chaîne), jobId, cycleId (chaîne), revision (entier croissant par session/cycle),
observedAt (date ISO UTC), eggs (liste).
Œuf : uid, category, name, rarity (Divine/Eternal/Secret), weightKg et incomePerSecond
(nombre fini >=0 ou null si inconnu). Ne jamais remplacer une donnée inconnue par zéro.

L'envoi n'applique pas le minimum de collecte ni le filtre Manquants.
Le serveur conserve des observations par session et serveur/cycle ; il ne compare pas les numéros
de révision de deux sessions différentes. Déduplication de l'affichage par placeId/jobId/cycleId/uid.
Les snapshots périmés doivent être ignorés et les anciennes sessions expirer.
Ne pas comparer les poids de deux serveurs sans vérifier le cycle.

## Dashboard

Le futur serveur publiera eggs.state aux abonnés autorisés : affichage dans Eggs,
revenu décroissant et filtre par rareté/cycle, avec serveur et heure de dernière observation.
Le bouton GO apparaît désactivé. Aucune commande distante n'est définie pour l'instant.

## Avant activation

Réutiliser l'authentification existante du dashboard ; définir séparément l'authentification
des clients Roblox avant de monter /sae/ws. Ne pas mettre de secret dans ce dépôt public.
Prévoir taille maximale, validation des messages, limite de fréquence, ping/pong et
reconnexion avec temporisation. Les clients sont des sources d'observation non autoritaires.
