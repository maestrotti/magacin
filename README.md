# Praćenje magacina – postavljanje od nule

## 1. Baza (Supabase)
1. Supabase → **SQL Editor** → New query. **Dolje desno pored Run mora pisati rola `postgres`** (ne `authenticated`/`anon`).
2. Provjera: `select current_user;` → mora vratiti `postgres`.
3. Brisanje stare baze: zalijepi `reset.sql` → Run. (Ili napravi potpuno novi Supabase projekat pa preskoči ovaj korak i u `index.html` upiši novi URL i ključ.)
4. Zalijepi cijeli `schema.sql` → Run. Treba pisati "Success".
4b. **Ako baza već postoji** (ne radiš reset): pokreni `migracija_izlaz.sql` → Run. Uvodi magacin kao jednu lokaciju (ulaz bez pogona, izlaz bira pogon), bez ruta. Skripta je idempotentna i dodaje kolonu `movements.to_plant` (pogon u koji je roba otišla) — pa je pokreni i ako si je već ranije pokretao.
4c. Pokreni `admin.sql` → Run. Dodaje rolu **admin**, dozvole za sve tabele i admin nalog `admin` (lozinka je u samoj skripti; prijava ide kao `admin@pobjeda.com`). Skripta je idempotentna i sigurna za ponovno pokretanje. **`admin.sql` ne ide na GitHub** (sadrži lozinku) — u `.gitignore` je.
4d. Pokreni `mok.sql` → Run. Dodaje drugi magacin **Pogon MOK** i korisnika **Elmir Kentra** (`mok`, lozinka je u skripti). Skripta je idempotentna; ponovno pokretanje vraća Elmirovu lozinku na početnu. **`mok.sql` ne ide na GitHub** (sadrži lozinku) — u `.gitignore` je.
4e. Pokreni `migracija_mok.sql` → Run. Dodaje **status proizvodnje** (na čekanju / prekontrolisano), **škart** pri kontroli, odredište **Laboracija** za Pogon MOK, **opcionalnog kupca** i **više kupaca po proizvodu** (tabela `stock_customers`). Skripta je idempotentna i sigurna za ponovno pokretanje.
4f. Pokreni `migracija_mok_nazivi.sql` → Run. Omogućava da **Pogon MOK ima svoje nazive proizvoda, nezavisno od glavnog magacina** (kolona `products.plant_id`). **Ne briše postojeće proizvode/šifre ni transakcije** — samo dodaje kolonu i mijenja jedinstvenost naziva (naziv je jedinstven unutar magacina). Skripta je idempotentna.
4g. Pokreni `migracija_razdvajanje.sql` → Run. **Obavezno poslije svih prethodnih skripti.** Dodaje **odvojene kupce za Pogon MOK** (kolona `customers.plant_id`), tabelu **`kontrole`** i kolonu `movements.kontrola_id`. Postojeće kupce/proizvode koji se koriste u MOK-u automatski prebacuje na MOK-ove kopije (globalni ostaju glavnom magacinu), a stare prekontrolisane unose i škart ubacuje u historiju kontrola/škarta. **Ne briše transakcije.** Skripta je idempotentna; može se pokrenuti više puta.
5. Authentication → Sign In / Providers → Email → isključi **Confirm email**.
6. Provjera: `select email, role from profiles;` → Senad = upravnik, Belmin = vodja (glavni magacin), Elmir = vodja (Pogon MOK), admin = admin. Provjeri i `select name, is_store from plants;` i `select c.name, pl.name as magacin from customers c left join plants pl on pl.id=c.plant_id order by 1;` (Kupci MOK-a moraju imati `Pogon MOK`, a glavni `null`/glavni magacin).

## 2. Aplikacija
U `index.html` su na vrhu `SUPABASE_URL` i `SUPABASE_KEY` (Project Settings → API → publishable/anon key). Provjeri da odgovaraju projektu.

Vođa (k.belmin) vidi tab **Magacin** i radi u **Glavnom magacinu**:
- **Ulaz** – nema izbora pogona, roba ulazi u magacin.
- **Izlaz** – bira kupca, artikal i **odredište (pogon) u koje roba ide**; količina se skida sa stanja magacina (artikal nestaje iz stanja kad padne na 0), a odredište i transakcija ostaju u **Historiji**.
- Rute se više ne koriste.

Vođa (mok / Elmir Kentra) radi u **Pogonu MOK**:
- **Ulaz** – upisuje se **proizvedena količina čahura**. Ona dobija status **na čekanju kontrole** i još se ne može izdati. Polje **Kupac nije obavezno**; ako ga upišeš, on postaje jedna od oznaka kupaca za taj proizvod i **pripada samo MOK-u**.
- **Naziv proizvoda i kupci** – u Pogonu MOK polje se zove **Naziv proizvoda** (ne šifra). Elmir sam dodaje nazive i kupce i oni su **potpuno nezavisni od glavnog magacina** (isti naziv može postojati u oba magacina, ali se ne miješa). Dugme **FI ⊘** ubacuje **FI oznaku (krug prekrižen)** u naziv; ako se `FI` upiše kao zasebna riječ, pri spremanju se pretvara u **⊘**.
- **Kontrola** – u listi **„Na čekanju kontrole“** (ispod forme za unos) ili na kartici u **Stanju** klikneš **✔ Prekontrolisano**. Upišeš **škart** (ako ga je bilo): škart se odmah odbija od stanja, a ostatak postaje **prekontrolisano** i spreman za izlaz. Ako škarta nema, ostavi 0. Primjer: ulaz 1.000 → škart 50 → stanje 950 → prekontrolisano 950.
- **Izlaz** – dozvoljen je **samo za prekontrolisano**; odredište je **Laboracija**. Stanje se skida sa Pogona MOK, a u Historiji ostaje datum, količina, kupac (ako je upisan) i odredište. Stanje na Laboraciji se ne prati.
- **Stanje** – prikazuje **ukupno stanje po proizvodu** (bez obzira na kupca), a ispod svakog proizvoda su **kupci kao oznake**. Dugme **+ Dodaj kupca** dodaje još jednog kupca, a **×** ga uklanja. Ista količina je zajednička za sve kupce – npr. 10.000 kom može ići za Tursku ili Australiju, ali se **ne duplira** na 20.000. Prekidač **Po kupcu** prikazuje iste proizvode razvrstane po kupcima, uz napomenu sa kojim kupcima se proizvod još dijeli.
- **Historija → Kontrole / Škart** – posebne liste svih kontrola i škarta, sortirane po datumu (sa danom) i uz pretragu. **Škart** možeš ispraviti (npr. 50 → 60: stanje se smanjuje za još 10) ili obrisati (stanje se povećava za taj škart). **Kontrolu** možeš poništiti (količina se vraća na čekanje, škart u stanje). Dok je kontrola završena, njen ulaz se **ne može** ispravljati/brisati — prvo je obriši u **Historija → Kontrole**. Ako je dio već izašao, brisanje/veće škart se blokira dok se izlaz ne ispravi.
- Elmir vidi **samo** podatke Pogon MOK (svoje kupce, proizvode, kontrole i škart). Belmin vidi **samo** glavni magacin.
- Ako je za isti proizvod na stanju **samo jedna serija**, polje **Serija** se popuni automatski; ako ih je više, ispod polja se prikažu dostupne serije.

Upravnik (o.senad) ima dva taba:
- **📦 Magacin** – stanje **nakon svih izlaza**, sa prekidačem između **glavnog magacina** i **Pogona MOK** (vidi oba). Ukupno komada + **zbir po kupcima na vrhu** (da se odmah vidi koliko koji kupac ima robe). Kod Pogona MOK posebno piše koliko je **na čekanju**, a koliko **prekontrolisano**. Glavni magacin ima prekidač **Po proizvodu** (sabira sve kupce za istu šifru, npr. LP-1 kupac X + LP-1 kupac Y) i **Po kupcu** (razdvaja kupce i artikle); Pogon MOK se prikazuje **po proizvodu**, a kupci su oznake (količina se ne dijeli). Uz to idu pretraga, sortiranje (Stanje / Naziv / Ulaz / Izlaz / Zadnji izlaz) i CSV izvoz. Klik na stavku otvara detalje (kupac/proizvod/serija, ulaz, izlaz, stanje, status za MOK).
- **🗓 Historija** – ima tri dijela: **📋 Transakcije**, **✔ Kontrole** i **⚠ Škart**. Transakcije imaju filtere **Od/Do datuma, kupac, proizvod, magacin (odakle), odredište (kuda je otišlo), tip (ulazi/izlazi)** i tekstualnu pretragu. Kontrole i škart imaju **Od/Do datuma, pretragu i sortiranje po datumu/danu, količini i škartu**. Sortiranje je klikom na zaglavlje kolone. Gore je zbir za trenutni filter, a CSV dugme izvozi filtrirane transakcije.
- U **Historiji → Kontrole** upravnik/admin može poništiti kontrolu, a u **Škart** ispraviti ili obrisati škart; time se stanje automatski koriguje. Završena kontrola se ne može ispravljati kroz transakcije dok se ne obriše u historiji kontrola.

**Admin** (korisničko ime `admin`; lozinka je u `admin.sql`, koji nije na GitHubu) ima sve što i upravnik, plus:
- **⬇ Unos** – može sam upisati ulaz/izlaz i birati magacin (**Glavni magacin** ili **Pogon MOK**).
- **⚙️ Admin** – upravljanje bazom: **Korisnici** (dodaj/izmijeni/obriši, promjena lozinke i role), **Artikli**, **Kupci** i **Pogoni** (dodaj/izmijeni/obriši). Kod novog artikla/kupca bira se **magacin** (Glavni ili Pogon MOK), pa se nazivi ne miješaju. Ako se zapis koristi u transakcijama, admin može potvrditi brisanje **i svih njegovih transakcija/kontrola** (time se mijenja stanje magacina). Pojedinačne transakcije briše u **Historiji** (🗑), a ispravlja količinu/datum sa ✏️.
- **Historija** – kod svakog unosa ima ✏️ (ispravka količine/datuma) i 🗑 (brisanje), pa tako mijenja i stanje magacina. Prekontrolisan MOK ulaz je zaključan (🔒) dok se kontrola ne obriše u **Historija → Kontrole**.

Polja **Kupac**, **Naziv/šifra artikla** i **Serija** imaju pametni padajući meni: dok kucaš, lista se filtrira i prvo prikazuje stavke koje **počinju** upisanim tekstom (npr. `LP-1` → LP-1, LP-11, LP-100…). Radi i strelicama ↑/↓ + Enter. U Pogonu MOK lista prikazuje **samo MOK-ove nazive i kupce**, a u glavnom magacinu samo glavne — nazivi i kupci se ne miješaju.

## 3. GitHub
```
cd C:\Users\t.nihad\Desktop\upravnik\magacin_monitoring
git add .
git commit -m "Nova verzija"
git push
```
Na GitHub idu `index.html`, `manifest.webmanifest`, `migracija_izlaz.sql`, `migracija_mok.sql`, `migracija_mok_nazivi.sql`, `migracija_razdvajanje.sql`, `reset.sql` i `README.md` (bez lozinki). `schema.sql`, `admin.sql` i `mok.sql` ne guraj u javni repo – sadrže lozinke.

## Korisnici
- **Admin** – sve (korisnici, artikli, kupci, pogoni, stanje): korisničko ime `admin` (lozinka je u `admin.sql`, koji se ne objavljuje na GitHubu)
- **Upravnik** (pregled oba magacina): o.senad@pobjeda.com
- **Belmin Korda** (Glavni magacin – ulaz, izlaz u pogon 12/12A/24A): k.belmin@pobjeda.com
- **Elmir Kentra** (Pogon MOK – ulaz, kontrola, izlaz na Laboraciju): `mok` (lozinka je u `mok.sql`, koji se ne objavljuje na GitHubu)

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
- **MOK: „column status does not exist“, nema Laboracije, ne radi „Prekontrolisano“ ili ne mogu dodati kupca**
  Nije pokrenut `migracija_mok.sql`. Pokreni ga kao `postgres` u Supabase → SQL Editor, pa osvježi aplikaciju (Ctrl+F5). Skripta dodaje status, Laboraciju, tabelu `stock_customers` i opcionalnog kupca.
- **MOK: „column plant_id does not exist“, nazivi se miješaju sa glavnim magacinom ili ne mogu dodati naziv koji već postoji**
  Nije pokrenut `migracija_mok_nazivi.sql`. Pokreni ga kao `postgres` u Supabase → SQL Editor, pa osvježi aplikaciju (Ctrl+F5). Skripta **ne briše** postojeće proizvode — samo dodaje `products.plant_id` i razdvaja jedinstvenost naziva po magacinu.
- **Kupci se miješaju između MOK-a i glavnog magacina / „column plant_id does not exist“ na kupcima**
  Nije pokrenut `migracija_razdvajanje.sql`. Pokreni ga kao `postgres` u Supabase → SQL Editor, pa osvježi aplikaciju (Ctrl+F5). Skripta pravi MOK-ove kopije kupaca/proizvoda koji se koriste u oba magacina i **ne briše** transakcije.
- **„Kontrola ne postoji“, „relation kontrole does not exist“ ili nema tabova Kontrole/Škart**
  Nije pokrenut `migracija_razdvajanje.sql` (ili je pokrenut prije `migracija_mok.sql`). Pokreni ga **poslije svih** MOK skripti, pa osvježi stranicu.
- **„Kontrola je završena. Prvo je obriši u Historiji → Kontrole“**
  To je namjerno: prekontrolisan ulaz je zaključan. Otvori **Historija → Kontrole**, nađi kontrolu (pretraga/sortiranje po datumu), pa je obriši (🗑) ili ispravi škart (✏️). Nakon toga se ulaz može ispravljati.
- **„Nema dovoljno prekontrolisanog stanja za taj škart“ / „dio je već izašao“**
  Dio kontrolisane količine je već izdat na Laboraciju. Prvo ispravi/obriši izlaz u **Historija → Transakcije**, pa onda mijenjaj škart ili poništi kontrolu. Time se sprječava negativno stanje.
- **„Ispravka bi dovela do negativnog stanja“ / „Brisanje bi dovelo do negativnog stanja“**
  Ne možeš smanjiti ulaz ispod količine koja je već izašla, ni povećati izlaz iznad prekontrolisanog stanja. Prvo ispravi ili obriši izlaz u **Historija → Transakcije**, pa onda ulaz.
