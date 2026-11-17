Pod::Spec.new do |s|
  s.name             = 'scout_flutter'
  s.version          = '0.0.1'
  s.summary          = 'Scout Flutter monitoring plugin'
  s.description      = 'Native crash, ANR, and app hang detection for Scout Flutter'
  s.homepage         = 'https://github.com/base-14/scout_flutter'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'base-14' => 'info@base14.dev' }
  s.source           = { :path => '.' }
  s.source_files     = 'scout_flutter/Sources/scout_flutter/**/*.swift'
  s.dependency 'Flutter'
  s.dependency 'KSCrash', '~> 2.0.0-rc'
  # The native engine (modules Scout + ScoutKit). Keep equal to the ios-<version>
  # revision in scout_flutter/Package.swift.
  s.dependency 'ScoutKit', '0.1.13'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'
end
