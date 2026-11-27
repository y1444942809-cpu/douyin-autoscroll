# DouyinAutoScroll —— 抖音播放完毕自动上滑插件

面向 **iOS 15.4.1 + 抖音 37.9.0**，通过巨魔（TrollStore）里的 **TrollFools** 直接注入抖音，产物是单个 `DouyinAutoScroll.dylib`。

功能：检测到当前视频播放完毕后，自动上滑到下一个视频并继续播放；屏幕左上角有**悬浮总开关**，随时开/关，状态自动保存。

---

## 一、拿到 dylib（二选一）

### 方式 A：云端自动编译（推荐，不需要 Mac）

当前电脑是 Windows，没有 iOS 编译环境，所以走 GitHub 的免费 macOS 机器：

1. 注册/登录 GitHub，新建一个空仓库（例如 `douyin-autoscroll`）。
2. 把本文件夹里的**全部文件**（包括隐藏的 `.github` 文件夹）上传到该仓库。
   - 网页上传不会带隐藏文件夹，建议用 Git：
     ```bash
     git init
     git add .
     git commit -m "init"
     git branch -M main
     git remote add origin https://github.com/你的用户名/douyin-autoscroll.git
     git push -u origin main
     ```
3. 打开仓库 → **Actions** 标签 → 左侧选 **Build DouyinAutoScroll dylib** → 点 **Run workflow** → 再点绿色 **Run workflow**。
4. 跑完后在本次运行页面底部 **Artifacts** 下载 `DouyinAutoScroll-dylib`，解压得到 `DouyinAutoScroll.dylib`。

> 首次推送到 `main` 也会自动触发一次构建。

### 方式 B：自己有 Mac

在 Mac 上安装 Xcode Command Line Tools 后，在此目录执行：

```bash
bash build.sh
```

即可在本目录生成 `DouyinAutoScroll.dylib`。

（可选）如果装了 Theos，也可以 `make` 打包成 deb。

---

## 二、注入抖音

1. 用隔空投送 / 文件 App / 邮件把 `DouyinAutoScroll.dylib` 传到 iPhone。
2. 打开 **TrollFools** → 在应用列表里点 **抖音** → **注入** → 从文件里选 `DouyinAutoScroll.dylib` → 确认。
3. 等待提示注入完成，然后**彻底退出抖音后台并重新打开**。

TrollFools 会自动处理签名和 CydiaSubstrate，本插件本身不依赖任何额外库，正常注入即可。

---

## 三、开关怎么用

- 抖音界面左上角有一个小胶囊按钮：
  - 绿色 `自动滑 ▮` = 已开启
  - 灰色 `自动滑 ○` = 已关闭
- 点一下即可切换，状态写入 `NSUserDefaults`，下次打开抖音保持上次设置。
- 高级用法：把 `DouyinAutoScroll.plist.example` 改名为 `DouyinAutoScroll.plist`，把 `Enabled` 改成 `false`，放到抖音 App 的 `Documents` 目录（可用 Filza），plist 里的值会覆盖开关状态。

---

## 四、实现原理（简要）

| 模块 | 做法 |
|---|---|
| 播放结束检测 | ① `AVPlayerItemDidPlayToEndTimeNotification`；② 每 0.25 秒轮询视图树里的 `AVPlayerLayer`，`currentTime ≥ duration - 0.3s` 判定结束；③ Hook `AWEPlayInteractionProgressController` 的 `-updateProgressSliderWithTime:totalDuration:`，到结尾时触发 |
| 防重复 | 1.2 秒冷却 + 每次播放需先“复位”（时间回到 <1 秒）才能再次触发 |
| 上滑 | 在 `AWEFeedTableViewController` 等 Feed 页面里找到全屏 `UICollectionView`/`UIScrollView`，按一屏高度设置 `contentOffset`；非分页模式改用 `scrollToItemAtIndexPath:` |
| 适用范围 | 只在 Bundle ID 含 `Aweme` 的 App 里生效，且只在推荐流/视频详情页触发，避开直播间 |

源码顶部有一批可调常量（`kEndTolerance`、`kScrollCooldown`、`kPollInterval` 等），改完重新编译即可。

---

## 五、注意事项

- 抖音升级版本后，TrollFools 注入会失效，需要重新注入；类结构变化也可能导致 Hook 失效（通知和轮询两路通常仍可用）。
- 建议在 App Store 里关闭抖音自动更新，避免刚注入就被更新覆盖。
- 任何插件注入都存在账号风控/闪退的可能，建议自用、小号先测试，别用于批量刷量。
- 仅供学习交流，请勿商用或二次分发。
