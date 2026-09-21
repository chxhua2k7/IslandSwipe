# 版本號只寫在這裡:也是 tweak 的 IS_VERSION。control 的 Version 由 Theos 用這個值覆蓋。
export PACKAGE_VERSION := 1.0.0

# 動態島從 iOS 16.1 開始;selector 來自 16.5.1 的 shared cache。
TARGET := iphone:clang:16.5:16.1

THEOS_PACKAGE_SCHEME = rootless

# arm64e slice 由 Xcode toolchain 產生(同 NowLyrics 的說明),SpringBoard 是 arm64e 程序。
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME += IslandSwipe

IslandSwipe_FILES += Tweak.x
IslandSwipe_CFLAGS += -fobjc-arc -Wall -DIS_VERSION=\"$(PACKAGE_VERSION)\"

include $(THEOS_MAKE_PATH)/tweak.mk

# 設定頁是純 plist 的 PreferenceLoader 頁(PSListController + 一個開關),不需要 preference bundle。
# PreferenceLoader 會遞迴掃描 Preferences/ 底下所有 .plist,plist 所在的資料夾就是它的
# 來源 bundle,PLLocalizedListController 從那裡讀各語言的 Localizable.strings。
internal-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/IslandSwipe"$(ECHO_END)
	$(ECHO_NOTHING)cp -R prefs/ "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/IslandSwipe/"$(ECHO_END)
	$(ECHO_NOTHING)sed -i '' "s/__VERSION__/$(PACKAGE_VERSION)/g" "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/IslandSwipe/IslandSwipe.plist"$(ECHO_END)
