# Repository Guidelines

## Commands

- Setup: `cp .env.local.example .env.local && bin/setup`
- Dev server: `bin/dev` (Rails + Sidekiq + Tailwind watcher via Procfile.dev)
- All tests: `bin/rails test`
- Single test file: `bin/rails test test/models/user_test.rb`
- Single test at line: `bin/rails test test/models/user_test.rb:17`
- System tests (serial, slow): `DISABLE_PARALLELIZATION=true bin/rails test:system`
- Lint Ruby: `bin/rubocop` (auto-fix: `bin/rubocop -A`)
- Lint ERB: `bundle exec erb_lint ./app/**/*.erb -a`
- Lint/fix JS: `npm run lint` / `npm run lint:fix` / `npm run format` (Biome, scoped to `app/javascript/**/*.js`)
- Security: `bin/brakeman`
- Demo data: `rake demo_data:default` (login: `user@example.com` / `Password1!`)

## Pre-commit checks

Run in this order before pushing:
1. `bin/rubocop`
2. `bundle exec erb_lint ./app/**/*.erb`
3. `npm run lint`
4. `bin/rails test`
5. `DISABLE_PARALLELIZATION=true bin/rails test:system` (only when applicable)
6. `bin/brakeman --no-pager`

## Critical gotchas

- Use `Current.user` and `Current.family` — NOT `current_user` / `current_family`
- Migrations must inherit `ActiveRecord::Migration[7.2]` — do NOT use version 8.0
- Entry amounts: negative = inflow (money in), positive = outflow (money out)
- Do not run `rails server`, `touch tmp/restart.txt`, `rails credentials`, or auto-run migrations
- Always use `icon` helper (in `application_helper.rb`) — NEVER `lucide_icon` directly
- Tailwind design system tokens are in `app/assets/tailwind/maybe-design-system.css` — use functional tokens (`text-primary`, `bg-container`) not raw colors (`text-white`, `bg-white`). Do not add new design system styles without permission.

## Architecture

- Ruby 3.4.7 / Rails 7.2 / PostgreSQL / Redis / Sidekiq
- Asset pipeline: Propshaft + importmap (no webpack/bundler). Stimulus controllers via importmap.
- App modes: `managed` (hosted service) or `self_hosted` (user Docker), controlled by `Rails.application.config.app_mode`
- Core domain: `Family` → `User` → `Account` → `Entry` (delegated type: Transaction / Valuation / Trade). Accounts are delegated types too (Depository, Investment, Crypto, Property, etc.)
- "Syncable" pattern: `Account`, `PlaidItem`, and `Family` can each sync data. Creates `Sync` records for audit. Family auto-syncs daily.
- Provider pattern: 3rd-party data providers (exchange rates, security prices) are registered at runtime via `Provider::Registry` with `Provided` concerns on domain models. See `app/models/provider/`.
- Background jobs: Sidekiq with sidekiq-cron for scheduling. Jobs in `app/jobs/`.
- State machines: AASM gem for model states.
- Pagination: `pagy` gem.
- Auth: Pundit for authorization, Doorkeeper for OAuth, API keys for external API access.

## Code organization conventions

- Business logic lives in `app/models/` as concerns and POROs. Avoid `app/services/` — this codebase deliberately does NOT use the service-object pattern.
- Models answer questions about themselves: prefer `account.balance_series` over `AccountSeries.new(account).call`.
- ViewComponents for reusable/complex UI elements; plain partials for simple static content. Prefer components when available.
- Stimulus controllers: declarative actions in HTML (`data-action="click->toggle#toggle"`), NOT imperative `addEventListener`. Keep under 7 targets. Component-scoped controllers stay in `app/components/`, global ones in `app/javascript/controllers/`.
- Native HTML over JS: `<dialog>` for modals, `<details>/<summary>` for disclosures.
- Turbo frames for page sections; query params for state over localStorage/sessions.

## Testing

- Minitest + fixtures only. NEVER RSpec or factories for behavioral tests.
- Fixtures: 2-3 per model for base cases; create edge cases inline.
- HTTP mocking: VCR cassettes in `test/vcr_cassettes`.
- Mocking: `mocha` gem; prefer `OpenStruct` for mocks; only mock what's necessary.
- Controller tests: use `sign_in(user)` helper for auth.
- Tests run in parallel by default; disable with `DISABLE_PARALLELIZATION=true`.
- Test boundaries: test command methods were called with correct params; test query method output. Never test another class's implementation details.
- Only test critical code paths that significantly increase confidence.

## API endpoints (dual test framework)

The repo uses TWO testing frameworks for different purposes:

1. **Minitest** (`test/controllers/api/v1/*_test.rb`): ALL behavioral assertions go here. Use `ApiKey` with `X-Api-Key` header via `api_headers(api_key)`.
2. **RSpec/rswag** (`spec/requests/api/v1/*_spec.rb`): DOCS ONLY for OpenAPI generation. No `expect`/`assert_*`. Use `run_test!` without assertion blocks. Auth via API key pattern (NOT OAuth/Bearer).
   - `.rspec` config limits rspec to `spec/requests/api/v1/**/*_spec.rb` only.
   - Regenerate docs: `RAILS_ENV=test bundle exec rake rswag:specs:swaggerize`
   - Generated output: `docs/api/openapi.yaml`
   - Verify consistency: `ruby test/support/verify_api_endpoint_consistency.rb`

After every API endpoint change, run the consistency checklist: `.cursor/rules/api-endpoint-consistency.mdc`.

## Providers: Pending transactions & FX

Provider metadata stored on `Transaction#extra`, namespaced by provider:
- SimpleFIN: `extra["simplefin"]["pending"]`, FX at `extra["simplefin"]["fx_from"]` / `fx_date`
- Plaid: `extra["plaid"]["pending"]` (bank/credit only; investments do not store pending)
- Lunchflow: `extra["lunchflow"]["pending"]`

Runtime toggles (default-off):
- `SIMPLEFIN_INCLUDE_PENDING=1`, `SIMPLEFIN_DEBUG_RAW=1`
- `LUNCHFLOW_INCLUDE_PENDING=1`, `LUNCHFLOW_DEBUG_RAW=1`
- Plaid pending fetched by default; disable with `PLAID_INCLUDE_PENDING=0`

Config files: `config/initializers/simplefin.rb`, `config/initializers/lunchflow.rb`, `config/initializers/plaid_config.rb`.

## Style enforcement

- Ruby: 2-space indent, double-quoted strings (enforced by `rubocop-rails-omakase` + `erb_lint`).
- JS: Biome with double quotes, scoped to `app/javascript/**/*.js` (see `biome.json`).
- i18n: all user-facing strings via `t()` helper. Update `config/locales/en.yml`.
- Rails time helpers: `1.day.ago`, `Time.current` — not `Time.now`.
- `ActiveSupport::Duration` (e.g., `15.minutes`) over integer seconds.

## Further reference

- Securities provider walkthrough: `docs/llm-guides/adding-a-securities-provider.md`
- API consistency checklist: `.cursor/rules/api-endpoint-consistency.mdc`
- Project design & data flow: `.cursor/rules/project-design.mdc`
- Project conventions: `.cursor/rules/project-conventions.mdc`
- View/component conventions: `.cursor/rules/view_conventions.mdc`
- Stimulus conventions: `.cursor/rules/stimulus_conventions.mdc`
- UI/design system: `.cursor/rules/ui-ux-design-guidelines.mdc`
- Testing philosophy: `.cursor/rules/testing.mdc`
