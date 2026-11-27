# CamDaemon · 阶段二手机端守护进程

越狱 iPhone 12 / iOS 16.0.2 上自写的局域网机位进程：后置摄像头常开采集（不录像），内嵌最小 HTTP 服务，供 Win 浏览器实时预览、拍照回传落盘。

## 目录结构

```
daemon/
├── Makefile                          # THEOS 工程（rootless 编译）
├── control                           # deb 包元数据
├── src/
│   ├── main.m                        # 入口：装配采集 + HTTP，RunLoop 保活
│   ├── Config.h/.m                   # 运行配置（环境变量覆盖默认值）
│   ├── FrameStore.h/.m              # 线程安全最新帧缓存（只留一帧）
│   ├── CameraCapture.h/.m           # AVFoundation 后置会话 + JPEG 编码
│   └── HttpServer.h/.m               # BSD socket 最小 HTTP 服务
├── layout/var/jb/
│   ├── usr/bin/                      # 编译后二进制安装位置
│   └── Library/LaunchDaemons/
│       └── com.local.camdaemon.plist # 开机自启 + KeepAlive
├── .github/workflows/build-deb.yml   # macOS runner 编译 rootless deb
└── deploy/deploy.ps1                 # SSH/scp 部署到手机
```

## 端点（监听默认 8090，与现成 App 的 8080 错开）

| 端点 | 说明 |
|---|---|
| `GET /health.json` | 采集/服务/帧状态 JSON |
| `GET /capabilities.json` | 能力清单（流/快照/音频/开关） |
| `GET /snapshot.jpg` | 当前帧高画质 JPEG；无帧返回 503 |
| `GET /stream` | MJPEG 连续帧（multipart/x-mixed-replace） |

## 配置（环境变量，可在 plist 的 EnvironmentVariables 里改）

| 变量 | 默认 | 说明 |
|---|---|---|
| `CAM_PORT` | 8090 | HTTP 端口 |
| `CAM_PRESET` | AVCaptureSessionPreset1280x720 | 采集预设 |
| `CAM_STREAM_Q` | 0.6 | 流 JPEG 质量 |
| `CAM_SNAP_Q` | 0.92 | 快照 JPEG 质量 |
| `CAM_STREAM_W` | 960 | 流最大宽度（等比缩放，0 不缩放） |
| `CAM_SNAP_W` | 1920 | 快照最大宽度 |
| `CAM_VERBOSE` | 1 | 详细日志 |

## 构建与部署流程

1. **编译**：源码推到 GitHub 仓库，Actions 走 `build-deb.yml`，在 macOS runner 出 rootless `*.deb`，下载到本地 `packages/`。
2. **手机侧前置**：Sileo 装 OpenSSH；确认同 WiFi；记下手机 IP。
3. **部署**：`powershell -File deploy.ps1 -DeviceIp <手机IP>`（默认 root，初始密码 `alpine`，登录后 `passwd` 修改）。
4. **验证**：浏览器/代理访问 `http://<手机IP>:8090/health.json`。

## 阶段二边界（本期不做，留阶段三及以后）

- 锁屏/后台常驻策略深化、断流自动重连、心跳日志；
- MJPEG ↔ H.264 编码切换、麦克风采集与音频开关；
- 流档/拍照档网页端手动切换 + 卡顿降档提示；
- VPS 中继 / 4G 外网、YOLO 对接、照片归档。

## 真机联调待确认项

- 摄像头首次授权：daemon 无 GUI，需先在系统设置允许相机权限；
- 画面方向（竖屏/镜像）以真机预览为准，必要时在采集连接上做方向修正；
- rootless 包架构与 SDK 版本在 CI 首跑时按报错校准；
- 时间戳基准（手机/电脑时钟）、固定落盘目录与命名规则。
