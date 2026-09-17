# Validating configuration templates in CI

Stop finding template typos in production. This job renders every HAProxy and nginx template the way the deploy will render it, then asks the actual binaries whether the result is valid — before anything is deployed.

```
$ ./scripts/validate.sh
HAProxy templates
  ok   templates/haproxy/db-proxy.cfg.template
nginx templates
  ok   templates/nginx/app.conf.template

All templates valid.
```

## The three things it checks

**1. Unsubstituted variables.** This is the failure worth building the job for. `envsubst` leaves any name it could not resolve as a literal `${BACKEND_IP}`, and `haproxy -c` then accepts the file — `"${BACKEND_IP}"` is a perfectly legal hostname as far as the parser is concerned. The config is syntactically valid and semantically wrong, which means it deploys cleanly and fails at runtime. Catching it is a `grep`, and it has to run before the syntax check, not after.

**2. HAProxy syntax** — `haproxy -c -f` on the rendered file.

**3. nginx syntax** — `nginx -t`, with the server blocks wrapped in a minimal `http{}` context and self-signed certificates generated per run. `nginx -t` refuses to parse a config whose `ssl_certificate` does not exist, so validating TLS-enabled templates requires *some* certificate; it does not require a real one.

## Two decisions that make it survive contact with reality

**Everything runs inside images that are already in the registry.** No `apt-get`, no `apk add`, no `pip install` anywhere in the job. This was originally forced by a runner with no internet route — only the internal registry was reachable — and it turned out to be the right design regardless: a validation job that installs packages is a job that breaks when a mirror is down, which is the exact moment you least want your safety net going red for unrelated reasons.

**`envsubst` gets an explicit variable list.** Bare `envsubst` substitutes *every* `$NAME` in the file. For nginx that is destructive: `$host`, `$remote_addr`, `$uri` and `$proxy_add_x_forwarded_for` are nginx's own variables and must survive into the output. Substituting them produces a config that passes `nginx -t` and serves wrong headers. The script derives the allowlist from the vars file, so adding a variable to the environment is enough — nobody has to remember this rule later.

## The self-test

A validator nobody tests is a validator that quietly stops working. `scripts/selftest.sh` injects each template in [`examples/broken/`](examples/broken/) and asserts that validation **fails**:

```
$ ./scripts/selftest.sh
  ok   syntax.cfg.template correctly rejected
  ok   unsubstituted.cfg.template correctly rejected

Self-test passed: every broken template was rejected.
```

The two cases are deliberately different: one is invalid syntax that `haproxy -c` catches, the other is valid syntax with an unresolved variable that only the grep catches. Together they prove both layers are alive.

## Layout

```
templates/haproxy/*.cfg.template   templates + vars.env
templates/nginx/*.conf.template
scripts/validate.sh                render → check unsubstituted → check syntax
scripts/selftest.sh                asserts broken input is rejected
examples/broken/                   deliberately broken templates
.github/workflows/validate-config.yml
```

The example templates are real ones: a HAProxy config fronting Patroni-managed PostgreSQL (health-checking the REST API on `/primary`, which is what makes failover invisible to clients) and a Redis primary behind a `tcp-check` conversation, plus an nginx site with TLS and an API proxy.

## Porting it

The workflow here is GitHub Actions; the original ran on Gitea Actions, and the only differences were the runner label and a registry login step in place of `docker pull`. The `::error file=...::` annotations work in both. All the logic is in `scripts/`, so any CI system that can run bash and docker will do.

Set `REGISTRY=registry.example.com` to pull the checker images from an internal mirror instead of Docker Hub.
