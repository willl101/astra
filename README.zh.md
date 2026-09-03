# Astra

[English](README.md) | 中文

<p align="center">
  <img src="packages/experimental/proactive-screen/app/Assets/AppIcon.png" width="112" alt="Astra 标志">
</p>

<p align="center"><strong>一个只在真正有帮助时出现的安静 AI 助手。</strong></p>

## 产品影片

https://github.com/user-attachments/assets/0141b0d4-c9b9-4e0c-a922-aac9e44df944

Astra 在 macOS 上陪伴你的工作，理解画面中的上下文，只在预期价值明显高于打扰和风险时行动。它不像一个等待提问的聊天机器人，更像一个体贴的助手：大部分时间保持安静，在你需要时立即提供价值，并能真正完成工作。

## 与 Astra 协作的三种方式

- **静默主动协助** — Astra 会克制地发现截止时间、风险、可以省下的工作、灵感以及有依据的情绪支持。绝大多数画面不会产生任何输出。
- **双击 Fn** — 无需编写提示词，让 Astra 理解当前画面或选中文字，并采取最有价值的下一步行动。
- **Fn + Space** — 当你已经知道想做什么时，打开极简指令框。Astra 会结合你的要求、选中内容或当前画面直接执行。

## 为什么体验不同

- 无需逐个适配应用，即可跨 macOS 应用工作。
- 将选中文字作为精确上下文，并可把验证过的结果直接写回当前编辑区。
- 系统通知保持精简，完整结果保留在可继续交流的对话中。
- 可以使用 Agent 工具处理低风险工作，并在重要操作前询问用户。
- 使用 Apple Vision 在本地完成 OCR。截图不会保存，只有经过长度限制的识别文字会发送给配置的模型。
- 抑制重复上下文和已经通知过的结果，降低打扰与模型成本。

## 当前状态

Astra 是一个基于 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的实验性 macOS 开发预览版，适合本地产品测试，但还不是可以在其他 Mac 上独立安装的公证分发包。

## 运行开发预览版

需要 macOS、Node.js 22 或更高版本、pnpm、Swift 工具链、DeepSeek API Key，以及名为 `Proactive AI Local Code Signing` 的本地代码签名证书（也可通过 `PROACTIVE_SIGNING_IDENTITY` 指定）。

```sh
pnpm install
cp .env.example .env
# Add your own DEEPSEEK_API_KEY to .env.
pnpm run app:proactive:install
```

在 macOS 提示时授权屏幕录制、辅助功能、通知，以及使用双击 Fn 时所需的输入监控。应用会安装到 `~/Applications/Astra.app`。

## 隐私与安全

Astra 默认屏蔽常见的密码、认证、通知及自身界面。这份应用屏蔽列表是一种实用保护，而不是安全边界。在敏感内容可见时使用前，请先检查相关配置。编辑操作以克制和可撤销为原则；发送、发布、删除、付款、账号和安全变更需要用户确认。

实现细节与限制请查看 [Astra 包参考](packages/experimental/proactive-screen/README.zh.md)和[产品设计](packages/experimental/proactive-screen/DESIGN.md)。

## 许可证

Astra 新增代码和媒体以 [PolyForm Noncommercial License 1.0.0](LICENSE)公开源代码，商业使用需要获得版权所有者的单独书面许可。仓库包含的 DeepSeek Harness 部分继续适用原有的 [MIT 许可证](LICENSES/DEEPSEEK-HARNESS-MIT.txt)，第三方声明保留在 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)中。
