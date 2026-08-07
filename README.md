# Tangled Mirror

Keep a [Tangled](https://tangled.org) repo in sync with one that lives on GitHub.

Tangled is a social coding platform built on the AT Protocol. If GitHub is your
project's home and you want a copy visible on Tangled, this action
handles the push. It checks the knot's host key, sends only the refs you ask for,
and won't delete anything unless you tell it to.

## Quick start

```yaml
name: Mirror to Tangled

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read

jobs:
  mirror:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
        with:
          fetch-depth: 0          # required, knots reject shallow pushes

      - uses: sethcottle/tangled-mirror@v1
        with:
          repo: your-handle.bsky.social/your-repo
          ssh-key: ${{ secrets.TANGLED_SSH_KEY }}
          known-hosts: ${{ vars.TANGLED_KNOWN_HOSTS }}
```

## Setup

### 1. Create the repo on Tangled

The action pushes to a repo that already exists and won't create one for you, so
make it first. Copy the SSH remote Tangled gives you. Everything after the colon
is the value for the `repo` input.

Tangled's web UI shows repo paths with a leading `@`, as in
`@seth.bsky.social/my-repo`, but the SSH remote drops it. The action strips a
leading `@` if you paste one, so either form works.

### 2. Make an SSH key just for CI

Generate a separate key rather than reusing the one on your laptop, so you can
revoke it on its own later.

```bash
ssh-keygen -t ed25519 -f ./tangled-ci -C "tangled-ci" -N ""
```

You'll get two files: `tangled-ci` (private) and `tangled-ci.pub` (public).

### 3. Register the public half with Tangled

Paste the contents of `tangled-ci.pub` at `https://tangled.org/settings/keys`.

> Tangled doesn't have per-repository deploy keys the way GitHub does. Keys are
> registered against your account, so this key can push to any repo you own on
> that knot, and there's no way to narrow its scope. This is a Tangled
> limitation rather than something the action can work around, but you should
> know about it before putting a key into CI.

### 4. Store the private half as a GitHub secret

If you have the `gh` CLI, this is one command from your repo root:

```bash
gh secret set TANGLED_SSH_KEY < ./tangled-ci
```

Otherwise, go to Settings, then Secrets and variables, then Actions, and add a
repository secret named `TANGLED_SSH_KEY` containing the contents of
`tangled-ci`, including the `BEGIN` and `END` lines.

Once GitHub has it you can remove your local copy with
`rm tangled-ci tangled-ci.pub`.

### 5. Pin the knot's host key

Without this, every run trusts whatever host answers at `tangled.org`. Run the
following from a machine you trust:

```bash
ssh-keyscan -t ed25519 tangled.org
```

Copy the line it prints. Back in Settings, Secrets and variables, Actions,
switch to the **Variables** tab and add `TANGLED_KNOWN_HOSTS` with that line as
its value.

A variable works here rather than a secret because a host key isn't secret. If
the knot's key ever changes, the build fails instead of silently accepting the
new one.

For a self-hosted knot, scan that host instead, and pass `-p` if it listens
somewhere other than 22:

```bash
ssh-keyscan -t ed25519 -p 2222 knot.example.com
```

### 6. Add the workflow

Copy the Quick start block above into `.github/workflows/mirror.yml` and fill in
your `repo` value. Adding `dry-run: true` for the first run will show you what
would be pushed without pushing it.

## Automatic and manual runs

Most setups end up with two workflows rather than one.

The automatic workflow runs on every push to `main` and sticks to safe
operations, with no forcing, pruning, or tag rewrites.

The manual workflow is a form in the Actions tab, and it's where the destructive
options live. Keeping them there rather than in the automatic workflow means
`force` and `prune` are a deliberate choice each time you run, instead of
settings that sit in a committed file and fire on the next push.

`workflow_dispatch` inputs render as form controls, so the block below shows up
as checkboxes and a dropdown:

```yaml
name: Mirror to Tangled (manual)

on:
  workflow_dispatch:
    inputs:
      dry_run:
        description: 'Preview only, push nothing'
        type: boolean
        default: true
      branches:
        description: 'Branches to push. Blank = current branch. * = all.'
        type: string
        default: ''
      on_divergence:
        type: choice
        options: [warn, fail, ignore]
        default: warn
      force_tags:
        description: 'Let tags move (needed for rolling tags such as nightly)'
        type: boolean
        default: false
      prune:
        description: 'Delete refs absent locally. Requires branches = *'
        type: boolean
        default: false

permissions:
  contents: read

jobs:
  mirror:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
        with:
          fetch-depth: 0

      - uses: sethcottle/tangled-mirror@v1
        with:
          repo: seth.bsky.social/my-repo
          ssh-key: ${{ secrets.TANGLED_SSH_KEY }}
          known-hosts: ${{ vars.TANGLED_KNOWN_HOSTS }}
          branches: ${{ inputs.branches }}
          on-divergence: ${{ inputs.on_divergence }}
          force-tags: ${{ inputs.force_tags }}
          prune: ${{ inputs.prune }}
          dry-run: ${{ inputs.dry_run }}
```

`dry_run` defaults to true because the manual form is where the destructive
options are, and a preview is usually the right first step.

Both workflows are in this repo under `.github/workflows/` if you'd rather copy
them directly. They're guarded by `if: vars.TANGLED_REPO != ''` so they stay
inert until you set that variable.

Note that ticking `prune` without setting `branches` to `*` gets rejected,
because pruning against a single branch would remove every other branch on the
knot.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `repo` | yes | | Path on the knot, exactly as it appears after the colon in the SSH remote. Works with a handle path (`seth.bsky.social/my-repo`) or a DID (`did:plc:abc123/my-repo`). |
| `ssh-key` | yes | | Private SSH key registered on the account that owns the repo. Always pass this from a secret. |
| `knot` | no | `tangled.org` | Knot hostname. Change it for a self-hosted knot. |
| `port` | no | `22` | SSH port on the knot. |
| `known-hosts` | no | `""` | Pinned host key in `known_hosts` format. Strongly recommended. |
| `skip-ci` | no | `false` | Send the `skip-ci` push option so Spindle doesn't run pipelines for this push. |
| `address-family` | no | `auto` | Restrict SSH to `inet` (IPv4) or `inet6`. Only needed for a self-hosted knot with broken IPv6. |
| `branches` | no | current branch | Branches to push, separated by spaces or newlines. `*` mirrors every branch. |
| `tags` | no | `true` | Push tags as well. |
| `on-divergence` | no | `warn` | What to do when the knot has refs you aren't pushing, or refs at different commits. One of `warn`, `fail`, `ignore`. |
| `allow-lfs` | no | `false` | Push a repo that uses Git LFS. See the LFS section. |
| `mirror` | no | `false` | **Deletes things.** Makes the knot an exact replica. Shorthand for `branches: "*"` plus `prune`, `force`, and `force-tags`, and it overrides all four. |
| `prune` | no | `false` | **Deletes things.** Removes branches and tags on the knot that no longer exist locally. Requires `branches: "*"`. |
| `force` | no | `false` | **Deletes things.** Allows non-fast-forward updates. |
| `force-tags` | no | `false` | **Overwrites tags.** Lets tags move on the knot. You need this for rolling tags like `nightly`. |
| `dry-run` | no | `false` | Show what would be pushed without pushing it. |

### Output

| Output | Description |
| --- | --- |
| `pushed` | Space-separated list of what was pushed. |

## What can destroy work on the Tangled side

By default the action only adds commits or fast-forwards, and a push that would
throw away work gets rejected instead. Four inputs change that, and each one
means accepting that work on the Tangled side can disappear.

**`force: true`** discards commits that exist only on the knot, with no prompt
and no way to recover them. Use it only when GitHub is genuinely the single
source of truth and you're fine with anything pushed straight to Tangled being
lost.

**`prune: true`** deletes branches and tags on the knot that aren't in your local
set. On Tangled that can include a contributor's branch behind an open
branch-based pull request, which breaks the PR without notifying either of you.

**`force-tags: true`** overwrites an existing tag on the knot with your version.
Rolling tags need it, but it will also flatten a tag someone created on Tangled
that you don't have locally.

**`mirror: true`** turns on all three plus `branches: "*"`. See below.

With all four left off, a disagreement between the two sides shows up as a failed
build rather than as lost work.

### Making the knot an exact replica

If Tangled is a read-only copy and nobody ever contributes there, you probably
want it to match GitHub exactly instead of drifting apart. `mirror: true` does
that in a single input: the knot ends up with your exact set of branches and
tags, with extras deleted, diverged branches overwritten, and tags moved to match
yours.

```yaml
- uses: sethcottle/tangled-mirror@v1
  with:
    repo: seth.bsky.social/my-repo
    ssh-key: ${{ secrets.TANGLED_SSH_KEY }}
    known-hosts: ${{ vars.TANGLED_KNOWN_HOSTS }}
    mirror: true
```

The end result matches `git push --mirror`, without two of its behaviors: your
remote-tracking refs don't get copied onto the knot, and the divergence report
runs first, so the log lists every branch about to be deleted and every ref about
to be overwritten.

Don't use this if anyone might open a pull request on the Tangled side, since
their branch will be gone on the next run.

## When Tangled changes

The default won't overwrite, so a knot that has moved ahead of you fails the next
run instead of getting steamrolled. The `on-divergence` check covers the case a
push result would never mention: refs your push doesn't touch at all, such as a
contributor's branch or a tag someone added on Tangled.

Pulling changes back from Tangled is manual. Tangled pull requests give you a
patch URL:

```bash
curl -sL <patch_url> | git am
```

The work lands in your history with the contributor's authorship intact. Push to
GitHub normally and it reaches Tangled again on the next mirror run.

There's no two-way sync, which is a deliberate choice. Automating both directions
requires loop-breaking logic, and when the same file changes on both sides
nothing can decide which version wins, since neither side is authoritative.
GitLab, Gitea, and GitHub's own importer all mirror in one direction per repo for
the same reason.

## Spindle CI on the Tangled side

Tangled has its own CI, Spindle, which runs workflows from `.tangled/workflows`
and triggers on push. If the repository you're mirroring happens to contain that
directory, every mirror push starts a Spindle run, re-testing code your GitHub
CI already tested.

Setting `skip-ci: true` sends Tangled's documented `skip-ci` push option so those
runs don't start:

```yaml
- uses: sethcottle/tangled-mirror@v1
  with:
    repo: seth.bsky.social/my-repo
    ssh-key: ${{ secrets.TANGLED_SSH_KEY }}
    known-hosts: ${{ vars.TANGLED_KNOWN_HOSTS }}
    skip-ci: true
```

It defaults to off, because a repo with `.tangled/workflows` in it usually has
that on purpose. Leave it off unless you're seeing duplicate CI runs.

If the knot doesn't accept push options, the action says so and points at
`skip-ci: false` rather than surfacing a raw git error.

`skip-ci` is ignored during a `dry-run`. A dry run sends no pack, and a knot
answers a push option in that situation with `malformed pack stream`, which
reads like an unrelated failure. Nothing can trigger a pipeline during a dry run
anyway, so the action drops the option and logs a notice.

## Git LFS

The action refuses LFS repositories unless you opt in, because it pushes LFS
pointer files but not the objects behind them. The mirror would look complete
while missing the actual file contents. Set `allow-lfs: true` if you're handling
the objects another way.

## Examples

**Mirror every branch and tag, including deletions.** Read the section above
first, since `prune` can remove contributor branches:

```yaml
- uses: sethcottle/tangled-mirror@v1
  with:
    repo: seth.bsky.social/my-repo
    ssh-key: ${{ secrets.TANGLED_SSH_KEY }}
    known-hosts: ${{ vars.TANGLED_KNOWN_HOSTS }}
    branches: '*'
    prune: true
```

**A repo with a rolling `nightly` tag.** Without `force-tags` the run gets
rejected, because git won't move an existing tag and the push is atomic:

```yaml
- uses: sethcottle/tangled-mirror@v1
  with:
    repo: seth.bsky.social/my-repo
    ssh-key: ${{ secrets.TANGLED_SSH_KEY }}
    known-hosts: ${{ vars.TANGLED_KNOWN_HOSTS }}
    force-tags: true
```

**Treat any divergence as a build failure:**

```yaml
- uses: sethcottle/tangled-mirror@v1
  with:
    repo: seth.bsky.social/my-repo
    ssh-key: ${{ secrets.TANGLED_SSH_KEY }}
    known-hosts: ${{ vars.TANGLED_KNOWN_HOSTS }}
    on-divergence: fail
```

**Mirror on stable releases only:**

```yaml
on:
  release:
    types: [published]

# ...
- uses: sethcottle/tangled-mirror@v1
  with:
    repo: seth.bsky.social/my-repo
    ssh-key: ${{ secrets.TANGLED_SSH_KEY }}
    branches: main
```

**Self-hosted knot on a different port:**

```yaml
- uses: sethcottle/tangled-mirror@v1
  with:
    repo: seth.bsky.social/my-repo
    ssh-key: ${{ secrets.TANGLED_SSH_KEY }}
    known-hosts: ${{ vars.KNOT_KNOWN_HOSTS }}
    knot: knot.example.com
    port: 2222
```

Nothing about the knot hostname is assumed anywhere. The remote, the host key
lookup, and the URL in the rejected-key error message all come from the `knot`
input.

One thing that catches people out on a custom port: OpenSSH looks a host up as
`[host]:port` when the port isn't 22, and that won't match a plain `host` entry
in `known_hosts`. If you captured your key with `ssh-keyscan knot.example.com`
and no `-p`, you'd have the plain form and verification would fail. The action
writes both forms when `port` isn't 22, so either works.

## How it works

**Host key verification.** The action builds a `known_hosts` file scoped to the
single `git push` it runs, using `GIT_SSH_COMMAND`. Nothing is written to
`~/.ssh`, so later steps in the job don't inherit the key or a loosened host
policy. If you skip `known-hosts`, it falls back to `ssh-keyscan` and warns,
which trusts the host on first contact every run.

**Explicit refspecs.** The action pushes the refspecs you configured and nothing
else. It avoids `git push --mirror`, which force-updates every ref under `refs/`,
deletes remote refs that aren't local, and copies `refs/remotes/*` onto the
mirror, since a CI checkout carries remote-tracking refs.

The deletion behavior matters more on Tangled than it might elsewhere. Tangled
supports branch-based pull requests, where the contributor's branch lives inside
your repo, so a mirror that removes unrecognized refs will delete that branch and
break the PR. This action leaves refs it wasn't told about alone unless you turn
on `prune`.

**Scoped deletions.** `prune: true` requires `branches: "*"`, because pruning
against a specific branch list would remove every other branch on the knot.
Pruning never touches anything outside `refs/heads` and `refs/tags`.

**No implicit checkout.** The action operates on whatever is already in the
workspace and won't re-checkout, so it can't discard work from earlier steps.

**Key handling.** The private key goes to a temp file created under `umask 077`
and is removed by an `EXIT` trap whether the push succeeds or fails. Composite
actions can't declare post-run cleanup steps, so the trap is what guarantees it.

## Troubleshooting

**`this ssh key doesn't match any key published by the accounts that may push here`**

The knot accepted the connection but the key isn't registered to an account with
push access. Add the public half at `https://tangled.org/settings/keys` on the
account that owns the repo. This is easy to hit when an SSH agent offers several
keys, since the connection succeeds on one key and the push is then judged
against it.

**`shallow update not allowed`**

Set `fetch-depth: 0` on `actions/checkout`. The default of `1` produces a shallow
clone, which knots reject.

**`'ssh-key' is empty`**

Usually a `pull_request` run from a fork, since GitHub doesn't expose secrets to
those. Mirror on `push` or `release` instead.

**`These tags point at something else on the knot`**

One of your tags disagrees with the knot's copy, typically a rolling tag like
`nightly` that CI re-points on every build. Git won't move an existing tag
without force, and because this push is atomic that single rejection takes the
branches with it. Set `force-tags: true`, or realign the tag locally.

**`The knot has commits that are not in this history`**

Someone pushed to Tangled directly. Look at what's there before deciding:

```bash
git fetch <remote> '+refs/heads/*:refs/tangled/*' && git log HEAD..refs/tangled/main
```

Then either merge it into GitHub or set `force: true` to discard it permanently.

**Nothing pushed, no error**

Check whether `dry-run` is still set.

## License

MIT
