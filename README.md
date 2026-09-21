# IslandSwipe

讓所有動態島元件都能向左滑隱藏，包括原本滑不掉的螢幕錄影、個人熱點、通話膠囊，以及自己宣告「不可關閉」的 Live Activity。

- 需要動態島機型（iPhone 14 Pro 以上）、rootless 越獄、PreferenceLoader。
- 在 iOS 16.5.1 實測；hook 的 selector 取自 16.5.1 的 shared cache，iOS 17 以上未驗證。
- 設定 → IslandSwipe 有一個「啟用」開關，切換立即生效。

## 原理

SpringBoard 在滑動結束時（`-[SBSystemApertureViewController _handleResizeResult:withContainerView:]`）先問
`_isInteractiveHidingSupportedByElement:`，代表狀態列 style override 的元件（錄影、熱點、通話、定位）在這裡被擋；
到最小 layout mode 後再問 `SAUILayoutSpecifyingOverrider` 的 `isInteractiveDismissalEnabled`，
Live Activity 則靠 `SBUISA_preventsInteractiveDismissal` 退出。IslandSwipe 把這幾個閘門全部回 YES。

## 建置

```sh
make clean package FINALPACKAGE=1
```
