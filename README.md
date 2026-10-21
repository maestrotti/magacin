# Praćenje magacina – postavljanje od nule

## 1. Baza (Supabase)
1. Supabase → **SQL Editor** → New query. **Dolje desno pored Run mora pisati rola `postgres`** (ne `authenticated`/`anon`).
2. Provjera: `select current_user;` → mora vratiti `postgres`.
3. Brisanje stare baze: zalijepi `reset.sql` → Run. (Ili napravi potpuno novi Supabase projekat pa preskoči ovaj korak i u `index.html` upiši novi URL i ključ.)
4. Zalijepi cijeli `schema.sql` → Run. Treba pisati "Success".
4b. **Ako baza već postoji** (ne radiš reset): pokreni `migracija_izlaz.sql` → Run. Uvodi magacin kao jednu lokaciju (ulaz bez pogona, izlaz bira pogon), bez ruta.
5. Authentication → Sign In / Providers → Email → isključi **Confirm email**.
6. Provjera: `select email, role from profiles;` → Senad = upravnik, Belmin = vodja.

## 2. Aplikacija
U `index.html` su na vrhu `SUPABASE_URL` i `SUPABASE_KEY` (Project Settings → API → publishable/anon key). Provjeri da odgovaraju projektu.

Vođa (k.belmin) vidi tab **Magacin** i radi u **Glavnom magacinu**:
- **Ulaz** – nema izbora pogona, roba ulazi u magacin.
- **Izlaz** – bira kupca, artikal i **pogon u koji roba ide**; količina se skida sa stanja magacina (artikal nestaje iz stanja kad padne na 0), a pogon i transakcija ostaju u **Historiji**.
- Rute se više ne koriste.

## 3. GitHub
```
cd C:\Users\t.nihad\Desktop\upravnik\magacin_monitoring
git add .
git commit -m "Nova verzija"
git push
```
Na GitHub idu `index.html`, `manifest.webmanifest` i `migracija_izlaz.sql` (bez lozinki). `schema.sql` i `reset.sql` ne guraj u javni repo – sadrže lozinke/e-mailove.

## Korisnici
- Upravnik (samo pregled): o.senad@pobjeda.com / 123Pobjeda
- Belmin Korda (Glavni magacin – ulaz bez pogona, izlaz bira pogon): k.belmin@pobjeda.com / 1234Pobjeda
Lozinke promijeniti nakon prve prijave (Supabase → Authentication → Users).
