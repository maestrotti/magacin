-- MAGACIN: ulaz bez pogona, izlaz bira pogon — pokreni kao rola postgres u Supabase → SQL Editor
-- Sigurno je pokrenuti više puta (idempotentno).
-- Vođa (k.belmin) radi u "Glavnom magacinu": ulaz povećava stanje magacina,
-- izlaz skida sa stanja magacina i u historiji pamti u koji je pogon otišlo.

-- 0) Glavni magacin mora postojati
alter table plants add column if not exists is_main boolean not null default false;
alter table movements add column if not exists transfer_id uuid;
alter table movements add column if not exists to_plant uuid references plants(id);
insert into plants(name,is_main) values('Glavni magacin',true)
on conflict ((lower(name))) do update set is_main=true;

-- 1) Svi vođe rade u glavnom magacinu → daj im pristup glavnom magacinu
--    (bez ovoga upis ulaza pada na RLS: "new row violates row-level security policy")
insert into user_plants(user_id, plant_id)
select pr.id, pl.id from profiles pr cross join plants pl
where pl.is_main and pr.role='vodja'
on conflict do nothing;

-- 2) Skini SVE stare verzije funkcije izlaz (uključujući onu s rutama)
do $$
declare f text;
begin
  for f in select p.oid::regprocedure::text from pg_proc p
           where p.proname='izlaz' and p.pronamespace='public'::regnamespace
  loop
    execute 'drop function '||f;
  end loop;
end $$;

-- 3) Nova funkcija: p_plant = magacin (izvor), p_to = pogon (kuda ide)
create or replace function izlaz(p_plant uuid, p_customer uuid, p_product uuid, p_serija text, p_qty int, p_to uuid,
  p_date date default current_date, p_note text default null)
returns void language plpgsql security definer set search_path=public as $$
declare st int; s text := coalesce(p_serija,''); tn text;
begin
  if not can_plant(p_plant) then raise exception 'Nemate pravo na ovaj magacin'; end if;
  if p_qty is null or p_qty<=0 then raise exception 'Neispravna količina'; end if;
  select name into tn from plants where id=p_to;
  if tn is null then raise exception 'Nepoznat pogon'; end if;
  select coalesce(sum(qty_in-qty_out),0) into st from movements
    where plant_id=p_plant and customer_id=p_customer and product_id=p_product and serija=s;
  if p_qty>st then raise exception 'Količina je veća od stanja (stanje: %)', st; end if;
  insert into movements(date,plant_id,customer_id,product_id,serija,qty_out,note,kind,transfer_id,to_plant)
  values(p_date,p_plant,p_customer,p_product,s,p_qty,concat_ws(' · ','Izlaz u pogon: '||tn,nullif(p_note,'')),'izlaz',gen_random_uuid(),p_to);
end $$;

-- 3b) Stariji izlazi: pogon je bio samo u napomeni → prepiši ga u kolonu to_plant
update movements m set to_plant = pl.id
from plants pl
where m.kind='izlaz' and m.to_plant is null and m.note like 'Izlaz u pogon: %'
  and lower(pl.name) = lower(trim(split_part(split_part(m.note,'Izlaz u pogon: ',2),' · ',1)));

-- 4) Stanje uključuje i glavni magacin (ranije je bio isključen) i tip 'izlaz'
create or replace view v_stock with (security_invoker=true) as
select m.plant_id, p.name plant, m.customer_id, c.name customer, m.product_id, pr.name product, m.serija,
  coalesce(sum(m.qty_in) filter (where m.kind in ('promet','pogon')),0)::int qty_in,
  coalesce(sum(m.qty_out) filter (where m.kind in ('promet','pogon','otprema','izlaz')),0)::int qty_out,
  sum(m.qty_in-m.qty_out)::int stanje,
  max(m.date) filter (where m.kind in ('promet','pogon') and m.qty_in>0) last_in,
  max(m.date) filter (where m.kind in ('promet','pogon','otprema','izlaz') and m.qty_out>0) last_out
from movements m join plants p on p.id=m.plant_id join customers c on c.id=m.customer_id join products pr on pr.id=m.product_id
group by 1,2,3,4,5,6,7;

-- Provjera 1: vođe moraju imati Glavni magacin (mora se vidjeti k.belmin@pobjeda.com)
select pr.email, pl.name from profiles pr
join user_plants up on up.user_id=pr.id join plants pl on pl.id=up.plant_id
where pr.role='vodja' order by pr.email, pl.name;

-- Provjera 2: funkcija izlaz mora imati p_to, a NE p_route
select p.proname, pg_get_function_arguments(p.oid) from pg_proc p
where p.proname='izlaz' and p.pronamespace='public'::regnamespace;

-- Provjera 3: izlazi moraju imati upisan pogon (to_plant)
select count(*) filter (where kind='izlaz') as izlaza,
       count(*) filter (where kind='izlaz' and to_plant is not null) as sa_pogonom
from movements;
