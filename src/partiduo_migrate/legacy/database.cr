# SPDX-License-Identifier: AGPL-3.0-or-later

require "db"
require "pg"

module PartiduoMigrate
  module Legacy
    # Version de schéma lue et reprise (`DBVERSION` de l'application d'origine).
    DBVERSION = 208

    class Error < Exception
    end

    # Lecture d'une base d'origine (dossier) en DBVERSION 208, en lecture
    # seule : écritures (comme la vue `v_fec_operation` de l'export FEC d'origine,
    # lettrage et échéance en plus), plan comptable, journaux, fiches
    # complètes, taux de TVA, exercices et périodes, pièces jointes,
    # analytique, stock, prévisions et suivi (DECISIONS D-R5-011 à
    # D-R5-014). Les utilisateurs, leurs droits et leurs secrets ne sont
    # jamais lus (ADR-001 D5, ADR-002) ; des droits par dépôt et de la
    # visibilité des actions, seule l'existence est relevée, pour avertir
    # (BLOCAGES B-SEC-001).
    class Database
      getter url : String
      # Avertissements de connexion (URL hors socket Unix).
      getter warnings = [] of String

      def initialize(@url : String)
        @warnings << PartiduoMigrate.t("legacy.not_unix_socket", url: safe_url) unless unix_socket?
      end

      def read(with_attachments : Bool = true) : Source::Dataset
        DB.connect(@url) do |db|
          # Lecture seule garantie par la session : la source n'est jamais modifiée.
          db.exec("SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY")
          version = db.query_one("SELECT max(val) FROM version", as: Int32?)
          unless version == DBVERSION
            raise Error.new(PartiduoMigrate.t("legacy.wrong_version", version: version.inspect, expected: DBVERSION))
          end
          name = parameter(db, "MY_NAME")
          description = if name
                          PartiduoMigrate.t("source.legacy_description_named", database: database_name, name: name)
                        else
                          PartiduoMigrate.t("source.legacy_description", database: database_name)
                        end
          dataset = Source::Dataset.new(description)
          dataset.full_chart = true
          read_accounts(db, dataset)
          read_journals(db, dataset)
          read_categories(db, dataset)
          read_cards(db, dataset)
          read_vat(db, dataset)
          read_fiscal_years(db, dataset)
          read_entries(db, dataset)
          read_control(db, dataset)
          read_attachments(db, dataset) if with_attachments
          read_analytic(db, dataset)
          read_stock(db, dataset)
          read_forecasts(db, dataset)
          read_followup(db, dataset)
          dataset
        end
      rescue ex : DB::ConnectionRefused | Socket::Error | PQ::PQError
        raise Error.new(PartiduoMigrate.t("legacy.unreadable", url: safe_url, message: ex.message.to_s))
      end

      # SIREN du dossier (paramètre `MY_SIREN`, sinon tiré du numéro de TVA
      # `MY_TVA`) pour nommer le FEC.
      def siren : String?
        DB.connect(@url) do |db|
          parameter(db, "MY_SIREN").try(&.gsub(/\D/, "")).presence ||
            parameter(db, "MY_TVA").try { |vat| vat.gsub(/\s/, "").match(/\AFR\w{2}(\d{9})\z/i).try(&.[1]) }
        end
      rescue ex : DB::ConnectionRefused | Socket::Error | PQ::PQError
        raise Error.new(PartiduoMigrate.t("legacy.unreadable", url: safe_url, message: ex.message.to_s))
      end

      # URL sans utilisateur ni mot de passe (dans l'autorité ou en
      # paramètre), pour les messages et le rapport.
      def safe_url : String
        uri = URI.parse(@url)
        uri.user = nil
        uri.password = nil
        if query = uri.query
          params = URI::Params.parse(query)
          %w[password user].each { |key| params.delete_all(key) }
          uri.query = params.empty? ? nil : params.to_s
        end
        uri.to_s
      rescue URI::Error
        database_name
      end

      # Connexion par socket Unix (`host=/chemin` ou hôte vide), comme le
      # prévoit l'exploitation de Partiduo.
      def unix_socket? : Bool
        uri = URI.parse(@url)
        host = uri.query.try { |query| URI::Params.parse(query)["host"]? }
        return host.starts_with?('/') if host
        uri.host.nil? || uri.host.try(&.empty?) || uri.host.try(&.starts_with?('/')) || false
      rescue URI::Error
        false
      end

      private def database_name : String
        URI.parse(@url).path.lchop('/')
      rescue URI::Error
        "?"
      end

      private def parameter(db : DB::Connection, id : String) : String?
        db.query_one?("SELECT pr_value FROM parameter WHERE pr_id = $1", id, as: String?).try(&.strip.presence)
      end

      KINDS = {"ACT" => "asset", "PAS" => "liability", "ACTINV" => "asset_contra", "PASINV" => "liability_contra",
               "PRO" => "income", "PROINV" => "income_contra", "CHA" => "expense", "CHAINV" => "expense_contra",
               "CON" => "context"}

      private def read_accounts(db, dataset) : Nil
        db.query_each("SELECT pcm_val, coalesce(pcm_lib, ''), pcm_val_parent, coalesce(pcm_type, ''), " \
                      "pcm_direct_use = 'Y' FROM tmp_pcmn ORDER BY pcm_val") do |result|
          number = result.read(String)
          label = result.read(String)
          parent = result.read(String?)
          kind = KINDS[result.read(String)]?
          direct = result.read(Bool)
          parent = nil if parent.nil? || parent == "0" || parent == number
          dataset.accounts[number] = Source::Account.new(number, label, parent, kind, direct)
        end
      end

      LEDGER_KINDS = {"ACH" => "purchase", "VEN" => "sale", "FIN" => "financial", "ODS" => "misc"}

      private def read_journals(db, dataset) : Nil
        sql = <<-SQL
          SELECT jrn_def_code, jrn_def_name, jrn_def_type,
                 (SELECT ad_value FROM fiche_detail WHERE f_id = jrn_def_bank AND ad_id = 23),
                 coalesce(jrn_def_pj_pref, '')
          FROM jrn_def ORDER BY jrn_def_id
          SQL
        db.query_each(sql) do |result|
          code = result.read(String)
          dataset.journals[code] = Source::Journal.new(code, result.read(String), LEDGER_KINDS[result.read(String).strip]?,
            result.read(String?), result.read(String))
        end
      end

      private def read_categories(db, dataset) : Nil
        db.query_each("SELECT fd_id, fd_label, frd_id, coalesce(fd_description, '') FROM fiche_def ORDER BY fd_id") do |result|
          dataset.card_categories << Source::CardCategory.new(result.read(Int32).to_i64, result.read(String),
            result.read(Int32).to_i64, result.read(String))
        end
        db.query_each("SELECT ad_id, coalesce(ad_text, '') FROM attr_def") do |result|
          dataset.attribute_labels[result.read(Int32).to_i64] = result.read(String)
        end
      end

      private def read_cards(db, dataset) : Nil
        attributes = Hash(Int64, Hash(Int64, String)).new { |hash, key| hash[key] = {} of Int64 => String }
        db.query_each("SELECT f_id, ad_id, coalesce(ad_value, '') FROM fiche_detail WHERE ad_id IS NOT NULL") do |result|
          id = result.read(Int32).to_i64
          attributes[id][result.read(Int32).to_i64] = result.read(String).strip
        end
        db.query_each("SELECT f_id, fd_id, f_enable = '1' FROM fiche WHERE fd_id IS NOT NULL ORDER BY f_id") do |result|
          id = result.read(Int32).to_i64
          category = result.read(Int32).to_i64
          enabled = result.read(Bool)
          values = attributes[id]? || {} of Int64 => String
          code = values[23_i64]?.presence || next
          dataset.cards << Source::Card.new(code: code, name: values[1_i64]?.presence || code, category: category,
            account: values[5_i64]?.presence, enabled: enabled, attributes: values)
        end
      end

      private def read_vat(db, dataset) : Nil
        sql = <<-SQL
          SELECT tva_id, tva_code, tva_label, tva_rate, coalesce(tva_comment, ''), coalesce(tva_poste, ''),
                 coalesce(tva_both_side, 0), coalesce(tva_payment_sale, 'O'), coalesce(tva_payment_purchase, 'O')
          FROM tva_rate ORDER BY tva_id
          SQL
        db.query_each(sql) do |result|
          id = result.read(Int32).to_i64
          code = result.read(String)
          label = result.read(String)
          rate = result.read(PG::Numeric).to_big_d * 100
          comment = result.read(String)
          accounts = result.read(String).split(',').map(&.strip)
          both = result.read(Int32) == 1
          sale = result.read(String) == "P"
          purchase = result.read(String) == "P"
          dataset.vat_rates << Source::VatRate.new(code: code, label: label, rate: rate, comment: comment,
            reverse_charge: both, sale_on_payment: sale, purchase_on_payment: purchase,
            deductible_account: accounts[0]?.presence, collected_account: accounts[1]?.presence, id: id)
        end
      end

      # Exercices et leurs périodes (`parm_periode`), dans l'ordre des dates.
      private def read_fiscal_years(db, dataset) : Nil
        years = [] of {String, String, Array(Source::Period)}
        sql = "SELECT p_exercice, coalesce(p_exercice_label, p_exercice), p_start, p_end, coalesce(p_closed, false), p_id " \
              "FROM parm_periode ORDER BY p_start, p_end"
        db.query_each(sql) do |result|
          id = result.read(String)
          label = result.read(String)
          period = Source::Period.new(result.read(Time), result.read(Time), result.read(Bool), result.read(Int32).to_i64)
          year = years.find { |candidate| candidate[0] == id }
          if year
            year[2] << period
          else
            years << {id, label, [period]}
          end
        end
        years.each do |(_, label, periods)|
          starts = periods.min_of(&.starts_on)
          ends = periods.max_of(&.ends_on)
          months = (ends.year - starts.year) * 12 + ends.month - starts.month + 1
          dataset.fiscal_years << Source::FiscalYear.new(label, starts, months, periods)
        end
      end

      ENTRIES_SQL = <<-SQL
        SELECT r.jr_id, d.jrn_def_code, r.jr_date, coalesce(r.jr_comment, ''), coalesce(r.jr_pj_number, ''), r.jr_ech,
               x.j_id, x.j_poste, coalesce(p.pcm_lib, ''), nullif(trim(x.j_qcode), ''),
               (SELECT ad_value FROM fiche_detail fd WHERE fd.f_id = x.f_id AND fd.ad_id = 1),
               coalesce(x.j_text, ''), x.j_montant, x.j_debit, coalesce(ld.jl_id, lc.jl_id),
               nullif(oc.oc_amount, 0), CASE WHEN c.cr_code_iso = 'EUR' THEN NULL ELSE c.cr_code_iso END
        FROM jrnx x
        JOIN jrn r ON r.jr_grpt_id = x.j_grpt
        JOIN jrn_def d ON d.jrn_def_id = r.jr_def_id
        LEFT JOIN tmp_pcmn p ON p.pcm_val = x.j_poste
        LEFT JOIN letter_deb ld ON ld.j_id = x.j_id
        LEFT JOIN letter_cred lc ON lc.j_id = x.j_id
        LEFT JOIN operation_currency oc ON oc.j_id = x.j_id
        LEFT JOIN currency c ON c.id = r.currency_id
        WHERE x.j_montant <> 0
        ORDER BY r.jr_date, r.jr_id, x.j_debit DESC, x.j_id
        SQL

      # Écritures dans l'ordre de l'export FEC de l'application d'origine (date, opération,
      # débits d'abord) ; `EcritureNum` numérote les opérations dans cet
      # ordre. Lettrage : un code par `jnt_letter`, daté de la dernière
      # ligne lettrée.
      private def read_entries(db, dataset) : Nil
        by_id = {} of Int64 => Source::Entry
        letters = {} of Int64 => Array({Source::Entry, Int32})
        db.query_each(ENTRIES_SQL) do |result|
          jr_id = result.read(Int32).to_i64
          journal = result.read(String)
          date = result.read(Time)
          comment = result.read(String)
          receipt = result.read(String)
          due = result.read(Time?)
          j_id = result.read(Int32).to_i64
          account = result.read(String)
          account_label = result.read(String)
          aux = result.read(String?)
          aux_label = result.read(String?)
          text = result.read(String)
          amount = result.read(PG::Numeric).to_big_d
          debit = result.read(Bool)
          letter = result.read(Int64?)
          currency_amount = result.read(PG::Numeric?).try(&.to_big_d)
          currency_code = result.read(String?)
          debit = !debit if amount < 0
          amount = amount.abs
          zero = BigDecimal.new(0)

          entry = by_id[jr_id]? || begin
            created = Source::Entry.new(journal, (by_id.size + 1).to_s, date, receipt, date, comment, due,
              origin: jr_id)
            by_id[jr_id] = created
            dataset.entries << created
            created
          end
          line = Source::Line.new(
            account: account, account_label: account_label, aux: aux, aux_label: aux ? (aux_label || aux) : nil,
            label: text, debit: debit ? amount : zero, credit: debit ? zero : amount,
            letter: letter.try { |id| letter_code(id) }, currency_amount: currency_amount,
            currency_code: currency_code, row: j_id,
          )
          entry.lines << line
          letter.try { |id| (letters[id] ||= [] of {Source::Entry, Int32}) << {entry, entry.lines.size - 1} }
          aux.try { |code| dataset.parties[code] ||= aux_label || code }
        end
        letters.each_value do |members|
          last = members.max_of { |(entry, _)| entry.date }
          members.each do |(entry, index)|
            entry.lines[index] = entry.lines[index].copy_with(letter_date: last)
          end
        end
      end

      # Contrôle de lecture : balance par compte, totaux par journal et par
      # mois relus directement sur `jrnx` (modèle de `acc_balance.class.php`),
      # sans passer par la requête des écritures : une ligne sans opération
      # (`jrn`), une ligne dédoublée par une jointure ou un montant mal lu
      # apparaissent en écart au rapport. Même règle que la lecture pour les
      # montants négatifs (de l'autre côté) et les lignes nulles (ignorées).
      CONTROL_SQL = <<-SQL
        SELECT x.j_poste, coalesce(d.jrn_def_code, '#' || x.j_jrn_def::text), to_char(x.j_date, 'YYYY-MM'),
               count(*),
               coalesce(sum(CASE WHEN x.j_debit = (x.j_montant > 0) THEN abs(x.j_montant) ELSE 0 END), 0),
               coalesce(sum(CASE WHEN x.j_debit <> (x.j_montant > 0) THEN abs(x.j_montant) ELSE 0 END), 0)
        FROM jrnx x
        LEFT JOIN jrn_def d ON d.jrn_def_id = x.j_jrn_def
        WHERE x.j_montant <> 0
        GROUP BY 1, 2, 3
        SQL

      private def read_control(db, dataset) : Nil
        control = Source::Control.new(sides: true)
        db.query_each(CONTROL_SQL) do |result|
          account = result.read(String)
          journal = result.read(String)
          period = result.read(String)
          count = result.read(Int64).to_i32
          debit = result.read(PG::Numeric).to_big_d
          credit = result.read(PG::Numeric).to_big_d
          control.add(account, journal, period, Source::Tally.new(count, debit, credit))
        end
        dataset.control = control
      end

      # Code de lettrage tiré de `jnt_letter.jl_id` (1 → `A`, 27 → `AA`).
      def self.letter_code(id : Int64) : String
        n = id
        chars = [] of Char
        while n > 0
          n -= 1
          chars << ('A' + n % 26)
          n //= 26
        end
        chars.reverse.join
      end

      private def letter_code(id : Int64) : String
        Database.letter_code(id)
      end

      private def read_attachments(db, dataset) : Nil
        by_origin = dataset.entries.index_by(&.origin)
        sql = "SELECT jr_id, coalesce(jr_pj_name, ''), coalesce(jr_pj_type, ''), lo_get(jr_pj) FROM jrn " \
              "WHERE jr_pj IS NOT NULL ORDER BY jr_id"
        db.query_each(sql) do |result|
          jr_id = result.read(Int32).to_i64
          name = result.read(String)
          type = result.read(String)
          content = result.read(Bytes)
          entry = by_origin[jr_id]? || next
          entry.attachment = Source::Attachment.new(name.presence || "piece-#{jr_id}", type, content)
        end
        db.query_each("SELECT jr_id, js_filename, js_mimetype FROM jrn_sup_document ORDER BY js_id") do |result|
          jr_id = result.read(Int64)
          reference = by_origin[jr_id]?.try(&.reference) || "jr_id #{jr_id}"
          dataset.unported << Source::Unported.new("extra_attachment", reference,
            PartiduoMigrate.t("source.extra_attachment_detail", file: result.read(String), type: result.read(String)))
        end
      end

      # Analytique : plans, groupes, postes, imputations (lignes d'écriture
      # et opérations diverses). Reprise par le contrat de l'Analytique
      # (`Importer#import_analytic`).
      private def read_analytic(db, dataset) : Nil
        analytic = dataset.analytic
        db.query_each("SELECT pa_name, coalesce(pa_description, '') FROM plan_analytique ORDER BY pa_id") do |result|
          analytic.plans << Source::AnalyticPlan.new(result.read(String), result.read(String))
        end
        db.query_each("SELECT pa.pa_name, ga.ga_id, coalesce(ga.ga_description, '') FROM groupe_analytique ga " \
                      "JOIN plan_analytique pa ON pa.pa_id = ga.pa_id ORDER BY ga.ga_id") do |result|
          analytic.groups << Source::AnalyticGroup.new(result.read(String), result.read(String), result.read(String))
        end
        db.query_each("SELECT pa.pa_name, po.po_name, coalesce(po.po_description, ''), po.ga_id, po.po_state = 1 " \
                      "FROM poste_analytique po JOIN plan_analytique pa ON pa.pa_id = po.pa_id ORDER BY pa.pa_name, po.po_name") do |result|
          analytic.posts << Source::AnalyticPost.new(result.read(String), result.read(String), result.read(String),
            result.read(String?).try(&.presence), result.read(Bool))
        end
        sql = <<-SQL
          SELECT pa.pa_name, po.po_name, oa.oa_amount, oa.oa_debit, oa.oa_date, oa.j_id, coalesce(oa.oa_row, 0),
                 oa.oa_group, coalesce(oa.oa_description, ''),
                 (SELECT ad_value FROM fiche_detail fd WHERE fd.f_id = oa.f_id AND fd.ad_id = 23)
          FROM operation_analytique oa
          JOIN poste_analytique po ON po.po_id = oa.po_id
          JOIN plan_analytique pa ON pa.pa_id = po.pa_id
          ORDER BY oa.oa_date, oa.oa_group, oa.oa_row, oa.oa_id
          SQL
        db.query_each(sql) do |result|
          analytic.rows << Source::AnalyticRow.new(
            plan: result.read(String), post: result.read(String), amount: result.read(PG::Numeric).to_big_d,
            debit: result.read(Bool), date: result.read(Time), line_row: result.read(Int32?).try(&.to_i64),
            row: result.read(Int32), group: result.read(Int32).to_i64, description: result.read(String),
            card: result.read(String?).try(&.strip.presence))
        end
      end

      # Stock : dépôts, codes stock des fiches (attribut 19), mouvements
      # (`stock_goods` : `d` entrée, `c` sortie), opérations manuelles
      # (`stock_change`) ; droits par dépôt relevés pour avertir seulement.
      private def read_stock(db, dataset) : Nil
        stock = dataset.stock
        db.query_each("SELECT r_id, coalesce(r_name, ''), coalesce(r_adress, ''), coalesce(r_city, ''), " \
                      "coalesce(r_country, ''), coalesce(r_phone, '') FROM stock_repository ORDER BY r_id") do |result|
          stock.repositories << Source::Repository.new(result.read(Int64), result.read(String), result.read(String),
            result.read(String), result.read(String), result.read(String))
        end
        db.query_each("SELECT q.ad_value, s.ad_value FROM fiche_detail s JOIN fiche_detail q ON q.f_id = s.f_id AND q.ad_id = 23 " \
                      "WHERE s.ad_id = 19 AND coalesce(trim(s.ad_value), '') <> ''") do |result|
          stock.codes[result.read(String).strip] = result.read(String).strip
        end
        sql = <<-SQL
          SELECT g.r_id, q.ad_value, g.sg_quantity, g.sg_type, coalesce(g.sg_date, r.jr_date, c.c_date), coalesce(g.sg_comment, ''),
                 g.c_id, r.jr_id, coalesce(c.c_comment, '')
          FROM stock_goods g
          JOIN fiche_detail q ON q.f_id = g.f_id AND q.ad_id = 23
          LEFT JOIN stock_change c ON c.c_id = g.c_id
          LEFT JOIN jrnx x ON x.j_id = g.j_id
          LEFT JOIN jrn r ON r.jr_grpt_id = x.j_grpt
          WHERE g.r_id IS NOT NULL AND g.sg_quantity <> 0
          ORDER BY 5, g.sg_id
          SQL
        db.query_each(sql) do |result|
          repository = result.read(Int64)
          card = result.read(String).strip
          quantity = result.read(PG::Numeric).to_big_d.abs
          outgoing = result.read(String) == "c"
          date = result.read(Time?) || next
          stock.movements << Source::StockMovement.new(repository, card, outgoing ? -quantity : quantity, date,
            result.read(String), result.read(Int64?), result.read(Int32?).try(&.to_i64), result.read(String))
        end
        stock.repository_rights = db.query_one("SELECT count(*) FROM profile_sec_repository", as: Int64).to_i32
      end

      # Prévisions : périodes de la prévision et d'un élément par
      # identifiant de période (`parm_periode.p_id`).
      private def read_forecasts(db, dataset) : Nil
        periods = dataset.fiscal_years.flat_map(&.periods).index_by(&.id)
        items = Hash(Int64, Array(Source::ForecastItem)).new { |hash, key| hash[key] = [] of Source::ForecastItem }
        db.query_each("SELECT fc_id, coalesce(fi_text, ''), coalesce(fi_account, ''), coalesce(fi_amount, 0), " \
                      "coalesce(fi_amount_initial, 0), coalesce(fi_order, 0), coalesce(fi_pid, 0) FROM forecast_item " \
                      "ORDER BY fc_id, fi_order, fi_id") do |result|
          category = result.read(Int32?).try(&.to_i64) || next
          label, formula = result.read(String), result.read(String)
          amount, initial = result.read(PG::Numeric).to_big_d, result.read(PG::Numeric).to_big_d
          position, pid = result.read(Int32), result.read(Int32).to_i64
          items[category] << Source::ForecastItem.new(label, formula, amount, initial, position, periods[pid]?)
        end
        categories = Hash(Int64, Array(Source::ForecastCategory)).new { |hash, key| hash[key] = [] of Source::ForecastCategory }
        db.query_each("SELECT f_id, fc_id, fc_desc, fc_order FROM forecast_category ORDER BY f_id, fc_order, fc_id") do |result|
          forecast = result.read(Int64)
          id = result.read(Int32).to_i64
          categories[forecast] << Source::ForecastCategory.new(result.read(String), result.read(Int32), items[id])
        end
        db.query_each("SELECT f_id, f_name, f_start_date, f_end_date FROM forecast ORDER BY f_id") do |result|
          id = result.read(Int32).to_i64
          name = result.read(String)
          first = result.read(Int64?).try { |pid| periods[pid]? }
          last = result.read(Int64?).try { |pid| periods[pid]? }
          dataset.forecasts << Source::Forecast.new(name, first, last, categories[id])
        end
      end

      # États de l'application d'origine (`document_state`) → états du cœur.
      STATES = {1 => "closed", 2 => "follow", 3 => "todo", 4 => "abandoned"}

      # Suivi : types (`document_type`), étiquettes, actions, fiches
      # concernées, commentaires, actions liées.
      private def read_followup(db, dataset) : Nil
        followup = dataset.followup
        db.query_each("SELECT dt_id, coalesce(dt_value, ''), coalesce(dt_prefix, '') FROM document_type ORDER BY dt_id") do |result|
          followup.types << Source::ActionType.new(result.read(Int32).to_i64, result.read(String), result.read(String))
        end
        db.query_each("SELECT t_id, t_tag, coalesce(t_description, ''), coalesce(t_actif, 'Y') = 'Y', coalesce(t_color, 1) " \
                      "FROM tags ORDER BY t_id") do |result|
          followup.tags << Source::Tag.new(result.read(Int32).to_i64, result.read(String), result.read(String),
            result.read(Bool), result.read(Int32))
        end
        comments = Hash(Int64, Array(Source::ActionComment)).new { |hash, key| hash[key] = [] of Source::ActionComment }
        db.query_each("SELECT ag_id, agc_date, coalesce(agc_comment_raw, agc_comment, ''), coalesce(tech_user, '') " \
                      "FROM action_gestion_comment WHERE ag_id IS NOT NULL ORDER BY agc_date, agc_id") do |result|
          comments[result.read(Int64)] << Source::ActionComment.new(result.read(Time), result.read(String), result.read(String))
        end
        persons = Hash(Int64, Array(String)).new { |hash, key| hash[key] = [] of String }
        db.query_each("SELECT ap.ag_id, q.ad_value FROM action_person ap JOIN fiche_detail q ON q.f_id = ap.f_id AND q.ad_id = 23 " \
                      "ORDER BY ap.ap_id") do |result|
          persons[result.read(Int32).to_i64] << result.read(String).strip
        end
        tags = Hash(Int64, Array(Int64)).new { |hash, key| hash[key] = [] of Int64 }
        db.query_each("SELECT ag_id, t_id FROM action_tags WHERE ag_id IS NOT NULL AND t_id IS NOT NULL ORDER BY at_id") do |result|
          tags[result.read(Int32).to_i64] << result.read(Int32).to_i64
        end
        sql = <<-SQL
          SELECT a.ag_id, a.ag_type, coalesce(a.ag_ref, ''), coalesce(a.ag_title, ''), a.ag_timestamp, coalesce(a.ag_hour, ''),
                 coalesce(a.ag_priority, 2), a.ag_state, a.ag_remind_date,
                 (SELECT ad_value FROM fiche_detail fd WHERE fd.f_id = a.f_id_dest AND fd.ad_id = 23),
                 (SELECT ad_value FROM fiche_detail fd WHERE fd.f_id = a.ag_contact AND fd.ad_id = 23),
                 a.ag_dest
          FROM action_gestion a WHERE a.ag_type IS NOT NULL ORDER BY a.ag_timestamp, a.ag_id
          SQL
        db.query_each(sql) do |result|
          id = result.read(Int32).to_i64
          type = result.read(Int32).to_i64
          reference, title = result.read(String), result.read(String)
          date = result.read(Time?) || Time.utc
          hour = result.read(String)
          priority = result.read(Int32).clamp(1, 3)
          state = STATES[result.read(Int32?) || 3]? || "todo"
          remind = result.read(Time?)
          card, contact = result.read(String?).try(&.strip.presence), result.read(String?).try(&.strip.presence)
          restricted = result.read(Int64) != -1
          followup.actions << Source::Action.new(id: id, type: type, reference: reference, title: title,
            date: Time.utc(date.year, date.month, date.day), hour: hour, priority: priority, state: state,
            remind_on: remind, card: card, contact: contact, concerned: persons[id], tags: tags[id],
            comments: comments[id], restricted: restricted)
        end
        db.query_each("SELECT aga_least, aga_greatest FROM action_gestion_related ORDER BY aga_id") do |result|
          followup.related << {result.read(Int64), result.read(Int64)}
        end
      end
    end
  end
end
