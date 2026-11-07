include ../SBKStatusbackBuild.mk
include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = SBKStatusbackPrefs
SBKStatusbackPrefs_FILES = $(wildcard *.m)
SBKStatusbackPrefs_CFLAGS = -fobjc-arc -I../Sources
SBKStatusbackPrefs_FRAMEWORKS = UIKit Foundation CoreFoundation
SBKStatusbackPrefs_PRIVATE_FRAMEWORKS = Preferences
SBKStatusbackPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk
