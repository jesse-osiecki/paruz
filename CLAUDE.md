# Repo conventions

Standing rules for any agent working in this repository. Follow them exactly.

## Commit / PR attribution
- Do NOT add `Co-Authored-By: Claude` (or any AI/Claude co-author) trailer to
  commit messages or PR descriptions.
- Do NOT add "Generated with Claude", "🤖", or any similar AI-attribution line.
- Commits and PRs are authored solely by the human, using the repo's default
  git identity.

## No personal / environment-revealing details
- Do NOT commit personally-identifying or environment-specific content in code,
  comments, docs, or commit messages.
- No personal absolute paths (`/home/<user>`, etc.) — use `$HOME`, `~`, or a
  neutral placeholder.
- No machine hostnames, hardware specs (core count, RAM, disk type), or exact
  local tool/package version inventories presented as "what's on my machine".
- No "verified on my host / measured on my box / verified empirically against
  my libvirt X.Y" framing. State technical reasoning impersonally and keep it
  portable; timings are "approximate, hardware-dependent".
- Exception: the `PKGBUILD` `Maintainer:` line is a conventional public
  package-maintainer field and stays as-is.
