# Exemple de cible — ce qui remplace Supabase

*The target example — what replaces Supabase. Comments in the code are in
French; the patterns are language-agnostic.*

Squelette minimal d'un backend qui remplace **PostgREST + GoTrue + Realtime**
et parle directement à un add-on PostgreSQL managé.

**Ce n'est pas un framework.** C'est le plus petit code qui démontre les trois
choses qu'on ne trouve nulle part écrites noir sur blanc :

| Fichier | Ce qu'il démontre |
|---|---|
| `db.js` | garder la RLS **sans** les rôles Supabase, en posant le contexte utilisateur par transaction |
| `stockage.js` | parler à Cellar, avec le piège du nom d'hôte nu |
| `clevercloud/tache.sh` + `prendreCreneau` (`db.js`) | une tâche planifiée qui ne s'exécute **qu'une fois par créneau**, même quand deux instances sont numéro 0 |
| `serveur.js` | l'assemblage, et ce que remplace chaque route |

## Le point central : la RLS sans `anon` ni `authenticated`

C'est la question que se pose tout utilisateur de Supabase, et la réponse tient
en trois lignes.

Chez Supabase, PostgREST se connecte en `authenticator`, endosse `anon` ou
`authenticated` selon le JWT, et vos policies lisent `auth.uid()`.

Un add-on managé ne permet pas de les créer par défaut — le support peut les
ouvrir sur demande. Mais on peut s'en passer entièrement : **la RLS ne dépend
pas de ces rôles**, elle dépend d'un contexte lisible en SQL. On le pose
soi-même, par transaction, sans rien demander à personne :

```sql
set local app.utilisateur_id = '...';
```

Et les policies le lisent :

```sql
create policy "son propre dossier" on patients
  for select using (
    profil_id = nullif(current_setting('app.utilisateur_id', true), '')::uuid
  );
```

`set local` est **borné à la transaction** : pas de fuite d'un contexte vers la
requête suivante, même avec un pool de connexions réutilisées.

**Le `nullif` n'est pas décoratif.** Constaté sur la plateforme réelle : sur
une connexion de pool qui a déjà touché ce paramètre puis fait `rollback`,
`current_setting(…, true)` renvoie la **chaîne vide**, pas NULL — et
`''::uuid` fait planter la policy en `22P02`. Avec `nullif`, le cas retombe
sur NULL : zéro ligne, zéro erreur.

**Et le prérequis qu'on rate le plus souvent** : votre application se connecte
avec le rôle de l'add-on, qui est **propriétaire des tables** (c'est lui qui
joue les migrations). Or un propriétaire **contourne la RLS**, sauf si la
table porte :

```sql
alter table ma_table force row level security;
```

Sans ce `FORCE` sur chaque table protégée, toutes vos policies sont
**silencieusement ignorées**. Contrôle :

```sql
select relname from pg_class where relrowsecurity and not relforcerowsecurity;
```

**Migrer vos policies revient donc à remplacer `auth.uid()` par
`current_setting('app.utilisateur_id', true)::uuid`.** Le reste ne bouge pas.

## Ce que ce squelette ne fait pas

Volontairement, pour rester lisible :

- **l'authentification.** Vérifiez un JWT, ou déléguez à un add-on Keycloak.
  Le squelette suppose que `req.utilisateurId` est déjà rempli.
- **le temps réel.** Si vous utilisez *Broadcast* ou *Presence*, un WebSocket
  applicatif suffit. Si vous dépendez de *Postgres Changes*, relisez la section
  sur Kubernetes de [ATTERRIR-SUR-CLEVER-CLOUD.md](../ATTERRIR-SUR-CLEVER-CLOUD.md).
- **les migrations de schéma.** Gardez celles de Supabase : c'est du
  PostgreSQL standard. Seule exception : `db.js` crée lui-même la petite table
  `taches.execution_cron` des tâches planifiées.

## Les tâches planifiées : une fois par créneau

Les crons Clever Cloud tournent sur **chaque instance**. `tache.sh` écarte les
instances autres que 0, mais pendant un déploiement, un scale ou un
`clever restart`, l'ancienne instance et sa remplaçante peuvent être **toutes
deux numéro 0** (vérifié sur Clever Cloud le 4 novembre 2026) : la tâche
partirait deux fois.

La garantie est donc en base. La route `/taches/:nom` insère
`(tâche, créneau)` dans `taches.execution_cron` avec `on conflict do nothing` ;
le créneau est la période du cron (15 minutes pour `battement`), calculé par
PostgreSQL pour que toutes les instances tombent d'accord. Seule l'instance qui
obtient la ligne exécute ; les autres répondent 200 « déjà exécutée ». La table
est hors du schéma `medical`, où la RLS est forcée : le rôle de l'add-on n'a
pas `BYPASSRLS`.

Test, contre un PostgreSQL local :

```bash
DATABASE_URL='postgresql://localhost/<db>' npm test
```

## Démarrer

```bash
npm install
```

Les variables des add-ons liés sont injectées automatiquement. **Vérifiez leurs
noms plutôt que de les deviner** :

```bash
clever env --alias mon-app
```

| Variable | Vient de |
|---|---|
| `POSTGRESQL_ADDON_URI` | add-on PostgreSQL lié |
| `CELLAR_ADDON_HOST`, `CELLAR_ADDON_KEY_ID`, `CELLAR_ADDON_KEY_SECRET` | add-on Cellar lié |
| `PORT` | plateforme |
| `INSTANCE_NUMBER` | plateforme — premier filtre des crons (instance 0 seulement) ; ne suffit pas seul, voir ci-dessous |
| `API_SERVICE_TOKEN` | **à poser soi-même** : `clever env set API_SERVICE_TOKEN "$(openssl rand -hex 32)"` — exigé au démarrage, protège `/taches/*` |

```bash
clever deploy --alias mon-app
```
