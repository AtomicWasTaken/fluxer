# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is Fluxer

Fluxer is a free, open-source instant messaging and VoIP platform (similar to Discord). It's self-hostable and licensed under AGPLv3.

## Commands

| Task | Command |
|---|---|
| Build all | `pnpm build` |
| Lint all | `pnpm lint` (Biome) |
| Typecheck all | `pnpm typecheck` (uses `tsgo`, not `tsc`) |
| Test all | `pnpm test` |
| Integration tests | `pnpm test:integration` |
| Start dev environment | `devenv up` |
| Test single package | `pnpm --filter @fluxer/schema test` |
| Run single test file | `pnpm --filter @fluxer/schema exec vitest run src/path/to/test.test.ts` |
| Docs dev server | `pnpm dev:docs` |

## Architecture

**Monorepo** using pnpm workspaces + Turborepo. Multiple languages:

- **Backend services**: TypeScript/Node.js 24, all HTTP services use **Hono** framework
- **WebSocket gateway** (`fluxer_gateway/`): Erlang/OTP with Cowboy, handles real-time connections, presence, message fan-out. Communicates with backend via NATS
- **Frontend** (`fluxer_app/`): React 19 + MobX (state) + Rspack (bundler) + Tailwind CSS v4 + CSS Modules + LinguiJS (i18n)
- **Client WASM** (`fluxer_app/crates/libfluxcore/`): Rust compiled to WebAssembly via wasm-pack
- **Desktop** (`fluxer_desktop/`): Electron wrapper

### Key services

| Directory | Purpose |
|---|---|
| `fluxer_server/` | Umbrella server combining all TS backend services (for self-hosting) |
| `fluxer_api/` | Standalone API service entrypoint |
| `fluxer_gateway/` | Erlang real-time WebSocket gateway |
| `fluxer_app/` | Web/desktop frontend |
| `fluxer_admin/` | Admin panel |
| `fluxer_media_proxy/` | Media proxy service |
| `fluxer_relay/` | Relay service |
| `fluxer_integration/` | Integration test suite |
| `fluxer_marketing/` | Marketing site |

### Shared packages (`packages/`)

All under `@fluxer/*` scope. Key ones:

- `api/` — REST API controllers (Hono), organized by domain in `ControllerRegistry.tsx`. Routes mounted at `/v1/*`
- `schema/` — Zod schemas shared between backend and frontend
- `config/` — JSON config schema + generated types
- `errors/` — Error types with i18n messages
- `email/` — Email sending + i18n templates
- `cassandra/` — Cassandra driver wrappers
- `kv_client/` — Valkey/Redis client
- `nats/` — NATS messaging client
- `hono/` — Shared Hono middleware
- `i18n/` — LinguiJS i18n codegen
- `ui/` — Shared UI component library
- `snowflake/` — Snowflake ID generation

### Data layer

- **Default storage**: SQLite (no ORM, custom abstraction in `packages/api/src/database/`)
- **Optional**: Apache Cassandra for distributed deployments
- **Cache/coordination**: Valkey (Redis-compatible) via ioredis
- **Search**: Meilisearch
- **Messaging**: NATS (two instances: core pub/sub on 4222, JetStream on 4223)
- **Voice/video**: LiveKit

### Configuration

Driven by `FLUXER_CONFIG` env var pointing to a JSON file. Template: `config/config.dev.template.json`. Schema: `config/config.schema.json`.

## Development environment

Development uses **devenv (Nix) only**. Run `devenv shell` to enter the environment, `devenv up` to start all services. The `.envrc` supports direnv. Dev instance at `http://localhost:48763/`, dev email inbox at `http://localhost:48763/mailpit/`.

## Code style

- **Formatter/linter**: Biome — single quotes, tabs, 120 char line width
- **TypeScript**: Uses `tsgo` (native TS compiler preview, `@typescript/native-preview`) for typechecking
- **File extension**: `.tsx` is used for backend files too (JSX is used in email templates)

## Contributing conventions

- PRs target `canary` branch, squash-merged
- PR titles must follow Conventional Commits: `type(scope): description` (mostly lowercase)
- Common types: `feat`, `fix`, `docs`, `refactor`, `perf`, `test`, `chore`, `ci`, `build`, `revert`
- Backend changes should include unit tests; frontend tests only when clearly valuable
