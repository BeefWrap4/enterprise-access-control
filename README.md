# 企业访问控制平面

三套 BaseOps 项目共用的企业内部访问控制基座：

- [多模态基站运维 RAG](https://github.com/BeefWrap4/basestation-multimodal-rag)
- [AI 应用缓存中间件](https://github.com/BeefWrap4/llm-cache-middleware)
- [基站智能运维 Agent Harness + Plugins](https://github.com/BeefWrap4/basestation-agent-harness)

- Keycloak 26.7.0 负责 OIDC/SSO 和粗粒度角色。浏览器使用 Authorization Code + PKCE，后端通过标准 Token Introspection 校验访问令牌、受众与有效期。
- Cerbos 0.54.0 负责 Agent Tool Gateway 的调用级 ABAC。策略使用版本化 YAML 管理，PDP 不可用时 Tool Gateway fail-closed。
- 业务授权保留在业务边界：RAG 文档 ACL、缓存 workspace/subject 隔离、Agent L3 审批原子消费均不下沉到 IAM。

```mermaid
flowchart LR
  U[企业用户] -->|OIDC Code + PKCE| KC[Keycloak]
  U --> SPA[RAG / Cache / Agent Console]
  SPA -->|Bearer access token| API[三套业务 API]
  API -->|Token introspection| KC
  API --> ACL[RAG ACL / Cache Isolation]
  API --> TG[Agent Tool Gateway PEP]
  TG -->|principal + resource + action + context| CB[Cerbos PDP]
  CB -->|allow / deny| TG
  TG --> AP[风险门禁 + L3 原子审批消费]
```

## 本地开发账号

这些账号仅用于本地导入的 `baseops` Realm，不得复用于其他环境。

| Purpose | Username | Password | Realm roles |
| --- | --- | --- | --- |
| requester/admin | `ops-user` | `Ops-demo-2026!` | `ops`, `admin` |
| independent reviewer | `reviewer-user` | `Reviewer-demo-2026!` | `approver` |
| negative test | `viewer-user` | `Viewer-demo-2026!` | `viewer` |
| tenant isolation test | `other-workspace-user` | `Other-demo-2026!` | `ops` |

服务到服务身份使用独立 Client Credentials：`aegra-worker` 仅面向 `agent-backend`，`agent-mcp` 仅面向 `rag-backend` 且只持有 `rag-search-service` 查询角色，`rag-cache-client` 与 `agent-model-client` 仅面向 `cache-backend`。`rag-cache-client` 额外持有 `knowledge-version-publisher`；两个缓存调用方持有 `session-delegator`，可代表已经过各自后端验证的上游用户写入会话，但不能取得管理员权限。四类工作负载均不复用浏览器用户 Token，也不共享客户端密钥。

## 启动与验证

```powershell
docker compose up -d
powershell -ExecutionPolicy Bypass -File scripts/apply-realm-delta.ps1
powershell -ExecutionPolicy Bypass -File scripts/verify.ps1
python scripts/benchmark_access_control.py --requests 200 --concurrency 20
```

Keycloak 地址为 `http://localhost:8180`，管理健康端口为 `9000`；Cerbos HTTP/gRPC 端口为 `3592/3593`。三套业务应用应先启动本控制平面，再启动各自 Compose。已有 Keycloak 数据卷不会被 Realm 导入覆盖，变更客户端或角色后必须运行 `apply-realm-delta.ps1`；该脚本通过 Admin API 幂等更新，不删除 Realm、用户或业务数据。

`verify.ps1` 同时校验 Keycloak/Cerbos 健康、三套 API 的身份正向链路、无 Token/无角色负向链路、跨 workspace 隔离和 Cerbos allow/deny。性能脚本只记录当前单机复现环境的延迟与错误率，不代表生产 SLO。

`qa-client` 的密码模式只用于确定性 API 验证；三个生产形态的浏览器 Client 均未开启密码模式，必须使用 PKCE。生产部署还应通过 Secret Manager 注入密钥，并将 Keycloak、Cerbos 与数据库切换为高可用部署。
