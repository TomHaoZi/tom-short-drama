# 片库和播放维护

SwiftUI 和 AVKit 实现的 iPhone / iPad 原生影院。提供影片详情、题材筛选、搜索、收藏、选集、自动播下一集和续播。应用不添加广告，收藏和进度保存在设备上。

## 在 Apple 设备上运行

使用完整 Xcode 打开 `IntervalCinema.xcodeproj`，选择 `IntervalCinema` 方案和 iPhone 或 iPad 模拟器。macOS 15.1 可安装 Xcode 16.2 和 iOS 18.2 模拟器运行时。真机测试时在目标的 Signing & Capabilities 中选择开发团队。

最低系统为 iOS/iPadOS 16。应用导航和自有播放控件采用深色实色样式。Xcode 26 构建的系统控件使用系统兼容外观。

macOS 14 或更新版本可在退出旧预览后运行 `bash Native/build-mac-preview.sh`。生成的原生桌面预览位于 `DerivedData/MacPreview/Tom短剧.app`，与 iPhone 和 iPad 共用 SwiftUI 界面、片库和播放器。使用单独的 Swift 工具链时可通过 `TOM_SWIFTC` 指定 `swiftc` 的路径。

## 默认在线片源

首次打开无需填写地址，「片库」会直接展示随应用附带的发行方目录快照，并在后台向三个公开目录同步。来源筛选、题材和全文搜索都使用同一个片库。片库右上角可刷新。如果源站临时不可用，仍可浏览上次成功同步的目录；视频仍需网络，不是离线下载。

- **广州微短剧**：[广州市纪委监委专题](https://www.gzjjjc.gov.cn/ljgzw/ztzl/ljwhwdj/)，同步分页和官网播放器公开使用的正片地址，排除已内置的同一作品。
- **Blender 动画**：[Blender Open Movies 官方频道](https://video.blender.org/video-channels/blender_open_movies)，通过开源 PeerTube 的公开 API 读取正片、海报及 HLS/MP4；排除幕后、预告和重复版本。可选清晰度按发行方实际尺寸显示。
- **国会图书馆经典**：[National Screening Room](https://www.loc.gov/collections/national-screening-room/)，通过 [LOC JSON API](https://www.loc.gov/apis/) 同步 1890–1928 年的公开故事片、动画和默片，筛掉 API 标记的受限条目及已识别的片段，直接播放馆方 HLS 或 MP4。馆藏页面保留各自来源/权利说明。部分馆藏有高清扫描，但历史素材观感和最高画质各不相同。

1.2 随包片库为 **201 部、254 集/个正片**，其中原有 23 部，其余为广州 6 部、Blender 10 部、图书馆 162 部。数字不是红果商业片库或动漫站全量，且实际接入数量会随发行目录变化。项目未加入需要付费、DRM 或私有接口才能获取的商业正片。系统界面采用 Apple TV 风格，但不使用 Apple TV 商标或苹果自有内容。

## 在线联搜

1.3 在「搜索」增加「在线联搜」：输入片名或关键词后按回车或点按钮，应用会并行请求美国国会图书馆公开馆藏与 Blender Open Movies 官方频道。结果可翻页并去重，不局限于随包或已同步的目录。只展示来源明确、有可直接播放地址的公开条目。查阅过的作品只保存元数据和片源地址，让收藏与续播能在重启后恢复，不下载视频文件。广州微短剧和手工接入的发行方 JSON 目录仍通过已同步索引搜索。

可用 `train` 验证：`Freight train` 不在随包目录，但可从馆方实时搜到并播放。上游失败会明确显示，可按页重试；搜索不会调用破解接口、第三方解析脚本或商业平台私有接口。

## 红果等商业平台

没有把 [hongguo-drama](https://github.com/jackotom/hongguo-drama) 和 [hongguo-open-player](https://github.com/zfdang/hongguo-open-player) 的播放线路接入 Tom 短剧。两份上游分别以 GPL-3.0 与 AGPL-3.0 发布（后者 README 徽标写 GPL-3.0，仓库 LICENSE 与 GitHub 元数据为 GNU Affero GPL v3），且公开说明依赖匿名设备协议、请求签名和加密流解密，不是可直接交给 AVPlayer 的公开 HTTPS 正片目录。Tom 不会复制这些模块，也不会用网页嵌入或跳转官网播放器来代替原生播放。

如果发行方提供与 `catalog.json` 相同格式、可直接播放的 HTTPS JSON 目录，仍可在「我的 → 片库同步」粘贴地址导入。此前对红果官网播放页的核验见 [PROGRESS.md](../PROGRESS.md)：部分分集会出现登录墙，全集中也有需官方 App 观看的条目。

片库来源标签会标明「已同步」「上次目录」或失败原因（超时、网络不可用、服务无响应、目录无法解析）。在线联搜某个来源失败时会写出原因，不会把失败当成零结果；新的搜索会取消尚未完成的旧查询。

## 维护片库

在 [Native/catalog.json](../Native/catalog.json) 中维护每部作品的标题、地区、语言、主创、题材、简介、总集数、连载状态和分集。单集可记录原始集号 `number`、集名、简介、时长、字幕资源和 `sources`。以实际发布的全集数填写 `totalEpisodes`，详情以有可用地址的不同集数显示收录情况。缺集时保留原始集号。自动连播仅前往紧接的可播放剧集。

`sources` 按播放优先级填写同一集、同一剪辑版本的授权媒体地址。随应用提供的授权 MP4 放在 `assets/videos`，用 `bundledVideo` 填写文件名。启动失败或长时间卡顿时，播放器依次尝试后续地址，并从故障前的位置继续。片源切换在后台完成，观众在界面里操作剧集。作者署名和许可位于作品详情。

片库收录开放授权作品、迷你系列和国产定格动画短片《胡同猫》。原片经 CC BY 3.0 授权，应用内的版本转码为 MP4，作品详情保留作者署名。[《胡同猫》原始作品](https://vimeo.com/116507165) · [授权记录](https://commons.wikimedia.org/wiki/File:Hutong_Meow.webm)

首页「国产真人短剧」中的正片使用创作者的官方发布。分集的 `officialBilibiliID` 对应 B 站官方站外播放器，使用 App 内独立 WebKit 视图加载，保留播放器原有标识和控件。用户可以在 Tom短剧 内选集，继续观看会回到上次选的集。平台播放器负责该集内部的播放操作。[哔哩哔哩站外播放器](https://player.bilibili.com/)

国产真人短剧包括原生直播放的全集和使用平台官方播放器的全集。直播放剧集保留制作方与发布页，App 直接连接发布方的视频 CDN。《源起·从这里出发》《梅关道》以及《包拯在端州》的部分分集有另一个发布地址可用于续播。直播放的主备地址使用同一家视频 CDN。竖屏作品的画质按短边标注。[广州微短剧目录](https://www.gzjjjc.gov.cn/ljgzw/ztzl/ljwhwdj/) · [《梅关道》全集](https://www.gdjct.gd.gov.cn/ttxw/content/post_211073.html) · [《包拯在端州》全集](https://www.gdjct.gd.gov.cn/lrny/lht/content/post_211674.html) · [《孔繁森》全集](https://www.conghua.gov.cn/ljwh/content/post_11032492.html) · [《利剑1927》全集](https://www.conghua.gov.cn/ljwh/content/post_11046356.html)

播放页顶部可收起选集，右上角可关闭播放器。直播放源支持多档画质时，把 URL 和分辨率档位写进分集的 `sourceQualities`，播放器会显示「画质」菜单。切换画质会保持当前进度及播放或暂停状态。选中的档位失效后，播放器先尝试同画质的备用地址，再从相邻较低档开始回退。菜单按钮显示当前启用的画质。官方站外播放器的清晰度由发行平台提供。

## 接入发行方目录

「我的 → 片库同步」接收发行方的 HTTPS JSON 目录。目录沿用 `catalog.json` 的 `shows` 和可选 `featuredIds` 字段。支持用 `next` 指向同一域名的下一页，末页省略该字段或设为 `null`。每部剧使用发行方稳定的 `id`、实际发布的 `totalEpisodes` 和完整分集，每集的 `sources` 存放同一剪辑版本可直接播放的 HTTPS 正片地址。可通过 `sourceQualities` 标记每条线路的实际画质。连接后，App 会在下次启动时同步，也可在片库下拉或用「立即同步」刷新。

1.4 也支持粘贴发行方放在 GitHub 上的 JSON 文件页面（`github.com/…/blob/…/catalog.json`）或 `raw.githubusercontent.com` 原文地址，使用同一目录格式。普通 GitHub 项目主页、README、影视仓 / TVBox 配置不是发行方目录；不会加载它们声明的解析器、JAR 或脚本。源适配经验参考 [TVBoxOS 源配置实现](https://github.com/q215613905/TVBoxOS/blob/main/app/src/main/java/com/github/tvbox/osc/api/ApiConfig.java)，在线 Blender 频道运行于 [开源 PeerTube](https://github.com/Chocobozzz/PeerTube)；已有 Studio Open 短片的媒体来自 [作者在 GitHub 发布的 CC BY 4.0 正片](https://github.com/dlaneycreative-design/studio-open)。代码开源和影视内容授权是两件不同的事。

成功同步会替换该发行方的目录。网络或分页失败时使用上次保存的目录。每个发行方的收藏和续播位置由目录地址、剧 ID 和集号定位。如需平台密钥，由服务端保存并转换为此目录格式。

默认在线片源实现在 [Native/ProductionCatalog.swift](../Native/ProductionCatalog.swift)。发布前可用以下命令抓取真实目录快照，并可加 `--probe` 用 AVPlayer 验证所有新增广州/Blender 条目和四个馆藏样本；现有片库仍由 `Native/catalog.json` 维护：

```sh
swiftc -swift-version 5 -o /tmp/tom-live Tests/LiveSources.swift \
  Native/CatalogSync.swift Native/ProductionCatalog.swift Native/MediaCatalog.swift Native/OnlineSearch.swift
mkdir -p /tmp/tom-live-catalogs
/tmp/tom-live /tmp/tom-live-catalogs
python3 - <<'PY'
import json
from pathlib import Path
root = Path('/tmp/tom-live-catalogs')
shows = [show for name in ('guangzhou', 'blender', 'archive')
         for show in json.loads((root / (name + '.json')).read_text())['shows']]
Path('Native/online-starter.json').write_text(json.dumps({'shows': shows}, ensure_ascii=False, indent=2) + '\n')
PY
```

根目录的浏览器版本是旧原型；默认在线片源和上述界面为原生应用功能。
