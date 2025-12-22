
## Fork本项目后需要做些什么？

### 1. 修改工作流文件中的用户名
修改 `config/sync-config.yaml` 文件默认用户名，将`R2_PUBLIC_URL`地址替换成你的cloudflareR2公开地址。

### 2. 删除 version.txt 文件
如果不删除首次运行工作流时勾选强制同步

### 3. 注册代码托管平台并配置令牌

#### 3.1 注册平台并创建令牌
注册以下平台并创建访问令牌：
- [gitee](https://gitee.com)
- [gitcode](https://gitcode.com) 
- [gitlab](https://gitlab.com)
- [Cloudflare](https://dash.cloudflare.com)

在创建令牌时，请勾选所有权限，然后复制令牌备用，- [创建令牌指南](./tokens_README.md)。

#### 3.2 配置 GitHub Secrets
回到 GitHub 仓库，按以下步骤配置：
1. 点击 `Settings` →`Actions→General`→`Read and write permissions`→`Allow GitHub Actions to create and approve pull requests` →`Save`
2. 点击`Secrets and variables` → `Actions`
3. 点击 `New repository secret`
4. 按需要分别添加以下 secret：
   - **Name**: `GITCODE_TOKEN`，**Secret**: 你的 gitcode 访问令牌
   - **Name**: `GITEE_TOKEN`，**Secret**: 你的 gitee 访问令牌  
   - **Name**: `GITLAB_TOKEN`，**Secret**: 你的 gitlab 访问令牌
   - **Name**: `R2_ACCOUNT_ID`，**Secret**: cloudflare_R2的Account ID 
   - **Name**: `R2_ACCESS_KEY`，**Secret**: cloudflare_R2访问密钥
   - **Name**: `R2_SECRET_KEY`，**Secret**: cloudflare_R2机密访问密钥

#### 3.3 测试 Release 工作流
1. 点击 Actions
2. 运行 `Release 脚本` 工作流
3. 在项目名称处填写你 Fork 后的本项目名称
4. 运行工作流，系统将自动在 gitcode、gitee、gitlab 创建对应项目

#### 3.4 同步上游插件
运行 `同步上游发布插件` 工作流，系统将：
- 批量同步多个插件到 gitcode、gitee、gitlab、cloudflare_R2
- 自动创建仓库并发布 Releases
- 当有新版本时自动删除旧版本


# 插件配置参数说明 不是必须设置可按需要修改

## 参数说明表格

| 参数           | 类型     | 说明         | 作用                     |
|----------------|----------|--------------|--------------------------|
| github_owner   | 字符串   | 上游作者名   | 拉取上游项目             |
| github_repo    | 字符串   | 上游仓库名   | 指定要同步的仓库         |
| local_name     | 字符串   | 本地仓库名   | 同步后在本地仓库显示名称 |
| filter_include | 字符串   | 包含过滤规则 | 只保留匹配的文件         |
| filter_exclude | 字符串   | 排除过滤规则 | 排除匹配的文件           |

