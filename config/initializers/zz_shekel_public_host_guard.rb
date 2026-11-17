# Shekel fork: put the public-host guard at the very top of the middleware stack.
#
# The file name makes this initializer run after every other app initializer, so
# the guard also sits ahead of Rack::Cors (config/initializers/cors.rb inserts at 0
# and would otherwise answer preflight requests on the public host before the guard
# sees them). The middleware class is required explicitly because the stack is built
# before autoloading is available.
require Rails.root.join('app/middleware/shekel/public_host_guard').to_s

Rails.application.config.middleware.insert_before 0, Shekel::PublicHostGuard
