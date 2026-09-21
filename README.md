# IslandSwipe

讓所有動態島元件都能向左滑隱藏，包括原本滑不掉的螢幕錄影、個人熱點、通話膠囊，以及自己宣告「不可關閉」的 Live Activity。

- 需要動態島機型（iPhone 14 Pro 以上）、rootless 越獄、PreferenceLoader。
- 在 iOS 16.5.1 實測；hook 的 selector 取自 16.5.1 的 shared cache，iOS 17 以上未驗證。
- 設定 → IslandSwipe 有一個「啟用」開關，切換立即生效。

## 使用

- 往左滑：任何元件都會收起（原本滑不掉的會被設成隱藏，不會被移除）。
- 在**空的動態島**上往右滑：把最後一個被隱藏的元件叫回來（再滑一次叫下一個）。
- 原本就能滑掉的 Live Activity 維持系統行為。

## 原理

SpringBoard 在滑動結束時（`-[SBSystemApertureViewController _handleResizeResult:withContainerView:]`）先問
`_isInteractiveHidingSupportedByElement:`，代表狀態列 style override 的元件（錄影、熱點、通話、定位）在這裡被擋；
到最小 layout mode 後再問 `SAUILayoutSpecifyingOverrider` 的 `isInteractiveDismissalEnabled`，
Live Activity 則靠 `SBUISA_preventsInteractiveDismissal` 退出。直接放行「移除」會把 scene element 作廢、叫不回來，
所以 IslandSwipe 改走系統自己的隱藏機制：對這些元件讓 `minimumSupportedLayoutMode` 回 0，把使用者手勢的縮小
直接設成 layout mode 0（隱藏但仍註冊）；復原用系統的 `_axRevealHiddenElementIfPossible`（User Unhide）。
動態島空著時它自己的視窗收不到觸控，所以另開一個只蓋住動態島區域的高層級小視窗接往右滑。

## 建置

```sh
make clean package FINALPACKAGE=1
```

## 授權

本專案以 [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/deed.zh-Hant) 授權（全文見 [LICENSE](LICENSE)）：

- **姓名標示**：使用或修改需註明原作者 chxhua2k7 並附上原始 repo 連結。
- **非商業性**：不得販售，或用於任何商業目的（含付費 repo）。
- **相同方式分享**：fork 或修改版必須以同樣授權公開原始碼。

## License

© 2026 chxhua2k7. Licensed under the [GNU GPL v3.0](LICENSE): you may use, modify and redistribute this tweak, but any redistributed version (including modified builds) must be released under the same license with source available.
