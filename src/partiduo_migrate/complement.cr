# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoMigrate
  # FEC complété par la base NOALYSS dont il est issu (ADR-001 D5 : la base
  # apporte ce que le FEC ne porte pas). Les écritures, montants et
  # lettrages restent ceux du FEC ; la base ajoute le plan comptable complet
  # (types, comptes non mouvementés), la nature des journaux et leur fiche
  # Banque, les fiches complètes, les taux de TVA, les exercices et leurs
  # périodes closes, l'échéance des écritures et leurs pièces jointes,
  # rapprochées par journal, date et pièce.
  module Complement
    def self.merge(fec : Source::Dataset, noalyss : Source::Dataset) : Source::Dataset
      dataset = Source::Dataset.new(PartiduoMigrate.t("source.completed_description", fec: fec.description,
        noalyss: noalyss.description))
      dataset.file_name = fec.file_name
      dataset.full_chart = true
      dataset.zero_lines = fec.zero_lines
      # Écritures du FEC : contrôle de lecture du FEC.
      dataset.control = fec.control
      fec.entries.each { |entry| dataset.entries << entry }
      noalyss.accounts.each { |number, account| dataset.accounts[number] = account }
      fec.accounts.each { |number, account| dataset.accounts[number] ||= account }
      noalyss.journals.each { |code, journal| dataset.journals[code] = journal }
      fec.journals.each { |code, journal| dataset.journals[code] ||= journal }
      fec.parties.each { |code, label| dataset.parties[code] = label }
      dataset.cards.concat(noalyss.cards)
      dataset.card_categories.concat(noalyss.card_categories)
      dataset.attribute_labels.merge!(noalyss.attribute_labels)
      dataset.vat_rates.concat(noalyss.vat_rates)
      dataset.fiscal_years.concat(noalyss.fiscal_years)
      dataset.unported.concat(noalyss.unported)

      index = noalyss.entries.group_by { |entry| {entry.journal_code, entry.date, entry.receipt.strip} }
      used = Set(Int64).new
      dataset.entries.each do |entry|
        candidates = index[{entry.journal_code, entry.date, entry.receipt.strip}]? || next
        match = candidates.find { |candidate| candidate.total_debit == entry.total_debit && !used.includes?(candidate.origin || 0_i64) } ||
                next
        match.origin.try { |origin| used << origin }
        entry.due_date ||= match.due_date
        entry.attachment ||= match.attachment
      end
      noalyss.entries.each do |entry|
        next if entry.attachment.nil? || used.includes?(entry.origin || 0_i64)
        dataset.unported << Source::Unported.new("orphan_attachment", entry.reference,
          PartiduoMigrate.t("source.orphan_attachment_detail", file: entry.attachment.try(&.filename).to_s))
      end
      dataset
    end
  end
end
