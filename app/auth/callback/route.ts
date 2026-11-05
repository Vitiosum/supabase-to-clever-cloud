import { NextResponse, type NextRequest } from 'next/server';
import { creerClientServeur } from '@/lib/supabase/server';

/** Echange le code PKCE contre une session GoTrue. */
export async function GET(request: NextRequest) {
  const { searchParams, origin } = new URL(request.url);
  const code = searchParams.get('code');
  // Seul un chemin relatif du même site est accepté : sinon « suite=@autre.site »
  // donnerait https://<app>@autre.site, une redirection vers un autre domaine.
  const brut = searchParams.get('suite') ?? '/dossiers';
  const cible = new URL(brut.startsWith('/') && !brut.startsWith('//') ? brut : '/dossiers', origin);
  const suite = cible.origin === origin ? cible : new URL('/dossiers', origin);

  if (code) {
    const supabase = creerClientServeur();
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    if (!error) return NextResponse.redirect(suite);
  }

  return NextResponse.redirect(`${origin}/connexion?erreur=lien_invalide`);
}
