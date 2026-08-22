# Releasing agent-mesh

Agents install **only** releases that carry a signed Git tag from a key they
already trust. Pushing to `main` is no longer enough to reach the fleet — and
that is the point: write access to this repository should not equal root on
every machine in the mesh.

## One-time setup (maintainer)

Use a **dedicated** signing key, not your everyday SSH login key. It exists
for one job, can be kept offline, and can be replaced without touching how you
log into anything.

```bash
# 1. Create the release key
ssh-keygen -t ed25519 -f ~/.ssh/agent-mesh-release -C "release@moinsen.dev"

# 2. Tell git to sign tags with it
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/agent-mesh-release.pub

# 3. Publish the public half as the trust base
printf 'release@moinsen.dev %s\n' "$(cat ~/.ssh/agent-mesh-release.pub)" \
  > .github/allowed_signers
git add .github/allowed_signers
git commit -m "chore: add release signing key"
git push
```

Optionally add the same key to GitHub under *Settings → SSH and GPG keys → New
SSH key → Key type: **Signing key***. That makes tags show as "Verified" in the
web interface. It is cosmetic; agents verify against `allowed_signers`, not
against GitHub.

**Keep the private key safe.** Whoever holds it can reach every agent.

## Cutting a release

```bash
# 1. Version bump, committed as usual
echo "1.14.0" > VERSION
git add VERSION && git commit -m "chore: v1.14.0"

# 2. Add a MIGRATIONS.md section if agents must do something by hand

# 3. Sign the tag — this is what makes it a release
git tag -s v1.14.0 -m "agent-mesh v1.14.0"
git push origin main --follow-tags

# 4. Verify the way an agent will
git -c gpg.format=ssh \
    -c gpg.ssh.allowedSignersFile=.github/allowed_signers \
    verify-tag v1.14.0
```

Expected: `Good "git" signature for release@moinsen.dev`. Anything else and
the fleet will refuse the update — check it here, not on the agents.

The tag name must be `v` plus exactly the contents of `VERSION`. Agents read
`VERSION` from `origin/main`, then look for the matching tag.

## What agents do with it

1. Read `VERSION` from `origin/main`
2. Refuse anything **older** than what they run (downgrade protection — a
   tampered `main` could otherwise point at an old, validly signed release and
   reopen a patched hole)
3. Fetch tag `v<version>` and verify its signature against their local
   `trusted_signers`
4. Only then `git reset --hard` to **the tag** and install — the content comes
   from the signed object, never from `main`

Any failing step aborts the update and leaves the agent on its current
version, loudly.

## Rotating the signing key

1. Add the new key to `.github/allowed_signers` **next to** the old one, push
2. Sign the next release with the old key still listed, so agents can pick up
   the new trust base
3. Every agent runs `agent-mesh trust`, compares the diff and confirms
4. Once all agents are through, remove the old key and release again

Do not remove the old key in the same release that introduces the new one —
agents would reject the update that carries their new trust base.

## If the fleet is stuck

Symptom: agents report `Signatur von 'vX.Y.Z' NICHT vertrauenswürdig`.

```bash
agent-mesh trust --show      # what does this agent trust?
agent-mesh update            # full message, including git's reason
```

Usual causes: the tag was pushed unsigned, `VERSION` and the tag name disagree,
or the agent's trust base predates a key rotation.
