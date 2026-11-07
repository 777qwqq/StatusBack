# StatusBack（状态栏返回）

iOS 16 隐根（rootless）越狱插件：点击悬浮球即可返回上一级，到根页面后自动回主屏幕。

## 用法

安装后在 **设置 → 状态栏返回** 里配置：

- **启用插件** — 总开关
- **显示悬浮球** — 是否显示悬浮球
- **不透明度** — 悬浮球透明度（0.2–1.0）
- **大小** — 悬浮球直径（32–96pt）
- **到根之后** — 停在当前页 / 回主屏幕

悬浮球可以**拖动**，位置会被记住，跨 App 生效。

## 工作原理

1. 前台 App 在自己的 window 之上（`UIWindowLevelAlert + 10`）创建一个只包含悬浮球的独立 window。
2. 每个进程只在自己处于前台时创建该 window，退到后台时销毁，因此屏幕上始终只有一个悬浮球。
3. 点击悬浮球发出 Darwin 通知，当前 App 执行一次返回：
   - 先尝试 `accessibilityPerformEscape`（多数模态框/菜单会响应）
   - 再 pop 最深的导航栈
   - 再 dismiss 已 present 的控制器
   - 最后尝试把自己从所在导航栈 pop 掉
4. 若以上都无事可做，则发通知让 SpringBoard 回主屏幕（可在设置里关掉这一兜底）。

## 构建

```sh
THEOS_PACKAGE_SCHEME=rootless make package FINALPACKAGE=1
```

## 安装

deb 内布局为隐根路径（`/var/jb/...`），装到 iOS 15+ 的 rootless / roothide 越狱环境。
