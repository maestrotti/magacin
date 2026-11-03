-- CISCENJE NAZIVA KUPACA U GLAVNOM MAGACINU
-- Pokreni kao rola "postgres" u Supabase -> SQL Editor.
--
-- Neki kupci su greskom upisani zajedno sa sifrom proizvoda, npr.
--   "30-MSED-AL(SLOVAČKA,ELTEK,TURSKA)"
-- Ova skripta odvaja samo kupca iz zagrade:
--   "(SLOVAČKA,ELTEK,TURSKA)"
--
-- Ne mijenja ID kupca, ne brise kupce i ne dira stanje, transakcije,
-- kontrole ni skart. Sigurno je pokrenuti vise puta.
-- Uhvatice i "34-MSED-AL(NORTHEX)" jer je isti slucaj.

begin;

-- 1) PREGLED: ovo pokazuje sta ce se promijeniti
select id,
       name as stari_naziv,
       substring(name from position('(' in name)) as novi_naziv
from customers
where plant_id is null
  and name ~ '^[0-9]+-MSED-AL\(';

-- 2) IZMJENA
update customers
set name = substring(name from position('(' in name))
where plant_id is null
  and name ~ '^[0-9]+-MSED-AL\(';

-- 3) PROVJERA
select id, name
from customers
where name in ('(SLOVAČKA,ELTEK,TURSKA)', '(NORTHEX)')
order by name;

commit;

notify pgrst, 'reload schema';
