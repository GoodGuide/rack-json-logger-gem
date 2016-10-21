# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'rack_json_logger/version'

Gem::Specification.new do |gem|
  gem.name          = 'rack_json_logger'
  gem.version       = RackJsonLogger::VERSION
  gem.authors       = ['rtlong', 'Kenneth Ballenegger']
  gem.email         = ['ryan@rtlong.com', 'kenneth@ballenegger.com']
  gem.description   = 'RackJsonLogger is a gem that helps log sanely in production.'
  gem.summary       = gem.description
  gem.homepage      = ''

  gem.files         = `git ls-files -z`.split("\x0").reject do |f|
    f.match(%r{^(test|spec|features)/})
  end
  gem.bindir        = 'exe'
  gem.executables   = gem.files.grep(%r{^exe/}) { |f| File.basename(f) }
  gem.require_paths = ['lib']

  gem.add_dependency 'multi_json'
  gem.add_dependency 'colorize'
  gem.add_dependency 'trollop'
  gem.add_development_dependency 'minitest', '~> 5.0'
  gem.add_development_dependency 'bundler',  '~> 1.13'
  gem.add_development_dependency 'rake',     '~> 10.0'
  gem.add_development_dependency 'rack-test'
  gem.add_development_dependency 'hash_diff'
  gem.add_development_dependency 'awesome_print'
  gem.add_development_dependency 'deep_dup'
  gem.add_development_dependency 'timecop'
  gem.add_development_dependency 'simplecov'
  gem.add_development_dependency 'guard'
  gem.add_development_dependency 'guard-kjell'
  gem.add_development_dependency 'guard-rubocop'
end
