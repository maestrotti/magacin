-- MAGACIN: ulaz bez pogona, izlaz bira pogon — pokreni kao rola postgres u Supabase → SQL Editor
-- Vođa (k.belmin) radi u "Glavnom magacinu": ulaz povećava stanje magacina,
-- izlaz skida sa stanja magacina i u historiji pamti u koji je pogon otišlo.

-- 0) Glavni magacin mora postojati
alter table plants add column if not exists is_main boolean not null default false;
alter table movements add column if not exists transfer_id uuid;
insert into plants(name,is_main) values('Glavni magacin',true)
on conflict ((lower(name))) do update set is_main=true;

-- 1) Vođi daj pristup glavnom magacinu
insert into user_plants(user_id, plant_id)
select pr.id, pl.id from profiles pr join plants pl on pl.is_main
where lower(pr.email)='k.belmin@pobjeda.com'
on conflict do nothing;

-- 2) Skini stare verzije funkcije izlaz (sa rutama i bez pogona)
drop function if exists izlaz(uuid, uuid, uuid, uuid, text, int, date, text);
drop function if exists izlaz(uuid, uuid, uuid, text, int, date, text);

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
  insert into movements(date,plant_id,customer_id,product_id,serija,qty_out,note,kind,transfer_id)
  values(p_date,p_plant,p_customer,p_product,s,p_qty,concat_ws(' · ','Izlaz u pogon: '||tn,nullif(p_note,'')),'izlaz',gen_random_uuid());
end $$;

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

-- Provjera 1: Belmin mora imati Glavni magacin
select pr.email, pl.name from profiles pr
join user_plants up on up.user_id=pr.id join plants pl on pl.id=up.plant_id
where lower(pr.email)='k.belmin@pobjeda.com';

-- Provjera 2: funkcija izlaz mora imati p_to
select proname, pg_get_function_arguments(oid) from pg_proc where proname='izlaz';
