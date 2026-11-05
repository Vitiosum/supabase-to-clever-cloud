// ---------------------------------------------------------------------------
// Accès base — garder la RLS sans les rôles Supabase.
//
// Chez Supabase, PostgREST se connecte en `authenticator` et endosse `anon` ou
// `authenticated` selon le JWT ; les policies lisent auth.uid().
//
// Un add-on PostgreSQL managé ne permet pas de créer ces rôles par défaut
// (le support étudie ce type de demande — réponse écrite avant de planifier).
// Ce n'est de toute façon pas bloquant : la RLS ne dépend pas d'eux, elle
// dépend d'un contexte lisible en SQL, posé par transaction.
//
// PRÉREQUIS NON NÉGOCIABLE : l'application se connecte avec le rôle de
// l'add-on, qui est PROPRIÉTAIRE des tables (c'est lui qui joue les
// migrations). Or un propriétaire CONTOURNE la RLS, sauf si la table porte
//     alter table ma_table force row level security;
// Sans ce FORCE sur chaque table protégée, toutes les policies sont
// silencieusement ignorées et chaque requête voit tout. À vérifier :
//     select relname from pg_class
//      where relrowsecurity and not relforcerowsecurity;
// ---------------------------------------------------------------------------
import pg from 'pg';

// Nom de variable injecté par l'add-on lié. Vérifiez-le avec `clever env`
// plutôt que de le supposer — d'où le repli sur DATABASE_URL.
const chaine = process.env.POSTGRESQL_ADDON_URI || process.env.DATABASE_URL;
if (!chaine) throw new Error('Aucune chaîne de connexion : lancez `clever env`');

// LA RÈGLE QUI CASSE EN PREMIER À L'AUTOSCALING :
//     taille du pool × nombre max d'instances ≤ connexions max du plan.
// Ce chiffre n'est pas publié par plan : demandez-le au support avant de
// relever --max-instances. Un pool de 10 sur 3 instances sature un plan à 25.
export const pool = new pg.Pool({
  connectionString: chaine,
  max: Number(process.env.DB_POOL_MAX || 5),
  idleTimeoutMillis: 30_000,
});

/**
 * Exécute une fonction dans une transaction, avec le contexte utilisateur posé.
 *
 * `set local` est borné à la transaction : le contexte disparaît au COMMIT
 * comme au ROLLBACK. C'est ce qui rend le motif sûr malgré un pool de
 * connexions réutilisées — sans lui, la requête suivante hériterait de
 * l'identité de la précédente.
 *
 * Vos policies Supabase se migrent en remplaçant
 *     auth.uid()
 * par
 *     nullif(current_setting('app.utilisateur_id', true), '')::uuid
 *
 * Le nullif est OBLIGATOIRE : sur une connexion de pool ayant deja touche le
 * parametre puis rollback, current_setting renvoie '' (pas NULL), et ''::uuid
 * leve 22P02 dans chaque policy. Constate sur l'add-on reel.
 *
 * Le `true` demande à PostgreSQL de renvoyer NULL si le paramètre n'est pas
 * défini, au lieu de lever une erreur : une requête sans contexte ne voit donc
 * rien, au lieu de planter. C'est le comportement qu'on veut.
 */
export async function avecUtilisateur(utilisateurId, travail) {
  // Ne jamais poser la chaîne vide : contrairement à NULL, '' EST une valeur
  // pour current_setting, et ''::uuid lève 22P02 dans chaque policy. Un
  // identifiant absent ou mal formé => on ne pose rien, et
  // current_setting(..., true) renverra NULL : les policies ne voient rien.
  const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  const contexte = UUID.test(utilisateurId ?? '') ? utilisateurId : null;

  const client = await pool.connect();
  try {
    await client.query('begin');
    if (contexte) {
      // set_config(..., true) = équivalent de `set local`, mais paramétrable :
      // jamais d'interpolation de chaîne dans du SQL.
      await client.query("select set_config('app.utilisateur_id', $1, true)", [contexte]);
    }
    const resultat = await travail(client);
    await client.query('commit');
    return resultat;
  } catch (erreur) {
    await client.query('rollback');
    throw erreur;
  } finally {
    client.release();
  }
}

/** Requête sans identité : ne voit que ce qui est public au sens des policies. */
export async function anonyme(texte, valeurs) {
  return avecUtilisateur(null, (client) => client.query(texte, valeurs));
}

// --- Tâches planifiées : une exécution par créneau ----------------------------
// Les crons Clever Cloud tournent sur CHAQUE instance, et le filtre
// INSTANCE_NUMBER=0 de clevercloud/tache.sh ne suffit pas : pendant un
// déploiement, un scale ou un `clever restart`, l'ancienne instance et sa
// remplaçante peuvent être TOUTES DEUX numéro 0 (vérifié sur Clever Cloud le
// 2026-11-04). La garantie est donc en base : une ligne par tâche et par
// créneau, et seule l'instance qui l'insère exécute la tâche.
//
// Schéma à part, hors de medical : la phase E de reprise-cible.sh y force la
// RLS sur chaque table, et sans policy l'insert serait refusé (le rôle de
// l'add-on n'a pas BYPASSRLS). Ici, ce rôle crée la table, en est
// propriétaire, et la RLS n'y est pas activée.
//
// Le verrou consultatif sérialise la création : deux `create ... if not
// exists` concurrents peuvent échouer l'un sur l'autre, et deux instances
// numéro 0 appellent justement en même temps. Plusieurs instructions sans
// paramètre = une seule transaction implicite. Volume : une ligne par
// créneau, ~400 par jour pour les trois tâches, à purger si besoin.
const SCHEMA_TACHES = `
  select pg_advisory_xact_lock(hashtext('taches.execution_cron'));
  create schema if not exists taches;
  create table if not exists taches.execution_cron (
    tache   text        not null,
    creneau timestamptz not null,
    primary key (tache, creneau)
  );`;
let schemaTaches;

/**
 * Réserve le créneau courant de la tâche. Renvoie son horodatage si cette
 * instance l'a obtenu, null si une autre instance l'a déjà pris.
 *
 * Le créneau est calculé par la base, une seule horloge pour toutes les
 * instances : c'est la borne de période la plus proche de now(). Un cron du
 * quart d'heure parti à 09:44:59,9 ou à 09:45:01 tombe ainsi sur le même
 * créneau 09:45, malgré un léger décalage d'horloge ou un login shell lent.
 */
export async function prendreCreneau(tache, periode) {
  schemaTaches ??= pool.query(SCHEMA_TACHES).catch((erreur) => {
    schemaTaches = undefined; // réessayer au prochain appel
    throw erreur;
  });
  await schemaTaches;

  const { rows } = await pool.query(
    `insert into taches.execution_cron (tache, creneau)
     values ($1, date_bin($2::interval, now() + $2::interval / 2,
                          timestamptz '2000-01-01 00:00+00'))
     on conflict do nothing
     returning creneau`,
    [tache, periode],
  );
  return rows[0]?.creneau ?? null;
}
