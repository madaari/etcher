# ---------------------------------------------------------------------
# Build configuration
# ---------------------------------------------------------------------

# This directory will be completely deleted by the `clean` rule
BUILD_DIRECTORY ?= release

# See http://stackoverflow.com/a/20763842/1641422
BUILD_DIRECTORY_PARENT = $(dir $(BUILD_DIRECTORY))
ifeq ($(wildcard $(BUILD_DIRECTORY_PARENT).),)
$(error $(BUILD_DIRECTORY_PARENT) does not exist)
endif

BUILD_TEMPORARY_DIRECTORY = $(BUILD_DIRECTORY)/.tmp
BUILD_OUTPUT_DIRECTORY = $(BUILD_DIRECTORY)/out

# ---------------------------------------------------------------------
# Application configuration
# ---------------------------------------------------------------------

ELECTRON_VERSION = $(shell jq -r '.devDependencies["electron-prebuilt"]' package.json)
COMPANY_NAME = $(shell jq -r '.companyName' package.json)
APPLICATION_NAME = $(shell jq -r '.displayName' package.json)
APPLICATION_DESCRIPTION = $(shell jq -r '.description' package.json)
APPLICATION_COPYRIGHT = $(shell jq -r '.copyright' package.json)
APPLICATION_CATEGORY = public.app-category.developer-tools
APPLICATION_BUNDLE_ID = io.resin.etcher
APPLICATION_FILES = lib,assets
S3_BUCKET = resin-production-downloads

# Add the current commit to the version if release type is "snapshot"
RELEASE_TYPE ?= snapshot
PACKAGE_JSON_VERSION = $(shell jq -r '.version' package.json)
ifeq ($(RELEASE_TYPE),production)
APPLICATION_VERSION = $(PACKAGE_JSON_VERSION)
endif
ifeq ($(RELEASE_TYPE),snapshot)
CURRENT_COMMIT_HASH = $(shell git log -1 --format="%h")
APPLICATION_VERSION = $(PACKAGE_JSON_VERSION)+$(CURRENT_COMMIT_HASH)
endif
ifndef APPLICATION_VERSION
$(error Invalid release type: $(RELEASE_TYPE))
endif

# ---------------------------------------------------------------------
# Operating system and architecture detection
# ---------------------------------------------------------------------

# http://stackoverflow.com/a/12099167
ifeq ($(OS),Windows_NT)
	HOST_PLATFORM = win32

	ifeq ($(PROCESSOR_ARCHITEW6432),AMD64)
		HOST_ARCH = x64
	else
		ifeq ($(PROCESSOR_ARCHITECTURE),AMD64)
			HOST_ARCH = x64
		endif
		ifeq ($(PROCESSOR_ARCHITECTURE),x86)
			HOST_ARCH = x86
		endif
	endif
else
	ifeq ($(shell uname -s),Linux)
		HOST_PLATFORM = linux

		ifeq ($(shell uname -p),x86_64)
			HOST_ARCH = x64
		endif
		ifneq ($(filter %86,$(shell uname -p)),)
			HOST_ARCH = x86
		endif
		ifeq ($(shell uname -m),armv7l)
			HOST_ARCH = armv7l
		endif
	endif
	ifeq ($(shell uname -s),Darwin)
		HOST_PLATFORM = darwin

		ifeq ($(shell uname -m),x86_64)
			HOST_ARCH = x64
		endif
	endif
endif

ifndef HOST_PLATFORM
$(error We couldn't detect your host platform)
endif
ifndef HOST_ARCH
$(error We couldn't detect your host architecture)
endif

TARGET_PLATFORM = $(HOST_PLATFORM)

ifneq ($(TARGET_PLATFORM),$(HOST_PLATFORM))
$(error We don't support cross-platform builds yet)
endif

# Default to host architecture. You can override by doing:
#
#   make <target> TARGET_ARCH=<arch>
#
TARGET_ARCH ?= $(HOST_ARCH)

# Support x86 builds from x64 in GNU/Linux
# See https://github.com/addaleax/lzma-native/issues/27
ifeq ($(TARGET_PLATFORM),linux)
	ifneq ($(HOST_ARCH),$(TARGET_ARCH))
		ifeq ($(TARGET_ARCH),x86)
			export CFLAGS += -m32
		else
$(error Can't build $(TARGET_ARCH) binaries on a $(HOST_ARCH) host)
		endif
	endif
endif

# ---------------------------------------------------------------------
# Code signing
# ---------------------------------------------------------------------

ifeq ($(TARGET_PLATFORM),darwin)
ifndef CODE_SIGN_IDENTITY
$(warning No code-sign identity found (CODE_SIGN_IDENTITY is not set))
endif
endif

ifeq ($(TARGET_PLATFORM),win32)
ifndef CODE_SIGN_CERTIFICATE
$(warning No code-sign certificate found (CODE_SIGN_CERTIFICATE is not set))
ifndef CODE_SIGN_CERTIFICATE_PASSWORD
$(warning No code-sign certificate password found (CODE_SIGN_CERTIFICATE_PASSWORD is not set))
endif
endif
endif

# ---------------------------------------------------------------------
# Extra variables
# ---------------------------------------------------------------------

TARGET_ARCH_DEBIAN = $(shell ./scripts/build/architecture-convert.sh -r $(TARGET_ARCH) -t debian)

ifeq ($(RELEASE_TYPE),production)
	PRODUCT_NAME = etcher
endif
ifeq ($(RELEASE_TYPE),snapshot)
	PRODUCT_NAME = etcher-snapshots
endif

APPLICATION_NAME_LOWERCASE = $(shell echo $(APPLICATION_NAME) | tr A-Z a-z)
APPLICATION_VERSION_DEBIAN = $(shell echo $(APPLICATION_VERSION) | tr "-" "~")

# ---------------------------------------------------------------------
# Rules
# ---------------------------------------------------------------------

# See http://stackoverflow.com/a/12528721
# Note that the blank line before 'endef' is actually important - don't delete it
define execute-command
	$(1)

endef

$(BUILD_DIRECTORY):
	mkdir $@

$(BUILD_TEMPORARY_DIRECTORY): | $(BUILD_DIRECTORY)
	mkdir $@

$(BUILD_DIRECTORY)/electron-$(TARGET_PLATFORM)-$(TARGET_ARCH)-dependencies: | $(BUILD_DIRECTORY)
	mkdir $@

$(BUILD_OUTPUT_DIRECTORY): | $(BUILD_DIRECTORY)
	mkdir $@

$(BUILD_DIRECTORY)/electron-$(TARGET_PLATFORM)-$(TARGET_ARCH)-dependencies/node_modules: package.json npm-shrinkwrap.json \
	| $(BUILD_DIRECTORY)/electron-$(TARGET_PLATFORM)-$(TARGET_ARCH)-dependencies
	./scripts/build/dependencies-npm.sh -p \
		-r "$(TARGET_ARCH)" \
		-v "$(ELECTRON_VERSION)" \
		-x $| \
		-t electron \
		-s "$(TARGET_PLATFORM)"

$(BUILD_DIRECTORY)/electron-$(TARGET_PLATFORM)-$(TARGET_ARCH)-dependencies/bower_components: bower.json \
	| $(BUILD_DIRECTORY)/electron-$(TARGET_PLATFORM)-$(TARGET_ARCH)-dependencies
	./scripts/build/dependencies-bower.sh -p -x $|

$(BUILD_DIRECTORY)/electron-$(TARGET_PLATFORM)-$(APPLICATION_VERSION)-$(TARGET_ARCH)-app: \
	$(BUILD_DIRECTORY)/electron-$(TARGET_PLATFORM)-$(TARGET_ARCH)-dependencies/node_modules \
	$(BUILD_DIRECTORY)/electron-$(TARGET_PLATFORM)-$(TARGET_ARCH)-dependencies/bower_components \
	| $(BUILD_DIRECTORY)
	./scripts/build/electron-create-resources-app.sh -s . -o $@ \
		-v $(APPLICATION_VERSION) \
		-f "$(APPLICATION_FILES)"
	$(foreach prerequisite,$^,$(call execute-command,cp -rf $(prerequisite) $@))

$(BUILD_DIRECTORY)/electron-$(TARGET_PLATFORM)-$(APPLICATION_VERSION)-$(TARGET_ARCH)-app.asar: \
	$(BUILD_DIRECTORY)/electron-$(TARGET_PLATFORM)-$(APPLICATION_VERSION)-$(TARGET_ARCH)-app \
	| $(BUILD_DIRECTORY)
	./scripts/build/electron-create-asar.sh -d $< -o $@

$(BUILD_DIRECTORY)/electron-$(ELECTRON_VERSION)-$(TARGET_PLATFORM)-$(TARGET_ARCH).zip: \
	| $(BUILD_DIRECTORY)
	./scripts/build/electron-download-package.sh \
		-r "$(TARGET_ARCH)" \
		-v "$(ELECTRON_VERSION)" \
		-s "$(TARGET_PLATFORM)" \
		-o $@

$(BUILD_DIRECTORY)/$(APPLICATION_NAME)-$(APPLICATION_VERSION)-$(TARGET_PLATFORM)-$(TARGET_ARCH): \
	$(BUILD_DIRECTORY)/electron-$(TARGET_PLATFORM)-$(APPLICATION_VERSION)-$(TARGET_ARCH)-app.asar \
	$(BUILD_DIRECTORY)/electron-$(ELECTRON_VERSION)-$(TARGET_PLATFORM)-$(TARGET_ARCH).zip \
	| $(BUILD_DIRECTORY) $(BUILD_TEMPORARY_DIRECTORY)
ifeq ($(TARGET_PLATFORM),darwin)
	./scripts/build/electron-configure-package-darwin.sh -p $(word 2,$^) -a $< \
		-n "$(APPLICATION_NAME)" \
		-v "$(APPLICATION_VERSION)" \
		-b "$(APPLICATION_BUNDLE_ID)" \
		-c "$(APPLICATION_COPYRIGHT)" \
		-t "$(APPLICATION_CATEGORY)" \
		-i assets/icon.icns \
		-o $@
endif
ifeq ($(TARGET_PLATFORM),linux)
	./scripts/build/electron-configure-package-linux.sh -p $(word 2,$^) -a $< \
		-n "$(APPLICATION_NAME)" \
		-v "$(APPLICATION_VERSION)" \
		-l LICENSE \
		-o $@
endif
ifeq ($(TARGET_PLATFORM),win32)
	./scripts/build/electron-configure-package-win32.sh -p $(word 2,$^) -a $< \
		-n "$(APPLICATION_NAME)" \
		-d "$(APPLICATION_DESCRIPTION)" \
		-v "$(APPLICATION_VERSION)" \
		-l LICENSE \
		-c "$(APPLICATION_COPYRIGHT)" \
		-m "$(COMPANY_NAME)" \
		-i assets/icon.ico \
		-w $(BUILD_TEMPORARY_DIRECTORY) \
		-o $@
ifdef CODE_SIGN_CERTIFICATE
ifdef CODE_SIGN_CERTIFICATE_PASSWORD
	./scripts/build/electron-sign-exe-win32.sh -f $@/$(APPLICATION_NAME).exe \
		-d "$(APPLICATION_NAME) - $(APPLICATION_VERSION)" \
		-c $(CODE_SIGN_CERTIFICATE) \
		-p $(CODE_SIGN_CERTIFICATE_PASSWORD)
endif
endif
endif

$(BUILD_DIRECTORY)/$(APPLICATION_NAME)-$(APPLICATION_VERSION)-$(TARGET_PLATFORM)-$(TARGET_ARCH)-rw.dmg: \
	$(BUILD_DIRECTORY)/$(APPLICATION_NAME)-$(APPLICATION_VERSION)-darwin-$(TARGET_ARCH) \
	| $(BUILD_DIRECTORY)
	./scripts/build/electron-create-readwrite-dmg-darwin.sh -p $< -o $@ \
		-n "$(APPLICATION_NAME)" \
		-i assets/icon.icns \
		-b assets/osx/installer.png

$(BUILD_OUTPUT_DIRECTORY)/$(APPLICATION_NAME)-$(APPLICATION_VERSION)-darwin-$(TARGET_ARCH).zip: \
	$(BUILD_DIRECTORY)/$(APPLICATION_NAME)-$(APPLICATION_VERSION)-darwin-$(TARGET_ARCH) \
	| $(BUILD_OUTPUT_DIRECTORY)
ifdef CODE_SIGN_IDENTITY
	./scripts/build/electron-sign-app-darwin.sh -a $</$(APPLICATION_NAME).app -i "$(CODE_SIGN_IDENTITY)"
endif
	./scripts/build/electron-installer-app-zip-darwin.sh -a $</$(APPLICATION_NAME).app -o $@

$(BUILD_OUTPUT_DIRECTORY)/$(APPLICATION_NAME)-$(APPLICATION_VERSION)-darwin-$(TARGET_ARCH).dmg: \
	$(BUILD_DIRECTORY)/$(APPLICATION_NAME)-$(APPLICATION_VERSION)-$(TARGET_PLATFORM)-$(TARGET_ARCH)-rw.dmg \
	| $(BUILD_OUTPUT_DIRECTORY)
ifdef CODE_SIGN_IDENTITY
	./scripts/build/electron-sign-dmg-darwin.sh \
		-n "$(APPLICATION_NAME)" \
		-d $< \
		-i "$(CODE_SIGN_IDENTITY)"
endif
	./scripts/build/electron-create-readonly-dmg-darwin.sh -d $< -o $@

$(BUILD_DIRECTORY)/$(APPLICATION_NAME)-$(APPLICATION_VERSION)-linux-$(TARGET_ARCH).AppDir: \
	$(BUILD_DIRECTORY)/$(APPLICATION_NAME)-$(APPLICATION_VERSION)-linux-$(TARGET_ARCH) \
	| $(BUILD_DIRECTORY)
	./scripts/build/electron-create-appdir.sh -p $< -o $@ \
		-n "$(APPLICATION_NAME)" \
		-d "$(APPLICATION_DESCRIPTION)" \
		-r "$(TARGET_ARCH)" \
		-b "$(APPLICATION_NAME_LOWERCASE)" \
		-i assets/icon.png

$(BUILD_DIRECTORY)/$(APPLICATION_NAME)-$(APPLICATION_VERSION)-linux-$(TARGET_ARCH).AppImage: \
	$(BUILD_DIRECTORY)/$(APPLICATION_NAME)-$(APPLICATION_VERSION)-linux-$(TARGET_ARCH).AppDir \
	| $(BUILD_DIRECTORY) $(BUILD_TEMPORARY_DIRECTORY)
	./scripts/build/electron-create-appimage-linux.sh -d $< -o $@ \
		-r "$(TARGET_ARCH)" \
		-w "$(BUILD_TEMPORARY_DIRECTORY)"

$(BUILD_OUTPUT_DIRECTORY)/$(APPLICATION_NAME)-$(APPLICATION_VERSION)-linux-$(TARGET_ARCH).zip: \
	$(BUILD_DIRECTORY)/$(APPLICATION_NAME)-$(APPLICATION_VERSION)-linux-$(TARGET_ARCH).AppImage \
	| $(BUILD_OUTPUT_DIRECTORY)
	./scripts/build/electron-installer-appimage-zip.sh -i $< -o $@

$(BUILD_OUTPUT_DIRECTORY)/$(APPLICATION_NAME_LOWERCASE)-electron_$(APPLICATION_VERSION_DEBIAN)_$(TARGET_ARCH_DEBIAN).deb: \
	$(BUILD_DIRECTORY)/$(APPLICATION_NAME)-$(APPLICATION_VERSION)-linux-$(TARGET_ARCH) \
	| $(BUILD_OUTPUT_DIRECTORY)
	./scripts/build/electron-installer-debian-linux.sh -p $< -r "$(TARGET_ARCH)" -o $| \
		-c scripts/build/debian/config.json

$(BUILD_OUTPUT_DIRECTORY)/$(APPLICATION_NAME)-$(APPLICATION_VERSION)-win32-$(TARGET_ARCH).zip: \
	$(BUILD_DIRECTORY)/$(APPLICATION_NAME)-$(APPLICATION_VERSION)-win32-$(TARGET_ARCH) \
	| $(BUILD_OUTPUT_DIRECTORY)
	./scripts/build/electron-installer-zip-win32.sh -a $< -o $@

$(BUILD_OUTPUT_DIRECTORY)/$(APPLICATION_NAME)-$(APPLICATION_VERSION)-win32-$(TARGET_ARCH).exe: \
	$(BUILD_DIRECTORY)/$(APPLICATION_NAME)-$(APPLICATION_VERSION)-win32-$(TARGET_ARCH) \
	| $(BUILD_OUTPUT_DIRECTORY) $(BUILD_TEMPORARY_DIRECTORY)
	./scripts/build/electron-installer-nsis-win32.sh -n $(APPLICATION_NAME) -a $< -t $(BUILD_TEMPORARY_DIRECTORY) -o $@
ifdef CODE_SIGN_CERTIFICATE
ifdef CODE_SIGN_CERTIFICATE_PASSWORD
	./scripts/build/electron-sign-exe-win32.sh -f $@ \
		-d "$(APPLICATION_NAME) - $(APPLICATION_VERSION)" \
		-c $(CODE_SIGN_CERTIFICATE) \
		-p $(CODE_SIGN_CERTIFICATE_PASSWORD)
endif
endif

# ---------------------------------------------------------------------
# Phony targets
# ---------------------------------------------------------------------

TARGETS = \
	help \
	info \
	clean \
	distclean \
	package \
	electron-develop

package: $(BUILD_DIRECTORY)/$(APPLICATION_NAME)-$(APPLICATION_VERSION)-$(TARGET_PLATFORM)-$(TARGET_ARCH)

ifeq ($(TARGET_PLATFORM),darwin)
electron-installer-app-zip: $(BUILD_OUTPUT_DIRECTORY)/$(APPLICATION_NAME)-$(APPLICATION_VERSION)-$(TARGET_PLATFORM)-$(TARGET_ARCH).zip
electron-installer-dmg: $(BUILD_OUTPUT_DIRECTORY)/$(APPLICATION_NAME)-$(APPLICATION_VERSION)-$(TARGET_PLATFORM)-$(TARGET_ARCH).dmg
TARGETS += \
	electron-installer-dmg \
	electron-installer-app-zip
PUBLISH_AWS_S3 += \
	$(BUILD_OUTPUT_DIRECTORY)/$(APPLICATION_NAME)-$(APPLICATION_VERSION)-$(TARGET_PLATFORM)-$(TARGET_ARCH).zip \
	$(BUILD_OUTPUT_DIRECTORY)/$(APPLICATION_NAME)-$(APPLICATION_VERSION)-$(TARGET_PLATFORM)-$(TARGET_ARCH).dmg
endif

ifeq ($(TARGET_PLATFORM),linux)
electron-installer-appimage: $(BUILD_OUTPUT_DIRECTORY)/$(APPLICATION_NAME)-$(APPLICATION_VERSION)-$(TARGET_PLATFORM)-$(TARGET_ARCH).zip
electron-installer-debian: $(BUILD_OUTPUT_DIRECTORY)/$(APPLICATION_NAME_LOWERCASE)-electron_$(APPLICATION_VERSION_DEBIAN)_$(TARGET_ARCH_DEBIAN).deb
TARGETS +=  \
	electron-installer-appimage \
	electron-installer-debian
PUBLISH_AWS_S3 += \
	$(BUILD_OUTPUT_DIRECTORY)/$(APPLICATION_NAME)-$(APPLICATION_VERSION)-$(TARGET_PLATFORM)-$(TARGET_ARCH).zip
PUBLISH_BINTRAY_DEBIAN += \
	$(BUILD_OUTPUT_DIRECTORY)/$(APPLICATION_NAME_LOWERCASE)-electron_$(APPLICATION_VERSION_DEBIAN)_$(TARGET_ARCH_DEBIAN).deb
endif

ifeq ($(TARGET_PLATFORM),win32)
electron-installer-zip: $(BUILD_OUTPUT_DIRECTORY)/$(APPLICATION_NAME)-$(APPLICATION_VERSION)-$(TARGET_PLATFORM)-$(TARGET_ARCH).zip
electron-installer-nsis: $(BUILD_OUTPUT_DIRECTORY)/$(APPLICATION_NAME)-$(APPLICATION_VERSION)-win32-$(TARGET_ARCH).exe
TARGETS += \
	electron-installer-zip \
	electron-installer-nsis
PUBLISH_AWS_S3 += \
	$(BUILD_OUTPUT_DIRECTORY)/$(APPLICATION_NAME)-$(APPLICATION_VERSION)-$(TARGET_PLATFORM)-$(TARGET_ARCH).zip \
	$(BUILD_OUTPUT_DIRECTORY)/$(APPLICATION_NAME)-$(APPLICATION_VERSION)-win32-$(TARGET_ARCH).exe
endif

ifdef PUBLISH_AWS_S3
publish-aws-s3: $(PUBLISH_AWS_S3)
	$(foreach publishable,$^,$(call execute-command,./scripts/publish/aws-s3.sh \
		-f $(publishable) \
		-b $(S3_BUCKET) \
		-v $(APPLICATION_VERSION) \
		-p $(PRODUCT_NAME)))

TARGETS += publish-aws-s3
endif

ifdef PUBLISH_BINTRAY_DEBIAN
publish-bintray-debian: $(PUBLISH_BINTRAY_DEBIAN)
	$(foreach publishable,$^,$(call execute-command,./scripts/publish/bintray-debian.sh \
		-f $(publishable) \
		-v $(APPLICATION_VERSION_DEBIAN) \
		-r $(TARGET_ARCH) \
		-c $(APPLICATION_NAME_LOWERCASE) \
		-t $(RELEASE_TYPE)))

TARGETS += publish-bintray-debian
endif

.PHONY: $(TARGETS)

electron-develop:
# Since we use an `npm-shrinkwrap.json` file, if you pull changes
# that update a dependency and try to `npm install` directly, npm
# will complain that your `node_modules` tree is not equal to what
# is defined by the `npm-shrinkwrap.json` file, and will thus
# refuse to do anything but install from scratch.
# The `node_modules` directory also needs to be wiped out if you're
# changing between target architectures, since compiled add-ons
# will not work otherwise.
	rm -rf node_modules
	./scripts/build/dependencies-npm.sh \
		-r "$(TARGET_ARCH)" \
		-v "$(ELECTRON_VERSION)" \
		-t electron \
		-s "$(TARGET_PLATFORM)"
	./scripts/build/dependencies-bower.sh

help:
	@echo "Available targets: $(TARGETS)"

info:
	@echo "Application version : $(APPLICATION_VERSION)"
	@echo "Release type        : $(RELEASE_TYPE)"
	@echo "Host platform       : $(HOST_PLATFORM)"
	@echo "Host arch           : $(HOST_ARCH)"
	@echo "Target platform     : $(TARGET_PLATFORM)"
	@echo "Target arch         : $(TARGET_ARCH)"

clean:
	rm -rf $(BUILD_DIRECTORY)

distclean: clean
	rm -rf node_modules
	rm -rf bower_components

.DEFAULT_GOAL = help
