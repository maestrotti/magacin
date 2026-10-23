-- MOK: nazivi proizvoda neovisni od glavnog magacina (+ FI oznaka ⊘)
-- Pokreni kao rola "postgres" u Supabase -> SQL Editor.
--
-- VAŽNO: ova skripta NE briše proizvode, šifre artikala, kupce ni transakcije.
-- Samo dodaje kolonu products.plant_id i mijenja način na koji je naziv jedinstven.
-- Sigurno je pokrenuti više puta (idempotentno).

-- ===== 1) Proizvod može pripadati jednom magacinu =====
-- Postojeći proizvodi ostaju plant_id = null (glavni magacin / zajednički) i rade kao do sada.
alter table products add column if not exists plant_id uuid references plants(id) on delete cascade;

-- ===== 2) Jedinstvenost naziva po magacinu, umjesto globalno =====
-- Time Pogon MOK može imati svoj naziv neovisno od glavnog magacina
-- (i isti naziv kao glavni magacin, bez diranja postojećih redova).
drop index if exists products_u;
create unique index if not exists products_u_global on products (lower(name)) where plant_id is null;
create unique index if not exists products_u_plant  on products (plant_id, lower(name)) where plant_id is not null;

notify pgrst, 'reload schema';

-- ===== Provjere =====
-- Svi proizvodi i kojem magacinu pripadaju (null = glavni / zajednički)
select p.name, pl.name as magacin
from products p
left join plants pl on pl.id = p.plant_id
order by pl.name nulls first, p.name;

-- Koliko proizvoda ima koji magacin
select coalesce(pl.name, 'glavni / zajednički') as magacin, count(*) as proizvoda
from products p
left join plants pl on pl.id = p.plant_id
group by 1
order by 1;
