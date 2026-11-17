require 'rails_helper'

RSpec.describe Shekel::RetentionJob do
  it 'enqueues on the low queue' do
    expect { described_class.perform_later }.to have_enqueued_job(described_class).on_queue('low')
  end

  it 'runs the retention service' do
    retention = instance_double(Shekel::Retention, perform: nil)
    allow(Shekel::Retention).to receive(:new).and_return(retention)

    described_class.perform_now

    expect(retention).to have_received(:perform)
  end

  it 'is scheduled daily at 02:30' do
    schedule = Sidekiq::Cron::Support.load_yaml(ERB.new(Rails.root.join('config/schedule.yml').read).result)

    expect(schedule['shekel_retention_job']).to eq('cron' => '30 2 * * *', 'class' => 'Shekel::RetentionJob', 'queue' => 'low')
  end
end
