# Contributing to agent-mesh

Thanks for being here. The short and honest version first:

## We are not accepting pull requests right now

agent-mesh is young and moving fast. The framework installs itself with
`curl | bash`, runs as a service on other people's machines, holds private
keys, and updates itself every hour. That means a change merged here reaches
every machine in the mesh within the hour — including yours.

At this stage we cannot review outside code to the depth it deserves. Half
reviewing a pull request would be worse than not taking it at all. So please:
**no pull requests for now.**

## What we would love instead: issues

A good issue is worth more to us than a patch. It tells us where things break
and lets us fit the fix into the wider picture.

**Report a bug** → https://github.com/moinsen-dev/agent-mesh/issues/new

Useful things to include:

- Operating system and shell (`uname -a`, `bash --version`)
- What you did, what happened, what you expected
- The output of `agent-mesh doctor` — it explains most failures on its own
- For update problems: `agent-mesh update --check`

**Feature idea** → also an issue, ideally with the use case behind it. The
*why* matters more than the *how*: we may build it differently than you
suggest, but only if we understand what you are actually after.

**Question** → an issue as well. If you could not find something, the
documentation is usually what is missing, not your understanding.

## Security issues

**Please do not open a public issue.** Email
[developer@moinsen.dev](mailto:developer@moinsen.dev) or use GitHub Security
Advisories:
https://github.com/moinsen-dev/agent-mesh/security/advisories/new

Because of the self-update mechanism, a vulnerability here reaches every
running agent immediately. We respond accordingly, and we will credit you in
the release notes if you want us to.

## If you want to bend it to your own needs

Please do — that is what it is for. The clean path is **your own mesh**
rather than a pull request:

```bash
export AGENT_MESH_GH_ORG="your-github-name"
agent-mesh connect          # creates your own private mesh repo
```

Your fork, your rules, your data. If something useful comes out of it, tell
us about it in an issue.

## Will this change?

Yes. Once the framework settles down, once there are tests that can carry an
outside change, and once the security groundwork is in place, we will open up
for pull requests. It will say so here when we do — and whoever contributed
issues in the meantime is the first person we will ask.

Until then: issues are welcome, and they get read.
