#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Idempotently adds a `SocketTests` XCTest unit test target to Socket.xcodeproj.
# Run this once (or after a `git clean`) to (re)establish the test target; it's
# safe to run repeatedly. Does not rearrange or delete anything it didn't add.
#
# Usage:
#   gem install --user-install xcodeproj
#   ruby scripts/add-test-target.rb
#
# After running, `xcodebuild test -scheme Socket` picks up the target via the
# updated shared scheme.

require "xcodeproj"

PROJECT_PATH   = File.expand_path("../Socket.xcodeproj", __dir__)
TARGET_NAME    = "SocketTests"
BUNDLE_ID      = "io.socketbrowser.socket.tests"
DEPLOYMENT_TGT = "15.5"
TESTS_DIR_NAME = "SocketTests"

project = Xcodeproj::Project.open(PROJECT_PATH)

# ---- App target (the thing our tests load into) -----------------------------

app_target = project.native_targets.find { |t| t.name == "Socket" }
abort "Could not find the Socket app target" unless app_target

# ---- Ensure the SocketTests native target exists ----------------------------

existing = project.native_targets.find { |t| t.name == TARGET_NAME }
if existing
  puts "SocketTests target already present — refreshing settings."
  test_target = existing
else
  puts "Creating SocketTests native target."
  test_target = project.new(Xcodeproj::Project::Object::PBXNativeTarget)
  test_target.name = TARGET_NAME
  test_target.product_name = TARGET_NAME
  test_target.product_type = "com.apple.product-type.bundle.unit-test"
  test_target.build_configuration_list =
    Xcodeproj::Project::ProjectHelper.configuration_list(
      project, :osx, DEPLOYMENT_TGT, test_target, :swift
    )
  project.targets << test_target

  # Product reference (SocketTests.xctest) in the Products group.
  product_ref = project.new(Xcodeproj::Project::Object::PBXFileReference)
  product_ref.path = "#{TARGET_NAME}.xctest"
  product_ref.source_tree = "BUILT_PRODUCTS_DIR"
  product_ref.include_in_index = "0"
  product_ref.explicit_file_type = "wrapper.cfbundle"
  project.products_group.children << product_ref
  test_target.product_reference = product_ref

  # Sources + Frameworks + Resources build phases.
  test_target.build_phases << project.new(Xcodeproj::Project::Object::PBXSourcesBuildPhase)
  test_target.build_phases << project.new(Xcodeproj::Project::Object::PBXFrameworksBuildPhase)
  test_target.build_phases << project.new(Xcodeproj::Project::Object::PBXResourcesBuildPhase)
end

# ---- Wire settings so XCTest can reach the hosting app's types --------------

test_target.build_configurations.each do |cfg|
  s = cfg.build_settings
  s["PRODUCT_NAME"] = "$(TARGET_NAME)"
  s["PRODUCT_BUNDLE_IDENTIFIER"] = BUNDLE_ID
  s["MACOSX_DEPLOYMENT_TARGET"] = DEPLOYMENT_TGT
  s["SWIFT_VERSION"] = "5.0"
  s["CODE_SIGN_STYLE"] = "Automatic"
  s["CODE_SIGN_IDENTITY"] = "-"
  s["CODE_SIGN_IDENTITY[sdk=macosx*]"] = "-"
  s["GENERATE_INFOPLIST_FILE"] = "YES"
  s["SUPPORTED_PLATFORMS"] = "macosx"
  # TEST_HOST + BUNDLE_LOADER let unit tests import `@testable import Socket`
  # and exercise internal symbols from the main app bundle.
  s["TEST_HOST"] = "$(BUILT_PRODUCTS_DIR)/Socket.app/Contents/MacOS/Socket"
  s["BUNDLE_LOADER"] = "$(TEST_HOST)"
  s["LD_RUNPATH_SEARCH_PATHS"] = [
    "$(inherited)",
    "@executable_path/../Frameworks",
    "@loader_path/../Frameworks"
  ]
  # Mirror the app target's extra search paths so `@testable import Socket`
  # can resolve the Rust shields_compiler static library + its modulemap.
  s["HEADER_SEARCH_PATHS"] = "$(SRCROOT)/Socket/ThirdParty/ShieldsEngine"
  s["SWIFT_INCLUDE_PATHS"] = "$(SRCROOT)/Socket/ThirdParty/ShieldsEngine"
  s["LIBRARY_SEARCH_PATHS"] = [
    "$(inherited)",
    "$(SRCROOT)/Support/ShieldsCompiler/target/universal/release"
  ]
end

# ---- Make tests depend on the app so it builds first ------------------------

unless test_target.dependencies.any? { |d| d.target == app_target }
  test_target.add_dependency(app_target)
end

# ---- Filesystem-synchronized group for SocketTests/ -------------------------
# Mirrors how the Socket app target discovers its files so dropping a new test
# file in `SocketTests/` Just Works without further pbxproj edits.

sync_group_class = Xcodeproj::Project::Object.const_get("PBXFileSystemSynchronizedRootGroup")
existing_sync = project.root_object.main_group.children.find do |c|
  c.is_a?(sync_group_class) && c.path == TESTS_DIR_NAME
end

if existing_sync
  sync_group = existing_sync
else
  sync_group = project.new(sync_group_class)
  sync_group.path = TESTS_DIR_NAME
  sync_group.source_tree = "<group>"
  project.root_object.main_group.children << sync_group
end

# Attach sync group to the test target if not already linked.
# `file_system_synchronized_groups` is a read-only list accessor; mutate via <<.
synced = Array(test_target.file_system_synchronized_groups)
unless synced.include?(sync_group)
  test_target.file_system_synchronized_groups << sync_group
end

# ---- Persist ---------------------------------------------------------------

# =============================================================================
# UI test target (XCUITest) — separate from SocketTests so unit tests stay fast
# =============================================================================

UI_TARGET_NAME = "SocketUITests"
UI_BUNDLE_ID   = "io.socketbrowser.socket.uitests"
UI_TESTS_DIR   = "SocketUITests"

ui_target = project.native_targets.find { |t| t.name == UI_TARGET_NAME }
if ui_target
  puts "SocketUITests target already present — refreshing settings."
else
  puts "Creating SocketUITests native target."
  ui_target = project.new(Xcodeproj::Project::Object::PBXNativeTarget)
  ui_target.name = UI_TARGET_NAME
  ui_target.product_name = UI_TARGET_NAME
  ui_target.product_type = "com.apple.product-type.bundle.ui-testing"
  ui_target.build_configuration_list =
    Xcodeproj::Project::ProjectHelper.configuration_list(
      project, :osx, DEPLOYMENT_TGT, ui_target, :swift
    )
  project.targets << ui_target

  ui_product = project.new(Xcodeproj::Project::Object::PBXFileReference)
  ui_product.path = "#{UI_TARGET_NAME}.xctest"
  ui_product.source_tree = "BUILT_PRODUCTS_DIR"
  ui_product.include_in_index = "0"
  ui_product.explicit_file_type = "wrapper.cfbundle"
  project.products_group.children << ui_product
  ui_target.product_reference = ui_product

  ui_target.build_phases << project.new(Xcodeproj::Project::Object::PBXSourcesBuildPhase)
  ui_target.build_phases << project.new(Xcodeproj::Project::Object::PBXFrameworksBuildPhase)
  ui_target.build_phases << project.new(Xcodeproj::Project::Object::PBXResourcesBuildPhase)
end

ui_target.build_configurations.each do |cfg|
  s = cfg.build_settings
  s["PRODUCT_NAME"] = "$(TARGET_NAME)"
  s["PRODUCT_BUNDLE_IDENTIFIER"] = UI_BUNDLE_ID
  s["MACOSX_DEPLOYMENT_TARGET"] = DEPLOYMENT_TGT
  s["SWIFT_VERSION"] = "5.0"
  s["CODE_SIGN_STYLE"] = "Automatic"
  s["CODE_SIGN_IDENTITY"] = "-"
  s["CODE_SIGN_IDENTITY[sdk=macosx*]"] = "-"
  s["GENERATE_INFOPLIST_FILE"] = "YES"
  s["SUPPORTED_PLATFORMS"] = "macosx"
  # XCUITest targets the host app via TEST_TARGET_NAME (no BUNDLE_LOADER —
  # UI tests run out-of-process against a launched app, not in-process).
  s["TEST_TARGET_NAME"] = "Socket"
  s["LD_RUNPATH_SEARCH_PATHS"] = [
    "$(inherited)",
    "@executable_path/../Frameworks",
    "@loader_path/../Frameworks"
  ]
end

unless ui_target.dependencies.any? { |d| d.target == app_target }
  ui_target.add_dependency(app_target)
end

ui_sync_group = project.root_object.main_group.children.find do |c|
  c.is_a?(sync_group_class) && c.path == UI_TESTS_DIR
end
unless ui_sync_group
  ui_sync_group = project.new(sync_group_class)
  ui_sync_group.path = UI_TESTS_DIR
  ui_sync_group.source_tree = "<group>"
  project.root_object.main_group.children << ui_sync_group
end
unless Array(ui_target.file_system_synchronized_groups).include?(ui_sync_group)
  ui_target.file_system_synchronized_groups << ui_sync_group
end

# ---- Persist ---------------------------------------------------------------

project.save
puts "Saved #{PROJECT_PATH}"
puts "Next: add .swift files to SocketTests/ + SocketUITests/ — Xcode autodiscovers them via the sync groups."
