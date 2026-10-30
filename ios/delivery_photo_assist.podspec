#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint delivery_photo_assist.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'delivery_photo_assist'
  s.version          = '0.0.1'
  s.summary          = '司机配送拍照辅助，支持双照片取景提示与可替换的本地 PP-PicoDet 模型。'
  s.description      = <<-DESC
司机配送拍照辅助，支持双照片取景提示与可替换的本地 PP-PicoDet 模型。
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'delivery_photo_assist/Sources/delivery_photo_assist/**/*.{h,m,mm,swift}'
  s.dependency 'Flutter'
  s.platform = :ios, '16.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  s.resource_bundles = {'delivery_photo_assist_privacy' => ['delivery_photo_assist/Sources/delivery_photo_assist/PrivacyInfo.xcprivacy']}
end
