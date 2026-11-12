class DemoSimulation < ApplicationRecord
  class InvalidTransition < StandardError; end

  FLOWS = {
    "invoice" => {
      "draft" => {"issue" => "issued", "void" => "void"},
      "issued" => {"pay" => "paid", "past_due" => "past_due", "void" => "void"},
      "past_due" => {"pay" => "paid", "void" => "void"},
      "paid" => {}, "void" => {}
    },
    "transfer" => {
      "pending" => {"succeed" => "succeeded", "fail" => "failed"},
      "succeeded" => {}, "failed" => {}
    }
  }.freeze
  LABELS = {"issue" => "Simulate issuance", "pay" => "Simulate payment", "past_due" => "Simulate overdue", "void" => "Simulate void", "succeed" => "Simulate success", "fail" => "Simulate failure"}.freeze

  belongs_to :user
  validates :kind, inclusion: {in: FLOWS.keys}, uniqueness: {scope: :user_id}
  validates :status, inclusion: {in: ->(record) { FLOWS.fetch(record.kind, {}).keys }}
  before_validation :initialize_flow, on: :create

  def reference = "sim_#{kind}_#{id}"
  def actions = FLOWS.fetch(kind).fetch(status)

  def advance!(event)
    with_lock do
      next_status = (event == "reset") ? FLOWS.fetch(kind).keys.first : actions[event]
      raise InvalidTransition unless next_status
      entries = (event == "reset") ? [] : history
      update!(status: next_status, history: entries + [{"status" => next_status, "at" => Time.current.iso8601}])
    end
  end

  private

  def initialize_flow
    self.status = FLOWS.fetch(kind, {}).keys.first
    self.history = [{"status" => status, "at" => Time.current.iso8601}]
  end
end
