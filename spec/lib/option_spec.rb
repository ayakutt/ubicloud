# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Option do
  describe "#VmSize options" do
    it "no burstable cpu allowed for Standard VMs" do
      expect(Option::VmSizes.map { it.name.include?("burstable-") == (it.cpu_burst_percent_limit > 0) }.all?(true)).to be true
    end

    it "no odd number of vcpus allowed, except for 1" do
      expect(Option::VmSizes.all? { it.vcpus == 1 || it.vcpus.even? }).to be true
    end
  end

  describe "#VmFamily options" do
    it "families include burstables" do
      expect(described_class.families.map(&:name)).to include("burstable")
    end
  end

  describe "#kubernetes_upgrade_candidate" do
    it "returns upgrade version for upgradeable version" do
      expect(described_class.kubernetes_upgrade_candidate("v1.33")).to eq("v1.34")
    end

    it "returns nil for latest version" do
      expect(described_class.kubernetes_upgrade_candidate("v1.34")).to be_nil
    end
  end
end
