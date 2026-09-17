# Runtime secrets: Vault layout

The bundle in this directory gets a *machine* to a working state. It is not how a *service* receives its secrets at deploy time. This is the layout that replaced hand-edited `.env` files on production hosts.

## Mount per environment, not per service

```
vault/
  infra-prod/      kv-v2
  infra-staging/   kv-v2
  infra-dev/       kv-v2
```

One mount per environment, with identical key paths inside each:

```
infra-prod/data/api          DATABASE_URL, REDIS_URL, JWT_SECRET, …
infra-prod/data/worker       DATABASE_URL, QUEUE_URL, …
infra-prod/data/shared       values several services need
```

The reason for keeping the *shape* identical across environments is that it makes the deploy pipeline environment-agnostic: the same job, parameterised by mount name, fetches the same key paths. A staging deploy that works is then evidence that a production deploy will work, rather than evidence about staging only.

The corollary is worth stating: adding a key to production and not to staging breaks that property silently. Add to every environment, even where the value is a placeholder.

## AppRole for CI, tokens for nobody

CI authenticates with AppRole:

- `role_id` is not secret and lives in the pipeline definition
- `secret_id` is a CI secret, issued with a TTL and a use limit
- the resulting token is short-lived and scoped to one mount

What this replaces is a long-lived token pasted into CI settings — which nobody rotates, which is readable by everyone with repository admin, and which grants whatever it granted on the day it was created.

A root token should exist only during bootstrap and be revoked when it ends. If a root token is in a chat log, in a runbook, or in someone's notes, it is no longer a root token — it is a shared password with unlimited scope.

## Policies

```hcl
# CI reads one environment. It cannot write, and it cannot see the others.
path "infra-prod/data/*" {
  capabilities = ["read"]
}
path "infra-prod/metadata/*" {
  capabilities = ["list"]
}
```

Write access belongs to humans and to the migration tooling, not to a deploy job. A pipeline that can write secrets is a pipeline that can overwrite them, and a bad rollout then takes the credentials with it.

## Pull at deploy, not bake into images

The deploy step fetches secrets and renders the environment file on the target host, with the file mode set before the values are written. Baking secrets into an image means every registry copy holds them and every rollback resurrects the old values.

```bash
vault kv get -format=json "$MOUNT/api" \
  | jq -r '.data.data | to_entries[] | "\(.key)=\(.value)"' \
  > /etc/app/api.env
chmod 600 /etc/app/api.env
```

Create the file with a restrictive mode *first* — `install -m 600 /dev/null /etc/app/api.env` — if there is any chance another process reads that directory between the two commands.

## What breaks, based on having broken it

**Vault being down blocks deploys.** That is the correct behaviour, but only if you know it in advance and have a break-glass path. The encrypted bundle here is that path.

**A key present in one environment and missing in another** surfaces as a service that starts and then fails on first use. Rendering the environment file should fail loudly on a missing key rather than emitting an empty value.

**Rotation is not done until every consumer has restarted.** A rotated secret with a process still holding the old value in memory is a rotation that will fail at an unpredictable time — usually the next unrelated restart, which makes the cause hard to see.
