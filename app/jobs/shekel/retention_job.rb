# Shekel fork: daily conversation retention; see Shekel::Retention and
# docs/shekel/OPERATIONS.md. Scheduled in config/schedule.yml.
class Shekel::RetentionJob < ApplicationJob
  queue_as :low

  def perform
    Shekel::Retention.new.perform
  end
end
