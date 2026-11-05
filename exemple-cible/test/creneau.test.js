// ---------------------------------------------------------------------------
// Déduplication des tâches planifiées, contre un PostgreSQL local :
//
//   DATABASE_URL='postgresql://localhost/<db>' npm test
//
// Rejoue le cas vérifié sur Clever Cloud le 2026-11-04 : pendant un
// déploiement, deux instances numéro 0 lancent la même tâche au même créneau.
// Une seule doit l'exécuter. Noms de tâche aléatoires : le test ne prend
// jamais le créneau d'une vraie tâche, et peut être rejoué.
// ---------------------------------------------------------------------------
import { after, test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { pool, prendreCreneau } from '../db.js';

// Période d'un jour : les appels d'un même test tombent dans le même créneau.
const PERIODE = '1 day';
const noms = [];
const nom = () => {
  const n = `test-${randomUUID()}`;
  noms.push(n);
  return n;
};

after(async () => {
  await pool.query('delete from taches.execution_cron where tache = any($1)', [noms]);
  await pool.end();
});

test('deux instances, même créneau : une seule exécute', async () => {
  const tache = nom();
  const resultats = await Promise.all([
    prendreCreneau(tache, PERIODE),
    prendreCreneau(tache, PERIODE),
  ]);
  assert.equal(resultats.filter(Boolean).length, 1);
});

test('appel suivant dans le même créneau : déjà exécutée', async () => {
  const tache = nom();
  assert.ok(await prendreCreneau(tache, PERIODE));
  assert.equal(await prendreCreneau(tache, PERIODE), null);
});

test('une autre tâche garde son propre créneau', async () => {
  const a = nom();
  const b = nom();
  assert.ok(await prendreCreneau(a, PERIODE));
  assert.ok(await prendreCreneau(b, PERIODE));
});
