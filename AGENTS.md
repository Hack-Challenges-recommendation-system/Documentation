# Recommendation System: shared guide

The project-wide part of every AGENTS.md: what the system is, how it fits together, the rules from the case and the conventions all repositories follow. The AGENTS.md of each repository links here and adds only what is specific to it. Read both before changing anything.

## Project

Recommendation System is an entry for Hack&Change 2026, Alfa-Bank case «Альфа-Курс: знания в нужный момент», track 1: personal recommendations of educational materials for entrepreneurs. A vendor LLM ranks and explains materials; the services around it supply context, check its answers and record what users do.

| Repository | Role |
|---|---|
| `api-gateway` | Single entry point. Checks access tokens, routes `/api/v1/**`, sets `X-User-Id`. |
| `auth-service` | Registration, login, access and refresh JWT, logout denylist. |
| `profile-service` | Business profile of the user (onboarding answers). |
| `catalog-service` | Catalog of materials from the case data, with Russian full-text search. |
| `metric-service` | Raw user events and the metrics computed from them. |
| `recommendation-service` | Builds recommendations with the LLM. |
| `frontend` | Angular web app. |
| `Documentation` | This guide, `docker-compose.yaml` for the whole system and the architecture docs. Developers write the docs; agents change this repository only when asked and never touch the docs. |

All repositories live in the GitHub organization `Hack-Challenges-recommendation-system` and are **public**.

## Architecture

- **Request path:** browser → frontend (nginx) → `/api` → api-gateway → the service that owns the path. The browser talks to one origin, so the refresh cookie stays first-party. CORS matters only for other origins; the gateway allows localhost on any port and `https://cson.site`.
- **Who the user is:** auth-service issues HS512 JWTs: an access token (5 minutes) and a refresh token (30 days, the HttpOnly cookie `jwtRefreshToken`). api-gateway verifies the access token, rejects tokens that auth-service denylisted in Redis on logout, removes any `X-User-Id` sent by the client and sets it from the token. Services trust `X-User-Id` and never parse tokens.
- **Paths:** every service listens on 8080, serves under `/api/v1` and owns distinct path prefixes. api-gateway routes by prefix; the table is in its AGENTS.md.
- **Events between services:** auth-service publishes `users.to.create` `{userId, nickname}` and `users.to.delete` `{userId}` to Kafka, keyed by user id and without type headers; profile-service consumes them. Both services declare these topics with 3 partitions.
- **Storage:** one Postgres with a database per service (`auth`, `profile`, `catalog`, `metric`), each migrated by the Flyway of its service. Redis holds the access-token denylist.
- **Case data:** mounted read-only as `/data` into catalog-service and metric-service, which import it at startup. Its layout isn't mapped yet; the importers read a temporary JSON format described in the AGENTS.md of those services.
- **Recommendations:** recommendation-service, not built yet, will collect the profile, recent events and catalog candidates, ask the LLM to rank and explain them, validate the answer and log impressions. When it can't answer, the frontend shows topic matching from catalog search instead and marks it `engine: baseline`.

## Running the whole system

- `docker compose up` in this repository starts Postgres, Redis, Kafka and all seven apps, then serves the web app on http://localhost:8080.
- Images are pulled as `<DOCKERHUB_USER>/recommendation-system-<service>` when they are on Docker Hub; CI publishes them from `main`. Otherwise compose builds them from the `develop` branches on GitHub, which takes about 20 minutes.
- Every setting has a default, and `env.example` lists them all. Copy it to `.env` to change a value; for example, `AUTH_SERVICE_BUILD=../auth-service` builds that app from a local clone.
- The case data goes into `./data`; git ignores the folder.

## Rules for every change

These come from the case. Breaking one can disqualify the submission.

1. **The case data never goes into git or a Docker image**: not the dump, not a copy, not an extract. Services read it from a path mounted at runtime; `/data/` is in `.gitignore`. Synthetic test data written by the team may be committed.
2. **No keys, tokens or passwords in git.** Read them from environment variables; `env.example` files list names only.
3. **External APIs, such as the LLM, get only the fragments they need.** No user ids, names, emails or other personal data, and no paid or closed materials.
4. **Paid materials:** show only a short benefit and the provided link, never their content.
5. **Everything must start with one `docker compose up` from the README.** A submission that doesn't start scores 0. Don't add infrastructure or a required external service without agreeing on it first.
6. **Simple UI, no intrusive notifications.**

## Commits

Every commit follows [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/), in the style the history already uses:

    <type>(<scope>): <what was changed>

- **Type:** `feat`, `fix`, `refactor`, `perf`, `test`, `docs`, `build`, `ci`, `chore`, `style` or `revert`.
- **Scope:** optional; the area that changed, e.g. `(jwt)`, `(kafka)`, `(migrations)`, `(controllers)`, `(CI/CD)`.
- **Description:** English, past tense, e.g. `fix(cookie): logout cookie name was fixed`.
- **Breaking change:** `!` after the type or scope, plus a `BREAKING CHANGE:` footer saying what callers must change.
- One logical change per commit. Commit to `develop`; `main` receives merges from `develop`.

## Java services

auth-service, profile-service, catalog-service, metric-service and recommendation-service follow these conventions. api-gateway is reactive and has no database, so its own AGENTS.md describes its setup.

### Code conventions

- Java 25, Spring Boot 4.1.2, Maven. Base package `team.nofantasy.recommendationsystem.<service>`, entry point `Main`.
- Three layers: `controller` → `service` → `repository`. Controllers never touch repositories or entities.
- Two DTO layers, both Java records:
  - `dto/controller/<feature>/*ControllerDto`: HTTP requests and responses, with Jakarta validation.
  - `dto/service/<feature>/*ServiceDto`: between controllers and services. Kafka messages live in `dto/service/kafka`, import rows in `dto/service/importer`.
- Mapping goes through MapStruct interfaces in `mapper/`. Unmapped source or target properties fail the build, so map every field or ignore it explicitly. Keep methods in pairs: controller-to-service first, then service-to-controller.
- Entities in `entity/` use Lombok: `@Getter`, `@Setter`, `@Builder` and a protected no-args constructor. Enums of an entity are nested in it.
- Domain exceptions live in `exception/`; `controller/advice/GlobalExceptionHandler` turns them into HTTP statuses.
- Schema changes go only into new Flyway files in `src/main/resources/database/migrations` (`V<n>__<description>.sql`). Never edit a migration that a shared database already ran. Hibernate runs with `ddl-auto: validate`.
- Endpoints sit under `/api/v1` (`spring.mvc.servlet.path`). Each service owns distinct top-level paths, so the gateway can route by prefix.
- The gateway puts the signed-in user's id into `X-User-Id`. Read it with `@RequestHeader("X-User-Id") UUID userId`, never from the body.
- Log with the SLF4J fluent API: `log.atInfo().setMessage(...).addKeyValue(...).log()`. Files go to `/logs/<service>.log` as ECS JSON.
- Configuration comes from environment variables, with local defaults in `application.yaml`.

### Build and test

- `mvn -B -ntp verify` runs all tests. Integration tests use Testcontainers, so Docker must be running; without Docker they are skipped.
- `mvn -B -ntp -DskipTests package` builds `target/app.jar`, which the `Dockerfile` copies.
- `docker compose up -d` in a service repository starts that service's local infrastructure (its `docker-compose.yaml`).
- In MockMvc tests, request the full path and set the servlet path: `get("/api/v1/...").servletPath("/api/v1")`.
- CI: `.github/workflows/ci-cd.yml` tests every push and pull request, pushes the image to Docker Hub from `main`, and deploys on a manual run. Its header lists the secrets and variables it needs.
