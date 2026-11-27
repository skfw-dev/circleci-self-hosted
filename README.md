# CircleCI Self-Hosted Runner on Docker

Run your CircleCI jobs on your own server. This kit starts
[CircleCI machine runner 3](https://circleci.com/docs/runner/install-machine-runner-3-on-docker/)
in a Docker container on a single host such as a VPS. One script asks for your
runner name and token and brings the runner up; a second script handles the
daily operations.

## Description

CircleCI normally runs jobs on its own cloud machines. A **self-hosted runner**
is an agent you run on your own machine: it polls CircleCI over outbound HTTPS,
claims the jobs addressed to it, runs them locally and sends the logs back. You
keep CircleCI's web app and pipelines, while the compute, the network location
and the installed tools are yours. Runner jobs use no compute credits, though
CircleCI requires at least one credit on the account for storage and network use.

What this kit contains:

| File | Purpose |
| --- | --- |
| `setup.sh` | Interactive or unattended installer |
| `runner.sh` | Daily operations: status, logs, doctor, update, scale |
| `lib/common.sh` | Helpers shared by both scripts |
| `compose.yaml` | The runner service |
| `compose.dood.yaml` | Optional overlay: let jobs use the host's Docker |
| `Dockerfile` | Upstream image plus `git`, SSH client and your packages |
| `docker/entrypoint.sh` | Checks required variables; unique name per replica |
| `.env.example` | Compose-level settings (not secret) |
| `runner.env.example` | Container environment: name, token, mode |
| `examples/circleci-config.yml` | Sample pipeline that targets the runner |

What it does beyond a bare `docker run` of the upstream image:

- **`checkout` works.** The upstream image has no `git` and no SSH client; this
  image adds both.
- **The token stays off the command line.** It is read from a hidden prompt, a
  file, standard input or an environment variable, never from a flag, because
  flags show up in `ps` and in shell history. Config files are written `600`.
- **A bad token is caught at install time.** The runner does not exit on a
  rejected token; it keeps retrying. `setup.sh` watches the log, reports the
  `401 Unauthorized` and stops the runner.
- **Stopping does not kill a running job.** The container gets 10 minutes
  (configurable) to finish its active job after `docker stop`.
- **Replicas get unique names.** Several containers can share one token, each
  with its own name on the Runners page.
- **Logs are rotated** (5 files of 10 MB) so they cannot fill the disk.

## Three names that are easy to confuse

| Name | Example | Where you set it | What it is |
| --- | --- | --- | --- |
| Namespace | `acme-ci` | CircleCI, once per organization | Your organization's prefix. Unique across all of CircleCI and shared with your orbs. |
| Resource class | `acme-ci/vps-x64` | CircleCI | A named pool of runners. Jobs ask for it with `resource_class`. |
| Runner name | `vps-runner-01` | `setup.sh` | A label for one machine in that pool. Any name you like. |

The **resource class token** ties a runner to its resource class, so the runner
itself is never told the namespace or resource class: the token carries them.

Why the namespace often looks random: it is unique across every CircleCI
organization, so short common names are usually taken, and each organization
can claim only one. If your organization already publishes orbs, it already has
a namespace and runners must use that same one. Only CircleCI support can
change it.

## Getting started

### Before you begin

You need:

- A Linux server (Ubuntu 18.04 or later is what CircleCI supports; x86_64 or
  ARM64) that you can reach over SSH, with `sudo`.
- To be an **organization admin** in CircleCI, with at least one credit on the
  account.
- Outbound HTTPS from the server to:
  - `runner.circleci.com`
  - `circleci-binary-releases.s3.amazonaws.com`
  - `circleci-tasks-prod.s3.us-east-1.amazonaws.com` (caches, workspaces, artifacts)
  - your Git host, for `checkout`

  No inbound port has to be opened.

### Step 1 - Install Docker on the server

Skip this if `docker compose version` already prints a version.

```sh
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"
```

Log out and back in so the group change applies, then check:

```sh
docker run --rm hello-world
docker compose version
```

Other install methods are in the
[Docker Engine documentation](https://docs.docker.com/engine/install/).

### Step 2 - Create the resource class and get its token

**In the web app:**

1. Open <https://app.circleci.com> and select **Runners** in the sidebar. The
   first time, an organization admin has to accept the runner terms.
2. Select **Create Resource Class**.
3. Enter the namespace (CircleCI suggests your organization name; lowercase
   letters, digits, `_` and `-`) and a resource class name (letters, digits,
   `:`, `_`, `-`, `+`), for example `acme-ci` and `vps-x64`.
4. Optionally add a description, then select **Save and continue**.
5. **Copy the token now.** It is displayed once and cannot be retrieved later.
   Choose the **Machine** tab if the page asks.

**Or with the CircleCI CLI:**

```sh
circleci namespace create <namespace> --org-id <your-organization-id>
circleci runner resource-class create <namespace>/<resource-class> "my VPS" --generate-token
```

Lost the token? Create another one for the same resource class:

```sh
circleci runner token create <namespace>/<resource-class> --nickname vps-01
```

The token is shown once, but it is not single-use: one token can start several
runners, and all of them serve that resource class.

### Step 3 - Copy the kit to the server

From your own computer:

```sh
scp circleci-self-hosted.zip user@your-server:~
```

On the server:

```sh
sudo apt-get install -y unzip
unzip circleci-self-hosted.zip
cd circleci-self-hosted
```

### Step 4 - Run the installer

```sh
./setup.sh
```

It asks for:

1. **Runner name** - press Enter to accept the server's hostname, or type a
   label such as `vps-runner-01`. Letters, digits and `. ( ) - _` are allowed.
2. **Resource class token** - paste the token from step 2. Nothing is echoed.
3. **Configure advanced options?** - answer `n` for the defaults (one runner,
   no resource limits). The options are described under
   [Configuration](#configuration).
4. **Write this configuration and start the runner?** - answer `y`.

The script then builds the image, starts the container and waits for CircleCI
to answer. The first start takes about half a minute because the runner
downloads its task agent. A successful run ends with:

```
 ok  The runner is polling CircleCI and the token was accepted.
```

If the token is wrong you get this instead, and the runner is stopped:

```
fail CircleCI rejected the token (401 Unauthorized). The runner was stopped.
```

### Step 5 - Check that CircleCI sees the runner

```sh
./runner.sh doctor
```

Every line should start with `ok`. Then open **Runners** in the CircleCI web
app and select your resource class: the runner name from step 4 is listed there.

### Step 6 - Send a job to the runner

In the repository you want to build, create `.circleci/config.yml`:

```yaml
version: 2.1

jobs:
  hello-runner:
    machine: true
    resource_class: <namespace>/<resource-class>
    steps:
      - checkout
      - run:
          name: Show where this job runs
          command: |
            echo "Runner host: $(hostname)"
            uname -srm
            git --version

workflows:
  verify-runner:
    jobs:
      - hello-runner
```

Replace `<namespace>/<resource-class>` with yours, for example
`acme-ci/vps-x64`. Both lines are required: `machine: true` and
`resource_class`. A `docker:` executor would send the job to CircleCI's cloud
instead.

Commit and push. In the CircleCI pipeline view the `hello-runner` job runs and
prints the container's hostname. Follow it from the server with:

```sh
./runner.sh logs
```

The runner is now installed. It starts again by itself after a reboot, as long
as Docker starts at boot (the default for the packages above).

## Unattended install

For provisioning scripts, pass everything as options:

```sh
./setup.sh --name vps-01 --token-file /root/cci-token --non-interactive

printf '%s' "$TOKEN" | ./setup.sh --name vps-01 --token-stdin \
    --replicas 2 --cpus 2 --memory 4G --non-interactive
```

The token can come from `--token-file`, `--token-stdin` or the
`CIRCLECI_RUNNER_API_AUTH_TOKEN` environment variable. `--token` is refused.
`--no-start` writes the configuration without building or starting anything.

## Configuration

Run `./setup.sh` again at any time; it offers the current values as defaults
and keeps the token if you press Enter at the token prompt.

| Option | Default | Meaning |
| --- | --- | --- |
| `--name NAME` | hostname | Label of this runner in CircleCI |
| `--mode MODE` | `continuous` | `continuous` keeps polling; `single-task` exits after one job and Docker restarts it |
| `--replicas N` | `1` | Runner containers. Each runs one job at a time |
| `--cpus N` | `0` (no limit) | CPU limit per container, for example `2` or `1.5` |
| `--memory SIZE` | `0` (no limit) | Memory limit per container, for example `4G` |
| `--max-run-time DUR` | `5h` | Longest a job may run, for example `1h30m` |
| `--extra-packages "..."` | none | Extra apt packages baked into the image |
| `--dood` / `--no-dood` | off | Mount the host's Docker socket (see [Security](#security)) |
| `--api-url URL` | circleci.com | CircleCI Server installations only |

Settings without an option live in the two files `setup.sh` writes. Edit them
and run `./runner.sh up` to apply:

- `.env` - `RUNNER_IMAGE_TAG`, `RUNNER_PIDS_LIMIT`, `RUNNER_STOP_GRACE_PERIOD`
- `runner.env` - `CIRCLECI_RUNNER_LOGGING_LEVEL`, `CIRCLECI_RUNNER_LOGGING_FORMAT`,
  and any other `CIRCLECI_RUNNER_*` variable from the
  [configuration reference](https://circleci.com/docs/runner/machine-runner-3-configuration-reference/)

### Adding build tools

Jobs run inside the runner container, so a tool a pipeline needs has to be in
the image. For apt packages:

```sh
./setup.sh --extra-packages "python3 build-essential jq"
```

For anything else, add `RUN` lines to the `runner` stage of the `Dockerfile`
and run `./runner.sh up`.

## Daily operations

```sh
./runner.sh status    # container state, CPU and memory snapshot
./runner.sh logs      # follow the runner logs
./runner.sh doctor    # check Docker, config, permissions, network, token
./runner.sh update    # pull the newest base image, rebuild, recreate
./runner.sh scale 3   # run three runner containers
./runner.sh restart   # drain, then start again
./runner.sh down      # drain and remove the container(s)
./runner.sh up        # build if needed and start
./runner.sh shell     # shell inside the runner container
```

## How it behaves

- **Jobs run inside the runner container**, not in a container per job.
- **One job per container.** For parallel jobs use `--replicas N` or
  `./runner.sh scale N`. The entrypoint appends the container ID to the runner
  name so each replica is unique.
- **The container is reused between jobs.** The job's working directory is
  removed after each job, but anything written elsewhere (under `$HOME` or
  `/tmp`, for example) stays until the container is recreated.
- **Stopping drains.** `docker stop` sends TERM; the runner finishes the active
  job and claims no new one. Docker waits `RUNNER_STOP_GRACE_PERIOD` before
  killing it.
- **`single-task` mode restarts the process, not the filesystem.** It does not
  give each job a clean environment.
- **Not available on self-hosted runners:** Docker layer caching, and the
  `CIRCLE_PREVIOUS_BUILD_NUM` variable.

## Troubleshooting

Start with `./runner.sh doctor`; it names the failing check.

| Symptom | Cause and fix |
| --- | --- |
| `401 (Unauthorized)` in the logs | The token is wrong or was deleted. Create a new token (step 2) and run `./setup.sh` again. |
| Job stays "Not running" in CircleCI | `resource_class` in `config.yml` does not match the token's resource class, the runner is down, or every runner is busy. Check `./runner.sh status`. |
| `Cannot reach the Docker daemon` | Docker is not running, or your user is not in the `docker` group. Log out and in after `usermod`, or use `sudo`. |
| `Cannot reach https://runner.circleci.com` | Outbound HTTPS is blocked by a firewall or proxy. |
| `git: command not found` or another missing tool | The tool is not in the image. See [Adding build tools](#adding-build-tools). |
| `checkout` fails with a host key or permission error | The project has no checkout key in CircleCI, or the Git host is unreachable from the server. |
| `--dood: /var/run/docker.sock has mode 600` | The socket is not group-accessible, so the overlay cannot work on this host. |
| Runner missing from the Runners page | It only appears once it has connected. Check `./runner.sh logs`. |

## Security

- **Any job on this runner can read the token.** Jobs run as the same user as
  the runner, and that user has passwordless `sudo` in the upstream image. Only
  connect repositories whose contributors you trust.
- **Do not use it for public projects that build forked pull requests.**
  CircleCI blocks that combination, because a fork could run arbitrary code on
  your server.
- `runner.env` holds the token. It is written `600`, listed in `.gitignore`
  and kept out of the image build context by `.dockerignore`. The token is
  still visible to anyone who can run `docker inspect` on the host.
- **`--dood` gives jobs root-equivalent access to the host.** It mounts
  `/var/run/docker.sock` so jobs can run `docker build` and `docker compose`
  against the host daemon. Leave it off unless you need it.
- `machine-3` is a moving tag. Pin `RUNNER_IMAGE_TAG` in `.env` for repeatable
  builds, and run `./runner.sh update` to pick up fixes.

## Uninstall

```sh
./runner.sh down
docker image rm circleci-self-hosted-runner:local
cd .. && rm -rf circleci-self-hosted
```

Then delete the token or the resource class in CircleCI so the token can no
longer be used:

```sh
circleci runner resource-class delete <namespace>/<resource-class> --force
```

## What was tested

Run on 2026-11-27 inside a Linux container against Docker 27.5.1 / Compose
2.33.0 and `circleci/runner-agent:machine-3` (runner 3.1.14), with a
deliberately invalid token:

| Check | Result |
| --- | --- |
| `shellcheck -x` on all scripts, `hadolint` on the Dockerfile | no findings |
| `setup.sh` unattended and through a pseudo-terminal | both files written with mode `600` |
| `--token`, a bad name, `--cpus` above the host count, a missing token | each refused with exit 1 |
| Start with an invalid token | setup reports `401 Unauthorized`, stops the runner, exits 1 |
| `runner.sh doctor` with that token | reports the 401, exits 1 |
| Image contents | `git 2.34.1`, `OpenSSH 8.9p1`, runs as `circleci`, PID 1 is an init |
| `runner.sh scale 2` | two containers with different runner names |
| `runner.sh down` on an idle runner | exits within 1 second of TERM |
| Container started with no token | entrypoint exits 64 with a message |
| Zip unpacked on Linux | scripts executable, LF line endings, `compose config` valid |

Not tested, because it needs a real token or a different host:

- A job actually being claimed and run, including `checkout` (steps 5 and 6
  with a valid token).
- Draining while a job is active.
- The `--dood` overlay end to end. The image build and the mount were
  exercised, but the test host's socket was `root:root 600`, so group access
  as on a standard `root:docker 660` socket could not be confirmed.
- CircleCI Server (`--api-url`).
- The Docker install commands in step 1 and the `circleci` CLI commands, which
  are quoted from the Docker and CircleCI documentation.

## References

- [Self-hosted runner overview](https://circleci.com/docs/runner/runner-overview/)
- [Runner concepts: namespaces, resource classes, tokens](https://circleci.com/docs/runner/runner-concepts/)
- [Install machine runner 3 on Docker](https://circleci.com/docs/runner/install-machine-runner-3-on-docker/)
- [Machine runner 3 configuration reference](https://circleci.com/docs/runner/machine-runner-3-configuration-reference/)

## License

Copyright 2026 skfw-dev. Licensed under the [Apache License 2.0](LICENSE).
