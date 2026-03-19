#!/usr/bin/env ruby
# frozen_string_literal: true

config_path = File.expand_path("../Config/Base.xcconfig", __dir__)
content = File.read(config_path)

marketing_match = content.match(/^MARKETING_VERSION = (.+)$/)
build_match = content.match(/^CURRENT_PROJECT_VERSION = (.+)$/)

abort("Failed to find MARKETING_VERSION in #{config_path}") unless marketing_match
abort("Failed to find CURRENT_PROJECT_VERSION in #{config_path}") unless build_match

marketing_version = marketing_match[1].strip
build_number = Integer(build_match[1].strip, 10)

command = ARGV.fetch(0, "build")

major, minor, patch = marketing_version.split(".").map { |segment| Integer(segment, 10) }

case command
when "build"
  build_number += 1
when "patch"
  patch += 1
  build_number += 1
when "minor"
  minor += 1
  patch = 0
  build_number += 1
when "major"
  major += 1
  minor = 0
  patch = 0
  build_number += 1
when "set-version"
  new_version = ARGV[1] or abort("Usage: #{$PROGRAM_NAME} set-version X.Y.Z")
  unless new_version.match?(/\A\d+\.\d+\.\d+\z/)
    abort("Version must use X.Y.Z format")
  end
  major, minor, patch = new_version.split(".").map { |segment| Integer(segment, 10) }
when "set-build"
  new_build = ARGV[1] or abort("Usage: #{$PROGRAM_NAME} set-build N")
  build_number = Integer(new_build, 10)
  abort("Build number must be >= 1") if build_number < 1
else
  abort("Usage: #{$PROGRAM_NAME} [build|patch|minor|major|set-version X.Y.Z|set-build N]")
end

new_marketing_version = "#{major}.#{minor}.#{patch}"

updated = content
  .sub(/^MARKETING_VERSION = .+$/, "MARKETING_VERSION = #{new_marketing_version}")
  .sub(/^CURRENT_PROJECT_VERSION = .+$/, "CURRENT_PROJECT_VERSION = #{build_number}")

File.write(config_path, updated)

release_tag = "v#{new_marketing_version}-b#{build_number}"

puts "Updated #{config_path}"
puts "MARKETING_VERSION=#{new_marketing_version}"
puts "CURRENT_PROJECT_VERSION=#{build_number}"
puts "RELEASE_TAG=#{release_tag}"
