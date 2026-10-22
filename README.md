# Praćenje magacina – postavljanje od nule

## 1. Baza (Supabase)
1. Supabase → **SQL Editor** → New query. **Dolje desno pored Run mora pisati rola `postgres`** (ne `authenticated`/`anon`).
2. Provjera: `select current_user;` → mora vratiti `postgres`.
3. Brisanje stare baze: zalijepi `reset.sql` → Run. (Ili napravi potpuno novi Supabase projekat pa preskoči ovaj korak i u `index.html` upiši novi URL i ključ.)
4. Zalijepi cijeli `schema.sql` → Run. Treba pisati "Success".
4b. **Ako baza već postoji** (ne radiš reset): pokreni `migracija_izlaz.sql` → Run. Uvodi magacin kao jednu lokaciju (ulaz bez pogona, izlaz bira pogon), bez ruta. Skripta je idempotentna i dodaje kolonu `movements.to_plant` (pogon u koji je roba otišla) — pa je pokreni i ako si je već ranije pokretao.
4c. Pokreni `admin.sql` → Run. Dodaje rolu **admin**, dozvole za sve tabele i admin nalog `admin` (lozinka je u samoj skripti; prijava ide kao `admin@pobjeda.com`). Skripta je idempotentna i sigurna za ponovno pokretanje. **`admin.sql` ne ide na GitHub** (sadrži lozinku) — u `.gitignore` je.
4d. Pokreni `mok.sql` → Run. Dodaje drugi magacin **Pogon MOK** i korisnika **Elmir Kentra** (`mok`, lozinka je u skripti). Skripta je idempotentna; ponovno pokretanje vraća Elmirovu lozinku na početnu. **`mok.sql` ne ide na GitHub** (sadrži lozinku) — u `.gitignore` je.
5. Authentication → Sign In / Providers → Email → isključi **Confirm email**.
6. Provjera: `select email, role from profiles;` → Senad = upravnik, Belmin = vodja (glavni magacin), Elmir = vodja (Pogon MOK), admin = admin. Provjeri i `select name, is_store from plants;`.

## 2. Aplikacija
U `index.html` su na vrhu `SUPABASE_URL` i `SUPABASE_KEY` (Project Settings → API → publishable/anon key). Provjeri da odgovaraju projektu.

Vođa (k.belmin) vidi tab **Magacin** i radi u **Glavnom magacinu**:
- **Ulaz** – nema izbora pogona, roba ulazi u magacin.
- **Izlaz** – bira kupca, artikal i **odredište (pogon) u koje roba ide**; količina se skida sa stanja magacina (artikal nestaje iz stanja kad padne na 0), a odredište i transakcija ostaju u **Historiji**.
- Rute se više ne koriste.

Vođa (mok / Elmir Kentra) radi po istom principu u **Pogonu MOK**:
- **Ulaz** – roba ulazi u Pogon MOK i tu se pamti stanje.
- **Izlaz** – odredište je **glavni magacin (magacin čahure)**; stanje se skida samo sa Pogon MOK, a u Historiji ostaje dan, količina, kupac i odredište. Stanje glavnog magacina se ovim izlazom **ne povećava**.
- Elmir vidi **samo** podatke Pogon MOK. Belmin vidi **samo** glavni magacin.

Upravnik (o.senad) ima dva taba:
- **📦 Magacin** – stanje **nakon svih izlaza**, sa prekidačem između **glavnog magacina** i **Pogona MOK** (vidi oba). Ukupno komada + lista sa prekidačem **Po proizvodu / Po kupcu**, pretragom, sortiranjem (Stanje / Naziv / Ulaz / Izlaz / Zadnji izlaz) i CSV izvozom. Klik na stavku otvara detalje (kupac/proizvod/serija, ulaz, izlaz, stanje).
- **🗓 Historija** – sve transakcije iz **oba magacina** sa filterima: **Od/Do datuma, kupac, proizvod, magacin (odakle), odredište (kuda je otišlo), tip (ulazi/izlazi)** i tekstualna pretraga. Sortiranje klikom na zaglavlje kolone (Datum, Iz, Odredište, Kupac, Proizvod, Ulaz, Izlaz). Gore je zbir ulaza/izlaza za trenutni filter, a CSV dugme izvozi filtrirano stanje.

**Admin** (korisničko ime `admin`; lozinka je u `admin.sql`, koji nije na GitHubu) ima sve što i upravnik, plus:
- **⬇ Unos** – može sam upisati ulaz/izlaz i birati magacin (**Glavni magacin** ili **Pogon MOK**).
- **⚙️ Admin** – upravljanje bazom: **Korisnici** (dodaj/izmijeni/obriši, promjena lozinke i role), **Artikli**, **Kupci** i **Pogoni** (dodaj/izmijeni/obriši). Ako se zapis koristi u transakcijama, admin može potvrditi brisanje **i svih njegovih transakcija** (time se mijenja stanje magacina). Pojedinačne transakcije briše u **Historiji** (🗑), a ispravlja količinu/datum sa ✏️.
- **Historija** – kod svakog unosa ima ✏️ (ispravka količine/datuma) i 🗑 (brisanje), pa tako mijenja i stanje magacina.

Polja **Kupac**, **Šifra artikla** i **Serija** imaju pametni padajući meni: dok kucaš, lista se filtrira i prvo prikazuje stavke koje **počinju** upisanim tekstom (npr. `LP-1` → LP-1, LP-11, LP-100…). Radi i strelicama ↑/↓ + Enter.

## 3. GitHub
```
cd C:\Users\t.nihad\Desktop\upravnik\magacin_monitoring
git add .
git commit -m "Nova verzija"
git push
```
Na GitHub idu `index.html`, `manifest.webmanifest`, `migracija_izlaz.sql`, `reset.sql` i `README.md` (bez lozinki). `schema.sql`, `admin.sql` i `mok.sql` ne guraj u javni repo – sadrže lozinke.

## Korisnici
- **Admin** – sve (korisnici, artikli, kupci, pogoni, stanje): korisničko ime `admin` (lozinka je u `admin.sql`, koji se ne objavljuje na GitHubu)
- **Upravnik** (pregled oba magacina): o.senad@pobjeda.com
- **Belmin Korda** (Glavni magacin – ulaz, izlaz u pogon 12/12A/24A): k.belmin@pobjeda.com
- **Elmir Kentra** (Pogon MOK – ulaz, izlaz u glavni magacin / magacin čahure): `mok` (lozinka je u `mok.sql`, koji se ne objavljuje na GitHubu)

Lozinke su u `schema.sql` / `admin.sql` / `mok.sql` (nisu na GitHubu). Promijeni ih nakon prve prijave: Admin → Korisnici → ✏️, ili Supabase → Authentication → Users.

## Rješavanje problema
- **„Nemaš dozvolu za upis u ovaj magacin“ / „new row violates row-level security policy“**
  Vođa nema pristup svom magacinu u tabeli `user_plants` (ili profilu nedostaje `plant_id`). Pokreni `mok.sql` (rola `postgres`) – daje Elmiru pristup Pogonu MOK, a Belminu glavni magacin. Za novog vođu: Admin → Korisnici (automatski dobija glavni magacin) ili ga ručno dodaj u `user_plants`.
- **„Ta ruta nije dozvoljena“ pri izlazu**
  U bazi je ostala stara funkcija `izlaz` s rutama. `migracija_izlaz.sql` briše sve stare verzije i pravi novu (`p_plant` = magacin, `p_to` = pogon). Provjeri zadnji `select` na kraju skripte.
- Provjera pristupa: `select pr.email, pl.name, can_plant(pl.id) from profiles pr join plants pl on pl.id=pr.plant_id where pr.role='vodja';` → za Belmina i Elmira mora biti `true`.
- Aplikacija sama javlja ove dvije greške jasnom porukom i, ako pristup nedostaje, u tabu **Magacin** prikaže upozorenje umjesto forme.
- **Admin panel ne radi / „function ... does not exist“**
  Nije pokrenut `admin.sql`. Pokreni ga kao `postgres` u SQL Editoru.
