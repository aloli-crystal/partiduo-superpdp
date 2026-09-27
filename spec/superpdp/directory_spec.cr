# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Superpdp::SpecSupport
private alias E = Einvoicing::SpecSupport
private alias EApi = Einvoicing::Api

describe "Annuaire par SUPER PDP (ADR-004 D8)" do
  it "reconnaît les formats d'adresse française : SIREN, SIREN_SIRET, SIREN_SUFFIXE, SIREN_SIRET_CODEROUTAGE" do
    kinds = %w[853322915 853322915_85332291500010 853322915_DEPARTEMENTJURIDIQUE 853322915_85332291500010_FACTURESPUBLIQUES]
      .map { |address| Superpdp::Mapping.address_kind(address) }
    kinds.should eq(%w[SIREN SIREN_SIRET SIREN_SUFFIXE SIREN_SIRET_CODEROUTAGE])
    entry = Superpdp::Mapping.directory_entry("0225:853322915_85332291500010_FACTURESPUBLIQUES", "SUPER G", true)
    {entry.scheme, entry.address, entry.siren, entry.siret, entry.routing_id, entry.status}
      .should eq({"0225", "853322915_85332291500010_FACTURESPUBLIQUES", "853322915", "85332291500010", "FACTURESPUBLIQUES", "active"})
    belgian = Superpdp::Mapping.directory_entry("0208:0869763267", "", nil, "peppol")
    {belgian.scheme, belgian.address, belgian.siren}.should eq({"0208", "0869763267", ""})
  end

  it "cherche par SIREN, SIRET, adresse ou nom dans l'annuaire français ; numéro belge en schéma 0208" do
    S.books
    S.connect
    S.platform.add_company("SUPER G", "853322915", ["0225:853322915", "0225:853322915_85332291500010",
                                                    "0225:853322915_DEPARTEMENTJURIDIQUE"])
    E.card("CUSTOMER", "Super G SAS", "CLI-SUPERG", siren: "853322915")
    by_siren = EApi.lookup(E.admin, "853 322 915").value!
    by_siren.map(&.address).should eq(%w[853322915 853322915_85332291500010 853322915_DEPARTEMENTJURIDIQUE])
    by_siren.first.card_code.should eq("CLI-SUPERG")
    by_siren.map(&.scheme).uniq!.should eq(["0225"])
    EApi.lookup(E.admin, "85332291500010").value!.map(&.address).should eq(["853322915_85332291500010"])
    EApi.lookup(E.admin, "0225:853322915_departementjuridique").value!.map(&.routing_id).should eq(["DEPARTEMENTJURIDIQUE"])
    EApi.lookup(E.admin, "SUPER").value!.map { |entry| {entry.address, entry.name} }.should eq([{"853322915", "SUPER G"}])
    belgian = EApi.lookup(E.admin, "BE 0869.763.267".gsub(".", "")).value!
    belgian.map { |entry| {entry.scheme, entry.address, entry.platform} }.should eq([{"0208", "0869763267", "peppol"}])
  end

  it "liste les lignes d'annuaire de l'entreprise, avec leur format" do
    S.books
    S.connect
    lines = Superpdp::Api.directory_lines(S.admin).value!
    lines.map { |line| {line.identifier, line.kind, line.reply_to} }
      .should eq([{"0225:#{E::COMPANY_SIREN}", "SIREN", false}, {"0225:#{E::COMPANY_SIREN}_replyto", "SIREN", true}])
  end
end
