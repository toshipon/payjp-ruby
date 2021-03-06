$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), 'lib'))

require 'payjp/version'

Gem::Specification.new do |s|
  s.name = 'payjp'
  s.version = Payjp::VERSION
  s.summary = 'Ruby bindings for the Payjp API'
  s.description = 'PAY.JP is the easiest way to accept payments online.'
  s.authors = ['PAY.JP']
  s.email = ['support@pay.jp']
  s.homepage = 'https://pay.jp'
  s.license = 'MIT'

  s.add_dependency('rest-client', '~> 1.4')
  s.add_dependency('json', '~> 1.8.1')

  s.add_development_dependency('mocha', '~> 0.13.2')
  s.add_development_dependency('shoulda', '~> 3.4.0')
  s.add_development_dependency('test-unit')
  s.add_development_dependency('rake')

  s.files = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- test/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map { |f| File.basename(f) }
  s.require_paths = ['lib']
end
