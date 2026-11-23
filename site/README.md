# 官网

Cloudflare Pages 静态站点，线上地址 https://peek-macos.pages.dev 。

- 站点源码就是本目录的 `index.html` 和 `style.css`，没有构建步骤。
- 部署配置在仓库根目录的 `wrangler.jsonc`：项目名 `peek-macos`，输出目录 `./site`。
- 项目名带 `-macos` 是因为 `peek.pages.dev` 已被他人占用。
- Cloudflare 侧使用 Git 集成：推送 `main` 分支即自动部署。Dashboard 中构建命令留空，输出目录填 `site`。
- `assets/` 中的截图复制自 `docs/images/`，图标由 `app/Resources/AppIcon-1024.png` 缩到 128 像素。改界面后重新复制。

需要手动部署时：

```sh
npx wrangler pages deploy site --project-name peek-macos
```