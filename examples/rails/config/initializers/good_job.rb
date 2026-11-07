if Rails.env.production?
  Rails.application.configure do
    config.good_job.execution_mode = :async
    config.good_job.max_threads = 2
    config.good_job.enable_cron = true
    config.good_job.cron = {
      recover_deliveries: {cron: "*/5 * * * *", class: "RecoverDeliveriesJob"}
    }
  end
end
