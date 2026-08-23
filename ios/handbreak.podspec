Pod::Spec.new do |s|
  s.name             = 'handbreak'
  s.version          = '0.1.0'
  s.summary          = 'HandBrake-inspired video & image compression for Flutter.'
  s.description      = <<-DESC
  Production-grade Flutter video & image compression inspired by HandBrake's pipeline.
  Hardware accelerated via VideoToolbox / AVFoundation.
                       DESC
  s.homepage         = 'https://github.com/your-org/flutter_handbreak'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'handbreak' => 'handbreak@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
end
