-- SPDX-License-Identifier: AGPL-3.0-or-later
--
-- Données de démonstration d'un dossier de l'application d'origine (modèle français mod2,
-- DBVERSION 208) : un exercice 2024 complet d'une petite société de
-- conseil — à-nouveaux, ventes (dont un avoir), achats, extraits bancaires,
-- salaires, emprunt —, lettrage des tiers (dont un règlement partiel),
-- pièces jointes et analytique. Chargé par scripts/legacy-demo après les
-- scripts SQL d'origine include/sql/mod2 et les correctifs 202 à 207.
--
-- Écrit directement dans les tables de l'application d'origine (la base source n'est pas
-- une instance Partiduo) en respectant ses déclencheurs : lignes `jrnx`
-- d'abord, puis l'en-tête `jrn` (contrôle d'équilibre `proc_check_balance`).

\set ON_ERROR_STOP on
set search_path = public, comptaproc, pg_catalog;

begin;

create schema demo;

-- Société (paramètres du dossier).
update parameter set pr_value = 'Atelier Démo SARL' where pr_id = 'MY_NAME';
update parameter set pr_value = 'FR44732829320' where pr_id = 'MY_TVA';
update parameter set pr_value = 'rue des Lilas' where pr_id = 'MY_STREET';
update parameter set pr_value = '12' where pr_id = 'MY_NUMBER';
update parameter set pr_value = '44000' where pr_id = 'MY_POSTCODE';
update parameter set pr_value = 'Nantes' where pr_id = 'MY_CITY';
update parameter set pr_value = 'ob' where pr_id = 'MY_ANALYTIC';

-- Comptes complémentaires.
insert into tmp_pcmn (pcm_val, pcm_lib, pcm_val_parent, pcm_type) values
  ('164', 'Emprunts auprès des établissements de crédit', '16', 'PAS'),
  ('431', 'Sécurité sociale', '43', 'PAS'),
  ('6061', 'Fournitures non stockables', '60', 'CHA'),
  ('6132', 'Locations immobilières', '61', 'CHA'),
  ('6226', 'Honoraires', '62', 'CHA'),
  ('626', 'Frais postaux et de télécommunications', '62', 'CHA'),
  ('6611', 'Intérêts des emprunts et dettes', '66', 'CHA');

-- Fiche : une ligne `fiche_detail` par attribut de sa catégorie.
create function demo.card(p_fd_id integer, p_qcode text, p_name text, p_account text, p_attrs jsonb)
returns integer language plpgsql as $$
declare
  v_id integer;
  a record;
  v_value text;
begin
  if p_account is not null and not exists (select 1 from tmp_pcmn where pcm_val = p_account) then
    insert into tmp_pcmn (pcm_val, pcm_lib, pcm_val_parent, pcm_type)
    select p_account, p_name, fd_class_base,
           (select pcm_type from tmp_pcmn where pcm_val = fd_class_base)
    from fiche_def where fd_id = p_fd_id;
  end if;
  insert into fiche (fd_id, f_enable) values (p_fd_id, '1') returning f_id into v_id;
  for a in select ad_id from jnt_fic_attr where fd_id = p_fd_id order by jnt_order loop
    v_value := case a.ad_id
                 when 1 then p_name
                 when 5 then p_account
                 when 23 then p_qcode
                 else coalesce(p_attrs ->> a.ad_id::text, '')
               end;
    insert into fiche_detail (f_id, ad_id, ad_value) values (v_id, a.ad_id, v_value);
  end loop;
  return v_id;
end;
$$;

-- Opération : lignes (compte, quick code, montant, sens, libellé) puis
-- en-tête. `p_lines` : [{"a": compte, "q": quick code, "m": montant,
-- "d": débit ?, "t": libellé}].
create function demo.op(p_ledger text, p_date date, p_comment text, p_receipt text, p_due date, p_lines jsonb)
returns integer language plpgsql as $$
declare
  v_def integer;
  v_grpt integer := nextval('s_grpt');
  v_jr integer := nextval('s_jrn');
  v_total numeric(20,4) := 0;
  l jsonb;
begin
  select jrn_def_id into v_def from jrn_def where jrn_def_code = p_ledger;
  for l in select * from jsonb_array_elements(p_lines) loop
    insert into jrnx (j_date, j_montant, j_poste, j_grpt, j_jrn_def, j_debit, j_text, j_tech_user, j_qcode)
    values (p_date, (l ->> 'm')::numeric, l ->> 'a', v_grpt, v_def, (l ->> 'd')::boolean, l ->> 't', 'demo',
            l ->> 'q');
    if (l ->> 'd')::boolean then
      v_total := v_total + (l ->> 'm')::numeric;
    end if;
  end loop;
  insert into jrn (jr_id, jr_def_id, jr_montant, jr_comment, jr_date, jr_grpt_id, jr_internal, jr_tech_per,
                   jr_pj_number, jr_ech, jr_mt)
  values (v_jr, v_def, v_total, p_comment, p_date, v_grpt,
          left(p_ledger, 1) || lpad(upper(to_hex(v_jr)), 6, '0'), 0, p_receipt, p_due,
          to_char(p_date, 'YYYYMMDD') || lpad(v_jr::text, 8, '0'));
  return v_jr;
end;
$$;

-- Lettrage des lignes du compte `p_account` des opérations `p_ops`.
create function demo.letter(p_ops integer[], p_account text) returns integer language plpgsql as $$
declare
  v_jl integer;
  x record;
begin
  insert into jnt_letter default values returning jl_id into v_jl;
  for x in
    select j.j_id, j.j_debit from jrnx j join jrn r on r.jr_grpt_id = j.j_grpt
    where r.jr_id = any (p_ops) and j.j_poste = p_account
  loop
    if x.j_debit then
      insert into letter_deb (j_id, jl_id) values (x.j_id, v_jl);
    else
      insert into letter_cred (j_id, jl_id) values (x.j_id, v_jl);
    end if;
  end loop;
  return v_jl;
end;
$$;

-- Petit PDF valide (une page, un texte) en pièce jointe d'une opération.
create function demo.attach(p_jr integer, p_filename text, p_text text) returns void language plpgsql as $$
declare
  v_pdf text;
  v_stream text := 'BT /F1 14 Tf 72 720 Td (' || p_text || ') Tj ET';
begin
  v_pdf := '%PDF-1.4' || chr(10)
        || '1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj' || chr(10)
        || '2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj' || chr(10)
        || '3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R'
        || ' /Resources << /Font << /F1 5 0 R >> >> >> endobj' || chr(10)
        || '4 0 obj << /Length ' || length(v_stream) || ' >> stream' || chr(10) || v_stream || chr(10)
        || 'endstream endobj' || chr(10)
        || '5 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj' || chr(10)
        || 'trailer << /Root 1 0 R >>' || chr(10) || '%%EOF' || chr(10);
  update jrn set jr_pj = lo_from_bytea(0, convert_to(v_pdf, 'LATIN1')), jr_pj_name = p_filename,
                 jr_pj_type = 'application/pdf'
  where jr_id = p_jr;
end;
$$;

-- Fiches : clients (catégorie 2), fournisseurs (4), prestations et
-- marchandises vendues (6), services et biens achetés (5).
select demo.card(2, 'AUBEPINE', 'Librairie L''Aubépine', '4100002',
  '{"12": "Claire Martin", "13": "FR40303265045", "14": "3 place du Commerce", "15": "44000", "24": "Nantes",
    "16": "France", "17": "02 40 00 00 01", "18": "contact@aubepine.example", "55": "303265045", "57": "FR"}');
select demo.card(2, 'BRISEMAR', 'Brise Marine SAS', '4100003',
  '{"12": "Paul Durand", "13": "FR83404833048", "14": "18 quai Duperré", "15": "17000", "24": "La Rochelle",
    "16": "France", "18": "compta@brisemarine.example", "55": "404833048", "57": "FR"}');
select demo.card(2, 'CEDRE', 'Cèdre & Associés', '4100004',
  '{"14": "7 rue de la Monnaie", "15": "35000", "24": "Rennes", "16": "France", "55": "552081317", "57": "FR"}');
select demo.card(2, 'DUNE', 'Dune Évènements', '4100005',
  '{"14": "2 rue du Port", "15": "56000", "24": "Vannes", "16": "France", "57": "FR"}');
select demo.card(4, 'LOCAPRO', 'Locapro Immobilier', '4000002',
  '{"14": "40 boulevard Guist''hau", "15": "44000", "24": "Nantes", "16": "France", "55": "732829320", "57": "FR"}');
select demo.card(4, 'TELCOM', 'Telcom Ouest', '4000003',
  '{"14": "1 avenue des Ondes", "15": "35510", "24": "Cesson-Sévigné", "57": "FR"}');
select demo.card(4, 'PAPETERIE', 'Papeterie Nantaise', '4000004', '{"24": "Nantes", "57": "FR"}');
select demo.card(4, 'EXPERT', 'Cabinet Expert & Chiffres', '4000005', '{"24": "Saint-Herblain", "57": "FR"}');
select demo.card(6, 'CONSEIL', 'Conseil et accompagnement', '706', '{"2": "101", "6": "650"}');
select demo.card(6, 'LIVRES', 'Ouvrages et supports', '707', '{"2": "102", "6": "24.90"}');
select demo.card(5, 'LOYER', 'Loyer des bureaux', '6132', '{"2": "101"}');
select demo.card(5, 'TELEPHONE', 'Téléphonie et internet', '626', '{"2": "101"}');
select demo.card(5, 'FOURNIT', 'Fournitures de bureau', '6061', '{"2": "101"}');
select demo.card(5, 'HONORAIRE', 'Honoraires comptables', '6226', '{"2": "101"}');

-- Analytique : un plan, trois postes.
insert into plan_analytique (pa_name, pa_description) values ('Activités', 'Répartition par activité');
insert into poste_analytique (po_name, pa_id, po_description)
select x.name, pa_id, x.description
from plan_analytique, (values ('CONSEIL', 'Missions de conseil'), ('FORMATION', 'Formations'),
                              ('EDITION', 'Édition')) as x(name, description)
where pa_name = 'ACTIVITÉS';

-- Exercice 2024.
do $$
declare
  customers text[] := array['AUBEPINE', 'BRISEMAR', 'CEDRE', 'DUNE'];
  accounts text[] := array['4100002', '4100003', '4100004', '4100005'];
  m integer;
  c integer;
  d date;
  ht numeric;
  tva numeric;
  ttc numeric;
  inv integer;
  pay integer;
  loyer integer;
  tel integer;
  sal integer;
  sales integer[] := array[]::integer[];
  sale_customer integer[] := array[]::integer[];
  sale_amount numeric[] := array[]::numeric[];
  receipt integer := 0;
  purchase_receipt integer := 0;
  fin_receipt integer := 0;
  od_receipt integer := 0;
  avoir integer;
  partial integer;
  po_conseil integer;
  po_formation integer;
  po_edition integer;
begin
  select po_id into po_conseil from poste_analytique where po_name = 'CONSEIL';
  select po_id into po_formation from poste_analytique where po_name = 'FORMATION';
  select po_id into po_edition from poste_analytique where po_name = 'EDITION';

  -- À-nouveaux : trésorerie, capitaux, emprunt, une créance de 2023.
  od_receipt := od_receipt + 1;
  inv := demo.op('O01', date '2024-01-01', 'Reprise des soldes au 1er janvier 2024', 'O-AN2024', null,
    jsonb_build_array(
      jsonb_build_object('a', '510001', 'q', 'BANQUE', 'm', 24800, 'd', true, 't', 'Solde bancaire'),
      jsonb_build_object('a', '4100003', 'q', 'BRISEMAR', 'm', 1800, 'd', true, 't', 'Facture V23-0112'),
      jsonb_build_object('a', '101', 'm', 10000, 'd', false, 't', 'Capital'),
      jsonb_build_object('a', '1068', 'm', 1600, 'd', false, 't', 'Réserves'),
      jsonb_build_object('a', '164', 'm', 15000, 'd', false, 't', 'Emprunt BPO')));

  for m in 1..12 loop
    d := make_date(2024, m, 5);

    -- Vente de conseil du mois, 20 %.
    c := ((m - 1) % 4) + 1;
    ht := 1500 + 125 * m + 37.5 * (m % 3);
    tva := round(ht * 0.20, 2);
    ttc := ht + tva;
    receipt := receipt + 1;
    inv := demo.op('V01', d, 'Mission de conseil ' || to_char(d, 'MM/YYYY'), 'V24-' || lpad(receipt::text, 4, '0'),
      d + 30,
      jsonb_build_array(
        jsonb_build_object('a', accounts[c], 'q', customers[c], 'm', ttc, 'd', true, 't', 'Mission de conseil'),
        jsonb_build_object('a', '706', 'q', 'CONSEIL', 'm', ht, 'd', false, 't', 'Conseil et accompagnement'),
        jsonb_build_object('a', '44571', 'm', tva, 'd', false, 't', 'TVA 20 %')));
    sales := sales || inv;
    sale_customer := sale_customer || c;
    sale_amount := sale_amount || ttc;
    insert into operation_analytique (po_id, oa_amount, oa_description, oa_debit, j_id, oa_date, oa_row)
    select case when m % 3 = 0 then po_formation else po_conseil end, ht, 'Mission ' || m, false, j.j_id, d, 0
    from jrnx j join jrn r on r.jr_grpt_id = j.j_grpt where r.jr_id = inv and j.j_poste = '706';
    if m in (3, 9) then
      perform demo.attach(inv, 'V24-' || lpad(receipt::text, 4, '0') || '.pdf',
        'Facture V24-' || lpad(receipt::text, 4, '0'));
    end if;

    -- Vente d'ouvrages un mois sur deux, 5,5 %.
    if m % 2 = 0 then
      c := (m % 4) + 1;
      ht := 24.90 * (8 + m);
      tva := round(ht * 0.055, 2);
      ttc := ht + tva;
      receipt := receipt + 1;
      inv := demo.op('V01', d + 10, 'Vente d''ouvrages', 'V24-' || lpad(receipt::text, 4, '0'), d + 40,
        jsonb_build_array(
          jsonb_build_object('a', accounts[c], 'q', customers[c], 'm', ttc, 'd', true, 't', 'Ouvrages'),
          jsonb_build_object('a', '707', 'q', 'LIVRES', 'm', ht, 'd', false, 't', 'Ouvrages et supports'),
          jsonb_build_object('a', '44572', 'm', tva, 'd', false, 't', 'TVA 5,5 %')));
      sales := sales || inv;
      sale_customer := sale_customer || c;
      sale_amount := sale_amount || ttc;
      insert into operation_analytique (po_id, oa_amount, oa_description, oa_debit, j_id, oa_date, oa_row)
      select po_edition, ht, 'Ouvrages ' || m, false, j.j_id, d + 10, 0
      from jrnx j join jrn r on r.jr_grpt_id = j.j_grpt where r.jr_id = inv and j.j_poste = '707';
    end if;

    -- Loyer (pièce jointe) et téléphonie, payés le 28.
    purchase_receipt := purchase_receipt + 1;
    loyer := demo.op('A01', make_date(2024, m, 1), 'Loyer ' || to_char(d, 'MM/YYYY'),
      'A-' || lpad(purchase_receipt::text, 4, '0'), make_date(2024, m, 10),
      jsonb_build_array(
        jsonb_build_object('a', '6132', 'q', 'LOYER', 'm', 1200, 'd', true, 't', 'Loyer des bureaux'),
        jsonb_build_object('a', '445661', 'm', 240, 'd', true, 't', 'TVA déductible 20 %'),
        jsonb_build_object('a', '4000002', 'q', 'LOCAPRO', 'm', 1440, 'd', false, 't', 'Locapro')));
    perform demo.attach(loyer, 'loyer-2024-' || lpad(m::text, 2, '0') || '.pdf', 'Avis d''echeance ' || m || '/2024');
    purchase_receipt := purchase_receipt + 1;
    tel := demo.op('A01', make_date(2024, m, 3), 'Téléphonie ' || to_char(d, 'MM/YYYY'),
      'A-' || lpad(purchase_receipt::text, 4, '0'), make_date(2024, m, 20),
      jsonb_build_array(
        jsonb_build_object('a', '626', 'q', 'TELEPHONE', 'm', 89.90, 'd', true, 't', 'Forfait'),
        jsonb_build_object('a', '445661', 'm', 17.98, 'd', true, 't', 'TVA déductible 20 %'),
        jsonb_build_object('a', '4000003', 'q', 'TELCOM', 'm', 107.88, 'd', false, 't', 'Telcom Ouest')));

    fin_receipt := fin_receipt + 1;
    pay := demo.op('F01', make_date(2024, m, 10), 'Prélèvement loyer', 'F-' || lpad(fin_receipt::text, 4, '0'), null,
      jsonb_build_array(
        jsonb_build_object('a', '4000002', 'q', 'LOCAPRO', 'm', 1440, 'd', true, 't', 'Loyer'),
        jsonb_build_object('a', '510001', 'q', 'BANQUE', 'm', 1440, 'd', false, 't', 'Prélèvement Locapro')));
    perform demo.letter(array[loyer, pay], '4000002');
    -- Téléphonie de décembre non encore payée.
    if m < 12 then
      fin_receipt := fin_receipt + 1;
      pay := demo.op('F01', make_date(2024, m, 20), 'Prélèvement téléphonie', 'F-' || lpad(fin_receipt::text, 4, '0'),
        null,
        jsonb_build_array(
          jsonb_build_object('a', '4000003', 'q', 'TELCOM', 'm', 107.88, 'd', true, 't', 'Téléphonie'),
          jsonb_build_object('a', '510001', 'q', 'BANQUE', 'm', 107.88, 'd', false, 't', 'Prélèvement Telcom')));
      perform demo.letter(array[tel, pay], '4000003');
    end if;

    -- Fournitures chaque trimestre, payées le mois suivant (sauf décembre).
    if m % 3 = 0 then
      purchase_receipt := purchase_receipt + 1;
      ht := 245.30 + 12.5 * m;
      tva := round(ht * 0.20, 2);
      inv := demo.op('A01', make_date(2024, m, 15), 'Fournitures de bureau',
        'A-' || lpad(purchase_receipt::text, 4, '0'), make_date(2024, m, 15) + 30,
        jsonb_build_array(
          jsonb_build_object('a', '6061', 'q', 'FOURNIT', 'm', ht, 'd', true, 't', 'Fournitures'),
          jsonb_build_object('a', '445661', 'm', tva, 'd', true, 't', 'TVA déductible 20 %'),
          jsonb_build_object('a', '4000004', 'q', 'PAPETERIE', 'm', ht + tva, 'd', false, 't', 'Papeterie')));
      if m < 12 then
        fin_receipt := fin_receipt + 1;
        pay := demo.op('F01', make_date(2024, m + 1, 12), 'Virement Papeterie Nantaise',
          'F-' || lpad(fin_receipt::text, 4, '0'), null,
          jsonb_build_array(
            jsonb_build_object('a', '4000004', 'q', 'PAPETERIE', 'm', ht + tva, 'd', true, 't', 'Fournitures'),
            jsonb_build_object('a', '510001', 'q', 'BANQUE', 'm', ht + tva, 'd', false, 't', 'Virement')));
        perform demo.letter(array[inv, pay], '4000004');
      end if;
    end if;

    -- Honoraires comptables en mars et septembre, réglés à 45 jours.
    if m in (3, 9) then
      purchase_receipt := purchase_receipt + 1;
      inv := demo.op('A01', make_date(2024, m, 25), 'Honoraires comptables',
        'A-' || lpad(purchase_receipt::text, 4, '0'), make_date(2024, m, 25) + 45,
        jsonb_build_array(
          jsonb_build_object('a', '6226', 'q', 'HONORAIRE', 'm', 1500, 'd', true, 't', 'Mission comptable'),
          jsonb_build_object('a', '445661', 'm', 300, 'd', true, 't', 'TVA déductible 20 %'),
          jsonb_build_object('a', '4000005', 'q', 'EXPERT', 'm', 1800, 'd', false, 't', 'Expert & Chiffres')));
      fin_receipt := fin_receipt + 1;
      pay := demo.op('F01', make_date(2024, m + 2, 8), 'Virement Expert & Chiffres',
        'F-' || lpad(fin_receipt::text, 4, '0'), null,
        jsonb_build_array(
          jsonb_build_object('a', '4000005', 'q', 'EXPERT', 'm', 1800, 'd', true, 't', 'Honoraires'),
          jsonb_build_object('a', '510001', 'q', 'BANQUE', 'm', 1800, 'd', false, 't', 'Virement')));
      perform demo.letter(array[inv, pay], '4000005');
    end if;

    -- Salaires (opérations diverses), net payé le dernier jour du mois.
    od_receipt := od_receipt + 1;
    sal := demo.op('O01', (make_date(2024, m, 1) + interval '1 month - 1 day')::date,
      'Salaires ' || to_char(d, 'MM/YYYY'), 'O-SAL' || lpad(m::text, 2, '0'), null,
      jsonb_build_array(
        jsonb_build_object('a', '641', 'm', 2800, 'd', true, 't', 'Salaire brut'),
        jsonb_build_object('a', '645', 'm', 1150.40, 'd', true, 't', 'Charges patronales'),
        jsonb_build_object('a', '421', 'm', 2184.56, 'd', false, 't', 'Net à payer'),
        jsonb_build_object('a', '431', 'm', 1765.84, 'd', false, 't', 'Cotisations sociales')));
    fin_receipt := fin_receipt + 1;
    perform demo.op('F01', (make_date(2024, m, 1) + interval '1 month - 1 day')::date, 'Virement des salaires',
      'F-' || lpad(fin_receipt::text, 4, '0'), null,
      jsonb_build_array(
        jsonb_build_object('a', '421', 'm', 2184.56, 'd', true, 't', 'Salaires nets'),
        jsonb_build_object('a', '510001', 'q', 'BANQUE', 'm', 2184.56, 'd', false, 't', 'Salaires')));
    if m % 3 = 0 then
      fin_receipt := fin_receipt + 1;
      perform demo.op('F01', make_date(2024, m, 15), 'URSSAF trimestre',
        'F-' || lpad(fin_receipt::text, 4, '0'), null,
        jsonb_build_array(
          jsonb_build_object('a', '431', 'm', 1765.84 * 3, 'd', true, 't', 'Cotisations'),
          jsonb_build_object('a', '510001', 'q', 'BANQUE', 'm', 1765.84 * 3, 'd', false, 't', 'URSSAF')));
    end if;

    -- Échéance d'emprunt.
    fin_receipt := fin_receipt + 1;
    perform demo.op('F01', make_date(2024, m, 25), 'Échéance emprunt BPO', 'F-' || lpad(fin_receipt::text, 4, '0'), null,
      jsonb_build_array(
        jsonb_build_object('a', '164', 'm', 1180.00 + m * 2.35, 'd', true, 't', 'Capital'),
        jsonb_build_object('a', '6611', 'm', 52.40 - m * 2.35, 'd', true, 't', 'Intérêts'),
        jsonb_build_object('a', '510001', 'q', 'BANQUE', 'm', 1232.40, 'd', false, 't', 'Échéance')));
  end loop;

  -- Avoir sur la facture de février (Brise Marine) : remise de 200 € HT.
  receipt := receipt + 1;
  avoir := demo.op('V01', date '2024-02-20', 'Avoir - remise commerciale', 'V24-' || lpad(receipt::text, 4, '0'),
    null,
    jsonb_build_array(
      jsonb_build_object('a', '4100003', 'q', 'BRISEMAR', 'm', 240, 'd', false, 't', 'Avoir'),
      jsonb_build_object('a', '706', 'q', 'CONSEIL', 'm', 200, 'd', true, 't', 'Remise commerciale'),
      jsonb_build_object('a', '44571', 'm', 40, 'd', true, 't', 'TVA 20 %')));

  -- Encaissements : chaque facture est réglée 35 jours après, sauf
  -- celles de novembre et décembre ; la facture de conseil d'octobre ne
  -- l'est qu'à moitié. La créance de 2023 reste impayée.
  for c in 1..array_length(sales, 1) loop
    select jr_date into d from jrn where jr_id = sales[c];
    continue when d >= date '2024-11-01';
    ttc := sale_amount[c];
    if d = date '2024-10-05' then
      ttc := round(ttc / 2, 2);
    elsif d = date '2024-02-05' then
      ttc := ttc - 240;
    end if;
    fin_receipt := fin_receipt + 1;
    pay := demo.op('F01', d + 35, 'Règlement ' || (select jr_pj_number from jrn where jr_id = sales[c]),
      'F-' || lpad(fin_receipt::text, 4, '0'), null,
      jsonb_build_array(
        jsonb_build_object('a', '510001', 'q', 'BANQUE', 'm', ttc, 'd', true, 't', 'Virement reçu'),
        jsonb_build_object('a', accounts[sale_customer[c]], 'q', customers[sale_customer[c]], 'm', ttc, 'd', false,
          't', 'Règlement client')));
    if d = date '2024-02-05' then
      perform demo.letter(array[sales[c], avoir, pay], accounts[sale_customer[c]]);
    else
      perform demo.letter(array[sales[c], pay], accounts[sale_customer[c]]);
    end if;
  end loop;
end;
$$;

drop schema demo cascade;

commit;
