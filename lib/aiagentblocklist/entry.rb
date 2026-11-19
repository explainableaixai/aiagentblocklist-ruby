# frozen_string_literal: true

require "json"

module AiAgentBlocklist
  # One row of the feed, with the ten columns of aab_full.csv and aab_full.json.
  Entry = Struct.new(
    :tool_name, :tool_domain, :category, :subcategory, :agent_type,
    :kind, :ident, :name, :platform, :risk_grade,
    keyword_init: true
  ) do
    # Builds an entry from a decoded JSON object or a CSV row hash.
    def self.from_hash(hash)
      values = members.each_with_object({}) do |field, out|
        value = hash[field.to_s] || hash[field]
        out[field] = value.nil? ? "" : value.to_s
      end
      new(**values)
    end

    def domain?
      kind == "domain"
    end

    def to_json(*args)
      to_h.transform_keys(&:to_s).to_json(*args)
    end
  end
end
