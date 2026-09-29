# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoMigrate
  # Reprises de la base d'origine au-delà de la comptabilité générale
  # (BLOCAGES B-MIG-001, B-CRIT-003 ; DECISIONS D-R5-011 à D-R5-014) :
  # analytique, numéros de relevé des journaux financiers, stock,
  # prévisions, suivi. Toujours par le contrat `Partiduo::Api`, après les
  # écritures et le lettrage, *avant* la clôture des périodes reprises.
  #
  # Un module inactif sur l'instance : ses données sont consignées en
  # annexe (`non-repris.csv`) avec une note, comme avant. Les restrictions
  # de visibilité de la source (droits par dépôt, actions réservées à un
  # groupe de profils) ne sont pas reproduites : chacune donne un
  # avertissement (BLOCAGES B-SEC-001).
  class Importer
    # --- Analytique ---------------------------------------------------------------

    private def module_active?(code : String) : Bool
      Api::Modules.get(@actor, code).active
    rescue Api::NotFound
      false
    end

    # Plans, groupes, postes, puis ventilation des lignes d'écriture et
    # opérations diverses. Une imputation que l'instance ne sait pas
    # représenter (sens contraire à celui de la ligne, total d'un plan
    # supérieur au montant de la ligne, ligne non reprise) va en annexe ;
    # les autres forment les chiffres « avant » de la réconciliation par
    # poste (`Mapping#analytic_rows`).
    private def import_analytic : Nil
      analytic = dataset.analytic
      return if analytic.empty? && analytic.rows.empty?
      unless module_active?("ANALYTIC")
        notes << PartiduoMigrate.t("notes.module_inactive", module: "ANALYTIC")
        analytic.rows.each { |row| unported_analytic(row, "module_inactive") }
        return
      end
      plans = analytic_plans(analytic)
      posts = analytic_posts(analytic, plans)
      rows_by_line = analytic.rows.select(&.line_row).group_by { |row| row.line_row.as(Int64) }
      distribute_lines(rows_by_line, posts)
      analytic.rows.reject(&.line_row).group_by(&.group).each_value { |rows| misc_operation(rows, posts) }
    end

    private def analytic_plans(analytic : Source::Analytic) : Hash(String, Int64)
      plans = {} of String => Int64
      analytic.plans.each do |plan|
        name = plan.name.strip.presence || PartiduoMigrate.t("notes.unnamed_plan")
        view = check(Api::Analytic.create_plan(@actor, Api::Analytic::PlanInput.new(name[0, 255], plan.description)),
          "analytic_plan", plan.name) || next
        plans[plan.name] = view.id
        counts["analytic_plans"] += 1
      end
      plans
    end

    # Postes (et groupes) : `{plan, poste}` → identifiant du poste créé.
    private def analytic_posts(analytic : Source::Analytic, plans : Hash(String, Int64)) : Hash({String, String}, Int64)
      groups = {} of {String, String} => Int64
      analytic.groups.each do |group|
        plan_id = plans[group.plan]? || next
        view = check(Api::Analytic.create_group(@actor, Api::Analytic::GroupInput.new(plan_id, group.code, group.description)),
          "analytic_group", "#{group.plan}/#{group.code}", blocking: false) || next
        groups[{group.plan, group.code}] = view.id
      end
      posts = {} of {String, String} => Int64
      analytic.posts.each do |post|
        plan_id = plans[post.plan]? || next
        input = Api::Analytic::PostInput.new(plan_id: plan_id, code: post.code, description: post.description,
          group_id: post.group.try { |code| groups[{post.plan, code}]? }, active: post.active)
        view = check(Api::Analytic.create_post(@actor, input), "analytic_post", "#{post.plan}/#{post.code}") || next
        posts[{post.plan, post.code}] = view.id
        mapping.analytic_posts[{post.plan, post.code}] = {view.plan_name, view.code}
        counts["analytic_posts"] += 1
      end
      posts
    end

    # Ventilation des lignes, écriture par écriture (`distribute_entry`).
    private def distribute_lines(rows_by_line : Hash(Int64, Array(Source::AnalyticRow)),
                                 posts : Hash({String, String}, Int64)) : Nil
      located = {} of Int64 => {Int32, Int32}
      dataset.entries.each_with_index do |entry, index|
        entry.lines.each_with_index { |line, position| located[line.row] = {index, position} }
      end
      by_entry = Hash(Int32, Array({Int64, Array(Source::AnalyticRow)})).new { |hash, key| hash[key] = [] of {Int64, Array(Source::AnalyticRow)} }
      rows_by_line.each do |row_id, rows|
        ref = located[row_id]?
        line_id = ref.try { |value| mapping.lines[value]? }
        unless ref && line_id
          rows.each { |row| unported_analytic(row, "line_missing") }
          next
        end
        line = dataset.entries[ref[0]].lines[ref[1]]
        if reason = analytic_refusal(line, rows)
          rows.each { |row| unported_analytic(row, reason) }
          next
        end
        by_entry[ref[0]] << {line_id, rows}
      end
      by_entry.each do |index, lines|
        entry_id = mapping.entry_ids[index]? || next
        inputs = lines.map do |(line_id, rows)|
          Api::Analytic::LineDistributionInput.new(line_id, distribution_rows(rows, posts))
        end
        if check(Api::Analytic.distribute_entry(@actor, entry_id, inputs), "analytic", dataset.entries[index].reference)
          lines.each { |(_, rows)| mapping.analytic_rows.concat(rows) }
          counts["analytic_lines"] += lines.size
        end
      end
    end

    # Imputations d'une ligne que l'instance ne sait pas représenter : sens
    # contraire à la ligne, total d'un plan supérieur à son montant.
    private def analytic_refusal(line : Source::Line, rows : Array(Source::AnalyticRow)) : String?
      debit = line.debit > 0
      return "contrary_side" if rows.any? { |row| row.debit != debit }
      amount = debit ? line.debit : line.credit
      return "exceeds_line" if rows.group_by(&.plan).any? { |_, list| list.sum(Source::ZERO, &.amount) > amount }
      nil
    end

    # Lignes de ventilation : un rang (`oa_row`) commun aux plans, de même
    # montant, devient une ligne portant un poste par plan ; sinon une ligne
    # par imputation.
    private def distribution_rows(rows : Array(Source::AnalyticRow),
                                  posts : Hash({String, String}, Int64)) : Array(Api::Analytic::DistributionRowInput)
      rows.group_by(&.row).flat_map do |_, list|
        ids = list.compact_map { |row| posts[{row.plan, row.post}]? }
        if shared_row?(list)
          [Api::Analytic::DistributionRowInput.new(list.first.amount, ids)]
        else
          list.compact_map do |row|
            posts[{row.plan, row.post}]?.try { |id| Api::Analytic::DistributionRowInput.new(row.amount, [id]) }
          end
        end
      end
    end

    # Imputations d'un même rang, une par plan et de même montant : une
    # seule ligne de ventilation portant un poste par plan.
    private def shared_row?(list : Array(Source::AnalyticRow)) : Bool
      list.map(&.amount).uniq!.size == 1 && list.map(&.plan).uniq!.size == list.size
    end

    # Opération diverse analytique (imputations sans ligne d'écriture).
    private def misc_operation(rows : Array(Source::AnalyticRow), posts : Hash({String, String}, Int64)) : Nil
      first = rows.first
      lines = rows.group_by { |row| {row.row, row.debit, row.card} }.flat_map do |(_, debit, card), list|
        side = debit ? Api::Accounting::Side::Debit : Api::Accounting::Side::Credit
        ids = list.compact_map { |row| posts[{row.plan, row.post}]? }
        if shared_row?(list)
          [Api::Analytic::MiscRowInput.new(list.first.amount, side, ids, card.try { |code| mapping.cards[code]? || code })]
        else
          list.compact_map do |row|
            posts[{row.plan, row.post}]?.try { |id| Api::Analytic::MiscRowInput.new(row.amount, side, [id]) }
          end
        end
      end
      description = first.description.presence || PartiduoMigrate.t("notes.analytic_misc", group: first.group.to_s)
      input = Api::Analytic::MiscOperationInput.new(first.date, description[0, 255], lines)
      if check(Api::Analytic.create_misc_operation(@actor, input), "analytic", "#{first.date.to_s("%Y-%m-%d")} #{description}")
        mapping.analytic_rows.concat(rows)
        counts["analytic_misc"] += 1
      end
    end

    private def unported_analytic(row : Source::AnalyticRow, reason : String) : Nil
      dataset.unported << Source::Unported.new("analytic", "#{row.plan}/#{row.post}",
        PartiduoMigrate.t("source.analytic_detail", date: row.date.to_s("%Y-%m-%d"), plan: row.plan, post: row.post,
          side: PartiduoMigrate.t(row.debit ? "source.debit" : "source.credit"),
          amount: Fec.format_amount(row.amount), description: row.description).strip +
        " — " + PartiduoMigrate.t("notes.analytic_#{reason}"))
    end

    # --- Relevés bancaires ------------------------------------------------------------

    # Numéros de relevé des journaux financiers (base d'origine : la pièce
    # d'une opération financière est le numéro de l'extrait qui la porte,
    # posé aussi par le rapprochement d'origine) : les opérations d'un même
    # numéro forment un relevé rapproché (D-REC-001), la pièce reste celle
    # de l'écriture.
    private def import_statements : Nil
      groups = Hash({Int64, String}, Array(Int64)).new { |hash, key| hash[key] = [] of Int64 }
      dataset.entries.each_with_index do |entry, index|
        next unless entry.origin
        journal = dataset.journals[entry.journal_code]?
        next unless journal.try(&.kind) == "financial"
        number = entry.receipt.strip
        next if number.empty?
        ledger_id = mapping.ledger_ids[entry.journal_code]? || next
        entry_id = mapping.entry_ids[index]? || next
        groups[{ledger_id, number[0, Api::Accounting::MAX_STATEMENT_REFERENCE]}] << entry_id
      end
      groups.each do |(ledger_id, reference), ids|
        input = Api::Accounting::ReconcileInput.new(ledger_id: ledger_id, reference: reference, entry_ids: ids)
        counts["statements"] += 1 if check(Api::Accounting.reconcile(@actor, input), "statement", reference, blocking: false)
      end
    end

    # --- Stock ----------------------------------------------------------------------

    # Dépôts (le premier devient le dépôt par défaut), articles suivis sous
    # leur code stock, mouvements regroupés par opération manuelle ou par
    # écriture d'origine.
    private def import_stock : Nil
      stock = dataset.stock
      return if stock.empty?
      unless module_active?("STOCK")
        notes << PartiduoMigrate.t("notes.module_inactive", module: "STOCK")
        stock.movements.each do |movement|
          dataset.unported << Source::Unported.new("stock", movement.card,
            PartiduoMigrate.t("source.stock_detail", date: movement.date.to_s("%Y-%m-%d"),
              quantity: Fec.format_amount(movement.quantity), comment: movement.comment))
        end
        return
      end
      if stock.repository_rights > 0
        problems << Problem.new("security", "profile_sec_repository",
          PartiduoMigrate.t("notes.repository_rights", total: stock.repository_rights), blocking: false)
      end
      record_stock_changes(stock, stock_repositories(stock), track_items(stock))
    end

    # Mouvements regroupés par opération manuelle, écriture d'origine, ou
    # jour et commentaire.
    private def record_stock_changes(stock : Source::Stock, repositories : Hash(Int64, Int64), cards : Hash(String, Int64)) : Nil
      movements = stock.movements.group_by do |movement|
        key = movement.change.try { |id| "c#{id}" } || movement.entry_origin.try { |id| "e#{id}" } ||
              "d#{movement.date.to_s("%F")}:#{movement.comment}"
        {movement.repository, key}
      end
      movements.each do |(repository, _), list|
        repository_id = repositories[repository]? || next
        first = list.first
        lines = list.compact_map do |movement|
          card_id = cards[movement.card]? || next
          Api::Stock::ChangeLineInput.new(card_id, movement.quantity)
        end
        next if lines.empty?
        comment = first.change_comment.presence || first.comment.presence ||
                  first.entry_origin.try { |id| PartiduoMigrate.t("notes.stock_entry", origin: id.to_s) } || ""
        input = Api::Stock::ChangeInput.new(repository_id: repository_id, date: first.date, lines: lines, comment: comment[0, 1000])
        counts["stock_changes"] += 1 if check(Api::Stock.record_change(@actor, input), "stock", "#{first.date.to_s("%F")} #{comment}",
                                          blocking: false)
      end
    end

    private def stock_repositories(stock : Source::Stock) : Hash(Int64, Int64)
      repositories = {} of Int64 => Int64
      stock.repositories.each do |repository|
        country = repository.country.strip.upcase
        country = "" unless country.matches?(/\A[A-Z]{2}\z/)
        name = repository.name.strip.presence || "#{PartiduoMigrate.t("notes.repository")} #{repository.id}"
        input = Api::Stock::RepositoryInput.new(name: name[0, 100], address: repository.address, city: repository.city,
          country_code: country, phone: repository.phone)
        view = check(Api::Stock.create_repository(@actor, input), "stock_repository", name, blocking: false) || next
        repositories[repository.id] = view.id
        counts["stock_repositories"] += 1
      end
      if first = repositories.values.first?
        check(Api::Stock.update_settings(@actor, Api::Stock::SettingsInput.new(first)), "stock_repository", "default",
          blocking: false)
      end
      repositories
    end

    # Articles suivis : fiches qui ont un code stock ou des mouvements.
    private def track_items(stock : Source::Stock) : Hash(String, Int64)
      cards = {} of String => Int64
      (stock.codes.keys + stock.movements.map(&.card)).uniq.each do |code|
        view = Api::Cards.card_by_code(@actor, mapping.cards[code]? || code) || next
        input = Api::Stock::ItemInput.new(view.id, stock.codes[code]? || "")
        next unless check(Api::Stock.track_item(@actor, input), "stock_item", code, blocking: false)
        cards[code] = view.id
        counts["stock_items"] += 1
      end
      cards
    end

    # --- Prévisions --------------------------------------------------------------------

    # Prévisions sur les périodes de l'instance qui couvrent celles de la
    # source ; un élément propre à une période y reçoit son montant.
    private def import_forecasts : Nil
      dataset.forecasts.each do |forecast|
        first = forecast.first.try { |period| Api::Core.period_for(@actor, period.starts_on) }
        last = forecast.last.try { |period| Api::Core.period_for(@actor, period.ends_on) }
        unless first && last
          problems << Problem.new("forecast", forecast.name, PartiduoMigrate.t("notes.forecast_periods"), blocking: false)
          next
        end
        input = Api::Accounting::ForecastInput.new(forecast.name[0, 255], first.id, last.id)
        view = check(Api::Accounting.create_forecast(@actor, input), "forecast", forecast.name, blocking: false) || next
        counts["forecasts"] += 1
        forecast.categories.each { |category| import_forecast_category(view.forecast.id, forecast.name, category) }
      end
    end

    private def import_forecast_category(forecast_id : Int64, name : String, category : Source::ForecastCategory) : Nil
      input = Api::Accounting::ForecastCategoryInput.new(category.label, category.position)
      view = check(Api::Accounting.create_forecast_category(@actor, forecast_id, input), "forecast",
        "#{name} / #{category.label}", blocking: false) || return
      category.items.each do |item|
        period = item.period.try { |source| Api::Core.period_for(@actor, source.starts_on) }
        amounts = period ? [Api::Accounting::ForecastPeriodAmountInput.new(period.id, item.amount)] : [] of Api::Accounting::ForecastPeriodAmountInput
        input = Api::Accounting::ForecastItemInput.new(label: item.label, formula: item.formula,
          amount: period ? Source::ZERO : item.amount, initial_amount: item.initial, position: item.position,
          period_amounts: amounts)
        counts["forecast_items"] += 1 if check(Api::Accounting.create_forecast_item(@actor, view.id, input), "forecast",
                                           "#{name} / #{category.label} / #{item.label}", blocking: false)
      end
    end

    # --- Suivi -----------------------------------------------------------------------

    # Types (par code), étiquettes, actions (fiche, contact, fiches
    # concernées, étiquettes, état), commentaires (date et auteur d'origine
    # en tête), actions liées. Visibilité réservée à un groupe : non
    # reproduite, avertissement.
    private def import_followup : Nil
      followup = dataset.followup
      return if followup.empty?
      unless module_active?("FOLLOWUP")
        notes << PartiduoMigrate.t("notes.module_inactive", module: "FOLLOWUP")
        followup.actions.each do |action|
          dataset.unported << Source::Unported.new("followup", action.reference.presence || action.id.to_s, action.title)
        end
        return
      end
      restricted = followup.actions.count(&.restricted)
      if restricted > 0
        problems << Problem.new("security", "action_gestion.ag_dest",
          PartiduoMigrate.t("notes.restricted_actions", total: restricted), blocking: false)
      end
      types = action_types(followup)
      tags = followup_tags(followup)
      created = {} of Int64 => Int64
      followup.actions.each do |action|
        type_id = types[action.type]? || next
        view = check(Api::Followup.create_action(@actor, action_input(action, type_id, tags)), "followup",
          action.reference.presence || action.title, blocking: false) || next
        created[action.id] = view.id
        counts["actions"] += 1
        notes << PartiduoMigrate.t("notes.action_reference", source: action.reference, target: view.reference) unless action.reference.empty?
        action.comments.each do |comment|
          text = PartiduoMigrate.t("notes.action_comment", date: comment.date.to_s("%Y-%m-%d %H:%M"), author: comment.author,
            text: comment.text)
          check(Api::Followup.add_comment(@actor, view.id, text[0, 10_000]), "followup", view.reference, blocking: false)
        end
      end
      followup.related.each do |(left, right)|
        a, b = created[left]?, created[right]?
        check(Api::Followup.relate(@actor, a, b), "followup", "#{left}–#{right}", blocking: false) if a && b
      end
    end

    private def action_input(action : Source::Action, type_id : Int64, tags : Hash(Int64, Int64)) : Api::Followup::ActionInput
      card = ->(code : String?) { code.try { |value| Api::Cards.card_by_code(@actor, mapping.cards[value]? || value).try(&.id) } }
      Api::Followup::ActionInput.new(action_type_id: type_id, date: action.date, title: action.title[0, 255],
        hour: action_hour(action.hour), priority: action.priority, state: action.state, remind_on: action.remind_on,
        card_id: card.call(action.card), contact_card_id: card.call(action.contact),
        concerned_card_ids: action.concerned.compact_map { |code| card.call(code) }.uniq!,
        tag_ids: action.tags.compact_map { |id| tags[id]? })
    end

    # Heure libre de la source (`14h30`, `9.00`) → `HH:MM`, sinon vide.
    private def action_hour(text : String) : String
      match = text.strip.match(/\A(\d{1,2})\s*[:hH.]\s*(\d{2})/) || return ""
      hours, minutes = match[1].to_i, match[2].to_i
      hours < 24 && minutes < 60 ? "#{hours.to_s.rjust(2, '0')}:#{match[2]}" : ""
    end

    # Types de la source → types de l'instance, par code (préfixe nettoyé).
    private def action_types(followup : Source::Followup) : Hash(Int64, Int64)
      existing = Api::Followup.action_types(@actor).to_h { |type| {type.code, type.id} }
      followup.types.each_with_object({} of Int64 => Int64) do |type, result|
        code = type.prefix.upcase.gsub(/[^A-Z0-9]/, "")[0, 10].presence ||
               type.label.upcase.gsub(/[^A-Z0-9]/, "")[0, 10].presence || "T#{type.id}"
        if id = existing[code]?
          result[type.id] = id
          next
        end
        label = type.label.strip.presence || code
        view = check(Api::Followup.create_action_type(@actor, Api::Followup::ActionTypeInput.new(code, label[0, 80])),
          "followup", code, blocking: false) || next
        existing[view.code] = view.id
        result[type.id] = view.id
      end
    end

    private def followup_tags(followup : Source::Followup) : Hash(Int64, Int64)
      followup.tags.each_with_object({} of Int64 => Int64) do |tag, result|
        input = Api::Followup::TagInput.new(tag.label.strip[0, 60], tag.description, tag.active, tag.color.clamp(1, 10))
        view = check(Api::Followup.create_tag(@actor, input), "followup", tag.label, blocking: false) || next
        result[tag.id] = view.id
      end
    end
  end
end
