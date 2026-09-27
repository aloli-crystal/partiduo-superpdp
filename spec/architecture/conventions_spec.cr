# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"
require "../../lib/partiduo-ui-bulma/scripts/api_boundary"

private def source_files(pattern : String) : Array(String)
  Dir.glob(File.join(Superpdp::SpecSupport::ROOT, pattern)).reject(&.includes?("/lib/")).sort!
end

private def flatten_keys(value : YAML::Any, prefix : String = "") : Array(String)
  if hash = value.as_h?
    hash.flat_map { |key, child| flatten_keys(child, prefix.empty? ? key.as_s : "#{prefix}.#{key.as_s}") }
  else
    [prefix]
  end
end

describe "Conventions de l'extension SUPERPDP" do
  it "ouvre chaque fichier source par l'en-tête SPDX" do
    missing = (source_files("{src,ui,spec,config,scripts}/**/*.{cr,sh}") + source_files("*.cr")).reject do |path|
      lines = File.read_lines(path)
      (path.ends_with?(".sh") ? lines[1]? : lines.first?) == "# SPDX-License-Identifier: AGPL-3.0-or-later"
    end
    missing += source_files("ui/**/*.html").reject do |path|
      File.read(path).starts_with?("{# SPDX-License-Identifier: AGPL-3.0-or-later")
    end
    missing.should be_empty
  end

  it "a les mêmes clés de traduction en fr, en et nl" do
    %w[src/superpdp/locales ui/bulma/locales].each do |dir|
      keys = Partiduo::LOCALES.to_h do |locale|
        tree = YAML.parse(File.read(File.join(Superpdp::SpecSupport::ROOT, dir, "#{locale}.yml")))
        {locale, flatten_keys(tree[locale]).sort}
      end
      keys["en"].should eq(keys["fr"])
      keys["nl"].should eq(keys["fr"])
    end
  end

  it "traduit toute clé citée par le code et les gabarits de l'extension" do
    cited = source_files("{src,ui}/**/*.{cr,html}").flat_map do |path|
      File.read(path).scan(/["'](superpdp(?:_ui)?\.[a-z_]+(?:\.[a-z0-9_]+)+)["']/).map(&.[1])
    end.uniq! - Partiduo::Modules[Superpdp::CODE].permissions
    cited.size.should be > 40
    dynamic = ["superpdp.adapter"]
    %w[sandbox production].each { |code| dynamic << "superpdp.modes.#{code}" }
    Superpdp::Api::AUTH_MODES.each { |code| dynamic << "superpdp.auth_modes.#{code}" }
    Superpdp::Api::SCHEMES.each { |code| dynamic << "superpdp.schemes.#{code}" }
    Superpdp::Api::VAT_REGIMES.each { |code| dynamic << "superpdp.vat_regimes.#{code}" }
    Superpdp::Api::VERIFICATION_STATUSES.each { |code| dynamic << "superpdp.verification.#{code}" }
    Superpdp::Api::ADDRESS_KINDS.each { |code| dynamic << "superpdp.address_kinds.#{code}" }
    Superpdp::Connector::FIELDS.each { |field| dynamic << "einvoicing.fields.#{field.name}" }
    missing = Partiduo::LOCALES.flat_map do |locale|
      I18n.with_locale(locale) do
        (cited + dynamic).select { |key| I18n.t(key).includes?("missing") }.map { |key| "#{locale}:#{key}" }
      end
    end
    missing.should be_empty
  end

  it "range ses tables sous le préfixe superpdp_ (ADR-003 D5)" do
    [Superpdp::Account, Superpdp::Authorization, Superpdp::InvoiceRef, Superpdp::SentMessage].map(&.db_table)
      .should eq(%w[superpdp_account superpdp_authorization superpdp_invoice_ref superpdp_sent_message])
  end

  it "ne parle au cœur, depuis ui/bulma, que par Partiduo::Api (ADR-005 D3)" do
    root = Superpdp::SpecSupport::ROOT
    ApiBoundary.scan([File.join(root, "ui")], base: root).map(&.to_s).should eq([] of String)
  end

  it "ne parle aux métiers d'extension, depuis ui/bulma, que par leur module Api (ADR-005 D4)" do
    allowed = %w[Api Ui CODE VERSION]
    leaks = source_files("ui/**/*.cr").flat_map do |path|
      File.read_lines(path).each_with_index(1).flat_map do |line, number|
        ApiBoundary.strip_comment(line).scan(/(?<![\w:])(Superpdp|Einvoicing|Document)::([A-Za-z_]\w*)/).compact_map do |match|
          "#{path.lchop(Superpdp::SpecSupport::ROOT + "/")}:#{number} #{match[1]}::#{match[2]}" unless allowed.includes?(match[2])
        end
      end
    end
    leaks.should be_empty
  end

  it "ne parle au cœur, depuis src/, que par Partiduo::Api (ADR-006 D3)" do
    leaks = source_files("src/**/*.cr").select do |path|
      File.read(path).matches?(/Partiduo::(Invoicing|Accounting|Cards|Core|Vat)::/)
    end
    leaks.map(&.lchop(Superpdp::SpecSupport::ROOT + "/")).should be_empty
  end

  it "ne cite d'EINV que sa surface d'adaptateur (connecteur, raccordements, transport, secrets, contrat)" do
    allowed = %w[Api Connector ConnectorError Unsupported Connections Connection Http Secrets Formats]
    leaks = source_files("src/**/*.cr").flat_map do |path|
      code = File.read_lines(path).map { |line| ApiBoundary.strip_comment(line) }.join('\n')
      code.scan(/(?<![\w:])Einvoicing::([A-Za-z_]\w*)/).map(&.[1]).reject { |name| allowed.includes?(name) }
        .map { |name| "#{path.lchop(Superpdp::SpecSupport::ROOT + "/")} Einvoicing::#{name}" }
    end
    leaks.uniq.should be_empty
  end
end
