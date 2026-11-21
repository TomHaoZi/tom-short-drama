# 片库扩容交付记录

- 基线：`Native/catalog.json` 含 23 部作品。`CatalogSync` 仅同步手动接入的目录。当前主要交付为 SwiftUI 原生应用，根目录 Web 是旧原型。
- 已确认可访问：广州官方微短剧专题（当前两页）、Blender 官方 Open Movies 频道 API（当前 23 条，混含幕后、重复版本及预告）。只接正式作品和来源实际提供的媒体，不以展示占位或预告充数。
- 已交付：`Native/ProductionCatalog.swift` 默认同步广州、Blender PeerTube、国会图书馆；`Native/online-starter.json` 内置 178 部由发行站抓取所得的正片条目。和原来的 23 部合计 201 个不同 ID、254 集/个视频，含 20 部国产短剧。馆藏 162 部并非新番或商业短剧。Wikimedia Commons 实测《胡同猫》只提供 VP9/Opus WebM 派生，不作为 AVPlayer 批量源；原有随包 MP4 不变。
- macOS 15.1 构建：`TOM_SWIFTC=/path/to/swiftc bash Native/build-mac-preview.sh`。产物 `DerivedData/MacPreview/Tom短剧.app`，`codesign --verify --strict` 通过。最终可执行文件 SHA-256 `22aafbf8def0b03ab818efa1dcd3feca14dc3efedcae415abbfb743f3bdf8e3e`；快照 SHA-256 `a8a453bb193cf873fd497d6371975e7e5ed8165af064a92c178ea1e37421f3aa`。
- 真实网络验证：运行 `Tests/LiveSources.swift` 的 `--probe --only=<source>`，6 部广州、10 部 Blender 都有实际推进的 AVPlayer 播放，馆藏抽测首末四部通过，详见 `Verification/*-playback.txt`。个别上游起播超过 11 秒，按播放器正常等待窗口重测通过；不能保证每部或每条备线一直可播。`Tests/CatalogFallback.swift` 验证独立缓存、单源故障保留目录、首次离线浏览；这是注入式故障测试，不是假片源播放证明。
- GUI：签名包独立复制至 `Tom短剧.app`，以隔离 profile 启动。确认三个实际目录均显示「已同步」、来源筛选、搜索、详情、选集播放及关闭后回片库。实际搜索《临场发挥！》并播放；收藏馆藏片 `Dud leaves home`，重启显示 0:19，继续观看后保存到 0:46。最终包重新验证打开《账单》并实际播放，修复从播放返回详情后旧工具栏的关闭按钮消失的问题。界面及记录见 `Verification/`。
- 尚未实测：iPhone/iPad，当前 `xcodebuild` 无完整 Xcode；162 部馆藏不逐部播放，仅取样，所有库的最高画质无逐档校验。旧 Web 原型没有接入本次默认片源。

## 1.3：不预先收录也能找与播放

- 新增 `Native/OnlineSearch.swift`：并行搜索美国国会图书馆与 Blender Open Movies 公开接口，有分页、独立失败提示、去重。只保存已打开作品的目录信息供收藏和续播，不保存影片。未加入破解、盗链、DRM 绕过、任意远程脚本及商业平台私有线路。
- `Tests/OnlineSearchProbe.swift` 通过：`train` 向馆方实时查询，第一批 13 条、第二批 20 条；未预收录的 `Freight train` 由 AVPlayer 实播至 1.1 秒，1440×1080；重启后仍能从已浏览目录取到；另从 Blender 官方服务实时返回《临场发挥！》。
- `DerivedData/MacPreview/Tom短剧.app` 已重新构建并签名核验，1.3 原生包的可执行文件 SHA-256 为 `ba1f62d52da5cb03dd0cef03615fcbc62057a8e872986894397ff5a1b3aa3a4a`。复制至 `Tom短剧.app` 独立运行，在真实搜索页输入 `train` 后能看到 13 个在线结果；点击未收录 `Freight train`、收藏、播放，实际进度写到 9 秒。截图 `Verification/online-search.jpg`。

## 1.4 与红果原生全集验证

- 1.4 支持 GitHub JSON 目录链接转换与导入，`Tests/GitHubPublisher.swift` 测试注入目录、URL 校验与去重；未接入影视仓源包，也未验证外部实时 GitHub 目录 JSON 导入。独立 macOS 1.4 包实播《饼干狗变英雄》，见 `Verification/github-playing.jpg`。
- 用户验收要求：在 Tom 短剧自己的播放器免费播全集，不跳浏览器，也不把红果网页嵌进去当作原生播放。官网正片 `https://hongguoduanju.com/player/7693164412823161880` 显示《荒岛上还摆高姿态》共 109 集。用浏览器关闭官网提供的登录弹窗后，第 1 集实播至 9.62 秒（1254×720）；选择第 109 集时，官网显示「短剧独家内容，前往App端观看全部内容」。网页嵌入原型实际加载了红果登录界面，不符合验收，未交付。
- 已恢复独立验证过的 1.4 包 `DerivedData/MacPreview/Tom短剧.app`，`codesign --verify --strict` 通过，可执行文件 SHA-256 `c7fd309fb0a5db0b7a075dbffa490f0298284206544ed7244c63c5135abc5c7d`。下一步：取得许可供 Tom 原生播放的全集媒体或官方接口后，再接入 AVPlayer 验证免费选集、实际起播、续播和重启；在此之前不标注该剧可播全集。

## 1.5：参考两套开源播放器的搜索设计

- 审查 `jackotom/hongguo-drama` `1a4c9f011cca68f75f77a761b3a0702c4a754802` 与 `zfdang/hongguo-open-player` `f57df9c0d980c272714d270bd7065d55fd197de1`；两者 GPLv3。Tom 用 Swift 独立实现了精确片名、部分片名、元数据三级排序和无关回退结果过滤，未复制或运行上游代码、未安装发行包、未接入它们的私有取流模块或新片源。该剧仍不能在 Tom 直接播放。
- `Tests/OnlineSearchProbe.swift` 通过：中文片名、第二季、无关推荐、全半角测试；真实 `train` 联搜筛出 12 条，未预收录的 `Freight train` 1440×1080 通过 AVPlayer 起播，目录重启保留。1.5 签名核验通过，可执行文件 SHA-256 `23081b0a0ec068bb9fe99788d19f8014e7352f6ca071bdfe2559667b7633e9e1`。独立包 `Tom短剧.app` 用 UUID 隔离 profile 实测搜索、打开结果及播放，保存到 5.00 秒。没有实测 Intel Mac 或 iOS/iPadOS。

## 1.6：红果线路核查与来源故障展示

- 对照 [jackotom/hongguo-drama](https://github.com/jackotom/hongguo-drama) `1a4c9f011cca68f75f77a761b3a0702c4a754802`（LICENSE 为 GPL-3.0）和 [zfdang/hongguo-open-player](https://github.com/zfdang/hongguo-open-player) `f57df9c0d980c272714d270bd7065d55fd197de1`（LICENSE 与 GitHub 元数据为 AGPL-3.0，README 徽标仍写 GPL-3.0）。只做 GitHub 远端 README、许可证和源码文件面核对，未克隆、未安装或运行上游发行包，未把 GPL/AGPL 代码写入本项目。
- 两份上游的红果取流都依赖匿名设备协议、请求签名/会话，以及 CENC / Spade-A 加密流解密（文件面可见 `app-source.js`、`playback-device.js`、`playback-signature.js`、`sm3.js`、`decrypt-worker.cjs`、`device-session.js`、`streamService.js` 等）。这不是可交给 AVPlayer 的公开 HTTPS 正片目录。开源仓库说明不能把平台私有接口变成官方公开 API。按约束未接入红果、西饭、河马线路，也未增加空壳来源。
- 缺的是：红果官方或经授权的公开目录，其中每集是 AVPlayer 可直接播放的 HTTPS 地址，且不需要设备伪装、应用 token/cookie、签名或解密绕过；以及全集播放许可（1.4 已核验部分分集有登录墙，部分标记需官方 App 观看）。若发行方提供与现有 `catalog.json` 相同格式的 HTTPS JSON，仍可用「片库同步」导入。
- 本轮在原有广州、Blender、国会图书馆来源上补充故障展示：同步失败会写出具体来源和原因（超时、网络不可用、服务无响应、目录无法解析），片源筛选仍显示「上次目录 · 原因」，并保留已缓存目录；在线联搜失败同样标明来源和原因，不把失败当成零结果，取消中的旧搜索不记入失败、也不与新搜索串台。未改旧 Web 原型，未删 Verification 记录，未把旧截图当作新验收图。本轮未启动 GUI。
- 测试（Asia/Shanghai，2026-11-21 20:50–21:03；`TOM_SWIFTC=/path/to/swiftc`，Swift 6.0.3，`-swift-version 5`）。mock 与真实播放分开记录：
  - `Tests/CatalogFallback.swift`：PASS，独立回退、缓存与离线随包目录保留；新增超时与目录无法解析的原因文案（178 条 starter 条目）。
  - `Tests/GitHubPublisher.swift`：PASS。
  - `Tests/SourceAvailability.swift`：PASS，失败分类、搜索排序、超时展示、取消旧搜索不串台；并确认 `ProductionSource` 仍只有广州、Blender、图书馆三个来源。
  - `Tests/OnlineSearchProbe.swift`：在项目根目录运行 PASS。`train` 联搜 12 条；分页 13+20；未预收录的 `Freight train` 由 AVPlayer 实播至 1.014065152 秒，1440×1080，主机 `tile.loc.gov`；Blender 实时返回《临场发挥！》。若当前工作目录不是项目根，相对路径 `Native/online-starter.json` 会找不到文件，这是原测试的运行方式，不是新回归。
  - `Tests/LiveSources.swift` 只拉目录：广州 6 部 / 6 集，Blender 10 部 / 10 集，国会图书馆 162 部 / 162 集。
  - 真实 AVPlayer 非 GUI 探针：`--probe --only=guangzhou` 6/6 起播，进度 0.82–1.01 秒，画面 960×544 或 1280×720，主机 `gdvideo.southcn.com`。`--probe --only=blender` 10/10 起播，进度 0.80–1.01 秒，主机 `video.blender.org`。`--probe --only=archive` 抽测 4 部：`Dud leaves home`、`AWOL, all wrong old Laddiebuck`、`Golden trails` 起播至 0.89–1.01 秒、1440×1080、`tile.loc.gov`；`Ridin' wild #1` 在约 20 秒探针窗口内未能起播，测试退出码为 1。未从目录删除该条目，也不把它记成可播。同一晚另一次抽测中失败的是 `Golden trails #1`，说明馆藏抽测会受上游瞬时状态影响，不能据此宣称全部馆藏稳定可播。
  - `bash Native/build-mac-preview.sh` 编译并 `codesign --verify --strict` 通过。预览包 `DerivedData/MacPreview/Tom短剧.app` 版本 1.6 (12)，可执行文件 SHA-256 `bbaa167c0e7819908125e27490a82086599006a42750c5e2ba44efad2f8dd82d`。构建有两处既有的 macOS 14 `onChange` 弃用警告，未作无关重构。未启动该 App，也未用 Shell/AppleScript/浏览器截 GUI 图。
- 备份目录：`本地开发备份`。改动文件见该备份与当前树：`Native/ProductionCatalog.swift`、`Native/CatalogSync.swift`、`Native/OnlineSearch.swift`、`Native/CinemaApp.swift`、`Native/build-mac-preview.sh`、`Tests/CatalogFallback.swift`、`Tests/SourceAvailability.swift`（新建）、`README.md`、`PROGRESS.md`。
- 尚未实测：iPhone/iPad、Intel Mac，以及片源筛选失败文案的 GUI 点击验收。GUI 验收入口：退出旧预览后打开 `DerivedData/MacPreview/Tom短剧.app`。请核对片源胶囊是否显示「已同步」或「上次目录 · 原因」、同步说明是否点名来源和原因、联搜失败是否写「来源（原因）」且不把失败当零结果；来源列表中不应出现红果线路。
