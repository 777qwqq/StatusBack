DEBUG = 0
FINALPACKAGE = 1

ARCHS = arm64 arm64e

# Share the SDK and deployment targets with the PreferenceBundle.
include SBKStatusbackBuild.mk
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SBKStatusback
SBKStatusback_FILES = $(wildcard Hooks/*.xm Sources/*.m)
SBKStatusback_CFLAGS = -fobjc-arc -I./Headers -I./Sources
SBKStatusback_FRAMEWORKS = UIKit Foundation CoreFoundation
SBKStatusback_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += SBKStatusbackPrefs
include $(THEOS_MAKE_PATH)/aggregate.mk
