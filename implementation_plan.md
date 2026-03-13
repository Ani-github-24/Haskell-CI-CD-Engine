# Research-Grade Distributed CI/CD Engine — Implementation Plan

A greenfield Haskell project implementing a Jenkins-style CI/CD engine with a DAG-based pipeline scheduler, Docker native workers, live-streamed logs, and a Prometheus metrics endpoint.

## Tech Stack

| Concern | Library |
|---|---|
| Routing / API | `servant-server`, `servant-websockets` |
| Frontend / UI | `lucid` (HTML), HTMX + TailwindCSS (CDN) |
| Database | `persistent`, `persistent-postgresql` |
| Docker | `http-conduit` (HTTP over Unix socket / TCP) |
| Concurrency | `stm`, `async` |
| Config parsing | `yaml`, `aeson` |

## Project Structure

```
CI-CD Engine/
├── ci-cd-engine.cabal
├── app/
│   └── Main.hs              -- Entrypoint: DB migration, spawn workers, start Warp
├── src/
│   ├── Types.hs              -- Core types, DAG graph, YAML config parsing
│   ├── Database.hs           -- Persistent models, migrations, query helpers
│   ├── Docker.hs             -- Docker Engine HTTP API client (http-conduit)
│   ├── UI.hs                 -- Lucid HTML templates with HTMX/TailwindCSS
│   └── Server.hs             -- Servant API definition, handlers, WebSocket logs
└── example-pipeline.yaml     -- Sample pipeline config for manual testing
```

---

## Proposed Changes

### Project Config

#### [NEW] [ci-cd-engine.cabal](file:///c:/Vs/Haskell/CI-CD%20Engine/ci-cd-engine.cabal)

Full Cabal file with two stanzas:
- **library** (`src/`): `Types`, `Database`, `Docker`, `UI`, `Server`
- **executable** (`app/`): `Main.hs`

Key dependencies: `servant-server`, `servant-websockets`, `lucid`, `persistent`, `persistent-postgresql`, `http-conduit`, `stm`, `async`, `yaml`, `aeson`, `warp`, `wai`, `text`, `bytestring`, `containers`, `mtl`, `time`, `uuid`.

---

### Core Types & DAG Engine

#### [NEW] [Types.hs](file:///c:/Vs/Haskell/CI-CD%20Engine/src/Types.hs)

- `PipelineConfig` — YAML-parseable pipeline definition (name, commit, jobs)
- `JobConfig` — single job: name, Docker image, commands, `depends_on` list
- `JobNode` — runtime node: config + status (`Pending | Running | Success | Failed`) + log `TChan`
- `AppState` — `ReaderT` env: DB pool, `TQueue` of pending pipelines, `TVar Int` active-workers, broadcast channels
- `buildDAG :: PipelineConfig -> Map Text JobNode` — pure function building adjacency map
- `schedulerThread :: AppState -> IO ()` — dequeues pipelines, topologically walks DAG, runs independent jobs in parallel via `async`, blocks dependents until parents succeed

---

### Database

#### [NEW] [Database.hs](file:///c:/Vs/Haskell/CI-CD%20Engine/src/Database.hs)

Persistent models:
- `Pipeline` — `name`, `commitHash`, `status` (Pending/Running/Success/Failed), `createdAt`
- `Job` — `pipelineId` (FK), `name`, `status`, `dockerImage`, `logOutput`, `startedAt`, `finishedAt`

Helper functions:
- `runDB` — run a `SqlPersistT` action from `ReaderT AppState`
- `insertPipeline`, `updatePipelineStatus`, `getRecentPipelines`, `getJobsForPipeline`

---

### Docker Integration

#### [NEW] [Docker.hs](file:///c:/Vs/Haskell/CI-CD%20Engine/src/Docker.hs)

All Docker interaction over HTTP using `http-conduit`:
- `createContainer :: Text -> [Text] -> IO ContainerId` — `POST /containers/create`
- `startContainer :: ContainerId -> IO ()`
- `attachContainer :: ContainerId -> IO (ConduitT () ByteString IO ())` — attach for live log streaming
- `waitContainer :: ContainerId -> IO ExitCode`
- `removeContainer :: ContainerId -> IO ()`
- `dockerRequest` — low-level helper to make HTTP requests to the Docker daemon (Unix socket or TCP configurable)

---

### Web UI (Lucid + HTMX)

#### [NEW] [UI.hs](file:///c:/Vs/Haskell/CI-CD%20Engine/src/UI.hs)

Lucid HTML templates styled with TailwindCSS (CDN) and powered by HTMX:
- `basePage :: Text -> Html () -> Html ()` — layout with TailwindCSS/HTMX CDN links
- `dashboardPage :: [Entity Pipeline] -> Html ()` — table of recent pipelines with status badges (green/red/yellow)
- `pipelineDetailPage :: Entity Pipeline -> [Entity Job] -> Html ()` — DAG status cards + HTMX WebSocket container for live logs
- `metricsPage :: Int -> Int -> Text` — plain-text Prometheus-format metrics

---

### Server / API

#### [NEW] [Server.hs](file:///c:/Vs/Haskell/CI-CD%20Engine/src/Server.hs)

Servant API type:
```
GET  /                 -> Dashboard HTML
GET  /pipeline/:id     -> Pipeline detail HTML
POST /webhook          -> Trigger new pipeline from JSON payload
GET  /metrics          -> Prometheus text metrics
WS   /ws/logs/:id      -> WebSocket log stream for a pipeline
```

Handlers:
- `dashboardHandler` — query recent pipelines, render `dashboardPage`
- `pipelineHandler` — query pipeline + jobs, render `pipelineDetailPage`
- `webhookHandler` — parse YAML config from payload, insert pipeline into DB, enqueue into `TQueue`
- `metricsHandler` — read `TQueue` length + active worker count from STM, return Prometheus text
- `logStreamHandler` — WebSocket: subscribe to `TChan` for a pipeline, forward log lines to client

---

### Application Wiring

#### [NEW] [Main.hs](file:///c:/Vs/Haskell/CI-CD%20Engine/app/Main.hs)

- Create Postgres connection pool
- Run Persistent migrations
- Initialize `AppState` (pool, `TQueue`, `TVar`, channels)
- Spawn N worker threads (`async`)
- Start Warp server on port 8080

---

### Example Config

#### [NEW] [example-pipeline.yaml](file:///c:/Vs/Haskell/CI-CD%20Engine/example-pipeline.yaml)

A sample pipeline with 4 jobs demonstrating parallel + dependent execution:
```yaml
name: my-app
commit: abc123
jobs:
  - name: lint
    image: haskell:9.6
    commands: ["hlint ."]
  - name: test
    image: haskell:9.6
    commands: ["cabal test"]
  - name: build
    image: haskell:9.6
    commands: ["cabal build"]
    depends_on: [lint, test]
  - name: deploy
    image: alpine:latest
    commands: ["echo deploying"]
    depends_on: [build]
```

---

## Verification Plan

### Automated Verification

Since this is a greenfield project with heavyweight external dependencies (PostgreSQL, Docker daemon), there are no unit tests to leverage initially.

**Build verification** (primary gate):
```powershell
cd "c:\Vs\Haskell\CI-CD Engine"
cabal build all
```
This confirms all modules type-check and compile — which, given Haskell's type system, provides strong correctness guarantees for pure logic (DAG construction, YAML parsing, HTML rendering).

> [!IMPORTANT]
> Full runtime testing requires a running PostgreSQL instance and Docker daemon. These are beyond the scope of immediate automated verification.

### Manual Verification

1. **Inspect the compiled output** — confirm `cabal build` produces the `ci-cd-engine` executable with no errors.
2. **Review module structure** — confirm each module exports the expected API surface.
3. **YAML parse check** — the `example-pipeline.yaml` should be parseable by the `FromJSON` instances in `Types.hs`.
4. **If you have Docker + PostgreSQL running**: start the server (`cabal run ci-cd-engine`), open `http://localhost:8080`, and `POST` the example pipeline via `curl`.

> [!NOTE]
> I recommend we focus on getting a clean compile first. Runtime integration testing can follow once your environment (Postgres, Docker) is configured.
