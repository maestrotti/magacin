-- BRISANJE SVEGA (pokreni kao rola postgres!). Nakon toga pokreni schema.sql, pa admin.sql
drop view if exists v_stock;
drop trigger if exists on_auth_user_created on auth.users;
drop table if exists stock_customers cascade;
drop table if exists routes, movements, user_plants, customers, products, profiles, plants cascade;

-- briše sve verzije (overload-ove) funkcija, da ne ostanu stare iz prethodnih verzija
do $$ declare r record; begin
  for r in select p.oid::regprocedure as sig from pg_proc p
    where p.pronamespace='public'::regnamespace and p.proname in (
      'handle_new_user','is_upravnik','is_admin','my_plant','can_plant','transfer_stock','transfer_plants',
      'izlaz','prekontrolisi','ispravi_unos','obrisi_unos',
      'admin_dodaj_korisnika','admin_izmjeni_korisnika','admin_obrisi_korisnika')
  loop execute 'drop function if exists '||r.sig||' cascade'; end loop;
end $$;

delete from auth.users where email in ('o.senad@pobjeda.com','k.belmin@pobjeda.com','admin@pobjeda.com');
