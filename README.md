# Praćenje magacina – postavljanje od nule

## 1. Baza (Supabase)
1. Supabase → **SQL Editor** → New query. **Dolje desno pored Run mora pisati rola `postgres`** (ne `authenticated`/`anon`).
2. Provjera: `select current_user;` → mora vratiti `postgres`.
3. Brisanje stare baze: zalijepi `reset.sql` → Run. (Ili napravi potpuno novi Supabase projekat pa preskoči ovaj korak i u `index.html` upiši novi URL i ključ.)
4. Zalijepi cijeli `schema.sql` → Run. Treba pisati "Success".
4b. **Ako baza već postoji** (ne radiš reset): pokreni `migracija_izlaz.sql` → Run. Uvodi izlaz bez ruta (vođa bira pogon + kupca, izlaz skida sa stanja, historija ostaje).
5. Authentication → Sign In / Providers → Email → isključi **Confirm email**.
6. Provjera: `select email, role from profiles;` → Senad = upravnik, Belmin = vodja.

## 2. Aplikacija
U `index.html` su na vrhu `SUPABASE_URL` i `SUPABASE_KEY` (Project Settings → API → publishable/anon key). Provjeri da odgovaraju projektu.

Vođa (k.belmin) vidi tab **Magacin**: na **Izlazu** bira pogon i kupca, količina se skida sa stanja (artikal nestaje iz stanja kad padne na 0), a transakcija ostaje u **Historiji**. Rute se više ne koriste.

## 3. GitHub
```
cd C:\Users\t.nihad\Desktop\upravnik\magacin_monitoring
git add .
git commit -m "Nova verzija"
git push
```
Na GitHub stavi samo `index.html` i `manifest.webmanifest` (SQL fajlovi sadrže lozinke – ne guraj ih u javni repo).

## Korisnici
- Upravnik (samo pregled): o.senad@pobjeda.com / 123Pobjeda
- Belmin Korda (pogoni 12, 12A, 24A, prebacivanje među pogonima): k.belmin@pobjeda.com / 1234Pobjeda
Lozinke promijeniti nakon prve prijave (Supabase → Authentication → Users).
