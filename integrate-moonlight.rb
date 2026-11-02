# Integrates the TrueCloud panel into a Moonlight iOS checkout (moonlight-ios/ next to this file).
#
# Idempotent. It:
#   1. applies moonlight-objc.patch (AppDelegate, MainFrameViewController, StreamView, Info.plist incl. the
#      home-screen name "TrueCloud")
#   2. adds the Swift sources (Sources/Kit = TrueCloudKit networking compiled straight into the app,
#      Sources/Shared, Sources/iOS = panel, glass on-screen controls, settings) to the Moonlight target
#   3. installs the launch assets, the in-app logo and the app icon
#
# Usage: ruby integrate-moonlight.rb [path-to-moonlight-ios]
require 'xcodeproj'
require 'fileutils'

here = __dir__
moonlight = File.expand_path(ARGV[0] || File.join(here, 'moonlight-ios'))
abort "moonlight-ios not found at #{moonlight}" unless File.directory?(moonlight)
project_path = File.join(moonlight, 'Moonlight.xcodeproj')

patch = File.join(here, 'moonlight-objc.patch')
if system("git -C #{moonlight} apply --reverse --check #{patch} > /dev/null 2>&1")
  puts '• ObjC patch already applied'
else
  system("git -C #{moonlight} apply #{patch}") or abort 'failed to apply moonlight-objc.patch'
  puts '• applied ObjC patch'
end

project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'Moonlight' } or abort 'Moonlight target not found'

sources = Dir[File.join(here, 'Sources', '{Kit,Shared,iOS}', '**', '*.swift')].sort
abort 'no sources found' if sources.empty?

group = project.main_group['TrueCloud'] || project.main_group.new_group('TrueCloud')
# Drop sources from earlier integrations that point elsewhere, so no file is compiled twice.
group.files.select { |f| f.path.to_s.end_with?('.swift') && !sources.include?(f.real_path.to_s) }.each do |ref|
  target.source_build_phase.files.select { |bf| bf.file_ref == ref }.each(&:remove_from_project)
  ref.remove_from_project
  puts "• removed stale #{ref.real_path}"
end
existing = target.source_build_phase.files_references.map(&:real_path).map(&:to_s)
sources.each do |path|
  next if existing.include?(path)
  ref = group.files.find { |f| f.real_path.to_s == path } || group.new_reference(path)
  target.add_file_references([ref])
end

bridging = File.join(here, 'Sources', 'iOS', 'TrueCloud-Bridging-Header.h')
group.new_reference(bridging) unless group.files.any? { |f| f.real_path.to_s == bridging }

target.build_configurations.each do |config|
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['SWIFT_OBJC_BRIDGING_HEADER'] = bridging
end
project.save

# Launch screen colour/logo (Info.plist's UILaunchScreen) and the in-app logo.
assets = File.join(moonlight, 'Limelight', 'Images.xcassets')
Dir[File.join(here, 'Assets', '*.{colorset,imageset}')].each do |set|
  FileUtils.cp_r(set, assets, remove_destination: true)
end
puts '• installed launch assets'

# App icon: rasterize AppIcon-1024.png into the appiconset sizes.
iconset = File.join(assets, 'AppIcon.appiconset')
src = File.join(here, 'Assets', 'AppIcon-1024.png')
if File.exist?(src) && File.directory?(iconset)
  {
    'Icon-App-29x29@1x.png' => 29, 'Icon-App-29x29@2x.png' => 58, 'Icon-App-29x29@2x-1.png' => 58,
    'Icon-App-29x29@3x.png' => 87, 'Icon-App-40x40@1x.png' => 40, 'Icon-App-40x40@2x.png' => 80,
    'Icon-App-40x40@2x-1.png' => 80, 'Icon-App-40x40@3x.png' => 120, 'Icon-App-60x60@2x.png' => 120,
    'Icon-App-60x60@3x.png' => 180, 'Icon-App-76x76@1x.png' => 76, 'Icon-App-76x76@2x.png' => 152,
    'Icon-App-83.5x83.5@2x.png' => 167
  }.each do |name, size|
    system('sips', '-z', size.to_s, size.to_s, src, '--out', File.join(iconset, name), out: File::NULL, err: File::NULL)
  end
  FileUtils.cp(src, File.join(iconset, '1024x icon.png'))
  puts '• installed app icon'
end

puts "Integrated TrueCloud into #{target.name}: #{target.source_build_phase.files.count} source files"
