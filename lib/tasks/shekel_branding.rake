# Shekel fork: apply the Shekel Mobility branding defaults from
# config/installation_config.yml to an installation that already exists.
#
# ConfigLoader only creates missing configs on boot, so a database created
# before the branding change keeps Chatwoot's values. Upstream's way to edit
# them (Super Admin > Settings > Custom Branding) is enterprise-only, and
# `ConfigLoader.new.process(reconcile_only_new: false)` would reset every other
# installation config and feature flag too. This touches the branding keys only.
#
#   bundle exec rails shekel:apply_branding
namespace :shekel do
  branding_keys = %w[
    INSTALLATION_NAME LOGO LOGO_DARK LOGO_THUMBNAIL
    BRAND_NAME BRAND_URL WIDGET_BRAND_URL TERMS_URL PRIVACY_URL
  ]

  desc 'Apply the Shekel Mobility branding defaults to an existing installation'
  task apply_branding: :environment do
    defaults = ConfigLoader.new.general_configs.index_by { |config| config['name'] }

    branding_keys.each do |name|
      config = InstallationConfig.find_or_initialize_by(name: name)
      config.value = defaults.fetch(name).fetch('value')
      config.save!
      puts "#{name} = #{config.value}"
    end

    GlobalConfig.clear_cache
  end
end
