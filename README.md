# StatusBack（状态栏返回）

iOS 16 隐根（rootless）越狱插件：点击状态栏即可返回上一级，到根页面后自动回主屏幕。

## 用法

安装后在 **设置 → 状态栏返回** 里配置：

- **启用插件** — 总开关
- **触发区域** — 左侧 / 右侧 / 整条状态栏
- **到根之后** — 停在当前页 / 回主屏幕

## 工作原理

1. 状态栏上覆盖一层只响应顶部 44pt 的透明视图，点击后发出 Darwin 通知。
2. 所有注入的进程收到通知后执行一次返回：
   - 先尝试 `accessibilityPerformEscape`（多数模态框/菜单会响应）
   - 再 pop 最深的导航栈
   - 再 dismiss 已 present 的控制器
   - 最后尝试把自己从所在导航栈 pop 掉
3. 若以上都无事可做，则发通知让 SpringBoard 回主屏幕（可在设置里关掉这一兜底）。

## 构建

```sh
THEOS_PACKAGE_SCHEME=rootless make package FINALPACKAGE=1
```

## 安装

deb 内布局为隐根路径（`/var/jb/...`），装到 iOS 15+ 的 rootless / roothide 越狱环境。
