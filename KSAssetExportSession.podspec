Pod::Spec.new do |s|
    s.name             = 'KSAssetExportSession'
    s.version          = '1.0'
    s.summary          = 'Video Player Using Swift, based on AVPlayer,FFmpeg'
    s.description      = <<-DESC
    Video Player Using Swift, based on ffmpeg, support for the horizontal screen, vertical screen, the upper and lower slide to adjust the volume, the screen brightness, or so slide to adjust the playback progress.
    DESC

    s.homepage         = 'https://github.com/kingslay/KSAssetExportSession'
    s.authors = { 'kintan' => '554398854@qq.com' }
    s.license          = 'MIT'
    s.source           = { :git => 'https://github.com/kingslay/KSAssetExportSession.git', :tag => s.version.to_s }

    s.ios.deployment_target = '9.0'
    s.osx.deployment_target = '10.11'
    # s.watchos.deployment_target = '2.0'
    s.tvos.deployment_target = '10.2'
    s.swift_version = '5.0'
    # s.static_framework = true
    s.source_files = 'Sources/*.{swift}'
    s.frameworks = 'Foundation'
    s.frameworks = 'AVFoundation'
    s.test_spec 'Tests' do |test_spec|
        test_spec.source_files = 'Tests/*.swift'
        test_spec.resources = 'Tests/Resources/*'
    end    
end
