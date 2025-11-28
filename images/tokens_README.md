# 各平台令牌创建步骤指南

## Gitee (码云) 令牌创建步骤

### 1. 登录 Gitee
访问 [gitee.com](https://gitee.com) 并登录你的账号。

### 2. 进入个人设置
- 点击右上角头像
- 选择「设置」

### 3. 找到令牌管理
- 在左侧菜单中找到「安全设置」
- 点击「私人令牌」

### 4. 生成新令牌
- 点击「生成新令牌」
- 填写令牌描述，例如：`GitHub Actions Sync`
- **勾选所有权限**，特别是：
  - projects (项目)
  - pull_requests ( Pull 请求)
  - issues (问题)
  - notes (备注)
  - wiki (Wiki)
  - releases (发行版)

### 5. 创建并保存令牌
- 点击「提交」
- 输入登录密码验证
- **立即复制生成的令牌**并妥善保存（令牌只显示一次）

---

## GitCode 令牌创建步骤

### 1. 登录 GitCode
访问 [gitcode.com](https://gitcode.com) 并登录你的账号。

### 2. 进入访问令牌管理
- 点击右上角头像
- 选择「个人设置」
- 在左侧菜单中找到「访问令牌」

### 3. 创建新令牌
- 点击「生成新令牌」
- 填写令牌名称，例如：`GitHub Sync Token`
- 选择过期时间（建议选择较长时间或永不过期）
- **勾选所有权限范围**，包括：
  - api
  - read_user
  - read_repository
  - write_repository
  - 等其他所有可用权限

### 4. 生成令牌
- 点击「创建」
- **立即复制生成的访问令牌**并妥善保存

---

## GitLab 令牌创建步骤

### 1. 登录 GitLab
访问 [gitlab.com](https://gitlab.com) 并登录你的账号。

### 2. 进入偏好设置
- 点击右上角头像
- 选择「Edit profile」
- 或者直接访问：https://gitlab.com/-/profile/personal_access_tokens

### 3. 创建访问令牌
- 在左侧菜单选择「Access Tokens」
- 填写 Token name，例如：`GitHub-Actions-Sync`
- 选择过期日期（建议选择较远日期）
- **勾选所有权限范围**，包括：
  - api
  - read_user
  - read_repository
  - write_repository
  - read_registry
  - write_registry
  - 等其他所有可用权限

### 4. 生成令牌
- 点击「Create personal access token」
- **立即复制生成的令牌**并妥善保存

---

## 重要提醒

1. **令牌安全**：创建的令牌具有很高的权限，请妥善保管，不要泄露
2. **一次性显示**：令牌通常只在创建时显示一次，请务必立即复制保存
3. **权限选择**：为确保同步功能正常，请勾选所有可用权限
4. **GitHub 配置**：将三个令牌分别添加到 GitHub Secrets 中：
   - `GITEE_TOKEN` = Gitee 私人令牌
   - `GITCODE_TOKEN` = GitCode 访问令牌  
   - `GITLAB_TOKEN` = GitLab 个人访问令牌

完成以上步骤后，即可正常运行 GitHub Actions 工作流进行多平台同步。
