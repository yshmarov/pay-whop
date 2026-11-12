require "test_helper"

class DemoSimulationTest < ActiveSupport::TestCase
  test "invoice transitions enforce the lifecycle and reset clears history" do
    simulation = @user.demo_simulations.create!(kind: "invoice")
    assert_equal "draft", simulation.status
    assert_raises(DemoSimulation::InvalidTransition) { simulation.advance!("pay") }
    simulation.advance!("issue")
    simulation.advance!("past_due")
    simulation.advance!("pay")
    assert_equal %w[draft issued past_due paid], simulation.history.pluck("status")
    assert_raises(DemoSimulation::InvalidTransition) { simulation.advance!("void") }
    simulation.advance!("reset")
    simulation.advance!("void")
    assert_equal %w[draft void], simulation.history.pluck("status")
  end

  test "transfer outcomes are terminal and a reset permits trying the other outcome" do
    simulation = @user.demo_simulations.create!(kind: "transfer")
    simulation.advance!("fail")
    assert_equal "failed", simulation.status
    assert_raises(DemoSimulation::InvalidTransition) { simulation.advance!("succeed") }
    simulation.advance!("reset")
    simulation.advance!("succeed")
    assert_equal %w[pending succeeded], simulation.history.pluck("status")
  end
end
