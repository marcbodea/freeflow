#!/usr/bin/env ruby
require 'yaml'
require 'fileutils'
require 'pathname'
require 'xcodeproj'

root = File.expand_path('..', __dir__)
config = YAML.load_file(File.join(root, 'project.yml'))
project_path = File.join(root, "#{config.fetch('name')}.xcodeproj")

FileUtils.rm_rf(project_path)
project = Xcodeproj::Project.new(project_path)
project.root_object.attributes['LastUpgradeCheck'] = '1600'
project.root_object.attributes['ORGANIZATIONNAME'] = config['organizationName'] if config['organizationName']

def relative_path(root, absolute_path)
    Pathname.new(absolute_path).relative_path_from(Pathname.new(root)).to_s
end

config_group = project.main_group.new_group('Config')
source_group = project.main_group.new_group('Sources')
resource_group = project.main_group.new_group('Resources')
test_group = project.main_group.new_group('Tests')

xcconfig_refs = {}
config.fetch('configs').each_value do |path|
  xcconfig_refs[path] ||= config_group.new_file(path)
end

project.build_configuration_list.build_configurations.each do |build_config|
  path = config.fetch('configs').fetch(build_config.name)
  build_config.base_configuration_reference = xcconfig_refs.fetch(path)
end

app_config = config.fetch('appTarget')
deployment_target = config.fetch('deploymentTarget')
app_target = project.new_target(:application, app_config.fetch('name'), :osx, deployment_target)

app_target.build_configurations.each do |build_config|
  path = config.fetch('configs').fetch(build_config.name)
  build_config.base_configuration_reference = xcconfig_refs.fetch(path)
  build_config.build_settings['INFOPLIST_FILE'] = app_config.fetch('infoPlist')
  build_config.build_settings['GENERATE_INFOPLIST_FILE'] = 'NO'
  build_config.build_settings['CODE_SIGN_ENTITLEMENTS'] = app_config.fetch('entitlements')
  build_config.build_settings['PRODUCT_NAME'] = '$(APP_DISPLAY_NAME)'
  build_config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = '$(APP_BUNDLE_IDENTIFIER)'
  build_config.build_settings['PRODUCT_MODULE_NAME'] = 'FreeFlow'
  build_config.build_settings['SWIFT_VERSION'] = '5.0'
  build_config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = deployment_target
  build_config.build_settings['SDKROOT'] = 'macosx'
end

Dir.glob(File.join(root, *app_config.fetch('sources'))).sort.each do |path|
  file_ref = source_group.new_file(relative_path(root, path))
  app_target.add_file_references([file_ref])
end

resource_refs = Dir.glob(File.join(root, *app_config.fetch('resources'))).sort.map do |path|
  resource_group.new_file(relative_path(root, path))
end
app_target.add_resources(resource_refs)

test_config = config.fetch('testTarget')
test_target = project.new_target(:unit_test_bundle, test_config.fetch('name'), :osx, deployment_target)
test_target.add_dependency(app_target)

test_target.build_configurations.each do |build_config|
  path = config.fetch('configs').fetch(build_config.name)
  build_config.base_configuration_reference = xcconfig_refs.fetch(path)
  build_config.build_settings['PRODUCT_NAME'] = 'FreeFlowTests'
  build_config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.marcbodea.freeflow.tests'
  build_config.build_settings['PRODUCT_MODULE_NAME'] = 'FreeFlowTests'
  build_config.build_settings['SWIFT_VERSION'] = '5.0'
  build_config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = deployment_target
  build_config.build_settings['SDKROOT'] = 'macosx'
  build_config.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  build_config.build_settings['INFOPLIST_FILE'] = ''
  build_config.build_settings['CODE_SIGN_ENTITLEMENTS'] = ''
  build_config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
  build_config.build_settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/$(APP_DISPLAY_NAME).app/Contents/MacOS/$(APP_DISPLAY_NAME)'
  build_config.build_settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
end

Dir.glob(File.join(root, *test_config.fetch('sources'))).sort.each do |path|
  file_ref = test_group.new_file(relative_path(root, path))
  test_target.add_file_references([file_ref])
end

config.fetch('schemes').each do |scheme_config|
  scheme = Xcodeproj::XCScheme.new
  build_configuration = scheme_config.fetch('buildConfiguration')

  scheme.add_build_target(app_target)
  scheme.set_launch_target(app_target)
  scheme.launch_action.build_configuration = build_configuration
  scheme.profile_action.build_configuration = build_configuration
  scheme.analyze_action.build_configuration = build_configuration
  scheme.archive_action.build_configuration = build_configuration

  if scheme_config['testTarget']
    scheme.add_build_target(test_target, false)
    scheme.add_test_target(test_target)
    scheme.test_action.build_configuration = build_configuration
  end

  scheme.save_as(project.path, scheme_config.fetch('name'), true)
end

project.save
